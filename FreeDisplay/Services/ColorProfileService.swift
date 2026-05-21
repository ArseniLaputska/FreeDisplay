import Foundation
import CoreGraphics
import AppKit
import IOKit
import Darwin
@preconcurrency import ColorSync

private enum DisplayModeIntrospection {
    typealias CopyPixelEncoding = @convention(c) (CGDisplayMode?) -> Unmanaged<CFString>?

    private static let copyPixelEncoding: CopyPixelEncoding? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGDisplayModeCopyPixelEncoding") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CopyPixelEncoding.self)
    }()

    static func pixelEncoding(for mode: CGDisplayMode?) -> String {
        guard let encoded = copyPixelEncoding?(mode) else { return "" }
        return encoded.takeRetainedValue() as String
    }
}

/// ICC color profile model.
struct ICCProfile: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: URL
    let colorSpaceType: String  // "RGB", "CMYK", "Gray", etc.

    init(name: String, path: URL, colorSpaceType: String) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.colorSpaceType = colorSpaceType
    }

    /// Convenience failable initializer: loads profile metadata from a file URL.
    init?(url: URL) {
        guard let profile = ColorProfileService.makeProfile(from: url) else { return nil }
        self = profile
    }

    static func == (lhs: ICCProfile, rhs: ICCProfile) -> Bool {
        lhs.path == rhs.path
    }
}

/// Service for ICC color profile enumeration and switching.
/// Uses ColorSync framework + file system scanning.
final class ColorProfileService: @unchecked Sendable {
    static let shared = ColorProfileService()
    private init() {}

    // MARK: - Profile Enumeration

    /// Returns all installed ICC profiles sorted alphabetically.
    func enumerateProfiles() async -> [ICCProfile] {
        await Task.detached(priority: .userInitiated) {
            var profiles: [ICCProfile] = []
            let searchURLs: [URL] = [
                URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
                URL(fileURLWithPath: "/System/Library/ColorSync/Profiles"),
                URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/ColorSync/Profiles")
            ]

            var seenPaths = Set<URL>()
            let fm = FileManager.default

            for dir in searchURLs {
                guard let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                while let url = enumerator.nextObject() as? URL {
                    guard !seenPaths.contains(url) else { continue }
                    let ext = url.pathExtension.lowercased()
                    guard ext == "icc" || ext == "icm" else { continue }
                    seenPaths.insert(url)
                    if let profile = Self.makeProfileImpl(from: url) {
                        profiles.append(profile)
                    }
                }
            }

            return profiles.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value
    }

    static func makeProfile(from url: URL) -> ICCProfile? {
        makeProfileImpl(from: url)
    }

    private static func makeProfileImpl(from url: URL) -> ICCProfile? {
        let name: String
        let csType: String

        if let rawProfile = ColorSyncProfileCreateWithURL(url as CFURL, nil) {
            let profile = rawProfile.takeRetainedValue()
            if let rawDesc = ColorSyncProfileCopyDescriptionString(profile) {
                name = rawDesc.takeRetainedValue() as String
            } else {
                name = url.deletingPathExtension().lastPathComponent
            }
            csType = colorSpaceType(from: profile)
        } else {
            name = url.deletingPathExtension().lastPathComponent
            csType = "RGB"
        }

        return ICCProfile(name: name, path: url, colorSpaceType: csType)
    }

    private static func colorSpaceType(from profile: ColorSyncProfile) -> String {
        guard let rawData = ColorSyncProfileCopyHeader(profile) else { return "RGB" }
        let data = rawData.takeRetainedValue() as Data
        // ICC header: data color space at byte offset 16, 4 bytes (ASCII-encoded tag).
        guard data.count >= 20 else { return "RGB" }
        let bytes = [UInt8](data[16..<20])
        // Validate that all bytes are printable ASCII (0x20–0x7E) before decoding.
        // Non-ASCII bytes indicate a corrupt or non-standard header; fall back to "RGB".
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
              let str = String(bytes: bytes, encoding: .ascii) else { return "RGB" }
        switch str.trimmingCharacters(in: .whitespaces) {
        case "RGB":  return "RGB"
        case "CMYK": return "CMYK"
        case "GRAY": return "Gray"
        case "LAB":  return "Lab"
        case "XYZ":  return "XYZ"
        default:     return "RGB"
        }
    }

    // MARK: - Current Color Info

    /// Returns the human-readable color space name for the given display.
    func currentColorSpaceName(for displayID: CGDirectDisplayID) -> String {
        let colorSpace = CGDisplayCopyColorSpace(displayID)
        guard let cfName = colorSpace.name else { return String(localized: "Unknown") }
        return humanReadable(cfName as String)
    }

    /// Returns a description like "Built-in (8-bit)" for the display's current color mode.
    func colorModeDescription(for displayID: CGDirectDisplayID) -> String {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return String(localized: "Unknown") }
        let encoding = DisplayModeIntrospection.pixelEncoding(for: mode)
        let bpc = bitsPerChannel(from: encoding)
        let source = CGDisplayIsBuiltin(displayID) != 0 ? String(localized: "Built-in") : String(localized: "External")
        return "\(source) (\(bpc)-bit)"
    }

