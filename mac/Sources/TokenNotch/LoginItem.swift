import ServiceManagement
import SwiftUI

/// Opening the app when you log in, so the notch doesn't go blank after a restart.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }

    /// On the first launch only; after that it is the person's choice.
    static func enableOnFirstLaunch() {
        let key = "loginItemOffered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }

    /// A switch for menus, read fresh each time it is shown.
    static var binding: Binding<Bool> { Binding(get: { enabled }, set: { set($0) }) }
}
