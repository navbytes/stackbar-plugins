import StackbarKit
import Foundation

/// The folders and workspaces you opened lately in VS Code, Cursor,
/// Windsurf, VSCodium and Zed, in the palette: type a few letters of the
/// project and Return opens it in the editor you last used it in, or in the
/// default editor picked in Settings (Xcode, Sublime Text, a JetBrains IDE…).
///
/// Each editor keeps its recent list in a small database of its own;
/// Stackbar reads it with `sqlite3` in read-only mode, so the editor's own
/// files are never changed.
@main
final class RecentProjects: StackbarPlugin {
    struct Editor: Equatable, Sendable {
        /// Where the editor keeps its recent list.
        enum Store: Equatable, Sendable {
            /// The VS Code family: `state.vscdb`, key
            /// `history.recentlyOpenedPathsList`.
            case vscode
            /// Zed: `db.sqlite`, table `workspaces`, column `paths`.
            case zed
        }

        var name: String
        var bundleID: String
        /// The folders that hold the recent list, read in order. VS Code
        /// 1.118 moved it from Application Support to
        /// `~/<dataFolderName>-shared/sharedStorage`, so the VS Code family
        /// has both: forks pick up the move when they rebase on 1.118.
        var folders: [String]
        /// The editor's own link (`vscode://file/…`); nil opens the folder
        /// with the app, as Finder's Open With does.
        var scheme: String?
        var store: Store

        init(name: String, bundleID: String, folders: [String], scheme: String?, store: Store = .vscode) {
            self.name = name
            self.bundleID = bundleID
            self.folders = folders
            self.scheme = scheme
            self.store = store
        }

        /// A VS Code fork: its shared folder (`~/.cursor-shared`), then its
        /// Application Support one.
        static func vscode(_ name: String, _ bundleID: String, dataFolder: String, support: String, scheme: String) -> Editor {
            Editor(name: name, bundleID: bundleID, folders: ["~/\(dataFolder)-shared/sharedStorage", "~/Library/Application Support/\(support)/User/globalStorage"], scheme: scheme)
        }
    }

    static let editors: [Editor] = [
        .vscode("VS Code", "com.microsoft.VSCode", dataFolder: ".vscode", support: "Code", scheme: "vscode"),
        .vscode("Cursor", "com.todesktop.230313mzl4w4u92", dataFolder: ".cursor", support: "Cursor", scheme: "cursor"),
        .vscode("Windsurf", "com.exafunction.windsurf", dataFolder: ".windsurf", support: "Windsurf", scheme: "windsurf"),
        .vscode("VSCodium", "com.vscodium", dataFolder: ".vscode-oss", support: "VSCodium", scheme: "vscodium"),
        .vscode("VS Code Insiders", "com.microsoft.VSCodeInsiders", dataFolder: ".vscode-insiders", support: "Code - Insiders", scheme: "vscode-insiders"),
        Editor(name: "Zed", bundleID: "dev.zed.Zed", folders: ["~/Library/Application Support/Zed/db/0-stable"], scheme: nil, store: .zed),
        Editor(name: "Zed Preview", bundleID: "dev.zed.Zed-Preview", folders: ["~/Library/Application Support/Zed/db/0-preview"], scheme: nil, store: .zed),
    ]

    /// An app a project can open in. The VS Code family opens through its
    /// own link (`vscode://file/…`), which reuses a window already showing
    /// the folder; the rest are handed the folder like Finder's Open With.
    struct App: Equatable, Sendable {
        var name: String
        var bundleID: String
        var scheme: String?
        /// Whether it opens `.code-workspace` files: the VS Code family only.
        var opensWorkspaces: Bool { scheme != nil }
    }

