import SwiftUI

// The page for one workspace: a graph of its agents and what each one started
// (subagents, nested subagents, commands), then the details behind it.

struct GraphNode: Identifiable {
    enum Role { case workspace, agent, subagent, command }
    let id: String
    let role: Role
    let kind: Kind
    let title: String
    let subtitle: String
    let accent: Color // the role's color: icon, edge, glow
    let status: Color // the status dot
    let glow: Bool // working, running, or needing you
    var children: [GraphNode] = []
}

func brand(_ k: Kind) -> Color { k == .codex ? codexBlue : k == .claude ? claudeOrange : .secondary }

/// Workspace → agents → the subagents and commands each started. A task whose
/// parent isn't on this page (e.g. a command under a Codex process, which
/// records no thread) hangs off the workspace.
func graph(_ w: Workspace) -> GraphNode {
    let agentSessions = Set(w.agents.compactMap(\.sessionID))
    let taskIDs = Set(w.tasks.map(\.id))
    let byParent = Dictionary(grouping: w.tasks) { t -> String in
        guard let p = t.parent, agentSessions.contains(p) || taskIDs.contains(p) else { return "" }
        return p
    }
    func node(_ t: BackgroundTask) -> GraphNode {
        GraphNode(id: t.id, role: t.isCommand ? .command : .subagent, kind: t.agent, title: t.title,
                  subtitle: (t.running ? "Running · " : "Done · ") + ago(t.since),
                  accent: t.isCommand ? palette.command : palette.subagent,
                  status: t.running ? workingColor : .secondary, glow: t.running,
                  children: (byParent[t.id] ?? []).map(node))
    }
    let agents = w.agents.map { a in
        GraphNode(id: a.id, role: .agent, kind: a.kind, title: a.title,
                  subtitle: "\(capitalized(a.label)) · \(ago(a.since))",
                  accent: a.status == .needsYou ? needsColor : brand(a.kind),
                  status: color(a.status), glow: a.status != .idle,
                  children: a.sessionID.flatMap { byParent[$0] }.map { $0.map(node) } ?? [])
    }
    return GraphNode(id: w.id, role: .workspace, kind: .other, title: w.title, subtitle: w.branch ?? w.path,
                     accent: w.status == .idle ? .secondary : color(w.status), status: color(w.status),
                     glow: false, children: agents + (byParent[""] ?? []).map(node))
}

struct AgentGraph: View {
    let root: GraphNode
    let width: CGFloat // the space available; columns stretch to use it
    private let nodeHeight: CGFloat = 60
    private let rowGap: CGFloat = 16
    private let inset: CGFloat = 24

    struct Edge {
        let from: CGPoint
        let to: CGPoint
        let tint: Color
        let active: Bool

        var control: (CGPoint, CGPoint) {
            let midX = (from.x + to.x) / 2
            return (CGPoint(x: midX, y: from.y), CGPoint(x: midX, y: to.y))
        }

