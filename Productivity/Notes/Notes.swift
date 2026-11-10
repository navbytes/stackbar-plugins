import StackbarKit
import Foundation

/// Notes: a floating note pad on a hotkey, like Raycast Notes.
///
/// ⌃⌥N (or a click on the menu-bar icon) brings up a small window that
/// floats over whatever you are doing, with the note you were last in.
/// Markdown is styled as you type: headings, bold and italic, code, quotes,
/// lists and checklists (⌘Return or a click ticks a task). The first line
/// is the note's title. Everything is saved as you type, even if you close
/// the window mid-sentence.
///
/// One note at a time, like a pad of paper: "All Notes" lists them, pinned
/// first, and "Search Notes" in the palette finds one by any word in it.
/// A deleted note waits in Recently Deleted for 30 days. Any note copies or
/// saves as a Markdown file, or goes to Ask AI with a question.
@main
final class Notes: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.notes",
        name: "Notes",
        version: "1.0.0",
        summary: "A floating Markdown note pad on a hotkey, with checklists, pins and search.",
        surfaces: [.menuBar, .panel, .window],
        triggers: [.launch],
        // Room for a lot of writing; notes never leave this Mac.
        capabilities: [.storage(megabytes: 64)],
        hotkey: "ctrl+option+n",
        hotkeyCommand: "toggle",
        minimumStackbar: "0.38.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Notes",
        accent: .amber,
        symbol: "note.text"
    )

    let theme = Theme.amber
    /// Deleted notes are kept this long, then gone for good.
    static let keepDeleted: TimeInterval = 30 * 24 * 3600
    static let askAIPlugin = "io.navbytes.stackbar.plugins.ask-ai"

    // MARK: Previews

    static let previews: [PreviewScene<Notes>] = [
        PreviewScene("hero", "A note pad that floats over your work", surface: .window) { plugin in
            plugin.load(samples)
            plugin.currentID = samples[0].0.id
        },
        PreviewScene("all-notes", "Every note, pinned ones first", surface: .window) { plugin in
            plugin.load(samples)
            plugin.browsing = true
        },
        PreviewScene("panel", "Your notes from the menu bar") { plugin in
            plugin.load(samples)
        },
    ]

    static let samples: [(Note, String)] = {
        let now = Date()
        func note(_ number: Int, _ minutesAgo: Double, pinned: Bool = false, _ body: String) -> (Note, String) {
            let id = String(format: "5A1B0000-0000-4000-8000-%012d", number)
            let date = now.addingTimeInterval(-minutesAgo * 60)
            return (Note(id: id, created: date, modified: date, pinned: pinned), body)
        }
        return [
            note(1, 2, pinned: true, "# Launch checklist\n\n- [x] Notarize the build\n- [x] Update the changelog\n- [ ] Post on the forum\n- [ ] Email beta testers\n\n> Ship on **Thursday**, after the `0.38` tag."),
            note(2, 45, pinned: true, "Standup\n\n- Finished the editor node\n- Today: Notes plugin\n- Blocked on nothing"),
            note(3, 180, "Book ideas\n\n1. *The Overstory*\n2. *Piranesi*\n3. Something by Ursula K. Le Guin"),
            note(4, 1500, "Groceries\n- [ ] coffee beans\n- [ ] oat milk\n- [x] lemons"),
        ]
    }()

    // MARK: State

    /// A note's facts; its text is stored under its own key, so typing in
    /// one note saves only that note.
    struct Note: Codable, Equatable, Identifiable {
        var id: String
        var created: Date
        var modified: Date
        var pinned = false
        /// When it went to Recently Deleted.
        var deleted: Date?
    }

    /// Every note, read once and written back when it changes.
    private var cachedNotes: [Note]?
    var notes: [Note] {
        get {
            if let cachedNotes { return cachedNotes }
            let loaded = Stackbar.storage.value("notes", as: [Note].self) ?? []
            cachedNotes = loaded
            return loaded
        }
        set {
            cachedNotes = newValue
            Stackbar.storage.set("notes", newValue)
        }
    }

    func body(_ id: String) -> String {
        Stackbar.storage.value("body." + id, as: String.self) ?? ""
    }

    func setBody(_ id: String, _ text: String) {
        Stackbar.storage.set("body." + id, text.isEmpty ? nil : text)
    }

    /// The note on the pad.
    @Stored("current") var currentID: String? = nil
    /// The window shows the list of notes instead of a note.
    var browsing = false
    /// Notes visited, for Back and Forward.
    var history: [String] = []
    var future: [String] = []
    var showDeleted = false

    func load(_ samples: [(Note, String)]) {
        notes = samples.map(\.0)
        for (note, text) in samples { setBody(note.id, text) }
    }

    func refresh() async throws {
        purgeDeleted()
    }

    // MARK: Reading notes

    var live: [Note] { notes.filter { $0.deleted == nil } }
    var deleted: [Note] { notes.filter { $0.deleted != nil }.sorted { ($0.deleted ?? .distantPast) > ($1.deleted ?? .distantPast) } }

    /// Pinned first, then the most recently changed. Empty notes other than
    /// the one on the pad are left out.
    var ordered: [Note] {
        live.filter { $0.id == currentID || !body($0.id).isEmpty }
            .sorted { ($0.pinned ? 1 : 0, $0.modified) > ($1.pinned ? 1 : 0, $1.modified) }
    }

    var current: Note? {
        guard let currentID else { return nil }
        return live.first { $0.id == currentID }
    }

    /// A line's words without its Markdown: list and task markers, `#`,
    /// `>`, `**` and backticks.
    static func plain(_ line: Substring) -> String {
        var words = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- [ ] ", "- [x] ", "- [X] ", "> ", "- ", "* ", "+ "] where words.hasPrefix(prefix) {
            words.removeFirst(prefix.count)
            break
        }
        words = String(words.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        return words.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(plain).filter { !$0.isEmpty }
    }

    static func clip(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length - 1)) + "…" : text
    }

    /// The first line with words in it, without its Markdown.
    static func title(of text: String) -> String {
        lines(text).first.map { clip($0, 60) } ?? "Untitled"
    }

    /// The words after the title, for a row's subtitle.
    static func excerpt(of text: String) -> String? {
        lines(text).dropFirst().first.map { clip($0, 80) }
    }

    /// Ticked and open tasks in a note.
    static func tasks(in text: String) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [ ] ") || trimmed == "- [ ]" { total += 1 }
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") { total += 1; done += 1 }
        }
        return (done, total)
    }

    static func matches(_ text: String, _ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        let haystack = text.lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400)) d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: Changing notes

    /// Saves what the editor sent. The note's date moves only when its
    /// words changed.
    func save(_ id: String, _ text: String) {
        guard body(id) != text else { return }
        setBody(id, text)
        var all = notes
        if let index = all.firstIndex(where: { $0.id == id }) {
            all[index].modified = Date()
        } else {
            all.append(Note(id: id, created: Date(), modified: Date()))
        }
        notes = all
    }

    /// Puts a note on the pad, remembering the one before for Back.
    func open(_ id: String, remember: Bool = true) {
        if remember, let currentID, currentID != id {
            history.append(currentID)
            if history.count > 50 { history.removeFirst() }
            future = []
        }
        dropIfEmpty(currentID, unless: id)
        currentID = id
        browsing = false
    }

    /// A fresh, empty note on the pad. It is kept once something is typed.
    @discardableResult
    func newNote() -> String {
        if let current, body(current.id).isEmpty {
            browsing = false
            return current.id
        }
        let id = UUID().uuidString
        var all = notes
        all.append(Note(id: id, created: Date(), modified: Date()))
        notes = all
        open(id)
        return id
    }

    /// An empty note left behind is dropped, so the list holds only notes
    /// with something in them.
    func dropIfEmpty(_ id: String?, unless keep: String? = nil) {
        guard let id, id != keep, body(id).isEmpty else { return }
        notes = notes.filter { $0.id != id }
    }

    /// The pad always has a note on it.
    func ensureCurrent() {
        if current == nil {
            if let first = ordered.first { currentID = first.id } else { newNote() }
        }
    }

    func togglePin(_ id: String) {
        var all = notes
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].pinned.toggle()
        notes = all
    }

    func delete(_ id: String) {
        var all = notes
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        if body(id).isEmpty {
            all.remove(at: index)
        } else {
            all[index].deleted = Date()
            all[index].pinned = false
        }
        notes = all
        history.removeAll { $0 == id }
        future.removeAll { $0 == id }
        if currentID == id {
            currentID = ordered.first?.id
            ensureCurrent()
        }
        Stackbar.hud("Moved to Recently Deleted")
    }

    func restore(_ id: String) {
        var all = notes
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].deleted = nil
        notes = all
        open(id)
    }

    func erase(_ ids: [String]) {
        for id in ids { setBody(id, "") }
        notes = notes.filter { !ids.contains($0.id) }
    }

    func purgeDeleted(now: Date = Date()) {
        let old = notes.filter { $0.deleted.map { now.timeIntervalSince($0) > Self.keepDeleted } ?? false }.map(\.id)
        if !old.isEmpty { erase(old) }
    }

    func back() {
        guard let previous = history.popLast() else { return }
        if let currentID { future.append(currentID) }
        dropIfEmpty(currentID, unless: previous)
        currentID = previous
        browsing = false
    }

    func forward() {
        guard let next = future.popLast() else { return }
        if let currentID { history.append(currentID) }
        currentID = next
        browsing = false
    }

    func saveAsFile(_ id: String) async throws {
        let text = body(id)
        let name = Self.title(of: text).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if try await Stackbar.saveFile(name + ".md", data: Data(text.utf8)) != nil { Stackbar.hud("Saved") }
    }

    func askAI(_ id: String) {
        let text = body(id)
        let prompt = "About this note:\n\n" + String(text.prefix(6000)) + "\n\n"
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
        Stackbar.open("stackbar://commands/\(Self.askAIPlugin)/ask" + (query.percentEncodedQuery.map { "?" + $0 } ?? ""))
    }

    /// Opens the note on the pad, in the window.
    func show(_ id: String) async throws {
        open(id)
        try await Stackbar.showWindow(keepOnTop: true)
    }

    // MARK: Commands

    var commands: [Command] {
        Command("toggle", title: "Notes", subtitle: "Show or hide the note pad", symbol: "note.text", keywords: ["notes", "floating", "pad", "scratch"]) { _ in
            self.ensureCurrent()
            try await Stackbar.toggleWindow(keepOnTop: true)
            return .done
        }
        Command("new", title: "Create Note", symbol: "square.and.pencil", keywords: ["note", "new", "write"]) { _ in
            self.newNote()
            try await Stackbar.showWindow(keepOnTop: true)
            return .done
        }
        Command("search", title: "Search Notes", subtitle: "Find a note by any word in it", symbol: "magnifyingglass", keywords: ["note", "find"])
            .alias("notes")
            .view { invocation in self.searchView(invocation.text) }
    }

    @ViewBuilder func searchView(_ query: String) -> ViewContent {
        let found = ordered.filter { query.isEmpty || Self.matches(body($0.id), query) }
        if live.isEmpty {
            EmptyState("No notes yet", symbol: "note.text", message: "Write something down; it is saved as you type.", theme: theme) {
                ActionButton("Create Note", symbol: "square.and.pencil", theme: theme, prominent: true) {
                    self.newNote()
                    try await Stackbar.showWindow(keepOnTop: true)
                }
            }
        } else if found.isEmpty {
            EmptyState("No note has “\(query)”", symbol: "magnifyingglass", theme: theme)
        } else {
            List {
                ForEach(found) { note in self.row(note) }
            }
        }
    }

    func row(_ note: Note) -> Row {
        let text = body(note.id)
        let tasks = Self.tasks(in: text)
        var row = Row(Self.title(of: text), subtitle: [Self.relative(note.modified), Self.excerpt(of: text)].compactMap { $0 }.joined(separator: " · "),
                      symbol: note.pinned ? "pin.fill" : "note.text", key: note.id)
        if tasks.total > 0 { row = row.badge("\(tasks.done)/\(tasks.total)", role: tasks.done == tasks.total ? .success : .secondary) }
        return row
            .preview(text: text, caption: "Edited \(Self.relative(note.modified))")
            .action("Open") { try await self.show(note.id) }
            .action(note.pinned ? "Unpin" : "Pin", shortcut: "cmd+shift+p") { self.togglePin(note.id) }
            .action("Copy as Markdown", shortcut: "cmd+c") { Stackbar.copy(text) }
            .action("Save as Markdown File…", shortcut: "cmd+s") { try await self.saveAsFile(note.id) }
            .action("Ask AI About This Note") { self.askAI(note.id) }
            .action("Delete", shortcut: "ctrl+x", role: .critical, confirm: .none) { self.delete(note.id) }
    }

    // MARK: Surfaces

    var menuBar: ViewContent {
        Image(systemName: "note.text")
    }

    var menuBarClick: MenuBarAction? {
        MenuBarAction("Show or hide Notes") {
            self.ensureCurrent()
            try await Stackbar.toggleWindow(keepOnTop: true)
        }
    }

    var panel: ViewContent {
        PanelHeader(live.isEmpty ? "Notes" : live.count == 1 ? "1 note" : "\(live.count) notes", subtitle: "⌃⌥N shows the note pad", symbol: "note.text", theme: theme) {
            IconButton("square.and.pencil", label: "New Note", theme: theme, prominence: .tinted) {
                self.newNote()
                try await Stackbar.showWindow(keepOnTop: true)
            }
        }
        searchView("")
    }

    var window: ViewContent {
        toolbar
        if browsing {
            browser
        } else if let current {
            TextEditor(text: body(current.id), document: current.id, placeholder: "Start writing…", markdown: true, focus: true, key: "body") { text in
                self.save(current.id, text)
            }
        } else {
            EmptyState("No note open", symbol: "note.text", theme: theme) {
                ActionButton("Create Note", symbol: "square.and.pencil", theme: theme, prominent: true) { self.newNote() }
            }
        }
    }

    @ViewBuilder var toolbar: ViewContent {
        HStack(alignment: .center, spacing: Space.xs) {
            IconButton("chevron.left", label: "Back", size: 24, key: "back") { self.back() }
                .opacity(history.isEmpty ? 0.35 : 1)
            IconButton("chevron.right", label: "Forward", size: 24, key: "forward") { self.forward() }
                .opacity(future.isEmpty ? 0.35 : 1)
            if browsing {
                Text("All Notes").typography(.headline)
            } else if let current {
                Text(Self.title(of: body(current.id))).role(.secondary).typography(.headline)
            }
            Spacer()
            if !browsing, let current {
                IconButton(current.pinned ? "pin.fill" : "pin", label: current.pinned ? "Unpin Note" : "Pin Note", theme: current.pinned ? theme : .neutral, size: 24, key: "pin") {
                    self.togglePin(current.id)
                }
                IconButton("trash", label: "Delete Note", size: 24, key: "delete") { self.delete(current.id) }
            }
            IconButton(browsing ? "note.text" : "list.bullet", label: browsing ? "Back to the Note" : "All Notes", theme: browsing ? theme : .neutral, size: 24, key: "browse") {
                self.browsing.toggle()
                if !self.browsing { self.ensureCurrent() }
            }
            IconButton("square.and.pencil", label: "New Note", theme: theme, prominence: .tinted, size: 24, key: "new") { self.newNote() }
        }
    }

    @ViewBuilder var browser: ViewContent {
        searchView("")
        if !deleted.isEmpty {
            if showDeleted {
                Section("Recently Deleted") {
                    ForEach(deleted) { note in
                        let text = self.body(note.id)
                        Row(Self.title(of: text), subtitle: "Deleted \(Self.relative(note.deleted ?? Date()))", symbol: "trash", key: "deleted-" + note.id)
                            .action("Restore") { self.restore(note.id) }
                            .action("Delete Permanently", role: .critical, confirm: "delete it for good") { self.erase([note.id]) }
                    }
                }
                Button("Empty Recently Deleted", symbol: "trash.slash", role: .critical, confirm: "delete \(deleted.count == 1 ? "1 note" : "\(deleted.count) notes") for good") {
                    self.erase(self.deleted.map(\.id))
                    self.showDeleted = false
                }
            } else {
                Button("Recently Deleted (\(deleted.count))", symbol: "trash") { self.showDeleted = true }
            }
        }
    }
}
