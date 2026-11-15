import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class ApplicationsTests: XCTestCase {
    func testASettingsPaneOpensByItsLink() async throws {
        let host = Host(self)
        let session = try await host.session("Applications")
        let opened = try await session.openView("search", query: CommandQuery(text: "wi-fi"))
        let row = try XCTUnwrap(opened.root?.rows.first)
        XCTAssertEqual(row.title, "Wi-Fi")
        try await session.event(try XCTUnwrap(row.actions.first).id)
        let arrived = await waitUntil { host.opened.all.contains { $0.url == "x-apple.systempreferences:com.apple.Wi-Fi-Settings.extension" } }
        XCTAssertTrue(arrived, "\(host.opened.all)")
        await session.stop()
    }

    func testTypingFindsTheApp() async throws {
        let host = Host(self)
        let session = try await host.session("Applications")
        let opened = try await session.openView("search", query: CommandQuery(text: "saf"))
        XCTAssertEqual(opened.root?.rows.first?.title, "Safari")
        await session.stop()
    }

    // MARK: Scenarios (trust-first 3.1)

    /// A Mac with the apps people type most, so prefixes collide.
    private func host() -> Host {
        let host = Host(self)
        host.system.applications = [
            "Safari": "com.apple.Safari", "Slack": "com.tinyspeck.slackmacgap", "Spotify": "com.spotify.client",
            "System Settings": "com.apple.systempreferences", "Visual Studio Code": "com.microsoft.VSCode",
            "Xcode": "com.apple.dt.Xcode", "Google Chrome": "com.google.Chrome", "Finder": "com.apple.finder",
        ]
        return host
    }

    private func titles(_ session: PluginSession, _ text: String) async throws -> [String] {
        let opened = try await session.openView("search", query: CommandQuery(text: text))
        await session.closeView(opened.session)
        return opened.root?.rows.map(\.title) ?? []
    }

    /// Return on `title` among the results for `text`, then the palette
    /// closes once the app came forward.
    private func pick(_ title: String, for text: String, in session: PluginSession, host: Host) async throws {
        let opened = try await session.openView("search", query: CommandQuery(text: text))
        let row = try XCTUnwrap(opened.root?.rows.first { $0.title == title }, "\(opened.root?.rows.map(\.title) ?? [])")
        try await session.event(try XCTUnwrap(row.actions.first).id)
        let id = try XCTUnwrap(host.system.applications[title])
        let forward = await waitUntil { host.system.currentApps.first { $0.isActive }?.id == id }
        XCTAssertTrue(forward, "\(title) came forward")
        await session.closeView(opened.session)
    }

    func testInitialsAndWordStartsFindTheApp() async throws {
        let host = host()
        let session = try await host.session("Applications")
        let vsc = try await titles(session, "vsc")
        XCTAssertEqual(vsc.first, "Visual Studio Code", "initials")
        let code = try await titles(session, "code")
        XCTAssertEqual(code.first, "Visual Studio Code", "a word's start")
        let leading = try await titles(session, "  xc ")
        XCTAssertEqual(leading.first, "Xcode", "spaces around the text don't matter")
        let none = try await titles(session, "zzqq")
        XCTAssertEqual(none, [], "nothing matches, nothing shows")
        await session.stop()
    }

    /// Every pane has the keyword "settings"; the app itself still leads.
    func testSettingsFindsTheSystemSettingsAppBeforeItsPanes() async throws {
        let host = host()
        let session = try await host.session("Applications")
        let rows = try await titles(session, "settings")
        XCTAssertEqual(rows.first, "System Settings", "\(rows)")
        await session.stop()
    }

    /// Return on an app that isn't running launches it and brings it forward.
    func testReturnLaunchesTheApp() async throws {
        let host = host()
        let session = try await host.session("Applications")
        let opened = try await session.openView("search", query: CommandQuery(text: "chrome"))
        let row = try XCTUnwrap(opened.root?.rows.first)
        XCTAssertEqual(row.title, "Google Chrome")
        XCTAssertEqual(row.actions.first?.title, "Open", "Return opens")
        try await session.event(try XCTUnwrap(row.actions.first).id)
        let launched = await waitUntil { host.system.appActions.contains("launch com.google.Chrome") }
        XCTAssertTrue(launched, "\(host.system.appActions)")
        XCTAssertEqual(host.system.currentApps.first { $0.isActive }?.id, "com.google.Chrome")
        await session.stop()
    }

    func testCopyPathAndBundleID() async throws {
        let host = host()
        let session = try await host.session("Applications")
        let opened = try await session.openView("search", query: CommandQuery(text: "xcode"))
        let row = try XCTUnwrap(opened.root?.rows.first)
        try await session.event(try XCTUnwrap(row.actions.first { $0.title == "Copy Path" }).id)
        try await session.event(try XCTUnwrap(row.actions.first { $0.title == "Copy Bundle ID" }).id)
        let copied = await waitUntil { host.copies.all.count >= 2 }
        XCTAssertTrue(copied)
        XCTAssertEqual(host.copies.all, ["/Applications/Xcode.app", "com.apple.dt.Xcode"])
        await session.stop()
    }

    /// The mac-checks palette-ranking item at the plugin's level: pick a
    /// non-first app for "s" twice and it leads for "s", also after a restart.
    func testAnAppPickedTwiceLeadsItsLetterAndRemembersAcrossRestarts() async throws {
        let host = host()
        let session = try await host.session("Applications")
        let before = try await titles(session, "s")
        XCTAssertNotEqual(before.first, "Spotify", "\(before)")
        XCTAssertTrue(before.contains("Spotify"))
        for _ in 0..<2 {
            try await pick("Spotify", for: "s", in: session, host: host)
        }
        let after = try await titles(session, "s")
        XCTAssertEqual(after.first, "Spotify", "\(after)")
        await session.stop()

        let again = try await host.session("Applications")
        let restarted = try await titles(again, "s")
        XCTAssertEqual(restarted.first, "Spotify", "the picks are stored")
        // With nothing typed, the most opened come first.
        let empty = try await titles(again, "")
        XCTAssertEqual(empty.first, "Spotify", "\(empty)")
        await again.stop()
    }

    /// A pick never beats a much better match: an app whose name starts
    /// with the text still beats one that only has its letters in order.
    func testUsageDoesNotBeatABetterMatch() async throws {
        let host = host()
        let session = try await host.session("Applications")
        for _ in 0..<5 {
            try await pick("Slack", for: "sl", in: session, host: host)
        }
        let rows = try await titles(session, "sa")
        XCTAssertTrue(rows.contains("Slack"), "Slack matches \"sa\" by its letters in order")
        XCTAssertEqual(rows.first, "Safari", "\(rows)")
        await session.stop()
    }
}
