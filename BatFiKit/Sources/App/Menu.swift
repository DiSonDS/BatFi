//
//  Menu.swift
//  BatFi
//
//  Created by Adam on 26/04/2023.
//

import BatteryInfo
import Cocoa
import MenuBuilder

final class MenuFactory {
    static func standardMenu(
        disableCharging: @escaping () -> Void,
        enableCharging: @escaping () -> Void
    ) -> NSMenu {
        NSMenu {
            MenuItem("")
                .view {
                    BatteryInfoView()
                }
            SeparatorItem()
            MenuItem("Disable charging")
                .onSelect(disableCharging)
            MenuItem("Enable charging")
                .onSelect(enableCharging)
            SeparatorItem()
            MenuItem("Debug")
                .submenu {
                    MenuItem("Install Helper").onSelect {
                        try? HelperManager.shared.registerService()
                    }
                    MenuItem("Remove Helper").onSelect {
                        try? HelperManager.shared.removeService()
                    }
                }
            SeparatorItem()
            MenuItem("Quit BatFi")
                .onSelect(target: NSApp, action: #selector(NSApp.terminate(_:)))
                .shortcut("q")
        }
    }
}