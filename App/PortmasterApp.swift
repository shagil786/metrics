// PortmasterApp: SwiftUI app lifecycle, menu bar item, deterministic window.
import SwiftUI
import AppKit
import PortmasterCore

@main
struct PortmasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Shared instance: the AppKit-created window and the SwiftUI scenes
    // (menu bar popover, settings) must observe the same model.
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(model)
        }.commands {
            CommandMenu("Go") {
                ForEach(Array(MainTab.primary.prefix(9).enumerated()), id: \.element.id) { index, tab in
                    Button(tab.label) { NotificationCenter.default.post(name: .openPortmasterTab, object: tab.rawValue) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                }
                Divider()
                ForEach(MainTab.secondary) { tab in
                    Button(tab.label) { NotificationCenter.default.post(name: .openPortmasterTab, object: tab.rawValue) }
                        .keyboardShortcut(tab == .history ? "h" : tab == .alerts ? "a" : "p", modifiers: [.command, .shift])
                }
                Divider()
                Button("Show dropdown") { AppDelegate.shared?.statusItems?.show() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Check for Updates…") { AppDelegate.shared?.checkForUpdates() }
                    .disabled(AppDelegate.shared?.updates.canCheck != true)
                Button("Welcome…") { AppDelegate.shared?.openWelcomeWindow() }
                Button("Settings…") { AppDelegate.shared?.openSettingsWindow() }.keyboardShortcut(",")
            }
        }
    }
}

/// Owns the main window. SwiftUI's Window/WindowGroup scenes persist "no
/// windows" state for LSUIElement apps, so the window is created and shown
/// explicitly here — deterministic on every launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var shared: AppDelegate?
    var activityCancellable: Any?
    private(set) var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    @MainActor let updates = UpdateController()
    @MainActor private(set) var statusItems: StatusItemController?
    @MainActor private(set) var shortcuts: GlobalShortcuts?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        statusItems = StatusItemController(model: AppModel.shared)
        shortcuts = GlobalShortcuts(model: AppModel.shared)
        PortmasterShortcuts.updateAppShortcutParameters()
        // User activity unpauses sampling after the idle pause.
        let center = NSWorkspace.shared.notificationCenter
        activityCancellable = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                NotificationCenter.default.post(name: .portmasterUserActivity, object: nil)
            }
        }

        DispatchQueue.main.async { [weak self] in
            if AppModel.shared.prefs.hasCompletedOnboarding { self?.openMainWindow() }
            else { self?.openWelcomeWindow() }
        }

        // Settings requests from surfaces without the openSettings environment
        // (preview banner in the AppKit-hosted main window).
        NotificationCenter.default.addObserver(
            forName: .openPortmasterSettings, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.openSettingsWindow() }
        }
    }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.audioControls.stopAll()
    }

    /// Native hosting keeps Settings reachable from all accessory-app surfaces.
    @MainActor @objc func openSettingsWindow() {
        statusItems?.close()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Settings"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 700, height: 532)
            let host = NSHostingView(rootView: SettingsView().environmentObject(AppModel.shared))
            host.sizingOptions = []; window.contentView = host
            window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil); settingsWindow?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Create (once) and raise the main window.
    /// Accessory-app (LSUIElement) ordering rules on macOS 14+: the window
    /// must be ordered front (orderFrontRegardless — the app is never active,
    /// so makeKeyAndOrderFront alone can leave it under the frontmost app),
    /// and activation must happen AFTER the window is on screen.
    @MainActor @objc func openMainWindow() {
        statusItems?.close()
        if mainWindow == nil {
            let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1160, height: 840)
            let initialSize = NSSize(width: min(1120, max(980, available.width - 40)),
                                     height: min(800, max(700, available.height - 40)))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: initialSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Portmaster"
            if ProcessInfo.processInfo.environment["PORTMASTER_POPOVER"] != "1" {
                window.styleMask.insert(.fullSizeContentView)
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
            }
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 980, height: 700)
            // The hosting view is the window's contentView, so its default
            // sizingOptions (.intrinsicContentSize et al.) translate SwiftUI
            // content-size churn into window-constraint updates. When a tab
            // with dynamic content attaches mid-layout (CPU tab: placeholder→
            // chart swap, table rows appearing), that re-marks constraints
            // DURING the layout pass and AppKit throws — crashing on tab
            // switch. The window manages its own min/size, so the hosting
            // view must not drive constraints at all.
            //
            // PORTMASTER_POPOVER=1 (debug/UI-testing): host the menu-bar
            // panel in this window instead, so panel screens can be captured
            // without clicking the status item (which needs Accessibility).
            let rootView = ProcessInfo.processInfo.environment["PORTMASTER_POPOVER"] == "1"
                ? AnyView(MenuBarPanel().environmentObject(AppModel.shared))
                : AnyView(MainWindow().environmentObject(AppModel.shared))
            let hosting = NSHostingView(rootView: rootView)
            hosting.sizingOptions = []
            window.contentView = hosting
            window.center()
            mainWindow = window
        }
        // The panel is narrower than the main window; recenter for it.
        if ProcessInfo.processInfo.environment["PORTMASTER_POPOVER"] == "1" {
            mainWindow?.setContentSize(NSSize(width: 340, height: 700))
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        mainWindow?.orderFrontRegardless() // bypass activation requirement
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc func checkForUpdates() { updates.check() }

    @MainActor @objc func openWelcomeWindow() {
        statusItems?.close()
        if welcomeWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Welcome to Portmaster"; window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: WelcomeView { [weak self] in
                AppModel.shared.prefs.hasCompletedOnboarding = true
                self?.welcomeWindow?.close(); self?.openMainWindow()
            })
            host.sizingOptions = []; window.contentView = host; window.center(); welcomeWindow = window
        }
        welcomeWindow?.makeKeyAndOrderFront(nil); welcomeWindow?.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func noteActivity() {
        NotificationCenter.default.post(name: .portmasterUserActivity, object: nil)
    }
}

extension Notification.Name {
    static let portmasterUserActivity = Notification.Name("dev.portmaster.userActivity")
}
