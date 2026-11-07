#if os(macOS)
import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

/// The plugin lists this Mac's real processes, so these tests look for the one
/// `sleep` they start. A quit may only end that process.
final class KillProcessTests: XCTestCase {
    private func startSleep() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["31337"]
        try process.run()
        return process
    }

    /// The rows the open view shows now.
    private func rows(_ session: PluginSession, _ view: Int) async -> [RowNode] {
        await session.commandView(view)?.rows ?? []
    }

    func testQuitTakesTwoPressesWithinTenSeconds() async throws {
        let sleeper = try startSleep()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let pid = Int(sleeper.processIdentifier)
        let host = Host(self)
        let session = try await host.session("KillProcess")
        let opened = try await session.openView("search", query: CommandQuery(text: "sleep 31337"))
        let found = try XCTUnwrap(opened.root?.rows.first { $0.key == "\(pid)" }, "the test's sleep is listed")
        let quit = try XCTUnwrap(found.actions.first { $0.title == "Quit Process" })
        XCTAssertEqual(quit.role, .critical)

        try await session.event(quit.id)
        XCTAssertTrue(sleeper.isRunning, "the first press only asks again")
        let asked = await rows(session, opened.session).first { $0.key == "\(pid)" }
        XCTAssertEqual(asked?.subtitle, "Press again to quit sleep")

        // Past the ten seconds, the first press has lapsed, so the next one asks again.
        try await Task.sleep(for: .seconds(10.5))
        try await session.event(quit.id)
        XCTAssertTrue(sleeper.isRunning, "a press after the window asks again")

        try await session.event(quit.id)
        let ended = await waitUntil(5) { !sleeper.isRunning }
        XCTAssertTrue(ended, "a second press within the window ends it")
        let remaining = await rows(session, opened.session)
        XCTAssertFalse(remaining.contains { $0.key == "\(pid)" }, "and it leaves the results, not just the system")
        await session.closeView(opened.session)
        await session.stop()
    }

    func testSearchFindsAProcessByItsCommandLine() async throws {
        let sleeper = try startSleep()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let pid = Int(sleeper.processIdentifier)
        let host = Host(self)
        let session = try await host.session("KillProcess")
        // "bin/sleep" appears in the command line, not in the name.
        let opened = try await session.openView("search", query: CommandQuery(text: "bin/sleep"))
        let found = try XCTUnwrap(opened.root?.rows.first { $0.key == "\(pid)" }, "search reads the command line too")
        XCTAssertEqual(found.title, "sleep")
        XCTAssertEqual(found.subtitle?.hasPrefix("sleep 31337"), true, "the subtitle drops the program's own path: \(found.subtitle ?? "")")
        await session.closeView(opened.session)
        await session.stop()
    }
}
#endif
