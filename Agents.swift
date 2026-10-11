import AppKit
import Darwin
import SQLite3
import SwiftUI

// The Agents tab: the coding agents running on this Mac, grouped by
// workspace. Everything is read, nothing is written:
//   - Conductor: its SQLite database (workspaces and their agent sessions)
//   - herdr: `herdr agent list`
//   - Claude Code in any other terminal: ~/.claude/sessions/<pid>.json, which
//     every interactive Claude Code process keeps up to date
//   - Claude Code background jobs: ~/.claude/jobs/<id>/state.json
//   - subagents: Claude Code's transcripts under ~/.claude/projects, and
//     Codex's thread table in ~/.codex/state_5.sqlite
//   - running commands: the shell processes each agent process has started
// Each source is read on its own, so one failing leaves the others working.

let home = FileManager.default.homeDirectoryForCurrentUser.path
let conductorDB = home + "/Library/Application Support/com.conductor.app/conductor.db"

enum Kind { case claude, codex, other }
enum Source: String { case conductor = "Conductor", herdr, terminal = "Terminal", job = "Background job" }

// Declaration order is display order.
enum Status: Int, Comparable {
    case needsYou, working, idle
    static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
}

struct Agent: Identifiable {
    let id: String
    let kind: Kind
    let source: Source
    var title: String
    var status: Status
    var label: String // the source's own word for the status: "waiting", "blocked", …
    var since: Date?
    var detail: String? // what a blocked background job needs from you
    var herdrPane: String?
    var conductorSession: String?
}

struct Workspace: Identifiable {
    var id: String { path }
    let path: String
    var repo: String
    var name: String
    var branch: String?
    var createdAt: Date?
    var source: Source
    var agents: [Agent] = []
    var updatedAt: Date?
    var conductorID: String?
    var tasks: [BackgroundTask] = []

    // A running subagent or command keeps the workspace "working" even when
    // the agent that started it is idle.
    var status: Status {
        (agents.map(\.status) + (tasks.contains { $0.running } ? [.working] : [])).min() ?? .idle
    }
    var lastActivity: Date? { ([updatedAt] + agents.map(\.since) + tasks.map(\.since)).compactMap { $0 }.max() }
    var isStale: Bool {
        status == .idle && (lastActivity.map { -$0.timeIntervalSinceNow > 3 * 86400 } ?? true)
    }
}

/// A subagent or a shell command started by an agent in this workspace.
struct BackgroundTask: Identifiable {
    let id: String
    let isCommand: Bool
    let agent: Kind
    var title: String
    var running: Bool
    var since: Date? // when a command started; when a subagent last wrote
}

func contains(_ dir: String, _ path: String) -> Bool { path == dir || path.hasPrefix(dir + "/") }

// MARK: Helpers

func run(_ path: String, _ args: [String]) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

func readJSON(_ path: String) -> [String: Any]? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func query(_ dbPath: String, _ sql: String) throws -> [[String: String]] {
    var db: OpaquePointer?
    let uri = URL(fileURLWithPath: dbPath).absoluteString + "?mode=ro"
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        throw Failure("can't open \(dbPath)")
    }
    sqlite3_busy_timeout(db, 1000)
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw Failure(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }
    var rows: [[String: String]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        var row: [String: String] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
            if let v = sqlite3_column_text(stmt, i) {
                row[String(cString: sqlite3_column_name(stmt, i))] = String(cString: v)
            }
        }
        rows.append(row)
    }
    return rows
}

/// Claude Code writes each subagent's transcript to
/// ~/.claude/projects/<cwd, non-alphanumerics as "-">/<session>/subagents/agent-<id>.jsonl,
/// with its type and task in agent-<id>.meta.json. A transcript written in the
/// last minute counts as running; finished ones stay listed for 10 minutes.
func claudeSubagents(cwd: String, session: String) -> [BackgroundTask] {
    let project = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    let dir = "\(home)/.claude/projects/\(project)/\(session)/subagents"
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return files.filter { $0.hasSuffix(".jsonl") }.compactMap { f in
        guard let m = try? FileManager.default.attributesOfItem(atPath: dir + "/" + f)[.modificationDate] as? Date,
              -m.timeIntervalSinceNow < 600
        else { return nil }
        let meta = readJSON(dir + "/" + f.replacingOccurrences(of: ".jsonl", with: ".meta.json"))
        let type = meta?["agentType"] as? String ?? "subagent"
        let task = meta?["description"] as? String ?? ""
        return BackgroundTask(id: "cs:" + f, isCommand: false, agent: .claude,
                              title: task.isEmpty ? type : "\(type): \(task)",
                              running: -m.timeIntervalSinceNow < 60, since: m)
    }
}

