import CoreGraphics
import Foundation
import IOKit

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isExternal: Bool
}

struct Resolution: Identifiable, Hashable {
    let width: Int
    let height: Int
    let hiDPI: Bool

    var id: String { "\(width)x\(height)" }
    var label: String { "\(width) × \(height)" }
}

struct DisplayMode: Identifiable, Hashable {
    let id: Int32 // modeNumber
    let width: Int
    let height: Int
    let refreshRate: Double
    let isHiDPI: Bool

    var label: String {
        "\(Int(refreshRate)) Hz"
    }
}

final class DisplayManager {
    static let shared = DisplayManager()

    // Cached modes for sleep/wake — resolved while display is still active
    private var cachedSleepMode: CGDisplayMode?
    private var cachedWakeMode: CGDisplayMode?
    private var cachedDisplayID: CGDirectDisplayID = 0

    /// Called when an external display is added or removed.
    /// Parameters: (displayID, isAdded). `isAdded` is true for connect, false for disconnect.
    var onExternalDisplayChanged: ((_ displayID: CGDirectDisplayID, _ isAdded: Bool) -> Void)?
    private var reconfigCallbackRegistered = false

    func startWatchingDisplays() {
        guard !reconfigCallbackRegistered else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, refcon)
        reconfigCallbackRegistered = (result == .success)
        NSLog("[Refreshing] CGDisplayRegisterReconfigurationCallback: \(reconfigCallbackRegistered ? "registered" : "FAILED")")
    }

    func stopWatchingDisplays() {
        guard reconfigCallbackRegistered else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, refcon)
        reconfigCallbackRegistered = false
    }

    fileprivate func handleReconfiguration(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        // Only act on the "completed" phase (afterDoneFlag), not the "begin" phase
        guard flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
        guard !flags.contains(.beginConfigurationFlag) else { return }

        let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
        guard !isBuiltin else { return }

        let isAdded = flags.contains(.addFlag)
        NSLog("[Refreshing] Display reconfiguration: id=\(displayID) \(isAdded ? "ADDED" : "REMOVED")")
        onExternalDisplayChanged?(displayID, isAdded)
    }

    func allDisplays() -> [(id: CGDirectDisplayID, builtin: Bool)] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displayIDs, &displayCount) == .success else {
            NSLog("[Refreshing] CGGetOnlineDisplayList failed")
            return []
        }
        let result = (0..<Int(displayCount)).map { i in
            let id = displayIDs[i]
            let builtin = CGDisplayIsBuiltin(id) != 0
            return (id: id, builtin: builtin)
        }
        NSLog("[Refreshing] allDisplays: \(result.map { "id=\($0.id) builtin=\($0.builtin)" })")
        return result
    }

    func externalDisplays() -> [DisplayInfo] {
        return allDisplays().compactMap { display in
            guard !display.builtin else { return nil }
            let name = displayName(for: display.id)
            return DisplayInfo(id: display.id, name: name, isExternal: true)
        }
    }

    /// Returns available HiDPI resolutions for a display, sorted largest first.
    func availableResolutions(for displayID: CGDirectDisplayID) -> [Resolution] {
        guard let allModes = CGDisplayCopyAllDisplayModes(displayID, [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary) as? [CGDisplayMode] else {
            return []
        }
        var seen = Set<String>()
        var results = [Resolution]()
        for mode in allModes where mode.pixelWidth > mode.width { // HiDPI only
            let key = "\(mode.width)x\(mode.height)"
            if seen.insert(key).inserted {
                results.append(Resolution(width: mode.width, height: mode.height, hiDPI: true))
            }
        }
        return results.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
    }

    func availableRefreshRates(for displayID: CGDirectDisplayID) -> [Double] {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary) as? [CGDisplayMode] else {
            return []
        }

        let currentMode = CGDisplayCopyDisplayMode(displayID)
        let currentWidth = currentMode?.width ?? 0
        let currentHeight = currentMode?.height ?? 0
        let currentHiDPI = (currentMode?.pixelWidth ?? 0) > currentWidth

        var rates = Set<Double>()
        for mode in modes {
            let isHiDPI = mode.pixelWidth > mode.width
            if mode.width == currentWidth && mode.height == currentHeight && isHiDPI == currentHiDPI {
                rates.insert(mode.refreshRate)
            }
        }
        return rates.sorted()
    }

    func currentRefreshRate(for displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return 0 }
        return mode.refreshRate
    }

    /// Pre-resolve the CGDisplayMode objects for sleep and wake Hz while the display is still active.
    /// Must be called while the display is on (e.g. at startup and whenever settings change).
    func cacheModesForSleepWake(displayID: CGDirectDisplayID, sleepHz: Double, wakeHz: Double) {
        cachedDisplayID = displayID
        cachedSleepMode = findMode(hz: sleepHz, for: displayID)
        cachedWakeMode = findMode(hz: wakeHz, for: displayID)
        NSLog("[Refreshing] cacheModesForSleepWake: display=\(displayID), sleepMode=\(cachedSleepMode?.refreshRate ?? -1) Hz, wakeMode=\(cachedWakeMode?.refreshRate ?? -1) Hz")
    }

    /// Apply the pre-cached sleep mode with permanent persistence.
    /// This writes 120Hz to the WindowServer plist so reconnection defaults to 120Hz.
    @discardableResult
    func applyCachedSleepMode() -> Bool {
        guard let mode = cachedSleepMode else {
            NSLog("[Refreshing] applyCachedSleepMode: no cached sleep mode")
            return false
        }
        return applyMode(mode, to: cachedDisplayID, persist: true)
    }

    /// Apply the pre-cached wake mode (session-only, not persisted to plist).
    @discardableResult
    func applyCachedWakeMode() -> Bool {
        guard let mode = cachedWakeMode else {
            NSLog("[Refreshing] applyCachedWakeMode: no cached wake mode")
            return false
        }
        return applyMode(mode, to: cachedDisplayID, persist: false)
    }

    private func findMode(hz: Double, for displayID: CGDirectDisplayID) -> CGDisplayMode? {
        guard let currentMode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        guard let allModes = CGDisplayCopyAllDisplayModes(displayID, [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary) as? [CGDisplayMode] else {
            return nil
        }
        let currentHiDPI = currentMode.pixelWidth > currentMode.width
        return allModes.first(where: {
            $0.width == currentMode.width &&
            $0.height == currentMode.height &&
            ($0.pixelWidth > $0.width) == currentHiDPI &&
            abs($0.refreshRate - hz) < 1.0
        })
    }

    private func applyMode(_ mode: CGDisplayMode, to displayID: CGDirectDisplayID, persist: Bool = false) -> Bool {
        let option: CGConfigureOption = persist ? .permanently : .forSession
        NSLog("[Refreshing] applyMode: switching display \(displayID) to \(mode.width)x\(mode.height) @ \(mode.refreshRate) Hz (persist=\(persist))")
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            NSLog("[Refreshing] applyMode: CGBeginDisplayConfiguration failed")
            return false
        }
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        let result = CGCompleteDisplayConfiguration(config, option)
        NSLog("[Refreshing] applyMode: result = \(result.rawValue) (0 = success)")
        return result == .success
    }

    /// Set refresh rate at current resolution. Use `persist: true` to write to WindowServer plist.
    @discardableResult
    func setRefreshRate(_ hz: Double, for displayID: CGDirectDisplayID, persist: Bool = false) -> Bool {
        guard let currentMode = CGDisplayCopyDisplayMode(displayID) else {
            NSLog("[Refreshing] setRefreshRate: no current mode for display \(displayID)")
            return false
        }
        return setMode(width: currentMode.width, height: currentMode.height,
                       hiDPI: currentMode.pixelWidth > currentMode.width,
                       hz: hz, for: displayID, persist: persist)
    }

    /// Set refresh rate at a specific resolution. Used when restoring the native resolution after reconnection.
    @discardableResult
    func setMode(width: Int, height: Int, hiDPI: Bool, hz: Double,
                 for displayID: CGDirectDisplayID, persist: Bool = false) -> Bool {
        NSLog("[Refreshing] setMode: target \(width)x\(height) HiDPI=\(hiDPI) @ \(hz) Hz (persist=\(persist))")

        guard let allModes = CGDisplayCopyAllDisplayModes(displayID, [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary) as? [CGDisplayMode] else {
            NSLog("[Refreshing] setMode: failed to get mode list")
            return false
        }

        let matchingModes = allModes.filter {
            $0.width == width &&
            $0.height == height &&
            ($0.pixelWidth > $0.width) == hiDPI
        }
        NSLog("[Refreshing] setMode: \(matchingModes.count) modes at \(width)x\(height) HiDPI=\(hiDPI): \(matchingModes.map { $0.refreshRate })")

        guard let targetMode = matchingModes.first(where: {
            abs($0.refreshRate - hz) < 1.0
        }) else {
            NSLog("[Refreshing] setMode: no mode found for \(hz) Hz")
            return false
        }

        NSLog("[Refreshing] setMode: switching to \(targetMode.width)x\(targetMode.height) @ \(targetMode.refreshRate) Hz")
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            NSLog("[Refreshing] setMode: CGBeginDisplayConfiguration failed")
            return false
        }
        let option: CGConfigureOption = persist ? .permanently : .forSession
        CGConfigureDisplayWithDisplayMode(config, displayID, targetMode, nil)
        let result = CGCompleteDisplayConfiguration(config, option)
        NSLog("[Refreshing] setMode: result = \(result.rawValue) (0 = success)")
        return result == .success
    }

    /// Find the native resolution for a display that supports a given refresh rate.
    /// Uses the display's physical pixel dimensions (from CGDisplayScreenSize and pixel bounds)
    /// to identify the true native mode vs scaled modes.
    func bestResolution(for displayID: CGDirectDisplayID, atHz hz: Double) -> (width: Int, height: Int, hiDPI: Bool)? {
        guard let allModes = CGDisplayCopyAllDisplayModes(displayID, [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary) as? [CGDisplayMode] else {
            return nil
        }

        // Get the display's native pixel dimensions from the non-HiDPI mode with the most pixels
        // (this matches the panel's physical resolution)
        let maxNonHiDPI = allModes
            .filter { $0.pixelWidth == $0.width }  // non-HiDPI: pixel == logical
            .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
        let panelWidth = maxNonHiDPI?.width ?? 0
        let panelHeight = maxNonHiDPI?.height ?? 0

        // Find all HiDPI resolutions that support the target Hz
        var candidates = [(width: Int, height: Int, pixelWidth: Int, isNative: Bool)]()
        var seen = Set<String>()
        for mode in allModes where mode.pixelWidth > mode.width {
            let key = "\(mode.width)x\(mode.height)"
            guard seen.insert(key).inserted else { continue }
            let hasTargetHz = allModes.contains {
                $0.width == mode.width &&
                $0.height == mode.height &&
                ($0.pixelWidth > $0.width) &&
                abs($0.refreshRate - hz) < 1.0
            }
            if hasTargetHz {
                // "Native" = pixel dimensions match the panel's physical pixels
                let isNative = (mode.pixelWidth == panelWidth) && (mode.pixelHeight == panelHeight)
                candidates.append((width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, isNative: isNative))
            }
        }

        NSLog("[Refreshing] bestResolution: panel=\(panelWidth)x\(panelHeight), candidates=\(candidates.map { "\($0.width)x\($0.height) px=\($0.pixelWidth) native=\($0.isNative)" })")

        // Prefer native (pixel dims == panel dims), then largest
        if let native = candidates.first(where: { $0.isNative }) {
            return (width: native.width, height: native.height, hiDPI: true)
        }
        if let best = candidates.max(by: { $0.pixelWidth < $1.pixelWidth }) {
            return (width: best.width, height: best.height, hiDPI: true)
        }
        return nil
    }

    private func displayName(for displayID: CGDirectDisplayID) -> String {
        // Use IOKit service registry to get display product name
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return fallbackName(for: displayID)
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            if let info = IODisplayCreateInfoDictionary(service, UInt32(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any],
               let names = info[kDisplayProductName] as? [String: String],
               let name = names.values.first {
                // Match by checking vendor/product against our display
                if let vendorID = info[kDisplayVendorID] as? Int,
                   let productID = info[kDisplayProductID] as? Int,
                   vendorID == CGDisplayVendorNumber(displayID),
                   productID == CGDisplayModelNumber(displayID) {
                    IOObjectRelease(service)
                    return name
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }

        return fallbackName(for: displayID)
    }

    private func fallbackName(for displayID: CGDirectDisplayID) -> String {
        let vendorNumber = CGDisplayVendorNumber(displayID)
        let modelNumber = CGDisplayModelNumber(displayID)
        return "Display \(vendorNumber)-\(modelNumber)"
    }
}

private func displayReconfigCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo = userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
    manager.handleReconfiguration(displayID: displayID, flags: flags)
}

private let kDisplayProductName = "DisplayProductName"
private let kDisplayVendorID = "DisplayVendorID"
private let kDisplayProductID = "DisplayProductID"
