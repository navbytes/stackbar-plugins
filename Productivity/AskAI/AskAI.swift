import StackbarKit
import Foundation

/// Ask an AI model from the palette, with your own key: type a question and
/// press Tab (Stackbar 0.36 and later), or Return on Ask AI under the
/// results. Follow-up questions keep the conversation. Commands on the selected text
/// summarize or explain it, or fix, improve or shorten it in place.
///
/// Anthropic's Claude is the default provider; OpenAI, OpenRouter, Ollama
/// (local, no key) and your own LiteLLM proxy are one setting away. LiteLLM
/// shares LITELLM_PROXY_URL and LITELLM_API_KEY with the LiteLLM plugin, and
/// its models come from the proxy's /v1/models. Keys stay in the Keychain and are
/// asked for only for the provider in use. Answers arrive whole, not word by
/// word.
@main
final class AskAI: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.ask-ai",
        name: "Ask AI",
        version: "1.2.0",
        summary: "Ask Claude, ChatGPT, a local model or your LiteLLM proxy from the palette, and fix or summarize selected text, with your own key.",
        surfaces: [.panel, .settings],
        triggers: [.launch],
        // The selection for the text commands; the clipboard to paste their
        // result over it; one host per provider (localhost is Ollama); one
        // key per provider; the LiteLLM proxy is the one host the user enters.
        capabilities: [.context, .clipboard,
                       .network("api.anthropic.com", "api.openai.com", "openrouter.ai", "localhost"),
                       .secret(name: "ANTHROPIC_API_KEY"), .secret(name: "OPENAI_API_KEY"), .secret(name: "OPENROUTER_API_KEY"),
                       .userServer(secret: "LITELLM_PROXY_URL"), .secret(name: "LITELLM_API_KEY")],
        minimumStackbar: "0.26.0",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/AskAI",
        accent: .violet,
        symbol: "sparkles"
    )

    // MARK: Previews

    static let previews: [PreviewScene<AskAI>] = [
        PreviewScene("hero", "Ask from the palette, follow up, copy the answer") { plugin in
            plugin.exchanges = [
                Exchange(question: "How do I undo the last git commit but keep the changes?",
                         answer: "git reset --soft HEAD~1\n\nThe commit is gone and its changes stay staged. Use --mixed instead to keep them unstaged.",
                         by: "Claude Opus 5.5"),
            ]
        },
    ]

    let theme = Theme.violet

    // MARK: Providers

    enum Provider: String, CaseIterable {
        case anthropic = "Anthropic", openai = "OpenAI", openrouter = "OpenRouter", ollama = "Ollama", litellm = "LiteLLM"

        var defaultModel: String {
            switch self {
            case .anthropic: return "claude-opus-5-5"
            case .openai: return "gpt-5-mini"
            case .openrouter: return "openrouter/auto"
            case .ollama: return "llama3.2"
            // The proxy's own model names; the first it lists until one is picked.
            case .litellm: return ""
            }
        }

        /// The Keychain secret, or nil for a local model.
        var secret: String? {
            switch self {
            case .anthropic: return "ANTHROPIC_API_KEY"
            case .openai: return "OPENAI_API_KEY"
            case .openrouter: return "OPENROUTER_API_KEY"
            case .litellm: return "LITELLM_API_KEY"
            case .ollama: return nil
            }
        }

        /// Where the question goes. LiteLLM's is under the proxy's URL.
        func chatURL(base: String? = nil) -> String {
            switch self {
            case .anthropic: return "https://api.anthropic.com/v1/messages"
            case .openai: return "https://api.openai.com/v1/chat/completions"
            case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
            case .ollama: return "http://localhost:11434/v1/chat/completions"
            case .litellm: return AskAI.apiRoot(base ?? "") + "/chat/completions"
            }
        }

        var keyPage: String? {
            switch self {
            case .anthropic: return "https://platform.claude.com/settings/keys"
            case .openai: return "https://platform.openai.com/api-keys"
            case .openrouter: return "https://openrouter.ai/settings/keys"
            case .ollama, .litellm: return nil
            }
        }
    }

    @Stored("provider") var storedProvider = Provider.anthropic.rawValue
    /// A model per provider, when changed from its default.
    @Stored("models") var models: [String: String] = [:]

    /// The models the LiteLLM proxy offers, from its /v1/models.
    @Stored("litellmModels") var litellmModels: [String] = []
    @Stored("litellmModelsFetched") var litellmModelsFetched: Date? = nil
    /// Why the proxy's models couldn't be listed, for Settings.
    var litellmProblem: String?

    var provider: Provider { Provider(rawValue: storedProvider) ?? .anthropic }
    var model: String {
        let chosen = models[provider.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        if chosen.isEmpty, provider == .litellm { return litellmModels.first ?? "" }
        return chosen.isEmpty ? provider.defaultModel : chosen
    }

    // MARK: LiteLLM

    /// The proxy's OpenAI-style API root: its URL with `/v1`, whether or not
    /// the user typed it, and no trailing slash.
    nonisolated static func apiRoot(_ base: String) -> String {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        return root.hasSuffix("/v1") ? root : root + "/v1"
    }

    /// The model names in a /v1/models reply, sorted.
    nonisolated static func modelIDs(status: Int, body: Data) throws -> [String] {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? (json?["error"] as? String)
            switch status {
            case 401, 403: throw HostError("The proxy refused the key (\(status)). Check LITELLM_API_KEY in Stackbar's Settings")
            case 404: throw HostError("The proxy has no /v1/models. Is LITELLM_PROXY_URL the proxy's base URL?")
            default: throw HostError("The proxy answered \(status)" + (message.map { ": \($0)" } ?? ""))
            }
        }
        let ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The proxy's URL and key, or why LiteLLM can't be asked yet.
    func litellmConnection() async throws -> (base: String, key: String) {
        guard let base = try await Stackbar.secret("LITELLM_PROXY_URL")?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty else {
            throw HostError("Enter your LiteLLM proxy's URL as LITELLM_PROXY_URL in Stackbar's Settings")
        }
        guard let key = try await Stackbar.secret("LITELLM_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw HostError("Add a LiteLLM key (LITELLM_API_KEY) in Stackbar's Settings")
        }
        return (base, key)
    }

    /// Lists the proxy's models for the Settings picker.
    func loadLiteLLMModels() async {
        do {
            let (base, key) = try await litellmConnection()
            let response = try await Stackbar.http(HTTPRequest(url: Self.apiRoot(base) + "/models",
                                                               headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"], timeout: 15))
            litellmModels = try Self.modelIDs(status: response.status, body: response.body)
            litellmModelsFetched = Date()
            litellmProblem = litellmModels.isEmpty ? "The proxy lists no models for this key" : nil
        } catch {
            litellmProblem = "\(error)"
        }
    }

    /// At launch, the proxy's models when LiteLLM is in use and the list is
    /// over a day old.
    func refresh() async throws {
        guard provider == .litellm, litellmModelsFetched.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true else { return }
        await loadLiteLLMModels()
    }

    // MARK: Conversation

    struct Exchange: Equatable {
        var question: String
        var answer: String
        var by: String
    }

    /// The conversation shown in the palette, oldest first.
    var exchanges: [Exchange] = []
    /// The question being answered now, shown as Thinking…. One at a time.
    var asking: String?
    var problem: String?
    /// The question `problem` is about, to try again.
    var failed: String?
    /// The answer on its way, which a new conversation drops.
    var pending: Task<Void, Never>?
    /// Counts conversations, so a late answer to an older one is dropped.
    var conversation = 0

    nonisolated static let systemPrompt = "You answer inside a Mac launcher. Be brief and direct, and start with the answer. Use plain text (no Markdown headings or tables); short lists and code are fine."

    /// One message as the APIs take it.
    struct Message: Equatable {
        var role: String
        var content: String
    }

    nonisolated static func messages(_ history: [Exchange], then question: String) -> [Message] {
        history.flatMap { [Message(role: "user", content: $0.question), Message(role: "assistant", content: $0.answer)] }
            + [Message(role: "user", content: question)]
    }

    /// Claude models that take `output_config.effort` and the server-side
    /// fallback on a refusal.
    nonisolated static func isCurrentClaude(_ model: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5"].contains { model.hasPrefix($0) }
    }

    /// The HTTP request for a provider.
    nonisolated static func request(_ provider: Provider, model: String, key: String?, messages: [Message], system: String = systemPrompt, base: String? = nil) throws -> HTTPRequest {
        let turns = messages.map { ["role": $0.role, "content": $0.content] }
        var headers = ["Content-Type": "application/json"]
        var body: [String: Any]
        switch provider {
        case .anthropic:
            headers["x-api-key"] = key ?? ""
            headers["anthropic-version"] = "2026-10-21"
            body = ["model": model, "max_tokens": 16_000, "system": system, "messages": turns]
            if isCurrentClaude(model) {
                // Quick answers: low effort keeps them fast.
                body["output_config"] = ["effort": "low"]
            }
            if ["claude-opus-5", "claude-sonnet-5-5", "claude-fable-5"].contains(where: { model.hasPrefix($0) }) {
                // A refused answer is retried on a model that can give it.
                headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
                body["fallbacks"] = "default"
            }
        case .openai, .openrouter, .ollama, .litellm:
            if let key { headers["Authorization"] = "Bearer \(key)" }
            body = ["model": model, "messages": [["role": "system", "content": system]] + turns]
        }
        return HTTPRequest(url: provider.chatURL(base: base), method: "POST", headers: headers,
                           body: try JSONSerialization.data(withJSONObject: body), timeout: 120)
    }

    /// The answer's text, or why there is none.
    nonisolated static func answer(_ provider: Provider, status: Int, body: Data) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? (json?["error"] as? String)
            switch status {
            case 401, 403: throw HostError("\(provider.rawValue) refused the key (\(status)). Check \(provider.secret ?? "the key") in Stackbar's Settings")
            case 404 where provider == .ollama: throw HostError(message ?? "Ollama doesn't have that model; run ollama pull, or pick another in Settings")
            case 400 where provider == .litellm, 404 where provider == .litellm: throw HostError("LiteLLM answered \(status)" + (message.map { ": \($0)" } ?? "") + ". Check the model in Settings")
            case 429: throw HostError("\(provider.rawValue) is busy or out of credit (429). \(message ?? "Try again in a moment")")
            default: throw HostError("\(provider.rawValue) answered \(status)" + (message.map { ": \($0)" } ?? ""))
            }
        }
        switch provider {
        case .anthropic:
            if json?["stop_reason"] as? String == "refusal" {
                throw HostError("Claude declined to answer that")
            }
            let blocks = json?["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw HostError("Claude sent no answer") }
            return json?["stop_reason"] as? String == "max_tokens" ? text + "\n\n(cut short)" : text
        case .openai, .openrouter, .ollama, .litellm:
            let choices = json?["choices"] as? [[String: Any]] ?? []
            guard let text = (choices.first?["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else {
                throw HostError("\(provider.rawValue) sent no answer")
            }
            return text
        }
    }

    /// Asks the provider in use, with the conversation so far.
    func ask(_ question: String, history: [Exchange], system: String = systemPrompt) async throws -> String {
        var key: String?
        var base: String?
        if provider == .litellm {
            (base, key) = try await litellmConnection()
            if model.isEmpty { await loadLiteLLMModels() }
            guard !model.isEmpty else { throw HostError(litellmProblem ?? "Pick a LiteLLM model in Ask AI's Settings") }
        } else if let secret = provider.secret {
            key = try await Stackbar.secret(secret)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key, !key.isEmpty else {
                throw HostError("Add your \(provider.rawValue) API key (\(secret)) in Stackbar's Settings, or switch to Ollama for a local model")
            }
        }
        let request = try Self.request(provider, model: model, key: key, messages: Self.messages(history, then: question), system: system, base: base)
        let response = try await Stackbar.http(request)
        return try Self.answer(provider, status: response.status, body: response.body)
    }

    /// Who answered, for the caption.
    var by: String { provider == .anthropic ? model : "\(provider.rawValue) · \(model)" }

    /// Starts a new conversation with `question`, dropping one on its way.
    /// The same question as the conversation shown started with keeps it,
    /// so reopening the palette on that text costs nothing.
    func begin(_ question: String, system: String = systemPrompt) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if (exchanges.first?.question ?? asking) == question, problem == nil { return }
        reset()
        send(question, system: system)
    }

    /// Asks within the conversation. While an answer is on its way another
    /// question waits for it: false, and nothing is sent.
    @discardableResult
    func follow(_ question: String, system: String = systemPrompt) -> Bool {
        guard asking == nil else { return false }
        return send(question.trimmingCharacters(in: .whitespacesAndNewlines), system: system)
    }

    /// Clears the conversation, and drops an answer on its way.
    func reset() {
        pending?.cancel()
        pending = nil
        conversation += 1
        exchanges = []
        asking = nil
        problem = nil
        failed = nil
    }

    /// Asks the question that got no answer again.
    func retry() {
        guard let question = failed else { return }
        if exchanges.isEmpty { begin(question) } else { follow(question) }
    }

    /// Sends one question in its own task, so typing in the palette while it
    /// is answered neither waits for it nor cancels it. Each question is
    /// one request: nothing here asks on a keystroke.
    @discardableResult
    private func send(_ question: String, system: String) -> Bool {
        guard !question.isEmpty else { return false }
        asking = question
        problem = nil
        failed = nil
        let history = exchanges
        let id = conversation
        pending = Task { @MainActor in
            await Stackbar.updating {
                do {
                    let answer = try await self.ask(question, history: history, system: system)
                    guard id == self.conversation else { return }
                    self.exchanges.append(Exchange(question: question, answer: answer, by: self.by))
                } catch {
                    guard id == self.conversation, !(error is CancellationError) else { return }
                    self.problem = "\(error)"
                    self.failed = question
                }
                self.asking = nil
                self.pending = nil
            }
        }
        return true
    }

    /// The question a view opened with: the palette's text (Return or Tab on
    /// it, an alias), or a `stackbar://` link's `prompt` from 1.1.0 and before.
    nonisolated static func opening(_ invocation: CommandInvocation) -> String? {
        let question = (invocation["prompt"] ?? invocation.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? nil : question
    }

    // MARK: Selected text

    struct TextCommand {
        var id: String
        var title: String
        var symbol: String
        var instruction: String
        /// Replaces the selection, rather than showing an answer.
        var replaces: Bool
    }

    nonisolated static let textCommands: [TextCommand] = [
        TextCommand(id: "fix", title: "Fix Spelling and Grammar", symbol: "textformat.abc",
                    instruction: "Fix the spelling and grammar of the text. Keep its meaning, tone, language and formatting. Reply with the corrected text only.", replaces: true),
        TextCommand(id: "improve", title: "Improve Writing", symbol: "wand.and.stars",
                    instruction: "Rewrite the text to read more clearly, in the same language and tone. Reply with the rewritten text only.", replaces: true),
        TextCommand(id: "shorter", title: "Make Shorter", symbol: "arrow.down.right.and.arrow.up.left",
                    instruction: "Make the text shorter without losing what it says, in the same language and tone. Reply with the shorter text only.", replaces: true),
        TextCommand(id: "summarize", title: "Summarize Selection", symbol: "text.append",
                    instruction: "Summarize the text in a few short points.", replaces: false),
        TextCommand(id: "explain", title: "Explain Selection", symbol: "questionmark.bubble",
                    instruction: "Explain the text simply: what it means and anything a reader might not know.", replaces: false),
    ]

    nonisolated static func prompt(_ command: TextCommand, text: String) -> String {
        "\(command.instruction)\n\n<text>\n\(text)\n</text>"
    }

    static func selection(_ invocation: CommandInvocation) -> String? {
        guard let text = invocation.context?.selectedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: Commands

    var commands: [Command] {
        // The view's one field is the question. What it opens with is asked
        // at once, as a new conversation; what is typed after is offered as a
        // follow-up, asked on Return.
        Command("ask", title: "Ask AI", subtitle: "A question, with follow-ups", symbol: "sparkles", keywords: ["ai", "chat", "claude", "gpt", "llm", "question"])
            .view(search: { invocation in
                guard invocation.isOpening, let question = Self.opening(invocation) else { return }
                self.begin(question)
            }) { invocation in
                self.conversation(typed: invocation.text)
            }
            .fallback()
        for command in Self.textCommands {
            if command.replaces {
                Command(command.id, title: command.title, subtitle: "Replaces the selected text", symbol: command.symbol, keywords: ["ai", "selection", "rewrite"]) { invocation in
                    guard let text = Self.selection(invocation) else { return .failure("Select some text first") }
                    let result = try await self.ask(Self.prompt(command, text: text), history: [],
                                                    system: "You edit text. Reply with the edited text only, with no introduction, quotes or notes.")
                    return .paste(result, cursorFromEnd: 0)
                }
            } else {
                Command(command.id, title: command.title, subtitle: "The selected text", symbol: command.symbol, keywords: ["ai", "selection"])
                    .view(search: { invocation in
                        guard invocation.isOpening else { return }
                        guard let text = Self.selection(invocation) else {
                            self.reset()
                            self.problem = "Select some text first, then run \(command.title)"
                            return
                        }
                        self.begin(Self.prompt(command, text: text))
                    }) { invocation in
                        self.conversation(typed: invocation.text)
                    }
            }
        }
    }

    /// The answers, newest first, under a row that asks what is typed. The
    /// field still holding a question already asked (the one the view
    /// opened with) offers nothing.
    @ViewBuilder func conversation(typed: String) -> ViewContent {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let asked = exchanges.map(\.question) + [asking, failed].compactMap { $0 }
        let offer = !typed.isEmpty && !asked.contains(typed)
        if exchanges.isEmpty, asking == nil, failed == nil, !offer {
            if let problem {
                ContentUnavailableView("No answer", symbol: "sparkles", message: problem)
            } else {
                ContentUnavailableView("Ask anything", symbol: "sparkles", message: "Type a question and press Return. Questions after it follow up on the answer.")
            }
        } else {
            List {
                if offer, exchanges.isEmpty, asking == nil {
                    Row("Ask “\(typed)”", subtitle: "A new question", symbol: "sparkles", key: "ask")
                        .action("Ask") { self.begin(typed) }
                } else if offer {
                    Row("Ask “\(typed)”", subtitle: asking == nil ? "A follow-up, with this conversation" : "A follow-up, once this answer is in",
                        symbol: "arrow.up.message", key: "follow-up")
                        .action("Ask") {
                            if !self.follow(typed) { Stackbar.hud("Still answering the last question") }
                        }
                        .action("Ask as a New Question", shortcut: "cmd+return") { self.begin(typed) }
                }
                if let asking {
                    Row("Thinking…", subtitle: Self.gist(Self.shownQuestion(asking)), symbol: "ellipsis", key: "thinking")
                }
                if let problem {
                    Row(problem, subtitle: "The last question got no answer", symbol: "exclamationmark.triangle", key: "problem")
                        .action("Try Again") { self.retry() }
                }
                for (index, exchange) in exchanges.enumerated().reversed() {
                    Row(Self.gist(exchange.answer), subtitle: Self.gist(Self.shownQuestion(exchange.question)), symbol: "sparkles", key: "answer-\(index)")
                        .preview(text: exchange.answer, caption: exchange.by)
                        .action("Copy Answer") { Stackbar.copy(exchange.answer) }
                        .action("Paste Answer", shortcut: "cmd+p") {
                            try await Stackbar.paste(.text(exchange.answer), restoringClipboard: true)
                        }
                }
            }
        }
    }

    /// A selection command's question shows as its instruction, not the text.
    nonisolated static func shownQuestion(_ question: String) -> String {
        guard let cut = question.range(of: "\n\n<text>") else { return question }
        return String(question[..<cut.lowerBound])
    }

    nonisolated static func gist(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }

    // MARK: Panel and settings

    var panel: ViewContent {
        PanelHeader("Ask AI", subtitle: by, symbol: "sparkles", theme: theme)
        TextField("Ask anything, then Return") { text in
            self.reset()
            self.begin(text)
        }
        if let problem {
            Banner(problem)
        }
        if let asking {
            Text(Self.shownQuestion(asking)).style(.caption).role(.secondary)
            Text("Thinking…").style(.body).role(.secondary)
        } else if let last = exchanges.last {
            Text(Self.shownQuestion(last.question)).style(.caption).role(.secondary)
            Text(last.answer).style(.body)
            HStack(spacing: Space.s) {
                ActionButton("Copy", symbol: "doc.on.doc", theme: theme, prominent: true) { Stackbar.copy(last.answer) }
                ActionButton("New Question", symbol: "plus", theme: theme) { self.reset() }
                Spacer()
            }
        } else if problem == nil {
            Text("Or type a question in the palette and press Tab.").style(.caption).role(.secondary)
        }
    }

    var settings: ViewContent {
        Section("Provider") {
            Picker("Ask", options: Provider.allCases.map(\.rawValue), selection: provider.rawValue, style: .segmented) { choice in
                self.storedProvider = choice
                self.problem = nil
                if self.provider == .litellm, self.litellmModels.isEmpty { await self.loadLiteLLMModels() }
            }
            if provider == .litellm {
                litellmModelPicker
            } else {
                TextField(provider.defaultModel, text: models[provider.rawValue] ?? "", key: "model-\(provider.rawValue)") { value in
                    self.models[self.provider.rawValue] = value.trimmingCharacters(in: .whitespaces)
                }
            }
            Text(caption).style(.caption)
        }
    }

    /// The proxy's models to pick from, a field when it can't list them, and
    /// a button to list them again.
    @ViewBuilder var litellmModelPicker: ViewContent {
        let chosen = model
        if litellmModels.isEmpty {
            TextField("Model name on your proxy", text: models[Provider.litellm.rawValue] ?? "", key: "model-LiteLLM") { value in
                self.models[Provider.litellm.rawValue] = value.trimmingCharacters(in: .whitespaces)
            }
        } else {
            // A model typed earlier and since gone from the proxy stays pickable.
            Picker("Model", options: litellmModels.contains(chosen) || chosen.isEmpty ? litellmModels : [chosen] + litellmModels,
                   selection: chosen, key: "litellm-model") { choice in
                self.models[Provider.litellm.rawValue] = choice
            }
        }
        if let litellmProblem {
            Banner(litellmProblem)
        }
        ActionButton(litellmModels.isEmpty ? "List the Proxy's Models" : "Refresh Models", symbol: "arrow.clockwise", theme: theme) {
            await self.loadLiteLLMModels()
        }
    }

    var caption: String {
        switch provider {
        case .anthropic:
            return "Uses Claude Opus 5.5 at low effort unless you name another model, such as claude-haiku-5-5 for cheaper answers. Needs ANTHROPIC_API_KEY from platform.claude.com; Stackbar asks for it the first time and keeps it in your Keychain."
        case .openai:
            return "Needs OPENAI_API_KEY from platform.openai.com. The model is any chat model your key can use."
        case .openrouter:
            return "Needs OPENROUTER_API_KEY. openrouter/auto picks a model per question; name one (anthropic/…, openai/…) to fix it."
        case .ollama:
            return "Runs on your Mac with Ollama (ollama.com), no key and nothing sent anywhere. Pull the model first: ollama pull llama3.2."
        case .litellm:
            return "Asks your own LiteLLM proxy. Uses the same LITELLM_PROXY_URL and LITELLM_API_KEY as the LiteLLM plugin, and reaches that host and no other. The models are the ones your key may use."
        }
    }
}
