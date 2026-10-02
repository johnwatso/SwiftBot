import Foundation

/// A readable description of the Mac SwiftBot is running on, for "About this
/// server": "Mac mini (M1, 2020) · 16 GB memory".
enum MacHardwareInfo {
    /// Worked out once; none of it changes while the app runs.
    static let summary: String = {
        let chip = sysctlString("machdep.cpu.brand_string") ?? ""
        let modelID = sysctlString("hw.model") ?? ""
        var name = marketingName() ?? familyName(forModelID: modelID)
        // The marketing name usually includes the chip ("M1, 2020"); add it when it doesn't.
        if !chip.isEmpty, !name.localizedCaseInsensitiveContains(chip.replacingOccurrences(of: "Apple ", with: "")) {
            name += " · \(chip)"
        }
        let memory = memoryDescription()
        return [name, memory].filter { !$0.isEmpty }.joined(separator: " · ")
    }()

    /// The name System Information shows, e.g. "MacBook Pro (14-inch, 2024)".
    /// macOS caches it per region; any entry will do.
    private static func marketingName() -> String? {
        guard let names = CFPreferencesCopyAppValue("CPU Names" as CFString, "com.apple.SystemProfiler" as CFString) as? [String: String] else {
            return nil
        }
        return names.values.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// "Mac mini" from "Macmini9,1" when there's no cached marketing name.
    static func familyName(forModelID modelID: String) -> String {
        let families: [(String, String)] = [
            ("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"), ("MacBook", "MacBook"),
            ("Macmini", "Mac mini"), ("MacPro", "Mac Pro"), ("iMacPro", "iMac Pro"), ("iMac", "iMac")
        ]
        return families.first { modelID.hasPrefix($0.0) }?.1 ?? (modelID.isEmpty ? "Mac" : "Mac (\(modelID))")
    }

    private static func memoryDescription() -> String {
        let bytes = ProcessInfo.processInfo.physicalMemory
        guard bytes > 0 else { return "" }
        return "\(Int((Double(bytes) / 1_073_741_824).rounded())) GB memory"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
