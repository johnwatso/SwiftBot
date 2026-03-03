import Foundation

// MARK: - Update Polling Manager

/// Manages periodic polling for driver updates.
/// Runs in the background using Swift concurrency.
/// Does NOT belong to UpdateEngine - this is SwiftBot runtime logic.
final class UpdatePollingManager: Sendable {
    private let interval: UInt64 = 60 * 60 // seconds (60 minutes)
    private let guildUpdateService: GuildUpdateService
    
    init(guildUpdateService: GuildUpdateService) {
        self.guildUpdateService = guildUpdateService
    }
    
    /// Start the polling loop.
    /// Runs on a detached task to avoid blocking the main thread.
    /// Each cycle completes before the next begins (no overlap).
    func start() {
        let service = self.guildUpdateService
        let pollingInterval = self.interval
        
        Task.detached {
            print("[UpdatePollingManager] Starting update polling (interval: \(pollingInterval)s)")
            
            while !Task.isCancelled {
                let cycleStart = Date()
                print("[UpdatePollingManager] Starting polling cycle at \(cycleStart)")
                
                // Await completion of guild checks (no overlap)
                await service.checkAllGuilds()
                
                let cycleDuration = Date().timeIntervalSince(cycleStart)
                print("[UpdatePollingManager] Polling cycle completed in \(String(format: "%.2f", cycleDuration))s")
                
                // Sleep until next cycle
                do {
                    try await Task.sleep(nanoseconds: pollingInterval * 1_000_000_000)
                } catch {
                    // Task was cancelled
                    print("[UpdatePollingManager] Polling stopped")
                    break
                }
            }
        }
    }
}
