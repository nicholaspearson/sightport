import SwiftUI
import AppKit
import Sparkle

@main
struct SightportApp: App {
    @StateObject private var workspace = Workspace()
    @StateObject private var updates = ClientUpdates()

    var body: some Scene {
        Window("Sightport", id: "workspace") {
            GeometryReader { window in
                ContentView()
                    .environmentObject(workspace)
                    .environment(\.workbenchContentSize, window.size)
            }
            .frame(minWidth: 850, minHeight: 520)
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1160, height: 725)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updates.check)
                    .disabled(!updates.canCheck)
                if let updater = updates.controller?.updater {
                    Menu("Automatic Updates") {
                        Toggle("Check Automatically", isOn: Binding(
                            get: { updates.checksAutomatically },
                            set: { updater.automaticallyChecksForUpdates = $0 }))
                        Toggle("Download and Install Automatically", isOn: Binding(
                            get: { updates.downloadsAutomatically },
                            set: { updater.automaticallyDownloadsUpdates = $0 }))
                            .disabled(!updates.checksAutomatically)
                    }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Kubeconfig…") { workspace.chooseFile() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Workspace") {
                ForEach([WorkbenchPage.contexts, .favorites, .files], id: \.self) { page in
                    Button(page.title) { workspace.open(page) }
                }
                Divider()
                Button("Refresh Current View") { workspace.refresh() }.keyboardShortcut("r")
            }
        }
    }
}

@MainActor
private final class ClientUpdates: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private(set) var controller: SPUStandardUpdaterController?
    private var preparedUpdateNeedsPrompt = false
    @Published private(set) var canCheck = true
    @Published private(set) var checksAutomatically = false
    @Published private(set) var downloadsAutomatically = false

    override init() {
        super.init()
        let info = Bundle.main
        guard let feed = info.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              let key = info.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$checksAutomatically)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$downloadsAutomatically)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
        controller.startUpdater()
        if updater.automaticallyChecksForUpdates && updater.canCheckForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        preparedUpdateNeedsPrompt = false
        if !immediateFocus && NSApp.isActive {
            // Sparkle has created the alert but normally waits for the next app activation.
            DispatchQueue.main.async { [weak self] in
                if NSApp.isActive { self?.controller?.userDriver.showUpdateInFocus() }
            }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        preparedUpdateNeedsPrompt = true
        return false // Sparkle still owns installation on quit.
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error != nil { preparedUpdateNeedsPrompt = false }
        presentPreparedUpdateIfActive()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        presentPreparedUpdateIfActive()
    }

    private func presentPreparedUpdateIfActive() {
        guard preparedUpdateNeedsPrompt, let updater = controller?.updater, NSApp.isActive,
              updater.automaticallyChecksForUpdates, updater.canCheckForUpdates, !updater.sessionInProgress else { return }
        preparedUpdateNeedsPrompt = false
        // The download session must finish before Sparkle can offer the prepared update.
        updater.checkForUpdates()
    }

    func check() {
        if let controller {
            preparedUpdateNeedsPrompt = false
            controller.checkForUpdates(nil)
        } else {
            let alert = NSAlert()
            alert.messageText = "Updates unavailable for this build"
            alert.informativeText = "Automatic updates require a build configured with an HTTPS release feed and its publisher’s public signing key."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
