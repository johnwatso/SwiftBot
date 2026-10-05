import CryptoKit
import Foundation

enum MeshJobKind: String, Codable, Sendable, CaseIterable {
    case aiReply
    case wikiLookup
    case playlistImport
}

/// Transport-neutral computation request. The active Primary owns the job ID;
/// every retry retains that ID and input hash. Workers never execute bot effects.
struct MeshJobRequestEnvelope: Codable, Sendable, Equatable {
    let jobID: UUID
    let originNodeName: String
    let leaderTerm: Int
    let kind: MeshJobKind
    let deadline: Date
    let attempt: Int
    let inputHash: String
    let payload: Data

    init(
        jobID: UUID = UUID(),
        originNodeName: String,
        leaderTerm: Int,
        kind: MeshJobKind,
        deadline: Date,
        attempt: Int = 1,
        payload: Data
    ) {
        self.jobID = jobID
        self.originNodeName = originNodeName
        self.leaderTerm = leaderTerm
        self.kind = kind
        self.deadline = deadline
        self.attempt = attempt
        self.payload = payload
        self.inputHash = Self.hash(kind: kind, payload: payload)
    }

    func retry(attempt: Int) -> Self {
        Self(
            jobID: jobID,
            originNodeName: originNodeName,
            leaderTerm: leaderTerm,
            kind: kind,
            deadline: deadline,
            attempt: attempt,
            payload: payload
        )
    }

    var hasValidInputHash: Bool { inputHash == Self.hash(kind: kind, payload: payload) }