        /// The point `t` (0…1) along the cubic Bézier curve between the nodes.
        func point(_ t: CGFloat) -> CGPoint {
            let (c1, c2) = control
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * from.x + b * c1.x + c * c2.x + d * to.x,
                           y: a * from.y + b * c1.y + c * c2.y + d * to.y)
        }
    }

    struct Layout {
        var nodes: [(GraphNode, CGPoint)] = []
        var edges: [Edge] = []
        var size = CGSize.zero
        var nodeWidth: CGFloat = 0
    }

    /// A left-to-right tree: leaves take consecutive rows, each parent sits
    /// halfway between its first and last child, and the columns are spread
    /// across `width` (between fixed minimum and maximum sizes), centered.
    func layout() -> Layout {
        func depth(_ n: GraphNode) -> Int { 1 + (n.children.map(depth).max() ?? 0) }
        let cols = CGFloat(depth(root))
        let usable = width - 2 * inset
        let nodeWidth = min(260, max(170, (usable - (cols - 1) * 56) / cols))
        let colGap = cols > 1 ? min(150, max(36, (usable - cols * nodeWidth) / (cols - 1))) : 0
        let contentWidth = cols * nodeWidth + (cols - 1) * colGap + 2 * inset
        let left = max(0, (width - contentWidth) / 2) + inset

        var out = Layout(nodeWidth: nodeWidth)
        var row = 0
        func place(_ n: GraphNode, _ d: Int) -> CGPoint {
            let x = left + CGFloat(d) * (nodeWidth + colGap) + nodeWidth / 2
            let kids = n.children.map { ($0, place($0, d + 1)) }
            let y: CGFloat
            if kids.isEmpty {
                y = inset + CGFloat(row) * (nodeHeight + rowGap) + nodeHeight / 2
                row += 1
            } else {
                y = (kids.first!.1.y + kids.last!.1.y) / 2
            }
            let p = CGPoint(x: x, y: y)
            for (k, kp) in kids {
                out.edges.append(Edge(from: CGPoint(x: p.x + nodeWidth / 2, y: p.y),
                                      to: CGPoint(x: kp.x - nodeWidth / 2, y: kp.y), tint: k.accent, active: k.glow))
            }
            out.nodes.append((n, p))
            return p
        }
        _ = place(root, 0)
        out.size = CGSize(width: max(width, contentWidth),
                          height: CGFloat(row) * (nodeHeight + rowGap) - rowGap + 2 * inset)
        return out
    }

    var body: some View {
        let l = layout()
        ZStack(alignment: .topLeading) {
            // Only this canvas redraws each frame, and only while something is active.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !l.edges.contains { $0.active })) { t in
                Canvas { ctx, canvas in
                    var dots = Path()
                    for x in stride(from: 12.0, to: canvas.width, by: 22) {
                        for y in stride(from: 12.0, to: canvas.height, by: 22) {
                            dots.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                        }
                    }
                    ctx.fill(dots, with: .color(.white.opacity(0.07)))

                    let time = t.date.timeIntervalSinceReferenceDate
                    for e in l.edges {
                        var path = Path()
                        let (c1, c2) = e.control
                        path.move(to: e.from)
                        path.addCurve(to: e.to, control1: c1, control2: c2)
                        if e.active {
                            ctx.stroke(path, with: .color(e.tint.opacity(0.12)), lineWidth: 8)
                            ctx.stroke(path, with: .linearGradient(Gradient(colors: [e.tint.opacity(0.25), e.tint.opacity(0.8)]),
                                                                   startPoint: e.from, endPoint: e.to), lineWidth: 2)
                            for k in 0..<3 { // pulses travelling from parent to child
                                let p = e.point(CGFloat((time * 0.45 + Double(k) / 3).truncatingRemainder(dividingBy: 1)))
                                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
                                         with: .color(e.tint.opacity(0.18)))
                                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                                         with: .color(.white.opacity(0.9)))
                            }
                        } else {
                            ctx.stroke(path, with: .color(.white.opacity(0.14)), lineWidth: 1.5)
                        }
                        for p in [e.from, e.to] {
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                                     with: .color(e.active ? e.tint : .white.opacity(0.25)))
                        }
                    }
                }
            }
            ForEach(l.nodes, id: \.0.id) { n, p in
                GraphNodeView(node: n).frame(width: l.nodeWidth, height: nodeHeight).position(p)
            }
        }
        .frame(width: l.size.width, height: l.size.height)
        .environment(\.colorScheme, .dark) // the canvas is always dark, in either appearance
    }
}

struct GraphNodeView: View {
    let node: GraphNode

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(node.accent.opacity(0.18))
                .overlay(icon.font(.system(size: 13, weight: .semibold)).foregroundStyle(node.accent))
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.title)
                    .font(node.role == .command ? .system(size: 11, design: .monospaced) : .system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(node.status).frame(width: 6, height: 6)
                    Text(node.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.11)))
                .shadow(color: node.glow ? node.accent.opacity(0.45) : .black.opacity(0.35), radius: node.glow ? 14 : 6, y: node.glow ? 0 : 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(node.glow ? node.accent.opacity(0.75) : .white.opacity(0.10), lineWidth: node.glow ? 1.5 : 1))
        .help(node.title)
    }

    @ViewBuilder var icon: some View {
        switch node.role {
        case .workspace: Image(systemName: "folder.fill")
        case .agent: Image(systemName: node.kind == .codex ? "terminal.fill" : "sparkle")
        case .subagent: Image(systemName: "person.2.fill")
        case .command: Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
    }
}

