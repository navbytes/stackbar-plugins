import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_AskAI

/// Nothing here reaches a provider: the requests are built and the answers
/// read from canned replies.
final class AskAITests: XCTestCase {
    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
    }

    func testAnthropicRequestCarriesTheKeyVersionAndConversation() throws {
        let history = [AskAI.Exchange(question: "2+2?", answer: "4", by: "x")]
        let request = try AskAI.request(.anthropic, model: "claude-opus-5-5", key: "sk-test", messages: AskAI.messages(history, then: "and 3+3?"))
        XCTAssertEqual(request.url, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.headers["x-api-key"], "sk-test")
        XCTAssertEqual(request.headers["anthropic-version"], "2026-10-21")
        XCTAssertEqual(request.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(json["system"] as? String, AskAI.systemPrompt)
        XCTAssertEqual((json["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(json["fallbacks"] as? String, "default")
        XCTAssertNil(json["temperature"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["user", "assistant", "user"])
        XCTAssertEqual(messages.last?["content"], "and 3+3?")
    }

    func testOlderClaudeModelsGetNoEffortOrFallback() throws {
        let request = try AskAI.request(.anthropic, model: "claude-haiku-4-5", key: "k", messages: AskAI.messages([], then: "hi"))
        let json = try body(request)
        XCTAssertNil(json["output_config"])
        XCTAssertNil(json["fallbacks"])
        XCTAssertNil(request.headers["anthropic-beta"])
        let haiku = try body(AskAI.request(.anthropic, model: "claude-haiku-5-5", key: "k", messages: AskAI.messages([], then: "hi")))
        XCTAssertNotNil(haiku["output_config"], "current Haiku takes effort")
        XCTAssertNil(haiku["fallbacks"], "but has no server-side fallback")
    }

    func testOpenAIStyleProvidersPutTheSystemPromptFirst() throws {
        let openai = try AskAI.request(.openai, model: "gpt-5-mini", key: "sk", messages: AskAI.messages([], then: "hi"))
        XCTAssertEqual(openai.headers["Authorization"], "Bearer sk")
        let messages = try XCTUnwrap(body(openai)["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.last?["content"], "hi")

        let ollama = try AskAI.request(.ollama, model: "llama3.2", key: nil, messages: AskAI.messages([], then: "hi"))
        XCTAssertEqual(ollama.url, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(ollama.headers["Authorization"], "a local model needs no key")
    }

    func testReadsAnswersAndExplainsFailures() throws {
        let claude = Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Paris"}],"stop_reason":"end_turn"}"#.utf8)
        XCTAssertEqual(try AskAI.answer(.anthropic, status: 200, body: claude), "Paris")
        let refused = Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)
        XCTAssertThrowsError(try AskAI.answer(.anthropic, status: 200, body: refused))
        let cut = Data(#"{"content":[{"type":"text","text":"Long"}],"stop_reason":"max_tokens"}"#.utf8)
        XCTAssertEqual(try AskAI.answer(.anthropic, status: 200, body: cut), "Long\n\n(cut short)")

        let chat = Data(#"{"choices":[{"message":{"role":"assistant","content":"Berlin"}}]}"#.utf8)
        XCTAssertEqual(try AskAI.answer(.openrouter, status: 200, body: chat), "Berlin")

        let unauthorized = Data(#"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        XCTAssertThrowsError(try AskAI.answer(.anthropic, status: 401, body: unauthorized)) { error in
            XCTAssertTrue("\(error)".contains("ANTHROPIC_API_KEY"))
        }
    }

    func testSelectionCommandsShowTheirInstructionNotTheText() {
        let fix = AskAI.textCommands[0]
        let prompt = AskAI.prompt(fix, text: "teh cat")
        XCTAssertTrue(prompt.hasSuffix("<text>\nteh cat\n</text>"))
        XCTAssertEqual(AskAI.shownQuestion(prompt), fix.instruction)
        XCTAssertEqual(AskAI.shownQuestion("plain question"), "plain question")
    }

    func testReplacingCommandsNeedASelection() async throws {
        let host = Host(self)
        let session = try await host.session("AskAI")
        let result = try await session.runCommand("fix")
        XCTAssertEqual(result, .failure("Select some text first"))
        XCTAssertTrue(host.system.pasted.isEmpty)
        await session.stop()
    }

    func testLiteLLMAsksTheProxyWithItsKey() throws {
        XCTAssertEqual(AskAI.apiRoot("https://llm.example.com/"), "https://llm.example.com/v1")
        XCTAssertEqual(AskAI.apiRoot(" https://llm.example.com/v1/ "), "https://llm.example.com/v1")
        let request = try AskAI.request(.litellm, model: "claude-sonnet", key: "sk-lite", messages: AskAI.messages([], then: "hi"), base: "https://llm.example.com")
        XCTAssertEqual(request.url, "https://llm.example.com/v1/chat/completions")
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-lite")
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "claude-sonnet")
        XCTAssertEqual((json["messages"] as? [[String: String]])?.first?["role"], "system")

        let chat = Data(#"{"choices":[{"message":{"role":"assistant","content":"Lisbon"}}]}"#.utf8)
        XCTAssertEqual(try AskAI.answer(.litellm, status: 200, body: chat), "Lisbon")
        let unknown = Data(#"{"error":{"message":"Invalid model name passed in model=nope"}}"#.utf8)
        XCTAssertThrowsError(try AskAI.answer(.litellm, status: 400, body: unknown)) { error in
            XCTAssertTrue("\(error)".contains("Invalid model name"), "\(error)")
            XCTAssertTrue("\(error)".contains("Settings"), "\(error)")
        }
        XCTAssertThrowsError(try AskAI.answer(.litellm, status: 401, body: Data())) { error in
            XCTAssertTrue("\(error)".contains("LITELLM_API_KEY"), "\(error)")
        }
    }

    func testReadsTheProxysModels() throws {
        let reply = Data(#"{"object":"list","data":[{"id":"gpt-5-mini","object":"model"},{"id":"claude-sonnet","object":"model"},{"id":"gpt-5-mini","object":"model"}]}"#.utf8)
        XCTAssertEqual(try AskAI.modelIDs(status: 200, body: reply), ["claude-sonnet", "gpt-5-mini"])
        XCTAssertThrowsError(try AskAI.modelIDs(status: 401, body: Data())) { error in
            XCTAssertTrue("\(error)".contains("LITELLM_API_KEY"), "\(error)")
        }
        XCTAssertThrowsError(try AskAI.modelIDs(status: 404, body: Data())) { error in
            XCTAssertTrue("\(error)".contains("LITELLM_PROXY_URL"), "\(error)")
        }
    }

    #if canImport(Network)
    /// Picking LiteLLM in Settings lists the proxy's models, and a question
    /// goes to the proxy with the picked one and the shared key.
    func testLiteLLMListsTheProxysModelsAndAsksWithThePickedOne() async throws {
        let stub = try LiteLLMStub { method, path, _, _ in
            switch (method, path) {
            case ("GET", "/v1/models"): return (200, #"{"data":[{"id":"gpt-5-mini"},{"id":"claude-sonnet"}]}"#)
            case ("POST", "/v1/chat/completions"): return (200, #"{"choices":[{"message":{"role":"assistant","content":"Four"}}]}"#)
            default: return (404, "{}")
            }
        }
        let host = Host(self)
        try host.services.secrets.setSecret("http://127.0.0.1:\(stub.port)/", for: "LITELLM_PROXY_URL")
        try host.services.secrets.setSecret("sk-lite", for: "LITELLM_API_KEY")
        let supervisor = try await host.start("AskAI")

        await supervisor.press("picker/Ask", value: .text("LiteLLM"))
        let listed = await waitUntil { await self.text(supervisor, .settings).contains("gpt-5-mini") }
        let shown = await self.text(supervisor, .settings)
        XCTAssertTrue(listed, shown)
        XCTAssertTrue(stub.requests.all.contains { $0.hasPrefix("GET /v1/models Bearer sk-lite") }, "\(stub.requests.all)")

        await supervisor.press("picker/litellm-model", value: .text("gpt-5-mini"))
        await supervisor.press("field/Ask anything, then Return", value: .text("2+2?"))
        let answered = await waitUntil { await self.text(supervisor, .panel).contains("Four") }
        let panelText = await self.text(supervisor, .panel)
        XCTAssertTrue(answered, panelText)
        let asked = stub.requests.all.first { $0.hasPrefix("POST /v1/chat/completions") } ?? ""
        XCTAssertTrue(asked.contains("Bearer sk-lite") && asked.contains(#""model":"gpt-5-mini""#), asked)
        await supervisor.stop()
    }

    private func text(_ supervisor: PluginSupervisor, _ surface: Surface) async -> String {
        await supervisor.views[surface].map { TreeTextRenderer.render($0) } ?? ""
    }
    #endif
}