    private func bitsPerChannel(from encoding: String) -> Int {
        let rCount = encoding.filter { $0 == "R" }.count
        if rCount > 0 { return rCount }
        let dCount = encoding.filter { $0 == "D" }.count
        return dCount >= 30 ? 10 : 8
    }

    // Bridge CGColorSpace CFString constants to Swift String for comparison
    private func humanReadable(_ name: String) -> String {
        if name == (CGColorSpace.displayP3 as String)           { return "Display P3" }
        if name == (CGColorSpace.sRGB as String)                { return "sRGB IEC61966-2.1" }
        if name == (CGColorSpace.adobeRGB1998 as String)        { return "Adobe RGB (1998)" }
        if name == (CGColorSpace.genericRGBLinear as String)    { return "Generic RGB Linear" }
        if name == (CGColorSpace.extendedSRGB as String)        { return "Extended sRGB" }
        if name == (CGColorSpace.linearSRGB as String)          { return "Linear sRGB" }
        if name == (CGColorSpace.extendedLinearSRGB as String)  { return "Extended Linear sRGB" }
        if name == (CGColorSpace.genericGrayGamma2_2 as String) { return "Generic Gray Gamma 2.2" }
        if name.hasPrefix("kCGColorSpace") {
            return String(name.dropFirst("kCGColorSpace".count))
        }
        return name
    }

    // MARK: - Current Profile URL

    /// Returns the file URL of the currently active ICC profile for the given display, if available.
    func currentProfileURL(for displayID: CGDirectDisplayID) -> URL? {
        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = rawUUID.takeRetainedValue()

        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue(),
              let factoryProfilesKey = kColorSyncFactoryProfiles?.takeUnretainedValue(),
              let customProfilesKey = kColorSyncCustomProfiles?.takeUnretainedValue(),
              let profileURLKey = kColorSyncDeviceProfileURL?.takeUnretainedValue()
        else { return nil }

        guard let rawInfo = ColorSyncDeviceCopyDeviceInfo(deviceClass, uuid) else { return nil }
        let info = rawInfo.takeRetainedValue() as NSDictionary

        let customProfiles = info[customProfilesKey] as? NSDictionary
        if let url = customProfiles?[profileIDKey] as? NSURL {
            return url as URL
        }

        // Determine the active mode name from FactoryProfiles[DeviceDefaultProfileID].
        // Both CustomProfiles and FactoryProfiles use this mode name as their key.
        let factoryProfiles = info[factoryProfilesKey] as? NSDictionary
        let activeModeName = factoryProfiles?[profileIDKey] as? String

        // CustomProfiles: keys are mode names, values are NSURL directly.
        if let modeName = activeModeName,
           let url = customProfiles?[modeName] as? NSURL {
            return url as URL
        }

        // Fall back to FactoryProfiles: the mode entry is a dict with a DeviceProfileURL.
        if let modeName = activeModeName,
           let modeDict = factoryProfiles?[modeName] as? NSDictionary {
            if let url = modeDict[profileURLKey] as? NSURL {
                return url as URL
            }
            if let urlString = modeDict[profileURLKey] as? String {
                return URL(string: urlString)
            }
        }

        return nil
    }

    // MARK: - Profile Switching

