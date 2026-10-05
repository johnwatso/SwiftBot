import Foundation

struct MeshJobPollRequest: Codable, Sendable {
    let nodeName: String
    let leaderTerm: Int
    let supportedKinds: [MeshJobKind]
    let maximumJobs: Int

    init(nodeName: String, leaderTerm: Int, supportedKinds: [MeshJobKind] = MeshJobKind.allCases, maximumJobs: Int = 1) {
        self.nodeName = nodeName
        self.leaderTerm = leaderTerm
        self.supportedKinds = supportedKinds
        self.maximumJobs = maximumJobs
    }
}

struct MeshJobPollResponse: Codable, Sendable {
    let leaderTerm: Int
    let jobs: [MeshJobRequestEnvelope]
}

struct MeshJobResultSubmission: Codable, Sendable {
    let nodeName: String
    let inputHash: String
    let response: MeshJobResponseEnvelope
}

/// Primary-side dispatch ledger. Workers poll and submit results over their
/// outbound authenticated connection, so dispatch never needs to connect back
/// through a worker's home router. The transport encrypts both response types.
actor MeshOutboundJobQueue {
    static let fileName = "mesh-outbound-jobs.json"

    private struct Assignment: Codable {
        let workerNodeName: String
        let request: MeshJobRequestEnvelope
        var deliveryAttempt: Int
        var lastDispatchedAt: Date?
        var response: MeshJobResponseEnvelope?
        var updatedAt: Date
    }

    private struct Snapshot: Codable {
        let assignments: [Assignment]
    }

    private let storageURL: URL?
    private let maximumPendingJobs: Int
    private let maximumStoredRecords: Int
    private let redeliveryInterval: TimeInterval
    private let retention: TimeInterval
    private var assignments: [UUID: Assignment] = [:]
    private var waiters: [UUID: [CheckedContinuation<MeshJobResponseEnvelope, Never>]] = [:]
    private var expirations: [UUID: Task<Void, Never>] = [:]
    private var highestObservedTerm = 0

    init(
        storageURL: URL? = nil,
        maximumPendingJobs: Int = 32,
        maximumStoredRecords: Int = 128,
        redeliveryInterval: TimeInterval = 15,
        retention: TimeInterval = 24 * 60 * 60
    ) {
        self.storageURL = storageURL
        self.maximumPendingJobs = max(1, maximumPendingJobs)
        self.maximumStoredRecords = max(maximumPendingJobs, maximumStoredRecords)
        self.redeliveryInterval = max(1, redeliveryInterval)
        self.retention = max(60, retention)
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            let now = Date()
            for assignment in snapshot.assignments.sorted(by: { $0.updatedAt > $1.updatedAt })
                .prefix(self.maximumStoredRecords) where now.timeIntervalSince(assignment.updatedAt) < self.retention {
                assignments[assignment.request.jobID] = assignment
            }
        }
    }

    var pendingJobCount: Int { assignments.values.filter { $0.response == nil }.count }

    func enqueue(
        nodeName: String,
        request: MeshJobRequestEnvelope,
        currentLeaderTerm: @escaping MeshJobLedger.LeaderTermProvider
    ) async -> MeshJobResponseEnvelope {
        observeLeadership(term: await currentLeaderTerm())
        guard request.leaderTerm == highestObservedTerm else { return reply(request, .staleLeadership) }
        guard request.hasValidInputHash,
              request.payload.count <= MeshJobLedger.maximumPayloadBytes,
              request.attempt > 0,
              request.deadline.timeIntervalSinceNow <= 24 * 60 * 60,
              !nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reply(request, .invalidRequest)
        }
        pruneAndExpire()
        if let assignment = assignments[request.jobID] {
            guard assignment.workerNodeName.caseInsensitiveCompare(nodeName) == .orderedSame,
                  matches(assignment.request, request) else { return reply(request, .conflictingJob) }
            if let response = assignment.response { return response }
        } else {
            guard request.deadline > Date() else { return reply(request, .expired) }
            guard pendingJobCount < maximumPendingJobs else { return reply(request, .busy) }
            assignments[request.jobID] = Assignment(
                workerNodeName: nodeName, request: request,
                deliveryAttempt: request.attempt - 1, lastDispatchedAt: nil,
                response: nil, updatedAt: Date()
            )
            do {
                try persist()
            } catch {
                assignments.removeValue(forKey: request.jobID)
                return reply(request, .storageUnavailable)
            }
        }
        armExpiry(for: request)
        let response = await withCheckedContinuation { continuation in
            waiters[request.jobID, default: []].append(continuation)
        }
        observeLeadership(term: await currentLeaderTerm())
        return request.leaderTerm == highestObservedTerm ? response : reply(request, .staleLeadership)
    }

    /// A failed result POST is safe: polling redelivers the same job ID and the
    /// worker's ledger returns the persisted result rather than recomputing.
    func poll(_ request: MeshJobPollRequest, currentLeaderTerm: Int) -> MeshJobPollResponse {
        observeLeadership(term: currentLeaderTerm)
        pruneAndExpire()
        guard request.leaderTerm == highestObservedTerm else {
            return MeshJobPollResponse(leaderTerm: highestObservedTerm, jobs: [])
        }
        let now = Date()
        let candidates = assignments.values.filter {
            $0.response == nil && $0.request.leaderTerm == highestObservedTerm &&
                $0.workerNodeName.caseInsensitiveCompare(request.nodeName) == .orderedSame &&
                request.supportedKinds.contains($0.request.kind) &&
                ($0.lastDispatchedAt == nil || now.timeIntervalSince($0.lastDispatchedAt!) >= redeliveryInterval)
        }.sorted { $0.request.deadline < $1.request.deadline }
        var jobs: [MeshJobRequestEnvelope] = []
        // One response stays comfortably below the mesh HTTP size ceiling.
        for var assignment in candidates.prefix(max(0, min(1, request.maximumJobs))) {
            assignment.deliveryAttempt += 1
            assignment.lastDispatchedAt = now
            assignment.updatedAt = now
            assignments[assignment.request.jobID] = assignment
            jobs.append(assignment.request.retry(attempt: assignment.deliveryAttempt))
        }
        do {
            try persist()
        } catch {
            return MeshJobPollResponse(leaderTerm: highestObservedTerm, jobs: [])
        }
        return MeshJobPollResponse(leaderTerm: highestObservedTerm, jobs: jobs)
    }

    /// Completed jobs are retained to make repeated submissions idempotent.
    /// A result from a different worker, input or leadership term is rejected.
    @discardableResult
    func complete(_ submission: MeshJobResultSubmission, currentLeaderTerm: Int) -> Bool {
        observeLeadership(term: currentLeaderTerm)
        pruneAndExpire()
        let response = submission.response
        guard var assignment = assignments[response.jobID],
              assignment.workerNodeName.caseInsensitiveCompare(submission.nodeName) == .orderedSame,
              assignment.request.inputHash == submission.inputHash,
              assignment.request.leaderTerm == highestObservedTerm,
              response.leaderTerm == highestObservedTerm,
              response.currentLeaderTerm == highestObservedTerm,
              response.result.map({ $0.count <= MeshJobLedger.maximumResultBytes }) ?? true else { return false }
        if let existing = assignment.response { return existing == response }
        guard response.status != .running && response.status != .retryable else { return false }
        guard (response.status == .completed) == (response.result != nil) else { return false }
        assignment.response = response
        assignment.updatedAt = Date()
        assignments[response.jobID] = assignment
        do {
            try persist()
        } catch {
            assignment.response = nil
            assignments[response.jobID] = assignment
            return false
        }
        resolve(response.jobID, response: response)
        return true
    }

    func observeLeadership(term: Int) {
        guard term > highestObservedTerm else { return }
        highestObservedTerm = term
        for assignment in assignments.values where assignment.response == nil && assignment.request.leaderTerm < term {
            terminate(assignment.request.jobID, status: .staleLeadership)
        }
    }

    func cancel(jobID: UUID, currentLeaderTerm: Int) -> MeshJobResponseEnvelope? {
        observeLeadership(term: currentLeaderTerm)
        guard let assignment = assignments[jobID], assignment.request.leaderTerm == highestObservedTerm else { return nil }
        if assignment.response == nil { terminate(jobID, status: .cancelled) }
        return assignments[jobID]?.response
    }

    func status(jobID: UUID, currentLeaderTerm: Int) -> MeshJobResponseEnvelope? {
        observeLeadership(term: currentLeaderTerm)
        pruneAndExpire()
        guard let assignment = assignments[jobID] else { return nil }
        guard assignment.request.leaderTerm == highestObservedTerm else { return reply(assignment.request, .staleLeadership) }
        return assignment.response ?? reply(assignment.request, .running)
    }

    private func armExpiry(for request: MeshJobRequestEnvelope) {
        guard expirations[request.jobID] == nil else { return }
        let remaining = max(0, min(request.deadline.timeIntervalSinceNow, 24 * 60 * 60))
        expirations[request.jobID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                await self?.terminate(request.jobID, status: .expired)
            } catch { }
        }
    }

    private func terminate(_ jobID: UUID, status: MeshJobStatus) {
        guard var assignment = assignments[jobID], assignment.response == nil else { return }
        let response = reply(assignment.request, status)
        assignment.response = response
        assignment.updatedAt = Date()
        assignments[jobID] = assignment
        try? persist()
        resolve(jobID, response: response)
    }

    private func resolve(_ jobID: UUID, response: MeshJobResponseEnvelope) {
        expirations.removeValue(forKey: jobID)?.cancel()
        for waiter in waiters.removeValue(forKey: jobID) ?? [] { waiter.resume(returning: response) }
    }

    private func pruneAndExpire() {
        let now = Date()
        for assignment in assignments.values where assignment.response == nil && assignment.request.deadline <= now {
            terminate(assignment.request.jobID, status: .expired)
        }
        assignments = assignments.filter {
            $0.value.response == nil || now.timeIntervalSince($0.value.updatedAt) < retention
        }
        let excess = max(0, assignments.count - maximumStoredRecords)
        for assignment in assignments.values.filter({ $0.response != nil })
            .sorted(by: { $0.updatedAt < $1.updatedAt }).prefix(excess) {
            assignments.removeValue(forKey: assignment.request.jobID)
        }
    }

    private func matches(_ lhs: MeshJobRequestEnvelope, _ rhs: MeshJobRequestEnvelope) -> Bool {
        lhs.jobID == rhs.jobID && lhs.originNodeName == rhs.originNodeName &&
            lhs.leaderTerm == rhs.leaderTerm && lhs.kind == rhs.kind &&
            lhs.inputHash == rhs.inputHash && lhs.deadline == rhs.deadline
    }

    private func reply(_ request: MeshJobRequestEnvelope, _ status: MeshJobStatus) -> MeshJobResponseEnvelope {
        MeshJobResponseEnvelope(
            jobID: request.jobID, leaderTerm: request.leaderTerm,
            currentLeaderTerm: highestObservedTerm, status: status, result: nil
        )
    }

    private func persist() throws {
        guard let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(assignments: assignments.values.sorted {
            $0.request.jobID.uuidString < $1.request.jobID.uuidString
        }))
        try data.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }
}
