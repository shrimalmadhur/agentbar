import Foundation
import SwiftUI

// Switches the Claude Code login from the menu bar.
//
// Storage is shared with cc-auth (github.com/rsnodgrass/claude-code-auth), so
// accounts saved there show up here without logging in again:
//   - each slot's login: Keychain service "cc-auth", account = slot name
//   - the slot list: directories under ~/.claude/cc-auth/slots, each with the
//     profile.json captured when it was saved
//
// Keychain access goes through /usr/bin/security rather than the Security
// framework: Claude Code writes its item with that tool, so it is already on
// the item's access list, while this ad-hoc signed app would get an access
// prompt per item, again after every rebuild.

let activeService = "Claude Code-credentials"
let slotService = "cc-auth"
let slotsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/cc-auth/slots")
// Cloudflare in front of console.anthropic.com rejects requests without a User-Agent.
let userAgent = "authbar/1.0"

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: Keychain

@discardableResult
func security(_ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// Claude Code keeps a second item under its service (account "unknown", MCP
// tokens), so reads pin the account or `security` may return that one.
func readItem(_ service: String, _ account: String) -> [String: Any]? {
    guard let s = security(["find-generic-password", "-s", service, "-a", account, "-w"]) else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
}

func writeItem(_ obj: [String: Any], _ service: String, _ account: String) throws {
    let json = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    guard security(["add-generic-password", "-U", "-s", service, "-a", account, "-w", json]) != nil
    else { throw Failure("Could not write Keychain item \(service) / \(account)") }
}

// The "claudeAiOauth" object Claude Code stores: accessToken, refreshToken, expiresAt (ms), …
typealias OAuth = [String: Any]

func activeOAuth() -> OAuth? { readItem(activeService, NSUserName())?["claudeAiOauth"] as? OAuth }
func slotOAuth(_ name: String) -> OAuth? { readItem(slotService, name)?["claudeAiOauth"] as? OAuth }

// Replaces only the login: the item may also hold `mcpOAuth` (MCP server
// tokens), which belong to this machine, not to the account.
func setOAuth(_ oauth: OAuth, _ service: String, _ account: String) throws {
    var item = readItem(service, account) ?? [:]
    item["claudeAiOauth"] = oauth
    try writeItem(item, service, account)
}

func token(_ o: OAuth) -> String { o["accessToken"] as? String ?? "" }

func isExpired(_ o: OAuth) -> Bool {
    guard let ms = o["expiresAt"] as? Double else { return false }
    return ms / 1000 - 60 < Date().timeIntervalSince1970
}

// MARK: API

func send(_ req: URLRequest) async throws -> [String: Any] {
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { throw Failure("\(req.url?.path ?? ""): HTTP \(code)") }
    return obj
}

func get(_ path: String, _ o: OAuth) async throws -> [String: Any] {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
    req.setValue("Bearer \(token(o))", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    return try await send(req)
}

// The server rotates the refresh token on every call, so the caller must save
// the result wherever the old one was stored.
func refreshed(_ o: OAuth) async throws -> OAuth {
    var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "grant_type": "refresh_token",
        "refresh_token": o["refreshToken"] as? String ?? "",
        "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e", // Claude Code's public OAuth client
    ])
    let r = try await send(req)
    guard let access = r["access_token"] as? String else { throw Failure("Refresh returned no access token") }
    var n = o
    n["accessToken"] = access
    n["refreshToken"] = r["refresh_token"] as? String ?? o["refreshToken"]
    n["expiresAt"] = Int((Date().timeIntervalSince1970 + (r["expires_in"] as? Double ?? 0)) * 1000)
    return n
}

func email(_ profile: [String: Any]?) -> String? {
    (profile?["account"] as? [String: Any])?["email"] as? String
}

// MARK: Slots

