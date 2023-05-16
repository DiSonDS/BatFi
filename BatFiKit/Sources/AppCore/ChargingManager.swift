//
//  ChargingManager.swift
//  
//
//  Created by Adam on 04/05/2023.
//

import AppShared
import AsyncAlgorithms
import Clients
import Dependencies
import Foundation
import IOKit.pwr_mgt
import os
import Settings
import Shared

public final class ChargingManager: ObservableObject {
    @Dependency(\.chargingClient)             private var chargingClient
    @Dependency(\.powerSourceClient)        private var powerSourceClient
    @Dependency(\.screenParametersClient)   private var screenParametersClient
    @Dependency(\.sleepClient)              private var sleepClient
    @Dependency(\.observeDefaultsClient)    private var observeDefaultsClient
    @Dependency(\.getDefaultsClient)        private var getDefaultsClient
    @Dependency(\.setDefaultsClient)        private var setDefaultsClient
    @Dependency(\.suspendingClock)          private var clock
    @Dependency(\.appChargingState)         private var appChargingState

    private var sleepAssertion: IOPMAssertionID?
    private lazy var logger = Logger(category: "🔌👨‍💼")

    public init() { }

    public func setUpObserving() {
        Task {
            await fetchChargingState()
            for await (powerState, (preventSleeping, forceCharging), (chargeLimit, manageCharging, allowDischarging)) in combineLatest(
                powerSourceClient.powerSourceChanges(),
                combineLatest(
                    observeDefaultsClient.observePreventSleeping(),
                    observeDefaultsClient.observeForceCharging()
                ),
                combineLatest(
                    observeDefaultsClient.observeChargeLimit(),
                    observeDefaultsClient.observeManageCharging(),
                    observeDefaultsClient.observeAllowDischargingFullBattery()
                )
            ).debounce(for: .seconds(1)) {
                logger.debug("something changed")
                await updateStatus(
                    powerState: powerState,
                    chargeLimit: chargeLimit,
                    manageCharging: manageCharging,
                    allowDischarging: allowDischarging,
                    preventSleeping: preventSleeping,
                    forceCharging: forceCharging
                )
            }
            logger.warning("The main loop did quit")
        }

        Task {
            for await sleepNote in sleepClient.observeMacSleepStatus() {
                switch sleepNote {
                case .willSleep:
                    let mode = await appChargingState.chargingStateMode()
                    if mode == .forceDischarge {
                        await inhibitChargingIfNeeded()
                    }
                case .didWake:
                    break
                }

            }
        }

        Task {
            for await _ in screenParametersClient.screenDidChangeParameters() {
                await fetchChargingState()
                await updateStatusWithCurrentState()
            }
        }
    }

