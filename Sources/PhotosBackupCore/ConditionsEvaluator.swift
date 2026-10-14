import Foundation

public enum NetworkInterface: String, Sendable {
    case wifi, ethernet, cellular, other

    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .cellular: "Cellular"
        case .other: "Network"
        }
    }
}

/// The network as NWPathMonitor sees it.
public struct NetworkConditions: Equatable, Sendable {
    public var online: Bool
    /// A phone's hotspot or a cellular link: macOS marks it expensive.
    public var expensive: Bool
    /// Low Data Mode is on for this network.
    public var constrained: Bool
    public var interface: NetworkInterface

    public init(online: Bool = true, expensive: Bool = false, constrained: Bool = false, interface: NetworkInterface = .wifi) {
        self.online = online
        self.expensive = expensive
        self.constrained = constrained
        self.interface = interface
    }
}

public struct PowerConditions: Equatable, Sendable {
    public var onBattery: Bool
    public var lowPowerMode: Bool

    public init(onBattery: Bool = false, lowPowerMode: Bool = false) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
    }
}

/// The four "pause when..." settings.
public struct ConditionFlags: Equatable, Sendable {
    public var pauseOnExpensiveNetwork: Bool
    public var pauseInLowDataMode: Bool
    public var pauseOnBattery: Bool
    public var pauseInLowPowerMode: Bool

    public init(pauseOnExpensiveNetwork: Bool, pauseInLowDataMode: Bool, pauseOnBattery: Bool, pauseInLowPowerMode: Bool) {
        self.pauseOnExpensiveNetwork = pauseOnExpensiveNetwork
        self.pauseInLowDataMode = pauseInLowDataMode
        self.pauseOnBattery = pauseOnBattery
        self.pauseInLowPowerMode = pauseInLowPowerMode
    }
}

public enum ConditionsEvaluator {
    /// The one reason uploads hold, in a fixed order so the reason shown
    /// does not flicker between two that both apply: no network first
    /// (nothing can go), then the network the person chose to spare, then
    /// power, Low Power Mode (a deliberate choice) before plain battery.
    public static func blocking(network: NetworkConditions, power: PowerConditions, flags: ConditionFlags) -> WaitReason? {
        if !network.online { return .offline }
        if flags.pauseOnExpensiveNetwork, network.expensive { return .expensiveNetwork }
        if flags.pauseInLowDataMode, network.constrained { return .lowDataMode }
        if flags.pauseInLowPowerMode, power.lowPowerMode { return .lowPowerMode }
        if flags.pauseOnBattery, power.onBattery { return .onBattery }
        return nil
    }

    /// How long a run a person started waits for a network that is gone.
    public static let manualOfflineLimit: TimeInterval = 120

    /// Whether a wait should end the run instead: Back Up Now with no
    /// network fails after two minutes with a clear answer, while an
    /// automatic run may wait as long as it takes (it holds nobody up).
    public static func givesUpWaiting(for reason: WaitReason, startedByPerson: Bool, since: Date, now: Date) -> Bool {
        reason == .offline && startedByPerson && now.timeIntervalSince(since) >= manualOfflineLimit
    }

    /// "Wi-Fi, on power" for the run history and the diagnostic report.
    public static func summary(network: NetworkConditions, power: PowerConditions) -> String {
        var parts: [String] = []
        if network.online {
            var link = network.interface.title
            if network.expensive { link += " (metered)" }
            if network.constrained { link += " (Low Data Mode)" }
            parts.append(link)
        } else {
            parts.append("Offline")
        }
        parts.append(power.onBattery ? "on battery" : "on power")
        if power.lowPowerMode { parts.append("Low Power Mode") }
        return parts.joined(separator: ", ")
    }
}