/// Inline Markdown (bold, code, links) as agents write it.
func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}

func agoPhrase(_ d: Date) -> String { ago(d) == "now" ? "just now" : "\(ago(d)) ago" }

/// The shared look of the page's panels.
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface()
    }
}

struct WorkspacePage: View {
    let workspace: Workspace

    var body: some View {
        let w = workspace
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    summary(w)
                    section("Activity") {
                        ScrollView(.horizontal) { AgentGraph(root: graph(w), width: geo.size.width - 56) }
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(LinearGradient(colors: palette.canvas, startPoint: .topLeading, endPoint: .bottomTrailing)))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Chrome.hairline))
                    }
                    section("Agents") {
                        VStack(spacing: 10) {
                            if w.agents.isEmpty { Panel { Text("No agents").foregroundStyle(.secondary) } }
                            ForEach(w.agents) { agentPanel($0) }
                        }
                    }
                    if !w.tasks.isEmpty {
                        section("Background") {
                            Panel {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(w.tasks.sorted { $0.running && !$1.running }) { taskRow($0) }
                                }
                            }
                        }
                    }
                    section("Workspace") {
                        Panel {
                            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                                info("Repository", w.repo.isEmpty ? "–" : w.repo)
                                info("Branch", w.branch ?? "–")
                                info("Created", w.createdAt.map { "\($0.formatted(date: .abbreviated, time: .shortened)) (\(agoPhrase($0)))" } ?? "–")
                                info("Last activity", w.lastActivity.map(agoPhrase) ?? "–")
                                info("Path", w.path)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
        }
        .navigationTitle(w.title)
        .navigationSubtitle(w.branch ?? "")
    }

    func summary(_ w: Workspace) -> some View {
        let subs = w.tasks.filter { !$0.isCommand && $0.running }.count
        let cmds = w.tasks.filter { $0.isCommand && $0.running }.count
        let (label, tint): (String, Color) = switch w.status {
        case .needsYou: ("Needs you", needsColor)
        case .working: ("Working", workingColor)
        case .idle: (w.isStale ? "Stale" : "Idle", .secondary)
        }
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(tint)
            AgeChip(createdAt: w.createdAt)
            SourceBadge(source: w.source)
            Spacer()
            stat(w.agents.count, "agent", brand(w.lead?.kind ?? .claude))
            stat(subs, "subagent", palette.subagent)
            stat(cmds, "command", palette.command)
            Button { w.target.open() } label: { Label("Open in \(w.target.appName)", systemImage: "arrow.up.forward.app") }
                .buttonStyle(.bordered)
                .padding(.leading, 6)
        }
    }

    func stat(_ n: Int, _ noun: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text("\(n)").font(mono(15, .semibold)).foregroundStyle(n > 0 ? tint : .secondary)
            Text(n == 1 ? noun : noun + "s").font(mono(11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).sectionLabel()
            content()
        }
    }

    func agentPanel(_ a: Agent) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(brand(a.kind).opacity(0.16))
                        .overlay(Image(systemName: a.kind == .codex ? "terminal.fill" : "sparkle")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(brand(a.kind)))
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title).font(.headline).lineLimit(1)
                        SourceBadge(source: a.source)
                    }
                    Spacer()
                    StatusPill(status: a.status, label: a.label, since: a.since)
                }
                if let d = a.detail { Text(d).foregroundStyle(needsColor).textSelection(.enabled) }
                if let m = a.lastMessage {
                    Text(markdown(m)).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    func taskRow(_ t: BackgroundTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: t.isCommand ? "chevron.left.forwardslash.chevron.right" : "person.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(t.isCommand ? palette.command : palette.subagent)
                .frame(width: 18)
            Text(t.title)
                .font(t.isCommand ? .system(.callout, design: .monospaced) : .callout)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            StatusPill(status: t.running ? .working : .idle, label: t.running ? "running" : "done", since: t.since)
        }
    }

    func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(mono(12)).textSelection(.enabled)
        }
    }
}