/// Codex records subagents as threads with thread_source "subagent". One
/// updated in the last minute counts as running; finished ones stay listed
/// for 10 minutes.
func codexSubagents() throws -> [(cwd: String, task: BackgroundTask)] {
    let path = home + "/.codex/state_5.sqlite"
    guard FileManager.default.fileExists(atPath: path) else { return [] }
    let cutoff = Int((Date().timeIntervalSince1970 - 600) * 1000)
    let rows = try query(path, """
        select id, cwd, agent_nickname as nick, agent_role as role, updated_at_ms as updated,
               coalesce(nullif(title, ''), substr(first_user_message, 1, 120)) as task
        from threads where thread_source = 'subagent' and updated_at_ms > \(cutoff)
        """)
    return rows.compactMap { r in
        guard let id = r["id"], let cwd = r["cwd"], let ms = Double(r["updated"] ?? "") else { return nil }
        let updated = Date(timeIntervalSince1970: ms / 1000)
        let who = [r["nick"], r["role"].map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        let title = [who.isEmpty ? "subagent" : who, r["task"]].compactMap { $0 }.joined(separator: ": ")
        return (cwd, BackgroundTask(id: "xs:" + id, isCommand: false, agent: .codex, title: title,
                                    running: -updated.timeIntervalSinceNow < 60, since: updated))
    }
}

struct Proc {
    let pid: Int32
    let ppid: Int32
    let started: Date
    let command: String
}

func processes() -> [Proc] {
    guard let data = run("/bin/ps", ["-axo", "pid=,ppid=,etime=,command="]) else { return [] }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard f.count == 4, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { return nil }
        // etime is [[dd-]hh:]mm:ss
        let dayParts = f[2].split(separator: "-")
        let clock = dayParts.last!.split(separator: ":").compactMap { Double($0) }
        var secs = clock.reduce(0) { $0 * 60 + $1 }
        if dayParts.count == 2, let d = Double(dayParts[0]) { secs += d * 86400 }
        return Proc(pid: pid, ppid: ppid, started: Date(timeIntervalSinceNow: -secs), command: String(f[3]))
    }
}

