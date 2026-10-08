import Foundation
import RecordingsKit

extension AppModel {
    var canServeSharedRecordings: Bool {
        mediaLibrarySettings.sharedLibraryEnabled && settings.adminWebUI.enabled
            && !settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Owned by the Web Interface/app lifetime, independently of Discord output
    /// and the mesh election/renewal tasks. Each Mac opts in separately.
    func configureRecordingCoordination() async {
        let configured = canServeSharedRecordings
        let origin = RecordingDirectoryClient.origin(localMeshPublicAddress)
        await recordingDirectory.configure(.init(
            witness: recordingWitnessConfiguration, nodeID: meshLocalNodeID,
            nodeName: settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines),
            libraryURL: origin.map { $0 + "/v1/media/library" }, enabled: configured
        ))
        recordingCoordinationTask?.cancel()
        recordingCoordinationTask = nil
        sharedRecordingLibraries.removeAll()
        sharedRecordingLibraryLastSeen.removeAll()
        clipPeopleCache = nil
        if !mediaLibrarySettings.sharedLibraryEnabled {
            recordingCoordinationStatus = "Sharing is off."
        } else if !settings.adminWebUI.enabled || settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordingCoordinationStatus = "Enable the Web Interface and configure a SwiftMesh Shared Secret."
        } else {
            recordingCoordinationStatus = "Connecting to Ruru…"
        }
        guard configured, !Self.isRunningUnderXCTest else { return }
        recordingCoordinationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let client = self?.recordingDirectory else { return }
                let snapshot = await client.refresh(force: true)
                guard !Task.isCancelled else { return }
                self?.recordingCoordinationStatus = snapshot.message
                do { try await Task.sleep(for: .seconds(Double.random(in: 25...35))) } catch { return }
            }
        }
    }

    /// Local recording preferences remain editable on a Fail Over. Commit this
    /// Mac's opt-in before enabling its public media routes or reporting to Ruru.
    func setRecordingSharingEnabled(_ enabled: Bool) async -> Bool {
        var next = mediaLibrarySettings
        next.sharedLibraryEnabled = enabled
        do {
            try await mediaLibraryConfigStore.saveSharingChoice(next)
            mediaLibrarySettings = next
            lastPersistedMediaLibrarySettingsSnapshot = next
            await configureRecordingCoordination()
            return true
        } catch {
            recordingCoordinationStatus = "Could not save recording sharing settings."
            return false
        }
    }

    func coordinatedMediaLibraries() async -> [MediaLibraryPayload] {
        let local = await localMediaLibrarySnapshot()
        guard mediaLibrarySettings.sharedLibraryEnabled else { return [local] }
        let snapshot = await recordingDirectory.refresh()
        recordingCoordinationStatus = snapshot.message
        let locations = snapshot.libraries.filter { $0.nodeID != meshLocalNodeID }
        let remotes = await withTaskGroup(of: (RecordingDirectoryClient.Library, MediaLibraryPayload?).self) { group in
            for location in locations {
                group.addTask { [cluster] in
                    (location, await cluster.fetchRemoteMediaLibrary(from: location.baseURL))
                }
            }
            var results: [(RecordingDirectoryClient.Library, MediaLibraryPayload?)] = []
            for await result in group { results.append(result) }
            return results
        }
        // Recheck after network awaits: a revoked origin/configuration or expired
        // report must not enter the view as a fresh playable library.
        let current = await recordingDirectory.snapshot()
        guard mediaLibrarySettings.sharedLibraryEnabled else { return [local] }
        let admitted = Set(current.libraries.map(\.nodeID))
        for (location, remote) in remotes where current.libraries.contains(where: {
            $0.nodeID == location.nodeID && $0.baseURL == location.baseURL
        }) {
            guard var remote, remote.nodeID == location.nodeID else {
                sharedRecordingLibraries[location.nodeID]?.fresh = false
                continue
            }
            remote.nodeName = location.nodeName
            // Only Ruru supplies the route. Ignore URLs embedded in peer data.
            remote.items = remote.items.map { item in
                var copy = item
                copy.ownerBaseURL = nil
                copy.ownerNodeName = location.nodeName
                return copy
            }
            sharedRecordingLibraries[location.nodeID] = remote
            sharedRecordingLibraryLastSeen[location.nodeID] = .now
        }
        let expired = sharedRecordingLibraryLastSeen.filter { $0.value.duration(to: .now) >= .seconds(600) }.map(\.key)
        for id in expired {
            sharedRecordingLibraries[id] = nil
            sharedRecordingLibraryLastSeen[id] = nil
        }
        // Bound remembered unavailable nodes as well as the live directory.
        while sharedRecordingLibraries.count > 16,
              let oldest = sharedRecordingLibraryLastSeen.min(by: { $0.value < $1.value })?.key {
            sharedRecordingLibraries[oldest] = nil
            sharedRecordingLibraryLastSeen[oldest] = nil
        }
        return [local] + sharedRecordingLibraries.values.map { cached in
            var copy = cached
            if !admitted.contains(copy.nodeID ?? "") { copy.fresh = false }
            return copy
        }.sorted { $0.identity < $1.identity }
    }

    enum RecordingRoute { case local, remote(String) }

    /// The browser identifies a node and recording, never the destination to
    /// which we send mesh authentication. This check runs for every range request.
    func recordingRoute(for descriptor: MediaStreamDescriptor) async -> RecordingRoute? {
        if let id = descriptor.ownerNodeID {
            if !meshLocalNodeID.isEmpty, id == meshLocalNodeID { return .local }
            guard mediaLibrarySettings.sharedLibraryEnabled,
                  let library = await recordingDirectory.snapshot().libraries.first(where: { $0.nodeID == id }) else { return nil }
            return .remote(library.baseURL)
        }
        // Legacy local links remain valid. Legacy remote URL descriptors cannot
        // authorize an outgoing request; refreshing the view issues new IDs.
        let localName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node") : settings.clusterNodeName
        return descriptor.ownerBaseURL == nil && descriptor.ownerNodeName == localName ? .local : nil
    }
}