    private static func hash(kind: MeshJobKind, payload: Data) -> String {
        var bytes = Data("SwiftMesh-job-v1:\(kind.rawValue):".utf8)
        bytes.append(payload)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

enum MeshJobStatus: String, Codable, Sendable {
    case running
    case completed
    case retryable
    case busy
    case expired
    case cancelled
    case staleLeadership
    case conflictingJob
    case invalidRequest
    case unavailable
    case storageUnavailable
}

struct MeshJobResponseEnvelope: Codable, Sendable, Equatable {
    let jobID: UUID
    let leaderTerm: Int
    let currentLeaderTerm: Int
    let status: MeshJobStatus
    let result: Data?
}

/// A bounded worker-side ledger for computation, not a Discord action queue.
/// Persisted results let a Primary retry an interrupted connection without
/// re-running completed work. A restart makes interrupted work retryable.
/// Results must travel over the encrypted mesh response path (or TLS).
actor MeshJobLedger {
    typealias LeaderTermProvider = @Sendable () async -> Int
    typealias Operation = @Sendable (Data) async -> Data?

    static let fileName = "mesh-job-ledger.json"
    static let maximumPayloadBytes = 512 * 1024
    static let maximumResultBytes = 512 * 1024

    private struct Identity: Codable, Equatable, Sendable {
        let originNodeName: String
        let leaderTerm: Int
        let kind: MeshJobKind
        let inputHash: String

        init(_ request: MeshJobRequestEnvelope) {
            originNodeName = request.originNodeName
            leaderTerm = request.leaderTerm
            kind = request.kind
            inputHash = request.inputHash
        }
    }

    private struct Record: Codable, Sendable {
        let jobID: UUID
        let identity: Identity
        let deadline: Date
        var attempt: Int
        var status: MeshJobStatus
        var result: Data?
        var updatedAt: Date
    }

    private struct Snapshot: Codable {
        var records: [Record]
    }

    private struct Flight {
        let generation: UUID
        let computation: Task<Void, Never>
        let expiry: Task<Void, Never>
        var waiters: [CheckedContinuation<MeshJobResponseEnvelope, Never>]
    }

    private let storageURL: URL?
    private let maximumConcurrentJobs: Int
    private let maximumStoredRecords: Int
    private let retention: TimeInterval
    private var records: [UUID: Record] = [:]
    private var flights: [UUID: Flight] = [:]
    private var liveComputations: Set<UUID> = []
    private var highestObservedTerm = 0

    /// nil storage is intentionally memory-only, useful for isolated tests.
    /// Production supplies an explicitly local URL; this file is never copied
    /// by generic configuration replication.
    init(
        storageURL: URL? = nil,
        maximumConcurrentJobs: Int = 2,
        maximumStoredRecords: Int = 128,
        retention: TimeInterval = 24 * 60 * 60
    ) {
        self.storageURL = storageURL
        self.maximumConcurrentJobs = max(1, maximumConcurrentJobs)
        self.maximumStoredRecords = max(1, maximumStoredRecords)
        self.retention = max(60, retention)
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            let now = Date()
            for var record in snapshot.records.sorted(by: { $0.updatedAt > $1.updatedAt })
                .prefix(self.maximumStoredRecords) where now.timeIntervalSince(record.updatedAt) < self.retention {
                if record.status == .running {
                    record.status = record.deadline > now ? .retryable : .expired
                    record.result = nil
                }
                records[record.jobID] = record
            }
        }
    }

    var activeJobCount: Int { liveComputations.count }

    /// Re-checking the supplied term after computation prevents a late result
    /// from the former Primary from becoming a current bot action.
    func execute(
        _ request: MeshJobRequestEnvelope,
        currentLeaderTerm: @escaping LeaderTermProvider,
        operation: @escaping Operation
    ) async -> MeshJobResponseEnvelope {
        await observeLeadership(term: await currentLeaderTerm())
        guard request.leaderTerm == highestObservedTerm else { return response(request, .staleLeadership) }
        guard request.leaderTerm >= 0,
              request.attempt > 0,
              !request.originNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.deadline.timeIntervalSinceNow <= 24 * 60 * 60,
              request.payload.count <= Self.maximumPayloadBytes,
              request.hasValidInputHash else { return response(request, .invalidRequest) }

        pruneRecords()
        if let record = records[request.jobID] {
            guard record.identity == Identity(request), record.deadline == request.deadline else {
                return response(request, .conflictingJob)
            }
            if flights[request.jobID] != nil { return await waitForResult(request.jobID) }
            if record.status != .retryable && record.status != .unavailable && record.status != .storageUnavailable {
                return response(record)
            }
        }
        guard request.deadline > Date() else { return response(request, .expired) }
        guard !Task.isCancelled else { return response(request, .cancelled) }
        guard liveComputations.count < maximumConcurrentJobs else { return response(request, .busy) }

        let previous = records[request.jobID]
        records[request.jobID] = Record(
            jobID: request.jobID,
            identity: Identity(request),
            deadline: request.deadline,
            attempt: request.attempt,
            status: .running,
            result: nil,
            updatedAt: Date()
        )
        do {
            try persist()
        } catch {
            records[request.jobID] = previous
            return response(request, .storageUnavailable)
        }

        let generation = UUID()
        liveComputations.insert(generation)
        let computation = Task { [weak self] in
            let result = await operation(request.payload)
            let term = await currentLeaderTerm()
            await self?.finish(request.jobID, generation: generation, result: result, observedTerm: term)
        }
        let remaining = max(0, min(request.deadline.timeIntervalSinceNow, 24 * 60 * 60))
        let expiry = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                await self?.terminate(request.jobID, generation: generation, status: .expired)
            } catch { }
        }
        flights[request.jobID] = Flight(generation: generation, computation: computation, expiry: expiry, waiters: [])
        return await waitForResult(request.jobID)
    }

    /// Generation checks discard eventual results from obsolete work. Capacity
    /// stays occupied until its provider actually returns, even if that provider
    /// does not cooperate with Task cancellation.
    func observeLeadership(term: Int) async {
        guard term > highestObservedTerm else { return }
        highestObservedTerm = term
        let stale = flights.keys.filter { (records[$0]?.identity.leaderTerm ?? term) < term }
        for jobID in stale {
            guard let generation = flights[jobID]?.generation else { continue }
            terminate(jobID, generation: generation, status: .staleLeadership)
        }
    }

    func status(for request: MeshJobRequestEnvelope, currentLeaderTerm: Int) async -> MeshJobResponseEnvelope? {
        await observeLeadership(term: currentLeaderTerm)
        guard request.leaderTerm == highestObservedTerm else { return response(request, .staleLeadership) }
        guard let record = records[request.jobID] else { return nil }
        guard record.identity == Identity(request) else { return response(request, .conflictingJob) }
        return response(record)
    }

    func cancel(_ request: MeshJobRequestEnvelope, currentLeaderTerm: Int) async -> MeshJobResponseEnvelope? {
        await observeLeadership(term: currentLeaderTerm)
        guard request.leaderTerm == highestObservedTerm else { return response(request, .staleLeadership) }
        guard let record = records[request.jobID] else { return nil }
        guard record.identity == Identity(request) else { return response(request, .conflictingJob) }
        if let generation = flights[request.jobID]?.generation {
            terminate(request.jobID, generation: generation, status: .cancelled)
        }
        return records[request.jobID].map(response)
    }

    private func waitForResult(_ jobID: UUID) async -> MeshJobResponseEnvelope {
        await withCheckedContinuation { continuation in
            if var flight = flights[jobID] {
                flight.waiters.append(continuation)
                flights[jobID] = flight
            } else if let record = records[jobID] {
                continuation.resume(returning: response(record))
            } else {
                continuation.resume(returning: MeshJobResponseEnvelope(
                    jobID: jobID, leaderTerm: highestObservedTerm,
                    currentLeaderTerm: highestObservedTerm, status: .unavailable, result: nil
                ))
            }
        }
    }

    private func finish(_ jobID: UUID, generation: UUID, result: Data?, observedTerm: Int) async {
        liveComputations.remove(generation)
        await observeLeadership(term: observedTerm)
        guard flights[jobID]?.generation == generation, var record = records[jobID] else { return }
        if record.identity.leaderTerm != highestObservedTerm {
            terminate(jobID, generation: generation, status: .staleLeadership)
            return
        }
        guard record.deadline > Date() else {
            terminate(jobID, generation: generation, status: .expired)
            return
        }
        record.status = result.map { $0.count <= Self.maximumResultBytes } == true ? .completed : .unavailable
        record.result = record.status == .completed ? result : nil
        record.updatedAt = Date()
        records[jobID] = record
        do {
            try persist()
        } catch {
            // Admission was persisted as running, so a restart remains retryable.
            // Never claim a recoverable completion when storing it failed.
            record.status = .storageUnavailable
            record.result = nil
            records[jobID] = record
        }
        resolve(jobID, generation: generation)
    }

    private func terminate(_ jobID: UUID, generation: UUID, status: MeshJobStatus) {
        guard flights[jobID]?.generation == generation, var record = records[jobID] else { return }
        record.status = status
        record.result = nil
        record.updatedAt = Date()
        records[jobID] = record
        try? persist()
        resolve(jobID, generation: generation)
    }

    private func resolve(_ jobID: UUID, generation: UUID) {
        guard flights[jobID]?.generation == generation,
              let flight = flights.removeValue(forKey: jobID),
              let record = records[jobID] else { return }
        flight.expiry.cancel()
        flight.computation.cancel()
        let reply = response(record)
        for waiter in flight.waiters { waiter.resume(returning: reply) }
        pruneRecords()
    }

    private func response(_ request: MeshJobRequestEnvelope, _ status: MeshJobStatus) -> MeshJobResponseEnvelope {
        MeshJobResponseEnvelope(
            jobID: request.jobID, leaderTerm: request.leaderTerm,
            currentLeaderTerm: highestObservedTerm, status: status, result: nil
        )
    }

    private func response(_ record: Record) -> MeshJobResponseEnvelope {
        MeshJobResponseEnvelope(
            jobID: record.jobID, leaderTerm: record.identity.leaderTerm,
            currentLeaderTerm: highestObservedTerm, status: record.status, result: record.result
        )
    }

    private func pruneRecords() {
        let now = Date()
        records = records.filter { flights[$0.key] != nil || now.timeIntervalSince($0.value.updatedAt) < retention }
        let excess = max(0, records.count - maximumStoredRecords)
        for record in records.values.filter({ flights[$0.jobID] == nil })
            .sorted(by: { $0.updatedAt < $1.updatedAt }).prefix(excess) {
            records.removeValue(forKey: record.jobID)
        }
    }

    private func persist() throws {
        guard let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(records: records.values.sorted { $0.updatedAt < $1.updatedAt }))
        try data.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }
}
