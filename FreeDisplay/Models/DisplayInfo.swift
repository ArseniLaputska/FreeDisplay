import Foundation
import CoreGraphics
import IOKit
import AppKit

@Observable
@MainActor
final class DisplayInfo: Identifiable {
    nonisolated var id: CGDirectDisplayID { displayID }
    let displayID: CGDirectDisplayID
    
    var name: String
    var isBuiltin: Bool
    var isMain: Bool
    var isOnline: Bool
    var isEnabled: Bool
    var bounds: CGRect
    var pixelWidth: Int
    var pixelHeight: Int
    var brightness: Double
    var availableModes: [DisplayMode]
    var currentDisplayMode: DisplayMode?
    var ddcValues: [UInt8: UInt16?] = [:]
    
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32

    /// A stable identifier for the physical display that persists across sleep/wake
    /// even if macOS reassigns the CGDirectDisplayID.
    var displayUUID: String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
           let uuidStr = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) {
            return uuidStr as String
        }
        // Fallback: vendor+model+serial hash is more stable than raw displayID
        return "v\(vendorNumber)-m\(modelNumber)-s\(serialNumber)"
    }

    /// The native (highest non-HiDPI) resolution, used for HiDPI enablement and presets.
    var nativeResolution: (width: Int, height: Int) {
        let nativeMode = availableModes
            .filter { !$0.isHiDPI }
            .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
        return (nativeMode?.width ?? pixelWidth, nativeMode?.height ?? pixelHeight)
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        let builtin = CGDisplayIsBuiltin(displayID) != 0
        self.isBuiltin = builtin
        self.isMain = CGDisplayIsMain(displayID) != 0
        self.isOnline = CGDisplayIsOnline(displayID) != 0
        self.isEnabled = CGDisplayIsActive(displayID) != 0
        self.bounds = CGDisplayBounds(displayID)
        self.pixelWidth = CGDisplayPixelsWide(displayID)
        self.pixelHeight = CGDisplayPixelsHigh(displayID)
        // Use persisted brightness as the initial value if available.
        // External displays without a readable DDC value should start at 100%, otherwise
        // touching the slider can unexpectedly dim a physically-bright monitor to 50%.
        // BrightnessService will overwrite this with the real hardware value once probed.
        self.brightness = SettingsService.shared.brightness(for: displayID) ?? (builtin ? 50.0 : 100.0)
        self.availableModes = []
        self.currentDisplayMode = DisplayMode.currentMode(for: displayID)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        self.vendorNumber = vendor
        self.modelNumber = model
        self.serialNumber = CGDisplaySerialNumber(displayID)

        if builtin {
            self.name = String(localized: "Built-in Display")
        } else {
            self.name = NSScreen.screen(for: displayID)?.localizedName ?? "Display \(displayID)"
        }

    }

    func loadDetails() async {
        let displayID = self.displayID

        async let modes = Task.detached(priority: .userInitiated) {
            DisplayMode.availableModes(for: displayID)
        }.value
        async let current = Task.detached(priority: .userInitiated) {
            DisplayMode.currentMode(for: displayID)
        }.value

        self.availableModes = await modes
        self.currentDisplayMode = await current
    }
}
