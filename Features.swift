import AppKit
import SwiftUI

// The Features tab: features that span repos. A workspace is a set of repos
// you pick. Starting a feature starts a lead agent that plans across all of
// them without changing files; the lead then starts one agent per repo it
// needs, each in its own worktree. agentbar-feature does the starting and
// documents the folders. Agents run in herdr, so the Agents tab's herdr
// source is what reports their status here.

let featuresRoot = home + "/agentbar"

/// A repo's worktree for a feature.
struct Lane: Identifiable {
    var id: String { path }
    let path: String
    var changed = 0 // uncommitted files
    var ahead = 0 // commits not on origin's default branch
}

struct Feature: Identifiable {
    var id: String { dir }
    let dir: String
    let name: String
    let herdrWorkspace: String
    var lanes: [Lane]
}

struct RepoSet: Identifiable {
    var id: String { name }
    let name: String
    var repos: [String]
    var features: [Feature]
}

func git(_ dir: String, _ args: [String]) -> String? {
    run("/usr/bin/git", ["-C", dir] + args).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

func lane(_ path: String) -> Lane {
    let base = git(path, ["rev-parse", "--abbrev-ref", "origin/HEAD"]) ?? "origin/main"
    return Lane(path: path,
                changed: git(path, ["status", "--porcelain"])?.split(separator: "\n").count ?? 0,
                ahead: Int(git(path, ["rev-list", "--count", "\(base)..HEAD"]) ?? "") ?? 0)
}

func loadRepoSets() -> [RepoSet] {
    let fm = FileManager.default
    func list(_ dir: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() }
    return list(featuresRoot).compactMap { name in
        let ws = featuresRoot + "/" + name
        guard let repos = try? String(contentsOfFile: ws + "/repos.txt", encoding: .utf8) else { return nil }
        let features = list(ws).compactMap { f -> Feature? in
            let dir = ws + "/" + f
            guard let herdr = try? String(contentsOfFile: dir + "/.herdr", encoding: .utf8) else { return nil }
            return Feature(dir: dir, name: f, herdrWorkspace: herdr.trimmingCharacters(in: .whitespacesAndNewlines),
                           lanes: list(dir).filter { fm.fileExists(atPath: "\(dir)/\($0)/.git") }.map { lane(dir + "/" + $0) })
        }
        return RepoSet(name: name, repos: repos.split(separator: "\n").map(String.init), features: features)
    }
}

/// Runs agentbar-feature and returns its output, or throws with it.
func featureScript(_ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: Bundle.main.resourcePath! + "/agentbar-feature")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Failure(text) }
    return text
}

@MainActor
final class FeaturesStore: ObservableObject {
    @Published var sets: [RepoSet] = []
    @Published var problem: String?
    @Published var starting = false

    func reload() async { sets = await Task.detached { loadRepoSets() }.value }

    func create(_ name: String) async {
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            problem = "Workspace names use letters, digits, '.', '_' or '-'."
            return
        }
        try? FileManager.default.createDirectory(atPath: featuresRoot + "/" + name, withIntermediateDirectories: true)
        save(name, repos: [])
        await reload()
    }

    func save(_ name: String, repos: [String]) {
        let text = repos.map { $0 + "\n" }.joined()
        do { try text.write(toFile: "\(featuresRoot)/\(name)/repos.txt", atomically: true, encoding: .utf8); problem = nil }
        catch { problem = error.localizedDescription }
    }

    func addRepos(to s: RepoSet) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose repos' main clones, or a folder of them"
        guard panel.runModal() == .OK else { return }
        let fm = FileManager.default
        func isRepo(_ path: String) -> Bool { fm.fileExists(atPath: path + "/.git") }
        // A folder that isn't a repo stands for the repos directly inside it.
        let picked = panel.urls.map(\.path).flatMap { p in
            isRepo(p) ? [p] : ((try? fm.contentsOfDirectory(atPath: p)) ?? []).sorted().map { p + "/" + $0 }.filter(isRepo)
        }
        // Agents find a repo by its folder name, so two repos can't share one.
        var repos = s.repos
        for p in picked where !repos.contains(where: { URL(fileURLWithPath: $0).lastPathComponent == URL(fileURLWithPath: p).lastPathComponent }) {
            repos.append(p)
        }
        save(s.name, repos: repos)
        if picked.isEmpty { problem = "No git repos in what you picked." }
        await reload()
    }

    func remove(_ repo: String, from s: RepoSet) async {
        save(s.name, repos: s.repos.filter { $0 != repo })
        await reload()
    }

    func start(_ feature: String, in s: RepoSet) async {
        starting = true
        defer { starting = false }
        do {
            let pane = try await Task.detached { try featureScript(["lead", s.name, feature]) }.value
            problem = nil
            Target(userInfo: ["path": "\(featuresRoot)/\(s.name)/main", "pane": pane])?.open()
        } catch {
            problem = error.localizedDescription
        }
        await reload()
    }
}

