import Foundation
import IOKit.ps
import Network
import Observation
import PhotosBackupCore

/// Watches the network (NWPathMonitor: offline, expensive, constrained) and
/// power (battery, Low Power Mode) and says whether a setting blocks uploads.
@MainActor
@Observable
final class ConditionsMonitor {
    /// The network and power right now, in words, for the run history.
    private(set) var summary = "Unknown"
    /// Online until NWPathMonitor says otherwise, so nothing holds in the
    /// moment before its first answer.
    private(set) var network = NetworkConditions()
    private(set) var power = PowerConditions()
    /// Fires on the main thread whenever the network or power changes.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var powerObserver: NSObjectProtocol?

    func start(settings: BackupSettings) {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let conditions = Self.conditions(of: path)
            DispatchQueue.main.async { self?.received(network: conditions) }
        }
        monitor.start(queue: DispatchQueue(label: "PhotosBackup.conditions", qos: .utility))
        pathMonitor = monitor

        // The monitor lives as long as the app model, which is the app's
        // lifetime, so an unretained pointer in the C callback is safe.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<ConditionsMonitor>.fromOpaque(context).takeUnretainedValue()
            // Added to the main run loop below, so this runs on main.
            MainActor.assumeIsolated { monitor.readPower() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readPower() }
        }
        readPower()
    }

    /// The first condition that holds uploads under these settings, or nil.
    func blocking(for settings: BackupSettings) -> WaitReason? {
        ConditionsEvaluator.blocking(network: network, power: power, flags: settings.conditionFlags)
    }

    private func readPower() {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let source = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        update(power: PowerConditions(onBattery: source == kIOPMBatteryPowerKey,
                                      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled))
    }

    #if DEBUG
    /// scripts/e2e.sh only (photosbackup://debug/conditions): pins the network
    /// or power to a value until "real" hands it back to the monitors.
    @ObservationIgnored private var pinnedNetwork: NetworkConditions?
    @ObservationIgnored private var pinnedPower: PowerConditions?
    @ObservationIgnored private var realNetwork = NetworkConditions()

    func simulate(network: String?, power: String?) {
        switch network {
        case "online": pinnedNetwork = NetworkConditions()
        case "offline": pinnedNetwork = NetworkConditions(online: false)
        case "expensive": pinnedNetwork = NetworkConditions(expensive: true, interface: .other)
        case "constrained": pinnedNetwork = NetworkConditions(constrained: true)
        case "real": pinnedNetwork = nil
        default: break
        }
        switch power {
        case "ac": pinnedPower = PowerConditions()
        case "battery": pinnedPower = PowerConditions(onBattery: true)
        case "lowpower": pinnedPower = PowerConditions(onBattery: true, lowPowerMode: true)
        case "real": pinnedPower = nil
        default: break
        }
        update(network: pinnedNetwork ?? realNetwork)
        if pinnedPower != nil { update(power: pinnedPower) } else { readPower() }
    }
    #endif

    private func received(network: NetworkConditions) {
        #if DEBUG
        realNetwork = network
        #endif
        update(network: network)
    }

    private func update(network: NetworkConditions? = nil, power: PowerConditions? = nil) {
        #if DEBUG
        let network = pinnedNetwork ?? network
        let power = pinnedPower ?? power
        #endif
        let newNetwork = network ?? self.network
        let newPower = power ?? self.power
        let newSummary = ConditionsEvaluator.summary(network: newNetwork, power: newPower)
        guard newNetwork != self.network || newPower != self.power || newSummary != summary else { return }
        self.network = newNetwork
        self.power = newPower
        summary = newSummary
        onChange?()
    }

    private nonisolated static func conditions(of path: NWPath) -> NetworkConditions {
        let interface: NetworkInterface
        if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .ethernet
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else {
            interface = .other
        }
        return NetworkConditions(online: path.status == .satisfied, expensive: path.isExpensive,
                                 constrained: path.isConstrained, interface: interface)
    }
}

extension BackupSettings {
    var conditionFlags: ConditionFlags {
        ConditionFlags(pauseOnExpensiveNetwork: pauseOnExpensiveNetwork, pauseInLowDataMode: pauseInLowDataMode,
                       pauseOnBattery: pauseOnBattery, pauseInLowPowerMode: pauseInLowPowerMode)
    }
}
