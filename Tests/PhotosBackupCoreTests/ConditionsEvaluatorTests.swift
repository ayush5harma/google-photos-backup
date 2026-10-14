import Foundation
import Testing
@testable import PhotosBackupCore

private let allOn = ConditionFlags(pauseOnExpensiveNetwork: true, pauseInLowDataMode: true, pauseOnBattery: true, pauseInLowPowerMode: true)
private let allOff = ConditionFlags(pauseOnExpensiveNetwork: false, pauseInLowDataMode: false, pauseOnBattery: false, pauseInLowPowerMode: false)

@Suite struct ConditionsEvaluatorTests {
    @Test func aGoodNetworkOnPowerNeverHolds() {
        #expect(ConditionsEvaluator.blocking(network: NetworkConditions(), power: PowerConditions(), flags: allOn) == nil)
    }

    @Test func offlineHoldsWhateverTheSettings() {
        let offline = NetworkConditions(online: false, expensive: true, constrained: true)
        let drained = PowerConditions(onBattery: true, lowPowerMode: true)
        #expect(ConditionsEvaluator.blocking(network: offline, power: drained, flags: allOn) == .offline)
        #expect(ConditionsEvaluator.blocking(network: offline, power: PowerConditions(), flags: allOff) == .offline)
    }

    @Test func eachConditionHoldsOnlyWhenItsSettingIsOn() {
        let cases: [(NetworkConditions, PowerConditions, WritableKeyPath<ConditionFlags, Bool>, WaitReason)] = [
            (NetworkConditions(expensive: true), PowerConditions(), \.pauseOnExpensiveNetwork, .expensiveNetwork),
            (NetworkConditions(constrained: true), PowerConditions(), \.pauseInLowDataMode, .lowDataMode),
            (NetworkConditions(), PowerConditions(onBattery: true), \.pauseOnBattery, .onBattery),
            (NetworkConditions(), PowerConditions(lowPowerMode: true), \.pauseInLowPowerMode, .lowPowerMode),
        ]
        for (network, power, flag, reason) in cases {
            var only = allOff
            only[keyPath: flag] = true
            #expect(ConditionsEvaluator.blocking(network: network, power: power, flags: only) == reason)
            #expect(ConditionsEvaluator.blocking(network: network, power: power, flags: allOff) == nil)
            var allButThis = allOn
            allButThis[keyPath: flag] = false
            #expect(ConditionsEvaluator.blocking(network: network, power: power, flags: allButThis) == nil)
        }
    }

    @Test func networkReasonsComeBeforePowerReasons() {
        let hotspot = NetworkConditions(expensive: true, constrained: true, interface: .cellular)
        let drained = PowerConditions(onBattery: true, lowPowerMode: true)
        #expect(ConditionsEvaluator.blocking(network: hotspot, power: drained, flags: allOn) == .expensiveNetwork)

        var flags = allOn
        flags.pauseOnExpensiveNetwork = false
        #expect(ConditionsEvaluator.blocking(network: hotspot, power: drained, flags: flags) == .lowDataMode)
        flags.pauseInLowDataMode = false
        #expect(ConditionsEvaluator.blocking(network: hotspot, power: drained, flags: flags) == .lowPowerMode)
        flags.pauseInLowPowerMode = false
        #expect(ConditionsEvaluator.blocking(network: hotspot, power: drained, flags: flags) == .onBattery)
    }

    @Test func summaryNamesTheLinkAndThePower() {
        #expect(ConditionsEvaluator.summary(network: NetworkConditions(), power: PowerConditions()) == "Wi-Fi, on power")
        #expect(ConditionsEvaluator.summary(network: NetworkConditions(online: false), power: PowerConditions(onBattery: true))
            == "Offline, on battery")
        #expect(ConditionsEvaluator.summary(network: NetworkConditions(expensive: true, constrained: true, interface: .cellular),
                                            power: PowerConditions(onBattery: true, lowPowerMode: true))
            == "Cellular (metered) (Low Data Mode), on battery, Low Power Mode")
        #expect(ConditionsEvaluator.summary(network: NetworkConditions(interface: .ethernet), power: PowerConditions()) == "Ethernet, on power")
    }
}
