import SwiftUI
import AppKit
import Sparkle

@main
struct SightportApp: App {
    @StateObject private var workspace = Workspace()
    @StateObject private var updates = ClientUpdates()

    var body: some Scene {
        Window("Sightport", id: "workspace") {
            ContentView()
                .environmentObject(workspace)
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
private final class ClientUpdates: ObservableObject {
    let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = true
    @Published private(set) var checksAutomatically = false
    @Published private(set) var downloadsAutomatically = false

    init() {
        let info = Bundle.main
        guard let feed = info.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              let key = info.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$checksAutomatically)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$downloadsAutomatically)
        controller.startUpdater()
    }

    func check() {
        if let controller {
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
