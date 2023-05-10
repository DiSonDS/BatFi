//
//  SMCStatus.swift
//  BatFi
//
//  Created by Adam on 25/04/2023.
//

import Foundation

public struct SMCStatus: Codable {
    public let forceDischarging: Bool
    public let inhitbitCharging: Bool
    public let lidClosed: Bool

    public var isCharging: Bool {
        !forceDischarging && !inhitbitCharging
    }

    public init(
        forceDischarging: Bool,
        inhitbitCharging: Bool,
        lidClosed: Bool
    ) {
        self.forceDischarging = forceDischarging
        self.inhitbitCharging = inhitbitCharging
        self.lidClosed = lidClosed
    }

}
