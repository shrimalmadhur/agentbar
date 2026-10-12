import SwiftUI
import UserNotifications

// AgentBar: a window with an Agents page (what every coding agent on this Mac
// is doing) and an Accounts page (Claude Code account switching and usage),
// plus a menu bar icon that brings the window up, and a notification when an
// agent starts needing you.

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func parseDate(_ v: Any?) -> Date? {
    guard var s = v as? String else { return nil }
    // ISO8601DateFormatter rejects fractional seconds of any length, and
    // Conductor also stores "2026-09-16 01:51:55" (UTC).
    s = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    if !s.contains("T") { s = s.replacingOccurrences(of: " ", with: "T") + "Z" }
    return ISO8601DateFormatter().date(from: s)
}

let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
let codexBlue = Color(red: 0.30, green: 0.58, blue: 0.98)

enum Page: String, CaseIterable, Identifiable {
    case agents = "Agents", accounts = "Accounts"
    var id: Self { self }
}

@main
struct AgentBar: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var agents = AgentsStore()
    @StateObject private var accounts = AccountsStore()

    var body: some Scene {
        Window("AgentBar", id: "main") {
            MainView(agents: agents, accounts: accounts)
        }
        .defaultSize(width: 920, height: 700)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var item: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "AgentBar")
        item?.button?.target = self
        item?.button?.action = #selector(showWindow)

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Clicking a notification goes to the agent it is about.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        Target(userInfo: response.notification.request.content.userInfo)?.open()
        done()
    }

    // Without this, notifications are dropped while AgentBar is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // Opening an app that is already running sends it a reopen event, which
    // SwiftUI handles like a Dock click: it shows the window, re-creating it
    // if it was closed.
    @objc func showWindow() {
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct MainView: View {
    @ObservedObject var agents: AgentsStore
    @ObservedObject var accounts: AccountsStore
    @State private var page: Page? = .agents

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(Page.allCases) { p in
                    Label(p.rawValue, systemImage: p == .agents ? "square.grid.2x2" : "person.2")
                        .badge(p == .agents ? agents.count(.needsYou) : 0)
                        .tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch page ?? .agents {
            case .agents:
                AgentsView(store: agents)
                    .navigationTitle("Agents")
                    .navigationSubtitle("\(agents.count(.needsYou)) need you · \(agents.count(.working)) working · \(agents.workspaces.count) workspaces")
                    .toolbar {
                        Button { Task { await agents.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
            case .accounts:
                AccountsView(store: accounts)
                    .navigationTitle("Accounts")
                    .toolbar {
                        Button { Task { await accounts.saveCurrent() } } label: {
                            Label("Save Current Login", systemImage: "plus")
                        }
                        .help("Save the login Claude Code is using now as an account")
                        Button { Task { await accounts.reload(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .disabled(accounts.loading)
                    }
            }
        }
    }
}