    /// Sets the ICC profile for the given display using ColorSync.
    /// Returns true on success.
    @discardableResult
    func setProfile(_ profile: ICCProfile, for displayID: CGDirectDisplayID) -> Bool {
        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return false }
        let uuid = rawUUID.takeRetainedValue()

        // kColorSyncDisplayDeviceClass and kColorSyncDeviceDefaultProfileID are
        // Unmanaged<CFString>? in the current SDK; use takeUnretainedValue() to borrow them.
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else { return false }

        let profileInfo: NSDictionary = [profileIDKey: profile.path as NSURL]

        return ColorSyncDeviceSetCustomProfiles(
            deviceClass,
            uuid,
            profileInfo as CFDictionary
        )
    }
}

// MARK: - Advanced Display Diagnostics

private enum CoreDisplayPrivate {
    typealias CGXDisplayDeviceRef = UnsafeRawPointer
    typealias CDDisplayRef = UnsafeRawPointer

    typealias CGXDisplayDeviceForDisplayID = @convention(c) (CGDirectDisplayID) -> CGXDisplayDeviceRef?
    typealias CoreDisplayForCGXDevice = @convention(c) (CGXDisplayDeviceRef?) -> CDDisplayRef?
    typealias BoolIDGetter = @convention(c) (CGDirectDisplayID) -> Bool
    typealias VoidIDBoolSetter = @convention(c) (CGDirectDisplayID, Bool) -> Void
    typealias FloatIDGetter = @convention(c) (CGDirectDisplayID) -> Float
    typealias VoidIDDoubleSetter = @convention(c) (CGDirectDisplayID, Double) -> Void
    typealias BoolDisplayGetter = @convention(c) (CDDisplayRef?) -> Bool
    typealias FloatDisplayGetter = @convention(c) (CDDisplayRef?) -> Float
    typealias VoidDisplayFloatSetter = @convention(c) (CDDisplayRef?, Float) -> Void
    typealias ForceColorOutput = @convention(c) (CGDirectDisplayID, UInt32, Float, Float, Float) -> Void

    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = {
        for path in [
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            "/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay",
            "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay",
            "CoreDisplay.framework/CoreDisplay"
        ] {
            if let handle = dlopen(path, RTLD_LAZY) {
                return handle
            }
        }
        return nil
    }()

    private static func load<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private nonisolated(unsafe) static let _displayDeviceForDisplayIDPtr: UnsafeMutableRawPointer? = {
        guard let handle = CoreDisplayPrivate.handle else { return nil }
        return dlsym(handle, "CGXDisplayDeviceForDisplayID")
    }()
    
    private nonisolated(unsafe) static let _coreDisplayForDevicePtr: UnsafeMutableRawPointer? = {
        guard let handle = CoreDisplayPrivate.handle else { return nil }
        return dlsym(handle, "CoreDisplay_GetDisplayForCGXDisplayDevice")
    }()

    static let supportsHDRMode = load("CoreDisplay_Display_SupportsHDRMode", as: BoolIDGetter.self)
    static let isHDRModeEnabled = load("CoreDisplay_Display_IsHDRModeEnabled", as: BoolIDGetter.self)
    static let setHDRModeEnabled = load("CoreDisplay_Display_SetHDRModeEnabled", as: VoidIDBoolSetter.self)
    static let isEDREnabled = load("CoreDisplay_Display_IsEDREnabled", as: BoolDisplayGetter.self)
    static let getCurrentHeadroom = load("CoreDisplay_Display_GetCurrentHeadroom", as: FloatIDGetter.self)
    static let getPotentialHeadroom = load("CoreDisplay_Display_GetPotentialHeadroom", as: FloatIDGetter.self)
    static let getReferenceHeadroom = load("CoreDisplay_Display_GetReferenceHeadroom", as: FloatIDGetter.self)
    static let requestHeadroom = load("CoreDisplay_Display_RequestHeadroom", as: VoidDisplayFloatSetter.self)
    static let getDisplayBrightnessInNits = load("CoreDisplay_Display_GetDisplayBrightnessInNits", as: FloatDisplayGetter.self)
    static let getNominalPixelNits = load("CoreDisplay_Display_GetNominalPixelNits", as: FloatIDGetter.self)
    static let setDynamicLinearBrightness = load("CoreDisplay_Display_SetDynamicLinearBrightness", as: VoidIDDoubleSetter.self)
    static let forceColorOutput = load("CoreDisplay_Display_ForceColorOutput", as: ForceColorOutput.self)