    public func appWillQuit() {
        logger.debug("App will quit")
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            try? await chargingClient.turnOnAutoChargingMode()
            try? await chargingClient.quitChargingHelper()
            semaphore.signal()
        }
        semaphore.wait()
        logger.debug("I tried to turn on charging and quit the helper.")
    }

    public func chargeToFull() {
        setDefaultsClient.setForceCharge(true)
    }

    public func turnOffChargeToFull() {
        setDefaultsClient.setForceCharge(false)
    }

    private func updateStatusWithCurrentState() async {
        let powerState = try? powerSourceClient.currentPowerSourceState()
        if let powerState {
            let chargeLimit = getDefaultsClient.chargeLimit()
            let manageCharging = getDefaultsClient.manageCharging()
            let allowDischargingFullBattery = getDefaultsClient.allowDischarging()
            let preventSleeping = getDefaultsClient.preventSleep()
            let forceCharging = getDefaultsClient.forceCharge()
            await updateStatus(
                powerState: powerState,
                chargeLimit: Int(chargeLimit),
                manageCharging: manageCharging,
                allowDischarging: allowDischargingFullBattery,
                preventSleeping: preventSleeping,
                forceCharging: forceCharging
            )
        }
    }

    @MainActor
    func updateStatus(
        powerState: PowerState,
        chargeLimit: Int,
        manageCharging: Bool,
        allowDischarging: Bool,
        preventSleeping: Bool,
        forceCharging: Bool
    ) async {
        logger.debug("⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇⬇")
        defer {
            logger.debug("⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆⬆")
        }
        if powerState.batteryLevel == 100 {
            turnOffChargeToFull()
        }
        guard manageCharging && !forceCharging else {
            logger.debug("Manage charging is turned off or Force charge is turned on")
            try? await chargingClient.turnOnAutoChargingMode()
            return
        }
        guard let lidOpened = await appChargingState.lidOpened() else {
            logger.warning("We don't know if the lid is opened")
            await fetchChargingState()
            return
        }
        do {
            let currentBatteryLevel = powerState.batteryLevel
            if currentBatteryLevel >= chargeLimit {
                if currentBatteryLevel > chargeLimit && allowDischarging && lidOpened {
                    await turnOnForceDischargeIfNeeded()
                } else {
                    await inhibitChargingIfNeeded()
                }
                restoreSleepifNeeded()
            } else {
                await turnOnChargingIfNeeded(preventSleeping: preventSleeping)
            }
        }

    }

    private func turnOnForceDischargeIfNeeded() async {
        let mode = await appChargingState.chargingStateMode()
        logger.debug("Should turn on force discharging...")
        if mode != .forceDischarge {
            logger.debug("Turning on force discharging")
            do {
                try await chargingClient.forceDischarge()
                await appChargingState.updateChargingStateMode(.forceDischarge)
                logger.debug("Force discharging TURNED ON")
            } catch {
                logger.critical("Failed to turn on force discharge. Error: \(error)")
            }
        } else {
            logger.debug("Force discharging already turned on")
        }
    }

    private func turnOnChargingIfNeeded(preventSleeping: Bool) async {
        let mode = await appChargingState.chargingStateMode()
        logger.debug("Should turn on charging...")
        if mode != .charging {
            logger.debug("Turning on charging")
            do {
                try await chargingClient.turnOnAutoChargingMode()
                await appChargingState.updateChargingStateMode(.charging)
                logger.debug("Charging TURNED ON")
            } catch {
                logger.critical("Failed to turn on charging. Error: \(error)")
            }
            if preventSleeping {
                delaySleep()
            }
        } else {
            logger.debug("Charging already turned on.")
        }
    }

    private func inhibitChargingIfNeeded() async {
        let mode = await appChargingState.chargingStateMode()
        logger.debug("Should inhibit charging...")
        if mode != .inhibit {
            logger.debug("Inhibiting charging")
            do {
                try await chargingClient.inhibitCharging()
                await appChargingState.updateChargingStateMode(.inhibit)
                logger.debug("Inhibit Charging TURNED ON")
            } catch {
                logger.critical("Failed to turn on inhibit charging. Error: \(error)")
            }
        } else {
            logger.debug("Inhibit charging already turned on.")
        }
    }

    private func delaySleep() {
        guard sleepAssertion == nil else { return }
        logger.debug("Delaying sleep")
        var assertionID: IOPMAssertionID = IOPMAssertionID(0)
        let reason: CFString = "BatFi" as NSString
        let cfAssertion: CFString = kIOPMAssertionTypePreventSystemSleep as NSString
        let success = IOPMAssertionCreateWithName(
            cfAssertion,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if success == kIOReturnSuccess {
            sleepAssertion = assertionID
        }
    }

    private func restoreSleepifNeeded() {
        if let sleepAssertion {
            logger.debug("Returning sleep")
            IOPMAssertionRelease(sleepAssertion)
            self.sleepAssertion = nil
        }
    }

    private func fetchChargingState() async {
        do {
            logger.debug("Fetching charging status")
            let chargingStatus = try await chargingClient.chargingStatus()
            if chargingStatus.forceDischarging {
                await appChargingState.updateChargingStateMode(.forceDischarge)
            } else if chargingStatus.inhitbitCharging {
                await appChargingState.updateChargingStateMode(.inhibit)
            } else {
                await appChargingState.updateChargingStateMode(.charging)
            }
            await appChargingState.updateLidOpenedStatus(!chargingStatus.lidClosed)
        } catch {
            logger.error("Error fetching charging state: \(error)")
        }
    }
}