struct FeaturesView: View {
    @ObservedObject var store: FeaturesStore
    @ObservedObject var agents: AgentsStore
    @State private var newSet = ""
    @State private var newFeature: [String: String] = [:]
    private let grid = [GridItem(.adaptive(minimum: 380), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let p = store.problem {
                    Label(p, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                ForEach(store.sets) { repoSet($0) }
                HStack {
                    input("New workspace", $newSet)
                    Button("Create") {
                        let n = newSet
                        newSet = ""
                        Task { await store.create(n) }
                    }
                    .disabled(newSet.isEmpty)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Features")
        .task {
            while !Task.isCancelled {
                await store.reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func repoSet(_ s: RepoSet) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(s.name).font(.system(size: 17, weight: .semibold))
                Button("Add Repos…") { Task { await store.addRepos(to: s) } }.controlSize(.small)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(s.repos, id: \.self) { r in
                    HStack(spacing: 5) {
                        Text(URL(fileURLWithPath: r).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button { Task { await store.remove(r, from: s) } } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .font(mono(11))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .surface()
                    .help(r)
                }
            }
            HStack {
                input("New feature", Binding(get: { newFeature[s.name] ?? "" }, set: { newFeature[s.name] = $0 }))
                Button("Start Lead") {
                    let f = newFeature[s.name] ?? ""
                    newFeature[s.name] = nil
                    Task { await store.start(f, in: s) }
                }
                .disabled((newFeature[s.name] ?? "").isEmpty || s.repos.isEmpty || store.starting)
                .help("Starts a lead agent in herdr that plans across these repos")
            }
            ForEach(s.features) { feature($0, in: s) }
        }
    }

    func feature(_ f: Feature, in s: RepoSet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(f.name, systemImage: "arrow.triangle.branch").font(mono(12, .medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: grid, spacing: 12) {
                let l = lead(f, in: s)
                WorkspaceCard(workspace: l).onTapGesture { l.target.open() }
                ForEach(f.lanes) { lane in
                    let w = agents.workspaces.first { $0.path == lane.path }
                        ?? checkout(lane.path).map { var w = $0; w.source = .herdr; return w }
                        ?? Workspace(path: lane.path, repo: "", name: URL(fileURLWithPath: lane.path).lastPathComponent, source: .herdr)
                    VStack(alignment: .leading, spacing: 4) {
                        WorkspaceCard(workspace: w).onTapGesture { w.target.open() }
                        HStack(spacing: 10) {
                            Text("\(lane.changed) uncommitted").foregroundStyle(lane.changed > 0 ? needsColor : .secondary)
                            Text("\(lane.ahead) ahead").foregroundStyle(lane.ahead > 0 ? workingColor : .secondary)
                        }
                        .font(mono(10)).padding(.leading, 4)
                    }
                }
            }
        }
    }

    func input(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(width: 240)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Chrome.raised))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Chrome.hairline))
    }

    /// Every feature's lead runs in the workspace's main/ folder, so the
    /// Agents tab groups them together; each one's herdr pane ids start with
    /// its feature's herdr workspace id.
    func lead(_ f: Feature, in s: RepoSet) -> Workspace {
        let path = "\(featuresRoot)/\(s.name)/main"
        var w = Workspace(path: path, repo: f.name, name: "lead", source: .herdr)
        if let all = agents.workspaces.first(where: { $0.path == path }) {
            w.agents = all.agents.filter { $0.herdrPane?.hasPrefix(f.herdrWorkspace + ":") == true }
            let sessions = Set(w.agents.compactMap(\.sessionID))
            w.tasks = all.tasks.filter { $0.parent.map(sessions.contains) == true }
        }
        return w
    }
}
