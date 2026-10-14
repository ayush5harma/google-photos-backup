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
            DispatchQueue.main.async { self?.update(network: conditions) }
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

    private func update(network: NetworkConditions? = nil, power: PowerConditions? = nil) {
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