    static var isAvailable: Bool { handle != nil }

    static func displayRef(for displayID: CGDirectDisplayID) -> CDDisplayRef? {
        guard CGDisplayIsActive(displayID) != 0 else { return nil }

        guard let fnPtr = _displayDeviceForDisplayIDPtr else { return nil }
        typealias Fn = @convention(c) (CGDirectDisplayID) -> CGXDisplayDeviceRef?
        let fn = unsafeBitCast(fnPtr, to: Fn.self)
        guard let device = fn(displayID) else { return nil }

        guard let fn2Ptr = _coreDisplayForDevicePtr else { return nil }
        typealias Fn2 = @convention(c) (CGXDisplayDeviceRef?) -> CDDisplayRef?
        let fn2 = unsafeBitCast(fn2Ptr, to: Fn2.self)
        return fn2(device)
    }
}

private enum SkyLightPrivate {
    typealias SLSConfigRef = UnsafeMutableRawPointer
    typealias BeginDisplayConfiguration = @convention(c) (UnsafeMutablePointer<SLSConfigRef?>) -> Int32
    typealias ConfigureDisplayEnabled = @convention(c) (SLSConfigRef?, CGDirectDisplayID, Int32) -> Int32
    typealias CompleteDisplayConfiguration = @convention(c) (SLSConfigRef?) -> Int32
    typealias CancelDisplayConfiguration = @convention(c) (SLSConfigRef?) -> Int32
    typealias GetDisplayOutputModeCount = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutablePointer<Int32>) -> Int32
    typealias GetDisplayOutputModeLinkDescriptions = @convention(c) (
        CGDirectDisplayID,
        Int32,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<Int32>,
        UnsafeMutablePointer<Int32>
    ) -> Int32
    typealias SetDisplayOutputMode = @convention(c) (CGDirectDisplayID, UInt64, UInt64) -> Int32
    typealias ConfigureDisplayOutputMode = @convention(c) (SLSConfigRef?, CGDirectDisplayID, UInt64, UInt64) -> Int32

    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = {
        for path in [
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            "SkyLight.framework/SkyLight"
        ] {
            if let handle = dlopen(path, RTLD_LAZY) {
                return handle
            }
        }
        return nil
    }()

    private static func load<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static let beginConfiguration = load(
        "SLSBeginDisplayConfiguration",
        as: BeginDisplayConfiguration.self
    )
    private static let configureDisplayEnabled = load(
        "SLSConfigureDisplayEnabled",
        as: ConfigureDisplayEnabled.self
    )
    private static let completeConfiguration = load(
        "SLSCompleteDisplayConfiguration",
        as: CompleteDisplayConfiguration.self
    )
    private static let cancelConfiguration = load(
        "SLSCancelDisplayConfiguration",
        as: CancelDisplayConfiguration.self
    )
    private static let getOutputModeCount = load(
        "SLSGetDisplayOutputModeCount",
        as: GetDisplayOutputModeCount.self
    )
    private static let getOutputModeLinks = load(
        "SLSGetDisplayOutputModeLinkDescriptions",
        as: GetDisplayOutputModeLinkDescriptions.self
    )
    private static let setOutputModeDirect = load(
        "SLSSetDisplayOutputMode",
        as: SetDisplayOutputMode.self
    )
    private static let configureOutputMode = load(
        "SLSConfigureDisplayOutputMode",
        as: ConfigureDisplayOutputMode.self
    )

    static var canConfigureDisplayEnabled: Bool {
        beginConfiguration != nil && configureDisplayEnabled != nil && completeConfiguration != nil
    }

    static var canSetOutputMode: Bool {
        setOutputModeDirect != nil || (
            beginConfiguration != nil &&
            configureOutputMode != nil &&
            completeConfiguration != nil
        )
    }

    static func setDisplayEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool {
        guard let beginConfiguration,
              let configureDisplayEnabled,
              let completeConfiguration else { return false }

        var config: SLSConfigRef?
        guard beginConfiguration(&config) == 0, config != nil else { return false }

        let configured = configureDisplayEnabled(config, displayID, enabled ? 1 : 0)
        guard configured == 0 else {
            _ = cancelConfiguration?(config)
            return false
        }

        let completed = completeConfiguration(config)
        if completed != 0 {
            _ = cancelConfiguration?(config)
        }
        return completed == 0
    }

    static func outputModes(for displayID: CGDirectDisplayID) -> [DisplayOutputMode] {
        guard let getOutputModeCount, let getOutputModeLinks else { return [] }

        for displayModeIndex in 0..<96 {
            var count: Int32 = 0
            guard getOutputModeCount(displayID, Int32(displayModeIndex), &count) == 0,
                  count > 0,
                  count <= 64 else { continue }

            var tokens = [UInt64](repeating: 0, count: Int(count) * 2)
            var requested = count
            var activeIndex: Int32 = -1
            let linksResult = tokens.withUnsafeMutableBytes { buffer -> Int32 in
                return getOutputModeLinks(
                    displayID,
                    Int32(displayModeIndex),
                    buffer.baseAddress,
                    &requested,
                    &activeIndex
                )
            }
            guard linksResult == 0 else { continue }

            let usableCount = max(0, min(Int(requested), tokens.count / 2))
            let modes = (0..<usableCount).compactMap { index -> DisplayOutputMode? in
                let tokenA = tokens[index * 2]
                let tokenB = tokens[index * 2 + 1]
                guard tokenA != 0 || tokenB != 0 else { return nil }
                return DisplayOutputMode(
                    displayModeIndex: Int32(displayModeIndex),
                    outputIndex: Int32(index),
                    tokenA: tokenA,
                    tokenB: tokenB,
                    isActive: Int32(index) == activeIndex
                )
            }
            if !modes.isEmpty {
                return modes
            }
        }

        return []
    }

    static func setOutputMode(_ mode: DisplayOutputMode, for displayID: CGDirectDisplayID) -> Bool {
        if let setOutputModeDirect {
            return setOutputModeDirect(displayID, mode.tokenA, mode.tokenB) == 0
        }

        guard let beginConfiguration,
              let configureOutputMode,
              let completeConfiguration else { return false }

        var config: SLSConfigRef?
        guard beginConfiguration(&config) == 0, config != nil else { return false }

        let configured = configureOutputMode(config, displayID, mode.tokenA, mode.tokenB)
        guard configured == 0 else {
            _ = cancelConfiguration?(config)
            return false
        }

        let completed = completeConfiguration(config)
        if completed != 0 {
            _ = cancelConfiguration?(config)
        }
        return completed == 0
    }
}

