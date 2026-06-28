import Foundation

struct UptimeInfo {
    let startedAt: Date

    var text: String {
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%02dh %02dm %02ds", h, m, s) }
        return String(format: "%02dm %02ds", m, s)
    }
}