    /// The editors Settings offers as the default, when installed.
    static let apps: [App] = editors.map { App(name: $0.name, bundleID: $0.bundleID, scheme: $0.scheme) } + [
        App(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        App(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        App(name: "Nova", bundleID: "com.panic.Nova"),
        App(name: "BBEdit", bundleID: "com.barebones.bbedit"),
        App(name: "TextMate", bundleID: "com.macromates.TextMate"),
        App(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij"),
        App(name: "IntelliJ IDEA CE", bundleID: "com.jetbrains.intellij.ce"),
        App(name: "WebStorm", bundleID: "com.jetbrains.WebStorm"),
        App(name: "PyCharm", bundleID: "com.jetbrains.pycharm"),
        App(name: "PyCharm CE", bundleID: "com.jetbrains.pycharm.ce"),
        App(name: "GoLand", bundleID: "com.jetbrains.goland"),
        App(name: "RustRover", bundleID: "com.jetbrains.rustrover"),
        App(name: "Android Studio", bundleID: "com.google.android.studio"),
    ]

    /// The default editor setting's first choice: each project opens where
    /// it came from.
    static let lastUsed = "Where it was last opened"

    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.recent-projects",
        name: "Recent Projects",
        version: "1.6.0",
        summary: "Open the projects you used lately in VS Code, Cursor, Windsurf, VSCodium or Zed from the palette.",
        surfaces: [.panel, .settings],
        triggers: [.launch, .minutes(5), .wake],
        capabilities: [
            .run(commands: ["sqlite3"]),
            .files(paths: editors.flatMap(\.folders)),
            // "*": folders open in any default editor, not only by link.
            .openURLs(schemes: ["*"]),
            // Which editors are installed, for the default editor setting.
            .apps,
        ],
        minimumStackbar: "0.37.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Developer/RecentProjects",
        accent: .blue,
        symbol: "folder.badge.gearshape"
    )

    static let previews: [PreviewScene<RecentProjects>] = [
        PreviewScene("hero", "Your projects, a few letters away") { plugin in
            plugin.projects = [
                Project(path: "/Users/you/code/stackbar", kind: .folder, editor: "VS Code"),
                Project(path: "/Users/you/code/stackbar-plugins", kind: .folder, editor: "Cursor"),
                Project(path: "/Users/you/code/site/site.code-workspace", kind: .workspace, editor: "VS Code"),
                Project(path: "/Users/you/code/notes", kind: .folder, editor: "Windsurf"),
            ]
            plugin.found = ["VS Code", "Cursor", "Windsurf"]
            plugin.loadedAt = Date()
        },
        PreviewScene("editors", "Open projects in the editor you prefer", surface: .settings) { plugin in
            plugin.installed = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode"]
            plugin.defaultEditor = "dev.zed.Zed"
            plugin.loadedAt = Date()
        },
    ]

    let theme = Theme.blue

    struct Project: Equatable, Identifiable {
        enum Kind: Equatable { case folder, workspace }
        var path: String
        var kind: Kind
        var editor: String
        var id: String { "\(editor)|\(path)" }
        var name: String {
            let last = (path as NSString).lastPathComponent
            return kind == .workspace ? (last as NSString).deletingPathExtension : last
        }
        /// The path with the home folder as ~.
        var shortPath: String {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "Users" else { return path }
            return "~/" + parts.dropFirst(2).joined(separator: "/")
        }
        /// What Show in Finder opens: a folder itself, or a workspace's folder.
        var folder: String { kind == .workspace ? (path as NSString).deletingLastPathComponent : path }
    }

    var projects: [Project] = []
    var loadedAt: Date?
    var found: [String] = []
    var results: [Project] = []
    @Stored("opens") var opens: [String: Int] = [:]
    @Stored("perEditor") var perEditor = 30
    /// The default editor's bundle id; empty opens each project where it
    /// was last opened.
    @Stored("defaultEditor") var defaultEditor = ""
    /// The bundle ids of the `apps` installed on this Mac.
    var installed: Set<String> = []
    /// Editors whose list couldn't be read, and why: a locked database, say.
    var problems: [String] = []
    /// Remote projects (SSH, containers, WSL) the editors listed, which
    /// open only through the editor, so they are left out.
    var remoteSkipped = 0

    // MARK: Reading

    func load(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        var all: [Project] = []
        var seen: [String] = []
        var failures: [String] = []
        var remote = 0
        for editor in Self.editors {
            var list: [Project] = []
            var read = false
            var failure: String?
            for folder in editor.folders {
                let result: RunResult
                do {
                    switch editor.store {
                    case .vscode:
                        result = try await Stackbar.run("sqlite3", ["-readonly", "state.vscdb", "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'"], workingDirectory: folder, timeout: .seconds(10))
                    case .zed:
                        result = try await Self.readZed(in: folder)
                    }
                } catch {
                    // An editor that isn't installed has no folder: the run is
                    // refused and it is skipped. Any other refusal is a failed read.
                    if !"\(error)".contains("is not a folder") { failure = failure ?? "\(editor.name): \(error)" }
                    continue
                }
                guard result.succeeded else {
                    failure = failure ?? "\(editor.name): " + (result.errorText.split(separator: "\n").first.map(String.init) ?? "sqlite3 failed (\(result.status))")
                    continue
                }
                read = true
                switch editor.store {
                case .vscode:
                    list += Self.parse(result.text, editor: editor.name)
                    remote += Self.remoteCount(result.text)
                case .zed:
                    list += Self.parseZed(result.text, editor: editor.name)
                }
            }
            // A folder that couldn't be read counts only when no other one
            // of this editor's could: VS Code before 1.118 has no shared one.
            if !read, let failure { failures.append(failure) }
            var mine = Set<String>()
            list = list.filter { mine.insert($0.path).inserted }
            if !list.isEmpty { seen.append(editor.name) }
            all += list.prefix(perEditor)
        }
        // One row a path: the editor listed first (VS Code, then Cursor…)
        // keeps it.
        var paths = Set<String>()
        projects = all.filter { paths.insert($0.path).inserted }
        found = seen
        problems = failures
        remoteSkipped = remote
        if let list = try? await Stackbar.installedApps() {
            let ids = Set(list.map(\.id))
            installed = Set(Self.apps.map(\.bundleID).filter(ids.contains))
        }
        // Counts for projects that have left every list are dropped. Not
        // after a failed read, which would lose the counts of its projects.
        if problems.isEmpty {
            let kept = opens.filter { paths.contains($0.key) }
            if kept.count != opens.count { opens = kept }
        }
        loadedAt = Date()
    }

    func refresh() async throws {
        await load(force: true)
    }

    /// The JSON VS Code keeps under `history.recentlyOpenedPathsList`:
    /// `{"entries": [{"folderUri": "file:///…"}, {"workspace": {"configPath": "file:///…"}}, {"fileUri": …}]}`.
    /// Folders and workspaces on this Mac only; files and remote ones are
    /// left out.
    static func parse(_ text: String, editor: String) -> [Project] {
        struct List: Decodable {
            struct Entry: Decodable {
                struct Workspace: Decodable { var configPath: String? }
                var folderUri: String?
                var workspace: Workspace?
            }
            var entries: [Entry]
        }
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        return list.entries.compactMap { entry in
            if let uri = entry.folderUri, let path = localPath(uri) { return Project(path: path, kind: .folder, editor: editor) }
            if let uri = entry.workspace?.configPath, let path = localPath(uri) { return Project(path: path, kind: .workspace, editor: editor) }
            return nil
        }
    }

    /// Zed's recent workspaces, newest first, local ones only. Zed renamed
    /// `ssh_connection_id` to `remote_connection_id` in 2025, so a database
    /// either one wrote is read; a Zed that hasn't run yet has no file,
    /// which reads as an empty list.
    static func readZed(in folder: String) async throws -> RunResult {
        func query(_ remote: String) -> String {
            "SELECT paths FROM workspaces WHERE paths IS NOT NULL AND paths != '' AND \(remote) IS NULL ORDER BY timestamp DESC LIMIT 200"
        }
        var result = try await Stackbar.run("sqlite3", ["-readonly", "-json", "db.sqlite", query("remote_connection_id")], workingDirectory: folder, timeout: .seconds(10))
        if !result.succeeded, result.errorText.contains("no such column") {
            result = try await Stackbar.run("sqlite3", ["-readonly", "-json", "db.sqlite", query("ssh_connection_id")], workingDirectory: folder, timeout: .seconds(10))
        }
        return result
    }

    /// `sqlite3 -json` rows of Zed's `paths` column: one workspace each,
    /// its folders one a line. A workspace of several folders is listed by
    /// its first; files and relative paths are left out.
    static func parseZed(_ text: String, editor: String) -> [Project] {
        struct Row: Decodable { var paths: String? }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // No rows prints nothing at all, not "[]".
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return rows.compactMap { row in
            guard let first = row.paths?.split(separator: "\n").first.map(String.init),
                  first.hasPrefix("/") else { return nil }
            return Project(path: first, kind: .folder, editor: editor)
        }
    }

    /// How many folders and workspaces in that JSON are remote
    /// (`vscode-remote://ssh-remote+…`).
    static func remoteCount(_ text: String) -> Int {
        text.components(separatedBy: "\"vscode-remote://").count - 1
    }

    static func localPath(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.scheme == "file" else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    // MARK: Matching

    func matches(_ query: String) -> [Project] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let used = { (project: Project) in self.opens[project.path] ?? 0 }
        guard !words.isEmpty else { return projects }
        return projects.compactMap { project -> (Project, Int)? in
            let name = project.name.lowercased()
            let path = project.shortPath.lowercased()
            var score = 0
            for word in words {
                if name.hasPrefix(word) { score += 300 } else if name.contains(word) { score += 200 } else if path.contains(word) { score += 50 } else { return nil }
            }
            return (project, score + min(200, used(project) * 20))
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    // MARK: Opening

    static func app(named name: String) -> App? { apps.first { $0.name == name } }

    /// The editor Return opens a project in: the default one when it can
    /// open it, else the one whose list it came from.
    func primary(for project: Project) -> App? {
        if let chosen = Self.apps.first(where: { $0.bundleID == defaultEditor }),
           project.kind == .folder || chosen.opensWorkspaces {
            return chosen
        }
        return Self.app(named: project.editor)
    }

    /// The other editors ⌘K offers: the ones with a recent list, and the
    /// default editor.
    func others(for project: Project) -> [App] {
        let primary = primary(for: project)
        var names = found
        if let chosen = Self.apps.first(where: { $0.bundleID == defaultEditor }), !names.contains(chosen.name) { names.append(chosen.name) }
        return names.compactMap(Self.app(named:)).filter { app in
            app != primary && (project.kind == .folder || app.opensWorkspaces)
        }
    }

    func open(_ project: Project, in app: App) async {
        opens[project.path, default: 0] += 1
        if let scheme = app.scheme {
            let encoded = project.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project.path
            Stackbar.open("\(scheme)://file\(encoded)")
            return
        }
        do {
            try await Stackbar.open(project.path, with: app.bundleID)
        } catch {
            Stackbar.hud("Couldn't open \(project.name) in \(app.name)", isError: true)
        }
    }

    func row(_ project: Project) -> Row {
        let primary = primary(for: project)
        var row = Row(project.name, subtitle: project.shortPath, symbol: project.kind == .workspace ? "square.stack.3d.up" : "folder", key: project.id)
            .appIcon(primary?.bundleID)
        if let primary {
            row = row.action("Open in \(primary.name)") { await self.open(project, in: primary) }
        }
        for other in others(for: project) {
            row = row.action("Open in \(other.name)") { await self.open(project, in: other) }
        }
        return row
            .action("Show in Finder", shortcut: "cmd+shift+f") { try await Stackbar.open(project.folder, with: "com.apple.finder") }
            .action("Copy Path", shortcut: "cmd+shift+c") { Stackbar.copy(project.path) }
            .badge(project.editor, role: .secondary)
    }

    // MARK: Settings

    /// The editors to pick from: the installed ones, and the current choice
    /// even when it isn't found.
    var choices: [App] {
        Self.apps.filter { installed.contains($0.bundleID) || $0.bundleID == defaultEditor }
    }

    var settings: ViewContent {
        Section("Opening") {
            Picker("Open projects in", options: [Self.lastUsed] + choices.map(\.name), selection: Self.apps.first { $0.bundleID == defaultEditor }?.name ?? Self.lastUsed) { choice in
                self.defaultEditor = Self.app(named: choice)?.bundleID ?? ""
            }
            Text("Return opens a project in this editor and ⌘K offers the others. Workspace files (.code-workspace) open in VS Code, Cursor, Windsurf or VSCodium, since other editors can't read them.").style(.caption)
            if choices.isEmpty {
                Text("No editor found on this Mac yet. VS Code, Cursor, Windsurf, VSCodium, Zed, Xcode, Sublime Text, Nova, BBEdit, TextMate, JetBrains IDEs and Android Studio show up here once installed.").style(.caption).role(.secondary)
            }
        }
    }

    // MARK: Commands

    var commands: [Command] {
        Command("search", title: "Search Recent Projects", subtitle: "Open a folder or workspace in your editor", symbol: "folder.badge.gearshape", keywords: ["project", "vscode", "code", "cursor", "windsurf", "recent", "open"])
            .view(search: { invocation in
                // Typing answers from the list read at launch, and again on the
                // timer or at wake, rather than reading every editor's list per keystroke.
                if self.loadedAt == nil { await self.load(force: true) }
                self.results = self.matches(invocation.text)
            }) { _ in
                if self.projects.isEmpty {
                    ContentUnavailableView("No recent projects", symbol: "folder", message: "Open a folder in VS Code, Cursor, Windsurf, VSCodium or Zed and it shows up here.")
                } else if self.results.isEmpty {
                    ContentUnavailableView("No project matches", symbol: "magnifyingglass", message: "Type part of a project's name or path.")
                } else {
                    List {
                        ForEach(self.results) { project in self.row(project) }
                    }
                }
            }
            .rootSearch(section: "Recent Projects")
            .alias("proj")
    }

    // MARK: Panel

    var panel: ViewContent {
        PanelHeader("Recent Projects", subtitle: found.isEmpty ? "No editor found yet" : found.joined(separator: " · "), symbol: "folder.badge.gearshape", theme: theme)
        if let first = problems.first { Banner("Couldn't read " + first, theme: .warning) }
        if projects.isEmpty {
            EmptyState("Open a project in your editor", symbol: "folder", message: "Folders and workspaces you open in VS Code, Cursor, Windsurf, VSCodium or Zed show up here and in the palette.", theme: theme)
        } else {
            List(projects, searchable: projects.count > 8) { project in self.row(project) }
        }
        if remoteSkipped > 0 {
            Text("\(remoteSkipped) remote \(remoteSkipped == 1 ? "project" : "projects") (SSH, containers) left out: open \(remoteSkipped == 1 ? "it" : "them") from your editor.").style(.caption).role(.secondary)
        }
    }
}