func slotNames() -> [String] {
    let dirs = (try? FileManager.default.contentsOfDirectory(
        at: slotsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    return dirs.filter { $0.hasDirectoryPath }.map(\.lastPathComponent).sorted()
}

// Read from disk, not the API: the slot's saved token may already be revoked.
func slotProfile(_ name: String) -> [String: Any]? {
    let url = slotsDir.appendingPathComponent(name).appendingPathComponent("profile.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func slotEmail(_ name: String) -> String? { email(slotProfile(name)) }

// "default_claude_max_20x" → "Max 20x"
func slotTier(_ name: String) -> String? {
    guard let t = (slotProfile(name)?["organization"] as? [String: Any])?["rate_limit_tier"] as? String
    else { return nil }
    let s = t.replacingOccurrences(of: "default_claude_", with: "").replacingOccurrences(of: "_", with: " ")
    return s.prefix(1).uppercased() + s.dropFirst()
}

struct Window {
    var pct: Double?
    var resetsAt: Date?
}

extension Window {
    // Claude's usage shape: {"utilization": 38.0, "resets_at": "2026-…"}
    init(claude json: Any?) {
        let w = json as? [String: Any]
        self.init(pct: w?["utilization"] as? Double, resetsAt: parseDate(w?["resets_at"]))
    }
}

struct Slot: Identifiable {
    let name: String
    var id: String { name }
    var email: String?
    var tier: String?
    // nil when the plan has no such window (Codex Pro only has a weekly one).
    var fiveHour: Window?
    var sevenDay: Window?
    var problem: String?
}

func parseDate(_ v: Any?) -> Date? {
    // ISO8601DateFormatter rejects the API's microsecond fractions.
    guard let s = v as? String else { return nil }
    return ISO8601DateFormatter().date(from: s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
}

// MARK: Codex

// Codex keeps its ChatGPT login in a file, not the Keychain. Only the logged-in
// account is shown, and it is never refreshed here: Codex rotates the refresh
// token and running sessions hold the current one.
let codexAuthFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")

func loadCodex() async -> Slot? {
    guard let data = try? Data(contentsOf: codexAuthFile),
          let auth = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let tokens = auth["tokens"] as? [String: Any],
          let access = tokens["access_token"] as? String
    else { return nil }
    var s = Slot(name: "Codex")
    do {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens["account_id"] as? String, forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let u = try await send(req)
        s = Slot(name: u["email"] as? String ?? "Codex",
                 tier: (u["plan_type"] as? String)?.capitalized)
        let limits = u["rate_limit"] as? [String: Any]
        // Which window is which comes from its length, not primary/secondary.
        for key in ["primary_window", "secondary_window"] {
            guard let w = limits?[key] as? [String: Any] else { continue }
            let window = Window(pct: w["used_percent"] as? Double,
                                resetsAt: (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
            switch w["limit_window_seconds"] as? Int {
            case 5 * 3600: s.fiveHour = window
            case 7 * 24 * 3600: s.sevenDay = window
            default: break
            }
        }
    } catch {
        s.problem = "\(error.localizedDescription) – run codex to refresh"
    }
    return s
}

@MainActor
final class Store: ObservableObject {
    @Published var slots: [Slot] = []
    @Published var active: String?
    @Published var message: String?
    @Published var loading = false
    @Published var switching: String?
    @Published var switchedTo: String?
    @Published var updatedAt: Date?
    @Published var codex: Slot?
    private var emailByToken: [String: String] = [:]
    private var timer: Timer?

    init() {
        Task { await reload() }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { await self?.reload() }
        }
    }

    private func activeEmail(_ o: OAuth) async throws -> String {
        if let e = emailByToken[token(o)] { return e }
        guard let e = email(try await get("/api/oauth/profile", o)) else { throw Failure("Profile has no email") }
        emailByToken[token(o)] = e
        return e
    }

    /// Finds the slot the active login belongs to and copies the active login
    /// into it: Claude Code rotates the refresh token while it runs, which
    /// revokes the slot's saved copy.
    private func syncActive() async throws -> String? {
        guard let a = activeOAuth() else { return nil }
        let names = slotNames()
        if let n = names.first(where: { slotOAuth($0).map(token) == token(a) }) { return n }
        let e = try await activeEmail(a)
        guard let n = names.first(where: { slotEmail($0)?.lowercased() == e.lowercased() }) else { return nil }
        try setOAuth(a, slotService, n)
        return n
    }

    func reload() async {
        loading = true
        defer { loading = false }
        message = nil
        do { active = try await syncActive() } catch { message = error.localizedDescription }
        var out: [Slot] = []
        for name in slotNames() {
            var s = Slot(name: name, email: slotEmail(name), tier: slotTier(name))
            do {
                let o: OAuth
                if name == active {
                    // Claude Code refreshes this one; refreshing here would revoke
                    // the refresh token held by running sessions.
                    guard let a = activeOAuth(), !isExpired(a) else { throw Failure("expired – run claude to refresh") }
                    o = a
                } else {
                    guard var so = slotOAuth(name) else { throw Failure("no saved login") }
                    if isExpired(so) {
                        so = try await refreshed(so)
                        try setOAuth(so, slotService, name)
                    }
                    o = so
                }
                let u = try await get("/api/oauth/usage", o)
                s.fiveHour = Window(claude: u["five_hour"])
                s.sevenDay = Window(claude: u["seven_day"])
            } catch {
                s.problem = error.localizedDescription
            }
            out.append(s)
        }
        slots = out
        codex = await loadCodex()
        updatedAt = Date()
    }

    func switchTo(_ name: String) async {
        switching = name
        defer { switching = nil }
        do {
            // Overwriting a login that no slot holds would lose it.
            if try await syncActive() == nil, activeOAuth() != nil {
                throw Failure("Current login isn't saved – use Save Current Login first")
            }
            guard var o = slotOAuth(name) else { throw Failure("No saved login for \(name)") }
            if isExpired(o) {
                o = try await refreshed(o)
                try setOAuth(o, slotService, name)
            }
            try setOAuth(o, activeService, NSUserName())
            switchedTo = name
        } catch {
            message = error.localizedDescription
            return
        }
        await reload()
    }

    func saveCurrent() async {
        do {
            guard let a = activeOAuth() else { throw Failure("No Claude Code login – run claude and /login") }
            if let n = try await syncActive() { throw Failure("Already saved as \(n)") }
            let profile = try await get("/api/oauth/profile", a)
            guard let e = email(profile) else { throw Failure("Profile has no email") }
            let dir = slotsDir.appendingPathComponent(e)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: profile).write(to: dir.appendingPathComponent("profile.json"))
            try setOAuth(a, slotService, e)
        } catch {
            message = error.localizedDescription
            return
        }
        await reload()
    }
}

// MARK: UI

let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
let codexBlue = Color(red: 0.30, green: 0.58, blue: 0.98)

func severity(_ pct: Double?) -> Color {
    switch pct ?? 0 {
    case ..<60: Color(red: 0.20, green: 0.78, blue: 0.55)
    case ..<85: Color(red: 0.98, green: 0.70, blue: 0.20)
    default: Color(red: 0.95, green: 0.33, blue: 0.30)
    }
}

func resetText(_ d: Date?) -> String {
    guard let d else { return "not started" }
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "resetting" }
    if s < 24 * 3600 { return s >= 3600 ? "resets in \(s / 3600)h \(s / 60 % 60)m" : "resets in \(s / 60)m" }
    return "resets " + d.formatted(.dateTime.weekday(.abbreviated).hour())
}

@main
struct AuthBar: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            Panel(store: store)
        } label: {
            MenuBarLabel(slot: store.slots.first { $0.name == store.active })
        }
        .menuBarExtraStyle(.window)
    }
}

/// Outer ring 5h, inner ring 7d, then the 5h percentage. Drawn into one
/// template image so the menu bar tints it for light and dark mode.
struct MenuBarLabel: View {
    let slot: Slot?

    var body: some View {
        let content = HStack(spacing: 4) {
            ZStack {
                Ring(pct: slot?.fiveHour?.pct, color: .black, width: 2).frame(width: 15, height: 15)
                Ring(pct: slot?.sevenDay?.pct, color: .black, width: 2).frame(width: 8, height: 8)
            }
            Text(slot?.fiveHour?.pct.map { "\(Int($0))%" } ?? "–")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.black)
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return Image(nsImage: image)
    }
}

struct Ring: View {
    let pct: Double?
    let color: Color
    var width: CGFloat = 5

    var body: some View {
        let frac = min(pct ?? 0, 100) / 100
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: width)
            Circle()
                .trim(from: 0, to: frac)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.6), color], center: .center,
                                    startAngle: .zero, endAngle: .degrees(360 * frac)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(width / 2)
    }
}