func cwd(of pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

/// The command a shell child of an agent is running. Claude Code wraps each
/// command as `zsh -c source <snapshot> … && eval '<command>' …`; Codex runs
/// `zsh -lc <command>`. `ps` prints newlines as \012.
func commandTitle(_ c: String) -> String {
    var s = c
    if let r = s.range(of: "eval '") {
        s = String(s[r.upperBound...])
        if let end = s.range(of: "' < /dev/null") ?? s.range(of: "'", options: .backwards) { s = String(s[..<end.lowerBound]) }
    } else if let r = s.range(of: #" -l?c "#, options: .regularExpression) {
        s = String(s[r.upperBound...])
    }
    s = s.replacingOccurrences(of: #"(\\012\s*)+"#, with: "; ", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: "do;", with: "do").replacingOccurrences(of: "then;", with: "then")
    return String(s.trimmingCharacters(in: .whitespaces).prefix(200))
}

/// Shells started directly by a Claude Code or Codex process, by that process's
/// working folder. MCP servers are also children of agents but run node or npm,
/// not a shell, so they're left out.
func runningCommands(claudePids: Set<Int32>) -> [(cwd: String, task: BackgroundTask)] {
    let procs = processes()
    let shells = ["/bin/zsh", "/bin/bash", "/bin/sh", "zsh", "bash", "sh"]
    let codexPids = Set(procs.filter { $0.command.range(of: #"(^|/)codex( |$)"#, options: .regularExpression) != nil }.map(\.pid))
    var out: [(String, BackgroundTask)] = []
    for p in procs {
        let isClaude = claudePids.contains(p.ppid)
        guard isClaude || codexPids.contains(p.ppid),
              shells.contains(where: { p.command.hasPrefix($0 + " ") }),
              let dir = cwd(of: p.pid)
        else { continue }
        out.append((dir, BackgroundTask(id: "p:\(p.pid)", isCommand: true, agent: isClaude ? .claude : .codex,
                                        title: commandTitle(p.command), running: true, since: p.started)))
    }
    return out
}

/// The git checkout containing `cwd`. Read from .git directly: one `git`
/// process per agent every refresh would be the slowest thing here.
func checkout(_ cwd: String) -> Workspace? {
    var dir = URL(fileURLWithPath: cwd)
    while dir.path != "/" {
        let dotgit = dir.appendingPathComponent(".git").path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotgit, isDirectory: &isDir) {
            var gitdir = dotgit
            var repo = dir.lastPathComponent
            var created: Date?
            // A linked worktree's .git is a file: "gitdir: <main>/.git/worktrees/<name>".
            if !isDir.boolValue, let s = try? String(contentsOfFile: dotgit, encoding: .utf8), s.hasPrefix("gitdir: ") {
                gitdir = String(s.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                repo = URL(fileURLWithPath: gitdir).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().lastPathComponent
                created = try? FileManager.default.attributesOfItem(atPath: dotgit)[.creationDate] as? Date
            }
            let head = (try? String(contentsOfFile: gitdir + "/HEAD", encoding: .utf8)) ?? ""
            let branch = head.hasPrefix("ref: refs/heads/")
                ? String(head.dropFirst(16)).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return Workspace(path: dir.path, repo: repo, name: dir.lastPathComponent, branch: branch,
                             createdAt: created, source: .terminal)
        }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

func kind(_ s: String?) -> Kind {
    switch s { case "claude": .claude; case "codex": .codex; default: .other }
}

// MARK: Sources

func conductorWorkspaces() throws -> [Workspace] {
    let rows = try query(conductorDB, """
        select w.id as wid, r.name as repo, w.directory_name as dir, w.workspace_path as path,
               w.branch as branch, w.created_at as created, w.updated_at as wupdated,
               s.id as sid, s.status as status, s.agent_type as agent, s.title as title,
               s.updated_at as supdated, s.claude_session_id as csid
        from workspaces w join repos r on r.id = w.repository_id
        left join sessions s on s.workspace_id = w.id and s.is_hidden = 0
        where w.state = 'ready'
        """)
    var byID: [String: Workspace] = [:]
    var order: [String] = []
    for r in rows {
        guard let wid = r["wid"] else { continue }
        if byID[wid] == nil {
            let path = r["path"] ?? "\(home)/conductor/workspaces/\(r["repo"] ?? "")/\(r["dir"] ?? "")"
            byID[wid] = Workspace(path: path, repo: r["repo"] ?? "", name: r["dir"] ?? "", branch: r["branch"],
                                  createdAt: parseDate(r["created"]), source: .conductor,
                                  updatedAt: parseDate(r["wupdated"]), conductorID: wid)
            order.append(wid)
        }
        guard let sid = r["sid"] else { continue }
        let raw = r["status"] ?? "idle"
        let status: Status = switch raw {
        case "waiting", "error": .needsYou
        case "working": .working
        default: .idle
        }
        byID[wid]!.agents.append(Agent(
            id: "c:" + sid, kind: kind(r["agent"]), source: .conductor,
            title: r["title"] ?? "Untitled", status: status, label: raw,
            since: parseDate(r["supdated"]), conductorSession: sid))
    }
    // A workspace collects one session per chat tab; idle ones only matter
    // when nothing else is going on, and then only the latest.
    return order.map { wid in
        var w = byID[wid]!
        let busy = w.agents.filter { $0.status != .idle }
        let latestIdle = w.agents.filter { $0.status == .idle }.max { ($0.since ?? .distantPast) < ($1.since ?? .distantPast) }
        w.agents = busy.isEmpty ? (latestIdle.map { [$0] } ?? []) : busy
        return w
    }
}

struct LocalAgent {
    var agent: Agent
    let cwd: String
}

func herdrAgents() throws -> [LocalAgent] {
    // GUI apps don't get the login shell's PATH.
    let candidates = ["\(home)/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
    guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
    guard let data = run(bin, ["agent", "list"]),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let list = (json["result"] as? [String: Any])?["agents"] as? [[String: Any]]
    else { throw Failure("`herdr agent list` failed – is the herdr server running?") }
    return list.compactMap { a in
        guard let pane = a["pane_id"] as? String, let cwd = a["cwd"] as? String else { return nil }
        let raw = a["agent_status"] as? String ?? "unknown"
        let status: Status = switch raw {
        case "blocked": .needsYou
        case "working": .working
        default: .idle
        }
        var title = (a["terminal_title_stripped"] as? String ?? "")
        // Claude Code prefixes its terminal title with a spinner glyph.
        title = title.replacingOccurrences(of: #"^[^\p{L}\p{N}]+\s*"#, with: "", options: .regularExpression)
        return LocalAgent(agent: Agent(id: "h:" + pane, kind: kind(a["agent"] as? String), source: .herdr,
                                       title: title.isEmpty ? "herdr pane \(pane)" : title,
                                       status: status, label: raw == "blocked" ? "needs input" : raw,
                                       herdrPane: pane),
                          cwd: cwd)
    }
}

/// Claude Code background jobs. Finished ones and ones untouched for a week
/// are left out: a job's state file stays behind after its process is gone.
func claudeJobs() -> [LocalAgent] {
    let dir = home + "/.claude/jobs"
    let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return ids.compactMap { id in
        guard let j = readJSON("\(dir)/\(id)/state.json"), let cwd = j["cwd"] as? String,
              let updated = parseDate(j["updatedAt"]), -updated.timeIntervalSinceNow < 7 * 86400
        else { return nil }
        let raw = j["state"] as? String ?? "unknown"
        let status: Status
        switch raw {
        case "blocked": status = .needsYou
        case "working": status = .working
        default: return nil
        }
        return LocalAgent(agent: Agent(id: "j:" + id, kind: .claude, source: .job,
                                       title: j["name"] as? String ?? j["detail"] as? String ?? "Background job",
                                       status: status, label: raw, since: updated,
                                       detail: j["needs"] as? String ?? j["detail"] as? String),
                          cwd: cwd)
    }
}

struct ClaudeProcess {
    let pid: Int32
    let session: String?
    let cwd: String
    let name: String
    let status: String
    let since: Date?
    let terminal: Bool
}

func claudeProcesses() -> [ClaudeProcess] {
    let dir = home + "/.claude/sessions"
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return files.filter { $0.hasSuffix(".json") }.compactMap { f in
        guard let j = readJSON(dir + "/" + f),
              let pid = (j["pid"] as? NSNumber)?.int32Value,
              let cwd = j["cwd"] as? String,
              kill(pid, 0) == 0 // the file outlives a crashed process
        else { return nil }
        return ClaudeProcess(
            pid: pid, session: j["sessionId"] as? String, cwd: cwd, name: j["name"] as? String ?? "claude",
            status: j["status"] as? String ?? "unknown",
            since: (j["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            // Conductor and scripts run Claude Code through the SDK or `-p`; only
            // "cli" + "interactive" is someone's terminal.
            terminal: j["entrypoint"] as? String == "cli" && j["kind"] as? String == "interactive")
    }
}

struct Snapshot {
    var workspaces: [Workspace] = []
    var problems: [String] = []
}

func collect() -> Snapshot {
    var snap = Snapshot()
    var workspaces: [Workspace] = []
    do { workspaces = try conductorWorkspaces() } catch { snap.problems.append("Conductor: \(error.localizedDescription)") }

    var local: [LocalAgent] = []
    do { local = try herdrAgents() } catch { snap.problems.append("herdr: \(error.localizedDescription)") }

    local += claudeJobs()

    let claude = claudeProcesses()
    let herdrCwds = Set(local.filter { $0.agent.source == .herdr && $0.agent.kind == .claude }.map(\.cwd))
    for p in claude where p.terminal && !herdrCwds.contains(p.cwd) {
        let status: Status = p.status == "busy" ? .working : .idle
        local.append(LocalAgent(
            agent: Agent(id: "t:\(p.pid)", kind: .claude, source: .terminal, title: p.name, status: status,
                         label: p.status == "busy" ? "working" : p.status, since: p.since),
            cwd: p.cwd))
    }

    for l in local {
        if let i = workspaces.firstIndex(where: { contains($0.path, l.cwd) }) {
            workspaces[i].agents.removeAll { $0.source == .conductor && $0.status == .idle }
            workspaces[i].agents.append(l.agent)
            continue
        }
        var w = checkout(l.cwd)
            ?? Workspace(path: l.cwd, repo: "", name: URL(fileURLWithPath: l.cwd).lastPathComponent, source: .terminal)
        w.source = l.agent.source
        w.agents = [l.agent]
        workspaces.append(w)
    }
    // Every Claude Code process has a session file, including Conductor's, so
    // this covers subagents of agents from all sources.
    var tasks = claude.flatMap { p in p.session.map { s in claudeSubagents(cwd: p.cwd, session: s).map { (p.cwd, $0) } } ?? [] }
    do { tasks += try codexSubagents() } catch { snap.problems.append("Codex subagents: \(error.localizedDescription)") }
    tasks += runningCommands(claudePids: Set(claude.map(\.pid)))
    for (dir, task) in tasks {
        if let i = workspaces.firstIndex(where: { contains($0.path, dir) }) { workspaces[i].tasks.append(task) }
    }
    snap.workspaces = workspaces
    return snap
}

// MARK: Store

@MainActor
final class AgentsStore: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var problems: [String] = []
    @Published var updatedAt: Date?
    /// When each agent was first seen in its current status, for sources that
    /// don't record it (herdr).
    private var seen: [String: (label: String, at: Date)] = [:]
    private var timer: Timer?
    private var refreshing = false

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var snap = await Task.detached { collect() }.value
        var nextSeen: [String: (label: String, at: Date)] = [:]
        for wi in snap.workspaces.indices {
            for ai in snap.workspaces[wi].agents.indices {
                let a = snap.workspaces[wi].agents[ai]
                let prev = seen[a.id]
                let at = prev?.label == a.label ? prev!.at : Date()
                nextSeen[a.id] = (a.label, at)
                if a.since == nil { snap.workspaces[wi].agents[ai].since = at }
            }
        }
        seen = nextSeen
        workspaces = snap.workspaces
        problems = snap.problems
        updatedAt = Date()
    }

    func section(_ s: Status, stale: Bool = false) -> [Workspace] {
        workspaces
            .filter { $0.status == s && (s != .idle || $0.isStale == stale) }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    func count(_ s: Status) -> Int { workspaces.flatMap(\.agents).filter { $0.status == s }.count }
}

// MARK: UI

struct AgentsView: View {
    @ObservedObject var store: AgentsStore
    @State private var showStale = false
    private let grid = [GridItem(.adaptive(minimum: 380), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView { content }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            if store.workspaces.isEmpty {
                Text("No open workspaces or running agents found.").foregroundStyle(.secondary)
            }
            section("Needs you", icon: "hand.raised.fill", tint: needsColor, store.section(.needsYou))
            section("Working", icon: "bolt.fill", tint: workingColor, store.section(.working))
            section("Idle", icon: "moon.fill", tint: .secondary, store.section(.idle))
            staleSection
            ForEach(store.problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20)
    }

    func header(_ title: String, icon: String, tint: Color, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    func section(_ title: String, icon: String, tint: Color, _ items: [Workspace]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header(title, icon: icon, tint: tint, count: items.count)
                LazyVGrid(columns: grid, spacing: 12) { ForEach(items) { WorkspaceCard(workspace: $0) } }
            }
        }
    }

    @ViewBuilder var staleSection: some View {
        let stale = store.section(.idle, stale: true)
        if !stale.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button { withAnimation(.easeOut(duration: 0.15)) { showStale.toggle() } } label: {
                    HStack(spacing: 6) {
                        header("Stale · nothing for 3+ days", icon: "archivebox.fill", tint: .brown, count: stale.count)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showStale ? 90 : 0))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showStale {
                    LazyVGrid(columns: grid, spacing: 12) { ForEach(stale) { WorkspaceCard(workspace: $0) } }
                }
            }
        }
    }
}

let needsColor = Color(red: 0.98, green: 0.55, blue: 0.20)
let workingColor = Color(red: 0.20, green: 0.78, blue: 0.55)

func ago(_ d: Date?) -> String {
    guard let d else { return "–" }
    let s = Int(-d.timeIntervalSinceNow)
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

func color(_ s: Status) -> Color {
    switch s { case .needsYou: needsColor; case .working: workingColor; case .idle: .secondary }
}

struct WorkspaceCard: View {
    let workspace: Workspace
    @State private var hovering = false

    var body: some View {
        let w = workspace
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if !w.repo.isEmpty && w.repo != w.name {
                            Text(w.repo).foregroundStyle(.secondary)
                            Text("/").foregroundStyle(.tertiary)
                        }
                        Text(w.name).fontWeight(.semibold)
                    }
                    .font(.system(size: 13))
                    .lineLimit(1)
                    if let b = w.branch {
                        Label(b, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                AgeChip(createdAt: w.createdAt)
            }
            ForEach(w.agents) { AgentRow(agent: $0) }
            if !w.tasks.isEmpty { TaskList(tasks: w.tasks) }
            HStack(spacing: 6) {
                Text(w.source.rawValue).font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Text(ago(w.lastActivity) == "now" ? "active now" : "active \(ago(w.lastActivity)) ago").font(.caption2)
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
        .overlay(alignment: .leading) {
            // Status stripe down the card's left edge.
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                .fill(color(w.status).opacity(w.status == .idle ? 0.3 : 1))
                .frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open(w) }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(w.path, forType: .string)
            }
        }
        .help(w.path)
    }

    /// Goes to the agent that most needs attention: its herdr pane, or its
    /// Conductor workspace and chat.
    func open(_ w: Workspace) {
        let target = w.agents.min { $0.status < $1.status }
        if let pane = target?.herdrPane ?? w.agents.first(where: { $0.herdrPane != nil })?.herdrPane {
            let bin = ["\(home)/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            if let bin { _ = run(bin, ["agent", "focus", pane]) }
        } else if let id = w.conductorID {
            // Undocumented: handled by Conductor's frontend as "open-workspace";
            // `session` picks the chat tab.
            var c = URLComponents(string: "conductor://workspace")!
            c.queryItems = [URLQueryItem(name: "id", value: id)]
                + (target?.conductorSession.map { [URLQueryItem(name: "session", value: $0)] } ?? [])
            NSWorkspace.shared.open(c.url!)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)])
        }
    }
}

struct AgentRow: View {
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                KindIcon(kind: agent.kind)
                Text(agent.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                StatusPill(status: agent.status, label: agent.label, since: agent.since)
            }
            if let d = agent.detail {
                Text(d).font(.caption).foregroundStyle(agent.status == .needsYou ? needsColor : .secondary)
                    .lineLimit(2).padding(.leading, 24)
            }
        }
    }
}

struct KindIcon: View {
    let kind: Kind

    var body: some View {
        Image(systemName: kind == .codex ? "terminal.fill" : "sparkle")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(kind == .codex ? codexBlue : claudeOrange)
            .frame(width: 16)
    }
}

/// Subagents and running commands, running first; long lists are cut to four.
struct TaskList: View {
    let tasks: [BackgroundTask]

    var body: some View {
        let sorted = tasks.sorted { ($0.running ? 0 : 1, $1.since ?? .distantPast) < ($1.running ? 0 : 1, $0.since ?? .distantPast) }
        let subagents = tasks.filter { !$0.isCommand && $0.running }.count
        let commands = tasks.filter(\.isCommand).count
        VStack(alignment: .leading, spacing: 5) {
            Text([subagents > 0 ? "\(subagents) subagent\(subagents == 1 ? "" : "s") running" : nil,
                  commands > 0 ? "\(commands) command\(commands == 1 ? "" : "s") running" : nil,
                  subagents + commands == 0 ? "Recently finished" : nil]
                .compactMap { $0 }.joined(separator: " · ").uppercased())
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            ForEach(sorted.prefix(4)) { t in
                HStack(spacing: 8) {
                    Image(systemName: t.isCommand ? "chevron.right.square.fill" : "person.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(t.agent == .codex ? codexBlue : claudeOrange)
                        .frame(width: 16)
                    Text(t.title)
                        .font(t.isCommand ? .system(size: 11, design: .monospaced) : .system(size: 11))
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(t.running ? .primary : .secondary)
                    Spacer(minLength: 4)
                    StatusPill(status: t.running ? .working : .idle, label: t.running ? "running" : "done", since: t.since)
                }
                .help(t.title)
            }
            if sorted.count > 4 {
                Text("+\(sorted.count - 4) more").font(.caption2).foregroundStyle(.secondary).padding(.leading, 24)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

struct StatusPill: View {
    let status: Status
    let label: String
    let since: Date?
    @State private var pulse = false

    var body: some View {
        let tint = color(status)
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
                .opacity(status == .working && pulse ? 0.3 : 1)
            Text("\(label) · \(ago(since))")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(status == .idle ? 0.08 : 0.15)))
        .foregroundStyle(status == .idle ? Color.secondary : tint)
        .onAppear {
            if status == .working {
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true }
            }
        }
    }
}

struct AgeChip: View {
    let createdAt: Date?

    var body: some View {
        if let createdAt {
            let days = -createdAt.timeIntervalSinceNow / 86400
            let tint: Color = days > 7 ? Color(red: 0.95, green: 0.33, blue: 0.30) : days > 2 ? needsColor : .secondary
            Label(ago(createdAt) == "now" ? "new" : ago(createdAt) + " old", systemImage: "clock")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.12)))
                .foregroundStyle(tint)
                .help("Worktree created \(createdAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}
