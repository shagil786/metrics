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
    /// Where an AI client's `confirmEach` request is put to a person. Owned here for the
    /// same reason as the other windows: it has to be reachable from a menu-bar-only app
    /// with no other window open. `MCPHostController` holds the same object as its
    /// `confirmationWindow`, which is how `stop()` can take it down on the way out.
    @MainActor private var mcpConfirmationWindow: MCPConfirmationWindow?
    @MainActor let updates = UpdateController()
    /// The app as an MCP host. Owned here because this delegate owns the app's other
    /// long-lived machinery (status item, shortcuts, extra windows) and the host has
    /// to start and stop with the process rather than with a surface.
    @MainActor let mcpHost = MCPHostController()
    /// Set while a quit is waiting for the host to release its socket.
    @MainActor private var mcpShutdown: Task<Void, Never>?
    @MainActor private(set) var statusItems: StatusItemController?
    @MainActor private(set) var shortcuts: GlobalShortcuts?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        statusItems = StatusItemController(model: AppModel.shared)
        shortcuts = GlobalShortcuts(model: AppModel.shared)
        PortmasterShortcuts.updateAppShortcutParameters()
        // Once per launch, not per surface: the host is a socket, not a window.
        mcpHost.start()
        // …and once per launch, the window its confirmations are asked in. Created here
        // rather than on the first request so the first request does not pay for it, and
        // installed unconditionally: with no presenter the host denies a confirmation
        // immediately with a reason, and there is no reason a request should find the
        // app without one.
        let confirmation = MCPConfirmationWindow()
        mcpConfirmationWindow = confirmation
        mcpHost.confirmationWindow = confirmation
        //
        // Weak, and the only thing a nil delegate can cost is a request that waits out
        // its budget: `Self.shared` is set at launch and never cleared, so a nil here
        // means the app is already on its way out — and `MCPHostController.stop` has
        // denied every pending request by then. Capturing the host instead would be a
        // cycle the controller owns and only `stop()` breaks.
        mcpHost.approvalPresenter = { [weak self] request in
            Task { @MainActor in
                await self?.mcpHost.presentConfirmation(request)
            }
        }
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

    /// Quitting waits for the MCP host to let go of its socket — and only when it has
    /// something to let go of.
    ///
    /// `applicationWillTerminate` cannot `await`, and `MCPHostServer.stop` has to: it
    /// closes every admitted connection, waits for the accept thread, and only then
    /// unlinks the socket and the endpoint file. Stopping it in a task the app does not
    /// wait for would leave a socket file behind on every ordinary quit — which
    /// `EndpointFileStore.read` rejects as stale anyway, so nothing would be broken,
    /// only untidy.
    ///
    /// **`.terminateNow` when there is no host to stop**, which is the common case for
    /// a launch whose bind failed and for any quit after the host has already stopped.
    /// Answering `.terminateLater` there with no task to reply would wedge the app
    /// permanently: AppKit waits for a reply that never comes, so the *second* quit in
    /// that state does nothing at all. The latch is cleared before replying for the
    /// same reason — a quit that was already in flight must not leave a flag behind
    /// that makes the next one wait for nothing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mcpHost.isRunning else { return .terminateNow }
        guard mcpShutdown == nil else { return .terminateLater }
        mcpShutdown = Task { @MainActor [weak self] in
            await self?.mcpHost.stop()
            self?.mcpShutdown = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Native hosting keeps Settings reachable from all accessory-app surfaces.
    @MainActor @objc func openSettingsWindow() {
        statusItems?.close()
        // Re-read both published facts at the moment they are shown, because neither
        // can be observed: a client can change `mcpMode` through `set_preference`,
        // which writes the file without reaching the controller, and a client can
        // connect, ask and disconnect entirely between two openings. Both are reads
        // of state the host already holds — no timer, no wakeups, nothing per sample.
        mcpHost.refreshFromSettings()
        mcpHost.refreshClients()
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