struct DisplayOutputMode: Identifiable, Equatable, Sendable {
    let displayModeIndex: Int32
    let outputIndex: Int32
    let tokenA: UInt64
    let tokenB: UInt64
    let isActive: Bool

    var id: String {
        "\(displayModeIndex)-\(outputIndex)-\(String(tokenA, radix: 16))-\(String(tokenB, radix: 16))"
    }

    var label: String {
        if isActive {
            return "Mode \(outputIndex + 1) (active)"
        }
        return "Mode \(outputIndex + 1)"
    }

    var tokenDescription: String {
        "0x\(String(tokenA, radix: 16).uppercased()) / 0x\(String(tokenB, radix: 16).uppercased())"
    }
}

struct SoftDisconnectedDisplay: Identifiable, Codable, Equatable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let serialID: UInt32
    let disconnectedAt: Date

    var displayID: CGDirectDisplayID { id }
}

struct AdvancedDisplayState: Sendable {
    let pixelEncoding: String
    let bitsPerChannel: Int
    let colorTransport: String
    let dynamicRange: String
    let edrCurrent: Double
    let edrPotential: Double
    let coreDisplayAvailable: Bool
    let hdrSupported: Bool?
    let hdrEnabled: Bool?
    let edrEnabled: Bool?
    let currentHeadroom: Double?
    let potentialHeadroom: Double?
    let referenceHeadroom: Double?
    let displayNits: Double?
    let nominalPixelNits: Double?
    let canSetHDR: Bool
    let canRequestHeadroom: Bool
    let canSetDynamicBrightness: Bool
    let canForceColorOutput: Bool
    let outputModes: [DisplayOutputMode]
    let canSetOutputMode: Bool
    let canSoftDisconnect: Bool
    let hasEDID: Bool
    let edidHex: String?
    let vendorID: UInt32
    let productID: UInt32
    let serialID: UInt32
}

