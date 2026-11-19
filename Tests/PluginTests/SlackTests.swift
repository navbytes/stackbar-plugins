import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class SlackTests: XCTestCase {
    /// Without a token the menu bar stays quiet, not a warning, and the panel
    /// offers to connect.
    func testWithoutATokenTheMenuBarStaysQuietAndThePanelOffersSetup() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Slack")
        let menu = await supervisor.views[.menuBar]
        guard case .label(_, _, let role)? = menu else { return XCTFail("the menu bar is a label: \(String(describing: menu))") }
        XCTAssertEqual(role, .secondary)
        let panel = await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(panel.contains("Connect Slack"), panel)
        await supervisor.stop()
    }
}

#if canImport(Network)
import Network

/// A Slack workspace on loopback, reached as a custom server
/// (`SLACK_API_URL`) the way GovSlack is.
private struct Workspace: Sendable {
    /// Each conversation's history, newest first, as (ts, user, text, subtype).
    var history: [String: [(ts: String, user: String, text: String, subtype: String?)]] = [:]
    var lastRead: [String: String] = [:]
    var rejectToken = false
}

private func form(_ body: Data) -> [String: String] {
    var fields: [String: String] = [:]
    for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        fields[parts[0]] = parts.count > 1 ? parts[1] : ""
    }
    return fields
}

private func json(_ object: Any) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

private func slack(_ path: String, _ body: Data, _ workspace: Workspace) -> (Int, String) {
    let method = path.replacingOccurrences(of: "/api/", with: "")
    let fields = form(body)
    if workspace.rejectToken { return (200, json(["ok": false, "error": "invalid_auth"])) }
    switch method {
    case "auth.test":
        return (200, json(["ok": true, "user": "sam", "user_id": "U1", "team": "Acme", "team_id": "T1", "url": "https://acme.slack.com/"]))
    case "users.list":
        return (200, json(["ok": true, "members": [
            ["id": "U1", "name": "sam", "profile": ["real_name": "Sam"]],
            ["id": "U2", "name": "mei", "profile": ["real_name": "Mei Tanaka"]],
            ["id": "U3", "name": "ravi", "real_name": "Ravi Kumar"],
        ], "response_metadata": ["next_cursor": ""]]))
    case "users.conversations":
        return (200, json(["ok": true, "channels": [
            ["id": "C1", "name": "general"],
            ["id": "D1", "is_im": true, "user": "U2"],
        ], "response_metadata": ["next_cursor": ""]]))
    case "conversations.info":
        let id = fields["channel"] ?? ""
        return (200, json(["ok": true, "channel": ["id": id, "last_read": workspace.lastRead[id] ?? "0000000000.000000"]]))
    case "conversations.history":
        let oldest = Double(fields["oldest"] ?? "0") ?? 0
        let messages = (workspace.history[fields["channel"] ?? ""] ?? []).filter { (Double($0.ts) ?? 0) > oldest }.map { message -> [String: Any] in
            var item: [String: Any] = ["ts": message.ts, "user": message.user, "text": message.text]
            if let subtype = message.subtype { item["subtype"] = subtype }
            return item
        }
        return (200, json(["ok": true, "messages": messages, "has_more": false]))
    case "users.profile.get":
        return (200, json(["ok": true, "profile": ["status_text": "", "status_emoji": ""]]))
    case "dnd.info":
        return (200, json(["ok": true, "snooze_enabled": false]))
    case "conversations.open":
        return (200, json(["ok": true, "channel": ["id": "D3"]]))
    case "conversations.mark", "chat.postMessage", "dnd.setSnooze", "dnd.endSnooze":
        return (200, json(["ok": true]))
    default:
        return (200, json(["ok": false, "error": "unknown_method"]))
    }
}

