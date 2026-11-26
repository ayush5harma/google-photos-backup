import Foundation
import Network
import Observation
import PhotosBackupCore
import UIKit

/// The network path and the power state, for the "When to back up"
/// settings. Core's ConditionsEvaluator turns them and the four switches
/// into the one reason an automatic backup waits, as on the Mac.
@MainActor
@Observable
final class ConditionsMonitor {
    /// nil until NWPathMonitor's first update: on a cold background launch
    /// the network is not known yet, and an automatic run must not take it
    /// for Wi-Fi (review finding 6).
    private(set) var network: NetworkConditions?
    private(set) var power = PowerConditions()

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interface: NetworkInterface = path.usesInterfaceType(.wifi) ? .wifi
                : path.usesInterfaceType(.cellular) ? .cellular
                : path.usesInterfaceType(.wiredEthernet) ? .ethernet : .other
            let conditions = NetworkConditions(online: path.status == .satisfied, expensive: path.isExpensive,
                                               constrained: path.isConstrained, interface: interface)
            Task { @MainActor in self?.update(network: conditions) }
        }
        monitor.start(queue: DispatchQueue(label: AppEnvironment.bundleID + ".conditions"))
        self.monitor = monitor

        // Battery state is only reported once monitoring is on.
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.readPower() }
            })
        }
        readPower()
    }

    /// Fixture mode: fixed conditions, no monitors.
    func use(network: NetworkConditions, power: PowerConditions) {
        self.network = network
        self.power = power
    }

    func blocking(for settings: BackupSettings, startedByPerson: Bool = false) -> WaitReason? {
        ConditionsEvaluator.blocking(network: network, power: power, flags: settings.conditionFlags, startedByPerson: startedByPerson)
    }

    var summary: String {
        guard let network else { return "Network not reported yet" }
        return ConditionsEvaluator.summary(network: network, power: power)
    }

    private func readPower() {
        let state = UIDevice.current.batteryState
        // .unknown is the simulator (and monitoring off): treated as plugged
        // in, so a simulator never waits for a charger.
        let conditions = PowerConditions(onBattery: state == .unplugged,
                                         lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        guard conditions != power else { return }
        power = conditions
        onChange?()
    }

    private func update(network conditions: NetworkConditions) {
        guard conditions != network else { return }
        network = conditions
        onChange?()
    }
}