extension AdvancedDisplayState {
    static func unavailable(for displayID: CGDirectDisplayID) -> AdvancedDisplayState {
        AdvancedDisplayState(
            pixelEncoding: "Unknown",
            bitsPerChannel: 8,
            colorTransport: "Unknown",
            dynamicRange: "SDR",
            edrCurrent: 1.0,
            edrPotential: 1.0,
            coreDisplayAvailable: false,
            hdrSupported: nil,
            hdrEnabled: nil,
            edrEnabled: nil,
            currentHeadroom: nil,
            potentialHeadroom: nil,
            referenceHeadroom: nil,
            displayNits: nil,
            nominalPixelNits: nil,
            canSetHDR: false,
            canRequestHeadroom: false,
            canSetDynamicBrightness: false,
            canForceColorOutput: false,
            outputModes: [],
            canSetOutputMode: false,
            canSoftDisconnect: false,
            hasEDID: false,
            edidHex: nil,
            vendorID: CGDisplayVendorNumber(displayID),
            productID: CGDisplayModelNumber(displayID),
            serialID: CGDisplaySerialNumber(displayID)
        )
    }
}

@MainActor @Observable
final class AdvancedDisplayService: @unchecked Sendable {
    static let shared = AdvancedDisplayService()
    private(set) var softDisconnectedDisplays: [SoftDisconnectedDisplay] = []
    @ObservationIgnored
    private var wsReady: Bool = false

    private let softDisconnectedKey = "fd.softDisconnectedDisplays"

