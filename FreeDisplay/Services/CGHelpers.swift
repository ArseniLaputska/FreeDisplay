import Foundation
import CoreGraphics
import IOKit
import Darwin

private final class CGHelpersResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

/// Shared utilities for wrapping blocking CoreGraphics calls.
enum CGHelpers {

    /// Runs a blocking operation on a background thread with a timeout.
    ///
    /// The operation is dispatched to a `.userInitiated` global queue. If it
    /// completes within `seconds`, its return value is forwarded. If the
    /// deadline fires first, `fallback` is returned instead.
    ///
    /// This is useful for any CoreGraphics / WindowServer IPC call that can
    /// hang indefinitely (e.g. `CGCompleteDisplayConfiguration`,
    /// `CGVirtualDisplay.apply(_:)`).
    ///
    /// - Parameters:
    ///   - seconds:   Maximum time to wait before returning `fallback`.
    ///   - fallback:  Value returned on timeout.
    ///   - operation: The blocking work to execute off-thread.
    /// - Returns: The operation's result, or `fallback` on timeout.
    static func runWithTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { cont in
            let gate = CGHelpersResumeGate()

            DispatchQueue.global(qos: .userInitiated).async {
                let result = operation()
                guard gate.claim() else { return }
                cont.resume(returning: result)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard gate.claim() else { return }
#if DEBUG
                print("[CGHelpers] runWithTimeout: timed out after \(seconds)s — returning fallback")
#endif
                cont.resume(returning: fallback)
            }
        }
    }
}

/// Runtime-loaded CoreGraphics private helpers.
///
/// Keep private symbols behind `dlopen`/`dlsym` so the app does not gain a hard
/// link-time dependency on undocumented framework exports.
enum CGPrivate {
    typealias DisplayIOServicePort = @convention(c) (CGDirectDisplayID) -> io_service_t

    private nonisolated(unsafe) static let coreGraphicsHandle: UnsafeMutableRawPointer? = {
        for path in [
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
            "CoreGraphics.framework/CoreGraphics"
        ] {
            if let handle = dlopen(path, RTLD_LAZY) {
                return handle
            }
        }
        return nil
    }()

    private static func load<T>(_ name: String, as type: T.Type) -> T? {
        guard let coreGraphicsHandle, let symbol = dlsym(coreGraphicsHandle, name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: type)
    }

    private static let displayIOServicePort = load(
        "CGDisplayIOServicePort",
        as: DisplayIOServicePort.self
    )

    static func ioServicePort(for displayID: CGDirectDisplayID) -> io_service_t {
        displayIOServicePort?(displayID) ?? io_service_t(MACH_PORT_NULL)
    }
}
