import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

#if canImport(Network)
import Network

/// A Jira Data Center server on loopback. The plugin's requests reach it
/// through the host like any other, and `requests` records each one as
/// "METHOD path auth body".
private typealias JiraStub = LoopbackStub

private struct Board: Sendable {
    /// The issue keys assigned to each Authorization header value.
    var assigned: [String: [String]] = [:]
    var searchFails = false
}

private func dataCenter(_ method: String, _ path: String, _ auth: String, _ body: Data, _ board: Board) -> (Int, String) {
    let jql = String(decoding: body, as: UTF8.self)
    if method == "POST", path == "/rest/api/2/search" {
        if board.searchFails { return (500, #"{"errorMessages":["Jira is down"]}"#) }
        if jql.contains("statusCategory = Done") { return (200, #"{"issues":[],"total":0}"#) }
        if jql.contains("key = ") || jql.contains("text ~ ") { return (200, searchPage(["OPS-9"])) }
        return (200, searchPage(board.assigned[auth] ?? []))
    }
    if method == "GET", path == "/rest/api/2/myself" {
        let name = auth == "Bearer tokenB" ? "userB" : "userA"
        return (200, "{\"name\":\"\(name)\"}")
    }
    if method == "GET", path == "/rest/api/2/project" { return (200, #"[{"id":"1","key":"OPS","name":"Ops"}]"#) }
    return (404, #"{"errorMessages":["Not found"]}"#)
}

/// One page of issues, all of them, as Data Center answers a search.
private func searchPage(_ keys: [String]) -> String {
    "{\"issues\":[" + keys.map(issue).joined(separator: ",") + "],\"total\":\(keys.count)}"
}

private func issue(_ key: String) -> String {
    #"{"id":"\#(key)","key":"\#(key)","fields":{"summary":"s","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"priority":{"name":"Medium"},"issuetype":{"name":"Task"},"project":{"key":"OPS","name":"Ops"}}}"#
}

final class JiraTests: XCTestCase {
    private let id = "io.navbytes.stackbar.plugins.jira"

    /// Waits out a refresh the test asked for.
    private func refreshed(_ supervisor: PluginSupervisor) async {
        let before = await supervisor.settledCount
        await supervisor.refresh()
        _ = await waitUntil { await supervisor.settledCount > before }
    }

    /// Points Jira at the stub as a Data Center server with a token.
    private func connect(_ host: Host, _ stub: JiraStub, token: String) throws {
        try host.services.secrets.setSecret("http://127.0.0.1:\(stub.port)", for: "JIRA_SERVER_URL")
        try host.services.secrets.setSecret(token, for: "JIRA_API_TOKEN")
    }

    /// A new API token is another account: its issues are not news, and the
    /// new account is who Assign to Me and Watch act as.
    func testSwitchingTokenDoesNotAnnounceTheNewAccount() async throws {
        let board = Locked(Board(assigned: [
            "Bearer tokenA": ["OPS-1", "OPS-2"],
            "Bearer tokenB": ["OPS-10", "OPS-11", "OPS-12", "OPS-13", "OPS-14", "OPS-15"],
        ]))
        let stub = try JiraStub { method, path, auth, body in dataCenter(method, path, auth, body, board.current) }
        let host = Host(self)
        try connect(host, stub, token: "tokenA")
        let supervisor = try await host.start("Jira")
        await supervisor.press("picker/Jira", value: .text("Data Center"))
        _ = await waitUntil { await supervisor.views[.menuBar]?.plainText == "2" }

        try host.services.secrets.setSecret("tokenB", for: "JIRA_API_TOKEN")
        await refreshed(supervisor)
        let menu = await supervisor.views[.menuBar]?.plainText
        XCTAssertEqual(menu, "6")
        XCTAssertTrue(host.notifications.all.isEmpty, "\(host.notifications.all.map(\.title))")

        // An issue assigned to the new account after that is still news.
        board.change { $0.assigned["Bearer tokenB", default: []].append("OPS-16") }
        await refreshed(supervisor)
        XCTAssertEqual(host.notifications.all.map(\.title), ["OPS-16 assigned to you"])
        await supervisor.stop()
    }

    /// A pasted issue link searches for the issue it names, not for the link's text.
    func testAPastedIssueLinkFindsItsKey() async throws {
        let board = Locked(Board())
        let stub = try JiraStub { method, path, auth, body in dataCenter(method, path, auth, body, board.current) }
        let host = Host(self)
        try connect(host, stub, token: "tokenA")
        let session = try await host.session("Jira")
        try await session.event("picker/Jira", value: .text("Data Center"))
        let opened = try await session.openView("search", query: CommandQuery(text: "http://127.0.0.1:\(stub.port)/browse/OPS-9"))
        let found = await waitUntil {
            guard let view = await session.commandView(opened.session) else { return false }
            return view.rows.contains { $0.key == "OPS-9" }
        }
        XCTAssertTrue(found, "the link's issue is listed")
        XCTAssertTrue(stub.requests.all.contains { $0.contains("key = \\\"OPS-9\\\"") }, "\(stub.requests.all)")
        await session.stop()
    }

    /// A list that failed a moment ago is not asked for again on every open.
    func testAFailedListWaitsBeforeAskingAgain() async throws {
        let board = Locked(Board(searchFails: true))
        let stub = try JiraStub { method, path, auth, body in dataCenter(method, path, auth, body, board.current) }
        let host = Host(self)
        try connect(host, stub, token: "tokenA")
        let session = try await host.session("Jira")
        try await session.event("picker/Jira", value: .text("Data Center"))
        let searches = { stub.requests.all.filter { $0.hasPrefix("POST /rest/api/2/search") }.count }
        let before = searches()
        XCTAssertGreaterThan(before, 0, "the failing load was tried")
        _ = try await session.openView("my-issues")
        _ = try await session.openView("my-issues")
        XCTAssertEqual(searches(), before, "no new requests within half a minute of a failure")
        await session.stop()
    }
}
#endif