    private init() {
        loadSoftDisconnectedDisplays()
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard let userInfo else { return }
            let service = Unmanaged<AdvancedDisplayService>
                .fromOpaque(userInfo).takeUnretainedValue()
            Task { @MainActor in service.wsReady = true }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func state(for displayID: CGDirectDisplayID) -> AdvancedDisplayState {
        guard wsReady else {
            return .unavailable(for: displayID)
        }
        guard CGDisplayIsActive(displayID) != 0 else {
            return .unavailable(for: displayID)
        }
        
        let mode = CGDisplayCopyDisplayMode(displayID)
        let rawEncoding = DisplayModeIntrospection.pixelEncoding(for: mode)
        let encoding = rawEncoding.isEmpty ? "Unknown" : rawEncoding
        let bits = bitsPerChannel(from: encoding)
        let screen = NSScreen.screen(for: displayID)
        let currentEDR = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0
        let potentialEDR = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? currentEDR
        let edid = edidData(for: displayID)
        let displayRef = CoreDisplayPrivate.displayRef(for: displayID)

        let hdrSupported = CoreDisplayPrivate.supportsHDRMode?(displayID)
        let hdrEnabled = CoreDisplayPrivate.isHDRModeEnabled?(displayID)
        let edrEnabled = displayRef.flatMap { CoreDisplayPrivate.isEDREnabled?($0) }
        let currentHeadroom = sanitizeHeadroom(CoreDisplayPrivate.getCurrentHeadroom?(displayID))
        let potentialHeadroom = sanitizeHeadroom(CoreDisplayPrivate.getPotentialHeadroom?(displayID))
        let referenceHeadroom = sanitizeHeadroom(CoreDisplayPrivate.getReferenceHeadroom?(displayID))
        let displayNits = displayRef.flatMap { sanitizeNits(CoreDisplayPrivate.getDisplayBrightnessInNits?($0)) }
        let nominalPixelNits = sanitizeNits(CoreDisplayPrivate.getNominalPixelNits?(displayID))
        let outputModes = SkyLightPrivate.outputModes(for: displayID)

        return AdvancedDisplayState(
            pixelEncoding: encoding,
            bitsPerChannel: bits,
            colorTransport: colorTransportDescription(from: encoding),
            dynamicRange: dynamicRangeDescription(
                hdrEnabled: hdrEnabled,
                edrPotential: potentialEDR,
                privatePotentialHeadroom: potentialHeadroom
            ),
            edrCurrent: currentEDR,
            edrPotential: potentialEDR,
            coreDisplayAvailable: CoreDisplayPrivate.isAvailable,
            hdrSupported: hdrSupported,
            hdrEnabled: hdrEnabled,
            edrEnabled: edrEnabled,
            currentHeadroom: currentHeadroom,
            potentialHeadroom: potentialHeadroom,
            referenceHeadroom: referenceHeadroom,
            displayNits: displayNits,
            nominalPixelNits: nominalPixelNits,
            canSetHDR: CoreDisplayPrivate.setHDRModeEnabled != nil && hdrSupported == true,
            canRequestHeadroom: CoreDisplayPrivate.requestHeadroom != nil && displayRef != nil,
            canSetDynamicBrightness: CoreDisplayPrivate.setDynamicLinearBrightness != nil,
            canForceColorOutput: CoreDisplayPrivate.forceColorOutput != nil,
            outputModes: outputModes,
            canSetOutputMode: SkyLightPrivate.canSetOutputMode && !outputModes.isEmpty,
            canSoftDisconnect: canSoftDisconnect(displayID),
            hasEDID: edid != nil,
            edidHex: edid?.map { String(format: "%02X", $0) }.joined(separator: " "),
            vendorID: CGDisplayVendorNumber(displayID),
            productID: CGDisplayModelNumber(displayID),
            serialID: CGDisplaySerialNumber(displayID)
        )
    }

    @discardableResult
    func setHDRMode(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Bool {
        guard CoreDisplayPrivate.supportsHDRMode?(displayID) == true,
              let setHDRModeEnabled = CoreDisplayPrivate.setHDRModeEnabled else {
            return false
        }
        setHDRModeEnabled(displayID, enabled)
        return true
    }

    @discardableResult
    func requestHeadroom(_ factor: Double, for displayID: CGDirectDisplayID) -> Bool {
        guard let displayRef = CoreDisplayPrivate.displayRef(for: displayID),
              let requestHeadroom = CoreDisplayPrivate.requestHeadroom else {
            return false
        }
        let maxKnown = sanitizeHeadroom(CoreDisplayPrivate.getPotentialHeadroom?(displayID)) ?? 64.0
        let upperBound = max(1.0, min(maxKnown, 64.0))
        let target = Float(max(1.0, min(factor, upperBound)))
        requestHeadroom(displayRef, target)
        return true
    }

    @discardableResult
    func setDynamicLinearBrightness(_ factor: Double, for displayID: CGDirectDisplayID) -> Bool {
        guard let setDynamicLinearBrightness = CoreDisplayPrivate.setDynamicLinearBrightness else {
            return false
        }
        let target = max(0.0, min(factor, 16.0))
        setDynamicLinearBrightness(displayID, target)
        return true
    }

    @discardableResult
    func forceColorOutput(_ rawMode: Int32, for displayID: CGDirectDisplayID) -> Bool {
        guard let forceColorOutput = CoreDisplayPrivate.forceColorOutput,
              rawMode >= 0,
              rawMode <= 8 else {
            return false
        }
        forceColorOutput(displayID, UInt32(rawMode), 1.0, 1.0, 1.0)
        return true
    }

    @discardableResult
    func setOutputMode(_ mode: DisplayOutputMode, for displayID: CGDirectDisplayID) -> Bool {
        SkyLightPrivate.setOutputMode(mode, for: displayID)
    }

    @discardableResult
    func softDisconnect(display: DisplayInfo) -> Bool {
        let displayID = display.displayID
        guard canSoftDisconnect(displayID) else { return false }

        rememberSoftDisconnectedDisplay(
            SoftDisconnectedDisplay(
                id: displayID,
                name: display.name,
                vendorID: CGDisplayVendorNumber(displayID),
                productID: CGDisplayModelNumber(displayID),
                serialID: CGDisplaySerialNumber(displayID),
                disconnectedAt: Date()
            )
        )

        let ok = SkyLightPrivate.setDisplayEnabled(false, for: displayID)
        if !ok {
            forgetSoftDisconnectedDisplay(displayID)
        }
        return ok
    }

    @discardableResult
    func reconnectSoftDisconnectedDisplay(_ record: SoftDisconnectedDisplay) -> Bool {
        let ok = SkyLightPrivate.setDisplayEnabled(true, for: record.displayID)
        if ok {
            forgetSoftDisconnectedDisplay(record.displayID)
        }
        return ok
    }

    func forgetSoftDisconnectedDisplay(_ displayID: CGDirectDisplayID) {
        softDisconnectedDisplays.removeAll { $0.displayID == displayID }
        saveSoftDisconnectedDisplays()
    }

    func copyEDIDHex(for displayID: CGDirectDisplayID) -> Bool {
        guard let hex = state(for: displayID).edidHex else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        return true
    }

    private func canSoftDisconnect(_ displayID: CGDirectDisplayID) -> Bool {
        guard SkyLightPrivate.canConfigureDisplayEnabled,
              CGDisplayIsBuiltin(displayID) == 0,
              CGMainDisplayID() != displayID else { return false }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        return count > 1
    }

    private func rememberSoftDisconnectedDisplay(_ record: SoftDisconnectedDisplay) {
        softDisconnectedDisplays.removeAll { $0.displayID == record.displayID }
        softDisconnectedDisplays.append(record)
        softDisconnectedDisplays.sort { $0.disconnectedAt > $1.disconnectedAt }
        saveSoftDisconnectedDisplays()
    }

    private func loadSoftDisconnectedDisplays() {
        guard let data = UserDefaults.standard.data(forKey: softDisconnectedKey),
              let decoded = try? JSONDecoder().decode([SoftDisconnectedDisplay].self, from: data) else {
            return
        }
        softDisconnectedDisplays = decoded
    }

    private func saveSoftDisconnectedDisplays() {
        guard let data = try? JSONEncoder().encode(softDisconnectedDisplays) else { return }
        UserDefaults.standard.set(data, forKey: softDisconnectedKey)
    }

    private func sanitizeHeadroom(_ value: Float?) -> Double? {
        guard let value, value.isFinite, value >= 0.0, value <= 64.0 else { return nil }
        return Double(value)
    }

    private func sanitizeNits(_ value: Float?) -> Double? {
        guard let value, value.isFinite, value >= 0.0, value <= 10000.0 else { return nil }
        return Double(value)
    }

    private func bitsPerChannel(from encoding: String) -> Int {
        let rCount = encoding.filter { $0 == "R" }.count
        if rCount > 0 { return rCount }
        let dCount = encoding.filter { $0 == "D" }.count
        return dCount >= 30 ? 10 : 8
    }

    private func colorTransportDescription(from encoding: String) -> String {
        let lower = encoding.lowercased()
        if lower.contains("ycbcr") || lower.contains("yuv") {
            return "YCbCr"
        }
        if lower.contains("rgb") || encoding.contains("R") {
            return "RGB"
        }
        return "Unknown"
    }

    private func dynamicRangeDescription(
        hdrEnabled: Bool?,
        edrPotential: Double,
        privatePotentialHeadroom: Double?
    ) -> String {
        if hdrEnabled == true {
            let headroom = privatePotentialHeadroom ?? edrPotential
            return "HDR \(String(format: "%.1fx", headroom))"
        }
        if edrPotential > 1.0 || (privatePotentialHeadroom ?? 1.0) > 1.0 {
            let headroom = max(edrPotential, privatePotentialHeadroom ?? 1.0)
            return "EDR \(String(format: "%.1fx", headroom))"
        }
        return "SDR"
    }

    private func edidData(for displayID: CGDirectDisplayID) -> Data? {
        let vendor = CGDisplayVendorNumber(displayID)
        let product = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let rawInfo = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue()
            else { continue }
            let info = rawInfo as NSDictionary

            let serviceVendor = uint32Value(info["DisplayVendorID"])
            let serviceProduct = uint32Value(info["DisplayProductID"])
            let serviceSerial = uint32Value(info["DisplaySerialNumber"])
            guard serviceVendor == vendor, serviceProduct == product else { continue }
            if serial != 0, serviceSerial != 0, serial != serviceSerial { continue }

            if let rawEDID = info["IODisplayEDID"] {
                return rawEDID as? Data
            }
        }
        return nil
    }

    private func uint32Value(_ value: Any?) -> UInt32 {
        if let n = value as? UInt32 { return n }
        if let n = value as? Int { return UInt32(bitPattern: Int32(truncatingIfNeeded: n)) }
        if let n = value as? NSNumber { return n.uint32Value }
        return 0
    }
}
