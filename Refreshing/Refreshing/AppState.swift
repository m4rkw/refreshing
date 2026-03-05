import AppKit
import Combine
import CoreGraphics
import Foundation
import ServiceManagement

final class AppState: ObservableObject {
    static let shared = AppState()

    private let displayManager = DisplayManager.shared
    private let sleepWakeManager = SleepWakeManager()
    private var upshiftWorkItem: DispatchWorkItem?
    private var debounceWorkItem: DispatchWorkItem?

    // Remembered native resolution for the target display
    private var nativeWidth: Int {
        get { UserDefaults.standard.integer(forKey: "nativeWidth") }
        set { UserDefaults.standard.set(newValue, forKey: "nativeWidth") }
    }
    private var nativeHeight: Int {
        get { UserDefaults.standard.integer(forKey: "nativeHeight") }
        set { UserDefaults.standard.set(newValue, forKey: "nativeHeight") }
    }
    private var nativeHiDPI: Bool {
        get { UserDefaults.standard.bool(forKey: "nativeHiDPI") }
        set { UserDefaults.standard.set(newValue, forKey: "nativeHiDPI") }
    }

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "isEnabled") }
    }

    @Published var selectedDisplayID: CGDirectDisplayID {
        didSet { UserDefaults.standard.set(Int(selectedDisplayID), forKey: "selectedDisplayID") }
    }

    @Published var highHz: Double {
        didSet { UserDefaults.standard.set(highHz, forKey: "highHz") }
    }

    @Published var lowHz: Double {
        didSet { UserDefaults.standard.set(lowHz, forKey: "lowHz") }
    }

    @Published var launchAtLogin: Bool = false

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            guard Self.isInApplicationsFolder else {
                showNotInApplicationsAlert()
                return
            }
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    static var isInApplicationsFolder: Bool {
        guard let path = Bundle.main.bundlePath as String? else { return false }
        return path.hasPrefix("/Applications/") ||
               path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private func showNotInApplicationsAlert() {
        let alert = NSAlert()
        alert.messageText = "Move to Applications"
        alert.informativeText = "Refreshing must be in /Applications or ~/Applications for Launch at Login to work reliably. Move the app there first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @Published var statusMessage: String = "Idle"
    @Published var availableDisplays: [DisplayInfo] = []
    @Published var availableRates: [Double] = []
    @Published var availableResolutions: [Resolution] = []
    @Published var currentRate: Double = 0

    /// The user-selected target resolution (label like "2560 × 1440"). Empty = native (auto).
    @Published var selectedResolution: String {
        didSet { UserDefaults.standard.set(selectedResolution, forKey: "selectedResolution") }
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: "isEnabled") as? Bool ?? true
        selectedDisplayID = CGDirectDisplayID(UserDefaults.standard.integer(forKey: "selectedDisplayID"))
        highHz = UserDefaults.standard.object(forKey: "highHz") as? Double ?? 240
        lowHz = UserDefaults.standard.object(forKey: "lowHz") as? Double ?? 120
        selectedResolution = UserDefaults.standard.string(forKey: "selectedResolution") ?? ""

        launchAtLogin = SMAppService.mainApp.status == .enabled

        refreshDisplays()
        NSLog("[Refreshing] Init: displays=\(availableDisplays.map { "\($0.name) (id=\($0.id))" }), selected=\(selectedDisplayID), rates=\(availableRates), high=\(highHz), low=\(lowHz), enabled=\(isEnabled)")

        // On first launch with an external display, persist 120Hz to the plist immediately
        if isEnabled, selectedDisplayID != 0 {
            NSLog("[Refreshing] Init: persisting \(lowHz) Hz to WindowServer plist")
            displayManager.setRefreshRate(lowHz, for: selectedDisplayID, persist: true)
            // Then upshift to high Hz for session
            displayManager.setRefreshRate(highHz, for: selectedDisplayID, persist: false)
            currentRate = displayManager.currentRefreshRate(for: selectedDisplayID)
        }

        setupSleepWake()
        setupDisplayWatcher()
    }

    func refreshDisplays() {
        availableDisplays = displayManager.externalDisplays()

        // Auto-select first external display if current selection is invalid
        if !availableDisplays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = availableDisplays.first?.id ?? 0
        }

        if selectedDisplayID != 0 {
            availableRates = displayManager.availableRefreshRates(for: selectedDisplayID)
            currentRate = displayManager.currentRefreshRate(for: selectedDisplayID)

            // Remember native resolution when display reports full mode list
            availableResolutions = displayManager.availableResolutions(for: selectedDisplayID)

            // Save the best resolution that supports the target high Hz
            if let best = displayManager.bestResolution(for: selectedDisplayID, atHz: highHz) {
                nativeWidth = best.width
                nativeHeight = best.height
                nativeHiDPI = best.hiDPI
                NSLog("[Refreshing] Best resolution for \(highHz) Hz: \(nativeWidth)x\(nativeHeight) HiDPI=\(nativeHiDPI)")
            }

            // Auto-pick high/low Hz if user hasn't explicitly set them
            let userSetHigh = UserDefaults.standard.object(forKey: "highHz") != nil
            let userSetLow = UserDefaults.standard.object(forKey: "lowHz") != nil

            if !userSetHigh || !availableRates.contains(where: { abs($0 - highHz) < 1 }) {
                if let max = availableRates.last {
                    highHz = max
                }
            }
            if !userSetLow || !availableRates.contains(where: { abs($0 - lowHz) < 1 }) {
                if let candidate = availableRates.last(where: { $0 <= 120 }) ?? availableRates.first {
                    lowHz = candidate
                }
            }
            if abs(highHz - lowHz) < 1, availableRates.count > 1 {
                highHz = availableRates.last!
                lowHz = availableRates.last(where: { $0 <= 120 }) ?? availableRates.first!
            }

            // Pre-resolve and cache the CGDisplayMode objects while display is active
            displayManager.cacheModesForSleepWake(displayID: selectedDisplayID, sleepHz: lowHz, wakeHz: highHz)
        }
    }

    /// Resolve the target resolution: user-selected, or native fallback.
    var targetResolution: (width: Int, height: Int, hiDPI: Bool) {
        if !selectedResolution.isEmpty,
           let res = availableResolutions.first(where: { $0.id == selectedResolution }) {
            return (res.width, res.height, res.hiDPI)
        }
        if nativeWidth > 0, nativeHeight > 0 {
            return (nativeWidth, nativeHeight, nativeHiDPI)
        }
        return (0, 0, true)
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        selectedDisplayID = id
        refreshDisplays()
    }

    // MARK: - Display connect/disconnect via CGDisplayReconfigurationCallback

    private func setupDisplayWatcher() {
        displayManager.onExternalDisplayChanged = { [weak self] displayID, isAdded in
            guard let self = self, self.isEnabled else { return }

            DispatchQueue.main.async {
                if isAdded {
                    self.handleDisplayConnected(displayID)
                } else {
                    self.handleDisplayDisconnected(displayID)
                }
            }
        }
        displayManager.startWatchingDisplays()
    }

    private func handleDisplayConnected(_ displayID: CGDirectDisplayID) {
        NSLog("[Refreshing] handleDisplayConnected: id=\(displayID)")

        // Cancel any pending upshift from a previous connection
        upshiftWorkItem?.cancel()

        // Filter out phantom displays (built-in appearing during clamshell transition).
        // Accept if: it's our known display, OR it supports >120Hz.
        let rates = displayManager.availableRefreshRates(for: displayID)
        let isKnownDisplay = (displayID == selectedDisplayID && selectedDisplayID != 0)
        let hasHighRefresh = rates.contains(where: { $0 > 120 })
        guard isKnownDisplay || hasHighRefresh else {
            NSLog("[Refreshing] handleDisplayConnected: display \(displayID) only supports \(rates) and not our selected display — ignoring")
            return
        }

        // Refresh display list
        refreshDisplays()

        guard selectedDisplayID != 0 else {
            NSLog("[Refreshing] handleDisplayConnected: no selected display after refresh")
            return
        }

        // Immediately downshift to safe Hz — persist so WindowServer remembers 120Hz for next connection
        statusMessage = "Display connected — setting \(Int(lowHz)) Hz…"
        let success = displayManager.setRefreshRate(lowHz, for: selectedDisplayID, persist: true)
        NSLog("[Refreshing] handleDisplayConnected: setRefreshRate(\(lowHz), persist=true) → \(success)")

        if success {
            statusMessage = "Safe at \(Int(lowHz)) Hz"
            currentRate = displayManager.currentRefreshRate(for: selectedDisplayID)
        }

        // Schedule upshift after display stabilizes — use target resolution
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isEnabled, self.selectedDisplayID != 0 else { return }

            let target = self.targetResolution

            guard target.width > 0, target.height > 0 else {
                NSLog("[Refreshing] handleDisplayConnected: no target resolution, falling back to current")
                let success = self.displayManager.setRefreshRate(self.highHz, for: self.selectedDisplayID, persist: false)
                NSLog("[Refreshing] handleDisplayConnected: setRefreshRate(\(self.highHz)) → \(success)")
                self.currentRate = self.displayManager.currentRefreshRate(for: self.selectedDisplayID)
                self.statusMessage = success ? "\(Int(self.highHz)) Hz restored" : "Restore failed"
                return
            }

            NSLog("[Refreshing] handleDisplayConnected: restoring \(target.width)x\(target.height) HiDPI=\(target.hiDPI) @ \(self.highHz) Hz")
            self.statusMessage = "Restoring \(target.width)×\(target.height) @ \(Int(self.highHz)) Hz…"

            // Set target resolution + high Hz, session only — plist stays at 120Hz
            let success = self.displayManager.setMode(
                width: target.width, height: target.height, hiDPI: target.hiDPI,
                hz: self.highHz, for: self.selectedDisplayID, persist: false
            )
            NSLog("[Refreshing] handleDisplayConnected: setMode → \(success)")

            self.currentRate = self.displayManager.currentRefreshRate(for: self.selectedDisplayID)
            self.statusMessage = success ? "\(Int(self.highHz)) Hz restored" : "Restore failed"

            // Re-cache modes for sleep/wake safety net
            self.displayManager.cacheModesForSleepWake(
                displayID: self.selectedDisplayID,
                sleepHz: self.lowHz,
                wakeHz: self.highHz
            )
        }
        upshiftWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }

    private func handleDisplayDisconnected(_ displayID: CGDirectDisplayID) {
        NSLog("[Refreshing] handleDisplayDisconnected: id=\(displayID)")

        // Cancel any pending upshift
        upshiftWorkItem?.cancel()
        upshiftWorkItem = nil

        refreshDisplays()
        statusMessage = selectedDisplayID == 0 ? "No external display" : "Idle"
    }

    // MARK: - Sleep/wake (safety net for non-cable-pull sleep)

    private func setupSleepWake() {
        sleepWakeManager.onWillSleep = { [weak self] allowSleep in
            guard let self = self else {
                NSLog("[Refreshing] onWillSleep: self is nil")
                allowSleep()
                return
            }

            NSLog("[Refreshing] onWillSleep: enabled=\(self.isEnabled), displayID=\(self.selectedDisplayID), lowHz=\(self.lowHz)")

            guard self.isEnabled, self.selectedDisplayID != 0 else {
                NSLog("[Refreshing] onWillSleep: skipping (disabled or no display)")
                allowSleep()
                return
            }

            self.statusMessage = "Downshifting to \(Int(self.lowHz)) Hz…"

            // Try cached mode first, fall back to live query
            let success = self.displayManager.applyCachedSleepMode()
            NSLog("[Refreshing] onWillSleep: applyCachedSleepMode → \(success)")

            self.statusMessage = success ? "Sleeping at \(Int(self.lowHz)) Hz" : "Downshift failed"

            allowSleep()
        }

        sleepWakeManager.onDidWake = { [weak self] in
            guard let self = self else { return }
            NSLog("[Refreshing] onDidWake: enabled=\(self.isEnabled), displayID=\(self.selectedDisplayID), highHz=\(self.highHz)")

            // Don't upshift here — let the display reconfiguration callback handle it.
            // The display may not be connected yet (clamshell reconnection scenario).
            // If the display IS already present, the reconfig callback will fire.
            // This just updates status.
            DispatchQueue.main.async {
                self.statusMessage = "Woke up — waiting for display…"
            }
        }

        sleepWakeManager.start()
    }
}
