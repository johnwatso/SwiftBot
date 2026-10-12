import Foundation
import IOKit.ps

struct PowerSnapshot: Sendable, Equatable {
    enum Source: String, Sendable, Encodable { case ac, ups, battery, unknown }
    let source: Source
    let externalPower: Bool?
    let batteryPercent: Int?
    let timeRemainingSeconds: Int?

    static let unavailable = PowerSnapshot(source: .unknown, externalPower: nil, batteryPercent: nil, timeRemainingSeconds: nil)
}

enum PowerSourceMonitor {
    static func current() -> PowerSnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any],
              let raw = list.first,
              let info = IOPSGetPowerSourceDescription(blob, raw as CFTypeRef)?.takeUnretainedValue() as? [String: Any] else {
            return .unavailable
        }

        let type = info[kIOPSTypeKey] as? String
        let source: PowerSnapshot.Source
        switch type {
        case kIOPSUPSType: source = .ups
        case kIOPSInternalBatteryType: source = .battery
        default: source = .unknown
        }

        let powerSource = info[kIOPSPowerSourceStateKey] as? String
        let externalPower: Bool?
        switch powerSource {
        case kIOPSACPowerValue: externalPower = true
        case kIOPSBatteryPowerValue: externalPower = false
        default: externalPower = nil
        }

        let percent: Int?
        if let capacity = info[kIOPSCurrentCapacityKey] as? Int,
           let maxCapacity = info[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0 {
            percent = Swift.min(100, Swift.max(0, capacity * 100 / maxCapacity))
        } else {
            percent = nil
        }

        let timeRemaining: Int?
        if let minutes = info[kIOPSTimeToEmptyKey] as? Int, minutes >= 0 {
            timeRemaining = minutes * 60
        } else {
            timeRemaining = nil
        }

        return PowerSnapshot(source: source, externalPower: externalPower,
                             batteryPercent: percent, timeRemainingSeconds: timeRemaining)
    }
}