final class SlackWorkspaceTests: XCTestCase {
    /// The Slack calls made, as "method field=value&…", in order.
    private func calls(_ stub: LoopbackStub) -> [String] {
        stub.requests.all.compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 4).map(String.init)
            guard parts.count >= 2 else { return nil }
            return parts[1].replacingOccurrences(of: "/api/", with: "") + " " + (parts.count > 4 ? parts[4] : "")
        }
    }

    private func connect(_ host: Host, _ stub: LoopbackStub) throws {
        try host.services.secrets.setSecret("xoxp-test", for: "SLACK_TOKEN")
        try host.services.secrets.setSecret("http://127.0.0.1:\(stub.port)", for: "SLACK_API_URL")
    }

    private func refreshed(_ supervisor: PluginSupervisor) async {
        let before = await supervisor.settledCount
        await supervisor.refresh()
        _ = await waitUntil { await supervisor.settledCount > before }
    }

    /// Messages from other people since you last read a watched conversation
    /// count; yours and joins don't. Mark as Read marks the newest one, and
    /// Slack's markup reads as names.
    func testWatchedUnreadCountsAndMarkAsReadMarksTheNewest() async throws {
        let workspace = Locked(Workspace(history: ["D1": [
            ("1700000300.000100", "U2", "ping <@U1> about <#C1|general> and <https://x.dev|the doc> &amp; more", nil),
            ("1700000200.000100", "U1", "my own message", nil),
            ("1700000100.000100", "U2", "morning", nil),
            ("1700000050.000100", "U3", "joined", "channel_join"),
        ]], lastRead: ["D1": "1700000000.000000"]))
        let stub = try LoopbackStub { _, path, _, body in slack(path, body, workspace.current) }
        let host = Host(self)
        try connect(host, stub)
        let supervisor = try await host.start("Slack")
        await supervisor.press("picker/Server", value: .text("Other"))
        await supervisor.press("field/add-watched", value: .text("@mei"))
        let counted = await waitUntil { await supervisor.views[.menuBar]?.plainText == "2" }
        let shown = await supervisor.views[.menuBar]?.plainText
        XCTAssertTrue(counted, "two unread from Mei: \(String(describing: shown))")
        let panel = await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(panel.contains("ping @Sam about #general and the doc & more"), panel)
        XCTAssertTrue(calls(stub).contains { $0.hasPrefix("auth.test") }, "\(calls(stub))")

        await supervisor.press("row/unread-D1/Mark as Read")
        XCTAssertTrue(calls(stub).contains("conversations.mark channel=D1&ts=1700000300.000100"), "\(calls(stub))")
        let cleared = await waitUntil { await supervisor.views[.menuBar]?.plainText == "" }
        XCTAssertTrue(cleared, "nothing unread after marking")
        await supervisor.stop()
    }

    /// New messages notify only once you turn notifications on, and only
    /// the ones you haven't been told about.
    func testNotificationsAreOffUntilTurnedOnThenEachNewMessageOnce() async throws {
        let workspace = Locked(Workspace(history: ["D1": [("1700000100.000100", "U2", "first", nil)]]))
        let stub = try LoopbackStub { _, path, _, body in slack(path, body, workspace.current) }
        let host = Host(self)
        try connect(host, stub)
        let supervisor = try await host.start("Slack")
        await supervisor.press("picker/Server", value: .text("Other"))
        await supervisor.press("field/add-watched", value: .text("Mei Tanaka"))
        _ = await waitUntil { await supervisor.views[.menuBar]?.plainText == "1" }

        workspace.change { $0.history["D1"]?.insert(("1700000200.000100", "U2", "second", nil), at: 0) }
        await refreshed(supervisor)
        XCTAssertTrue(host.notifications.all.isEmpty, "off by default: \(host.notifications.all.map(\.title))")

        await supervisor.press("toggle/Notify about new messages in watched conversations", value: .bool(true))
        workspace.change { $0.history["D1"]?.insert(("1700000300.000100", "U2", "third", nil), at: 0) }
        await refreshed(supervisor)
        await refreshed(supervisor)
        XCTAssertEqual(host.notifications.all.map(\.title), ["Mei Tanaka"])
        XCTAssertEqual(host.notifications.all.first?.body, "third")
        await supervisor.stop()
    }

    /// A message to someone you haven't written to opens a direct message
    /// first, then posts there.
    func testSendingToSomeoneNewOpensADirectMessageFirst() async throws {
        let stub = try LoopbackStub { _, path, _, body in slack(path, body, Workspace()) }
        let host = Host(self)
        try connect(host, stub)
        let session = try await host.session("Slack")
        try await session.event("picker/Server", value: .text("Other"))
        let opened = try await session.openView("compose", query: CommandQuery(arguments: ["to": "U3"]))
        try await session.event(ActionID("view/\(opened.session)/form/compose-U3"), value: .fields(["text": .text("hi & bye")]))
        let made = calls(stub).filter { $0.hasPrefix("conversations.open") || $0.hasPrefix("chat.postMessage") }
        XCTAssertEqual(made, ["conversations.open users=U3", "chat.postMessage channel=D3&text=hi%20%26%20bye"])
        await session.stop()
    }

    /// Snooze off ends a snooze; a time snoozes for that long.
    func testSnoozeChoices() async throws {
        let stub = try LoopbackStub { _, path, _, body in slack(path, body, Workspace()) }
        let host = Host(self)
        try connect(host, stub)
        let session = try await host.session("Slack")
        try await session.event("picker/Server", value: .text("Other"))
        _ = try await session.runCommand("snooze", arguments: ["for": "2 hours"])
        _ = try await session.runCommand("snooze", arguments: ["for": "Turn off"])
        let made = calls(stub).filter { $0.hasPrefix("dnd.") && !$0.hasPrefix("dnd.info") }
        XCTAssertEqual(made, ["dnd.setSnooze num_minutes=120", "dnd.endSnooze "])
        await session.stop()
    }

    /// A token Slack turns down says so, and the menu bar warns.
    func testARejectedTokenSaysSo() async throws {
        let stub = try LoopbackStub { _, path, _, body in slack(path, body, Workspace(rejectToken: true)) }
        let host = Host(self)
        try connect(host, stub)
        let supervisor = try await host.start("Slack")
        await supervisor.press("picker/Server", value: .text("Other"))
        let warned = await waitUntil {
            guard case .label(_, _, .warning)? = await supervisor.views[.menuBar] else { return false }
            return true
        }
        XCTAssertTrue(warned)
        let panel = await supervisor.views[.panel].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(panel.contains("Slack rejected the token"), panel)
        await supervisor.stop()
    }
}
#endif
