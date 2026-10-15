import SwiftUI
import UserNotifications

// AgentBar: a window with an Agents page (what every coding agent on this Mac
// is doing), a Features page (features that span repos: a lead agent plans,
// then one agent per repo builds), and an Accounts page (Claude Code account
// switching and usage), plus a menu bar icon that brings the window up, and a
// notification when an agent starts needing you.

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

func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
func hex(_ v: Int) -> Color { rgb(Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255) }

/// The window's colors, taken from Conductor's dark UI. AgentBar is always dark.
enum Chrome {
    static let background = hex(0x191513)
    static let sidebar = hex(0x23211E)
    static let surface = hex(0x201D1A) // cards and panels
    static let raised = hex(0x2A2725) // text fields, hovered rows
    static let selected = hex(0x33312E)
    static let hairline = Color.white.opacity(0.07)
}

/// Branches, paths, counts, statuses and section labels use monospace, as in
/// herdr; names and messages use the system font, as in Conductor.
func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

extension View {
    /// A card: a flat surface with a hairline border.
    func surface(hovering: Bool = false, border: Color = Chrome.hairline) -> some View {
        background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Chrome.raised : Chrome.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border))
    }

    /// A section label: lowercase monospace, as in herdr's sidebar.
    func sectionLabel() -> some View { font(mono(11, .medium)).foregroundStyle(.secondary).textCase(.lowercase) }
}

/// Colors for statuses and for the kinds of work in the activity graph.
struct Palette {
    let working: Color
    let needs: Color
    let subagent: Color
    let command: Color
    let canvas: [Color] // the graph's background gradient, top-leading to bottom-trailing
}

enum Theme: String, CaseIterable, Identifiable {
    case conductor, aurora, ember, ocean, classic, mono
    var id: Self { self }
    var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var palette: Palette {
        switch self {
        case .conductor:
            Palette(working: hex(0x7FC17B), needs: hex(0xE5865F),
                    subagent: hex(0xB39DF2), command: hex(0x7DB4E8),
                    canvas: [hex(0x1E1A17), hex(0x191513)])
        case .aurora:
            Palette(working: rgb(0.33, 0.86, 0.76), needs: rgb(1.0, 0.50, 0.45),
                    subagent: rgb(0.67, 0.52, 1.0), command: rgb(0.35, 0.74, 1.0),
                    canvas: [rgb(0.09, 0.10, 0.17), rgb(0.06, 0.12, 0.14)])
        case .ember:
            Palette(working: rgb(1.0, 0.72, 0.30), needs: rgb(1.0, 0.36, 0.36),
                    subagent: rgb(1.0, 0.47, 0.62), command: rgb(0.96, 0.84, 0.45),
                    canvas: [rgb(0.15, 0.09, 0.08), rgb(0.10, 0.07, 0.10)])
        case .ocean:
            Palette(working: rgb(0.36, 0.72, 1.0), needs: rgb(1.0, 0.62, 0.30),
                    subagent: rgb(0.50, 0.55, 1.0), command: rgb(0.30, 0.85, 0.85),
                    canvas: [rgb(0.05, 0.09, 0.17), rgb(0.04, 0.13, 0.18)])
        case .classic:
            Palette(working: .green, needs: .orange, subagent: .purple, command: .teal,
                    canvas: [rgb(0.10, 0.10, 0.11), rgb(0.08, 0.08, 0.09)])
        case .mono:
            Palette(working: rgb(0.92, 0.92, 0.94), needs: rgb(1.0, 0.55, 0.40),
                    subagent: rgb(0.72, 0.72, 0.76), command: rgb(0.58, 0.58, 0.62),
                    canvas: [rgb(0.10, 0.10, 0.10), rgb(0.07, 0.07, 0.07)])
        }
    }
}

/// The chosen theme's palette. Views re-read it because MainView rebuilds its
/// content when the "theme" setting changes.
var palette: Palette { (Theme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .conductor).palette }

enum Page: String, CaseIterable, Identifiable {
    case agents = "Agents", features = "Features", accounts = "Accounts"
    var id: Self { self }
    var icon: String {
        switch self { case .agents: "square.grid.2x2"; case .features: "square.stack.3d.up"; case .accounts: "person.2" }
    }
}

@main
struct AgentBar: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var agents = AgentsStore()
    @StateObject private var accounts = AccountsStore()
    @StateObject private var features = FeaturesStore()

    var body: some Scene {
        Window("AgentBar", id: "main") {
            MainView(agents: agents, accounts: accounts, features: features)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 920, height: 700)

        Settings { SettingsView() }
    }
}

struct SettingsView: View {
    @AppStorage("theme") private var theme = Theme.conductor.rawValue

    var body: some View {
        Form {
            Picker("Theme", selection: $theme) {
                ForEach(Theme.allCases) { t in
                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            ForEach(Array([t.palette.working, t.palette.subagent, t.palette.command, t.palette.needs].enumerated()),
                                    id: \.offset) { _, c in Circle().fill(c).frame(width: 10, height: 10) }
                        }
                        Text(t.name)
                    }
                    .tag(t.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize()
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
    @ObservedObject var features: FeaturesStore
    @State private var page: Page? = .agents
    @AppStorage("theme") private var theme = Theme.conductor.rawValue

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Page.allCases) { p in sidebarRow(p) }
                Spacer()
                SettingsLink { Image(systemName: "gearshape").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .padding(10)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Chrome.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            detail.id(theme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Chrome.background)
                .toolbarBackground(Chrome.background, for: .windowToolbar)
        }
    }

    func sidebarRow(_ p: Page) -> some View {
        let needs = p == .agents ? agents.count(.needsYou) : 0
        return Button { page = p } label: {
            HStack(spacing: 9) {
                Image(systemName: p.icon).frame(width: 16).foregroundStyle(.secondary)
                Text(p.rawValue)
                Spacer()
                if needs > 0 { Text("\(needs)").font(mono(11, .semibold)).foregroundStyle(needsColor) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(page == p ? Chrome.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder var detail: some View {
        switch page ?? .agents {
        case .agents:
            AgentsView(store: agents)
                .toolbar {
                    Button { Task { await agents.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
        case .features:
            FeaturesView(store: features, agents: agents)
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