struct Panel: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            sectionHeader("Claude Code", icon: "sparkle", tint: claudeOrange,
                          detail: "\(store.slots.count) accounts")

            if store.slots.isEmpty && !store.loading {
                Text("No saved accounts yet. Log in with `claude`, then save the login below.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(store.slots) { s in
                    AccountCard(slot: s, tint: claudeOrange, isActive: s.name == store.active,
                                isSwitching: s.name == store.switching) {
                        Task { await store.switchTo(s.name) }
                    }
                }
            }

            if let c = store.codex {
                sectionHeader("Codex", icon: "terminal.fill", tint: codexBlue, detail: "logged in")
                AccountCard(slot: c, tint: codexBlue, isActive: true, isSwitching: false, onSwitch: nil)
            }

            if let m = store.message {
                Label(m, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            } else if let n = store.switchedTo {
                Label("Switched to \(n) — restart Claude Code sessions to use it.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider().opacity(0.5)
            HStack {
                Button { Task { await store.saveCurrent() } } label: {
                    Label("Save current login", systemImage: "plus.circle.fill")
                }
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .help("Quit AuthBar")
                .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { Task { await store.reload() } }
    }

    func sectionHeader(_ title: String, icon: String, tint: Color, detail: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [claudeOrange, Color(red: 0.62, green: 0.32, blue: 0.75)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Image(systemName: "person.2.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("AuthBar").font(.system(size: 14, weight: .bold, design: .rounded))
                if let d = store.updatedAt {
                    (Text("Updated ") + Text(d, style: .relative) + Text(" ago"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { Task { await store.reload() } } label: {
                Group {
                    if store.loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold)) }
                }
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .disabled(store.loading)
            .help("Refresh usage")
        }
    }
}

struct AccountCard: View {
    let slot: Slot
    let tint: Color
    let isActive: Bool
    let isSwitching: Bool
    let onSwitch: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Avatar(seed: slot.email ?? slot.name)
                VStack(alignment: .leading, spacing: 3) {
                    Text(slot.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        if let t = slot.tier {
                            Text(t)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(tint.opacity(0.15)))
                                .foregroundStyle(tint)
                        }
                        if let e = slot.email, e != slot.name {
                            Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 4)
                trailing
            }
            if let p = slot.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                HStack(spacing: 12) {
                    if let w = slot.fiveHour { UsageGauge(label: "5-hour", window: w) }
                    if let w = slot.sevenDay { UsageGauge(label: "Weekly", window: w) }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering && !isActive ? 0.08 : 0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.25)],
                                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                                       : AnyShapeStyle(Color.primary.opacity(0.08)),
                              lineWidth: isActive ? 1.5 : 1))
        .shadow(color: isActive ? tint.opacity(0.25) : .clear, radius: 10)
        .scaleEffect(hovering && !isActive ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contentShape(Rectangle())
        .onTapGesture { if !isActive && !isSwitching { onSwitch?() } }
        .onHover { hovering = $0 }
    }

    @ViewBuilder var trailing: some View {
        if isSwitching {
            ProgressView().controlSize(.small)
        } else if isActive {
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("ACTIVE").font(.system(size: 9, weight: .heavy))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.green.opacity(0.15)))
            .foregroundStyle(.green)
        } else if onSwitch != nil {
            Text("Switch")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(hovering ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(0.08))))
                .foregroundStyle(hovering ? .white : .primary)
        }
    }
}

struct UsageGauge: View {
    let label: String
    let window: Window

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Ring(pct: window.pct, color: severity(window.pct), width: 4.5)
                Text(window.pct.map { "\(Int($0))" } ?? "–")
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
            }
            .frame(width: 38, height: 38)
            .animation(.spring(duration: 0.6), value: window.pct)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 11, weight: .semibold))
                Text(resetText(window.resetsAt)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Avatar: View {
    let seed: String

    var body: some View {
        // Sum of scalars, not hashValue: Swift randomizes hashValue per launch.
        let hue = Double(seed.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 360) / 360
        Circle()
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.95),
                                          Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.7)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text(seed.prefix(1).uppercased())
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white))
            .frame(width: 30, height: 30)
    }
}
