import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_BrowserTabs

final class BrowserTabsTests: XCTestCase {
    /// Inside `tell application`, `tab` is the browser's tab class, so the
    /// separators must be made before it.
    @MainActor func testTheListScriptMakesItsSeparatorsOutsideTheTell() async {
        for browser in BrowserTabs.browsers {
            let script = BrowserTabs.listScript(browser)
            let inside = script.components(separatedBy: "tell application").dropFirst().joined()
            XCTAssertFalse(inside.contains("& tab &"), "\(browser.name): a bare tab inside the tell joins as the word \"tab\"")
            XCTAssertTrue(script.hasPrefix("set sep to character id 9"), browser.name)
            let perTab = BrowserTabs.perTabListScript(browser)
            let perTabInside = perTab.components(separatedBy: "tell application").dropFirst().joined()
            XCTAssertFalse(perTabInside.contains("& tab &"), browser.name)
        }
    }

    /// Two Apple Events a browser, not two a tab: the browser is asked for
    /// every title and every address at once, and the lines are joined after
    /// `end tell`.
    @MainActor func testTheListScriptAsksEachBrowserOnceForEveryTab() async {
        for browser in BrowserTabs.browsers {
            let script = BrowserTabs.listScript(browser)
            let tell = script.components(separatedBy: "end tell")[0]
            XCTAssertTrue(tell.contains("\(browser.safari ? "name" : "title") of every tab of every window"), browser.name)
            XCTAssertTrue(tell.contains("URL of every tab of every window"), browser.name)
            XCTAssertFalse(tell.contains("repeat"), "\(browser.name): no loop may ask the browser a tab at a time")
        }
    }

    @MainActor func testAppleScriptStringsAreEscaped() async {
        XCTAssertEqual(BrowserTabs.quoted(#"https://e.com/?q="a"\b"#), #""https://e.com/?q=\"a\"\\b""#)
    }

    /// A switch checks the slot in the same script, so it needs no read of
    /// every tab first.
    @MainActor func testTheCheckedSwitchConfirmsThePageBeforeSwitching() async {
        let tab = BrowserTabs.Tab(browser: "Google Chrome", window: 2, index: 3, title: "Docs", url: #"https://e.com/"x""#)
        let script = BrowserTabs.checkedFocusScript(tab, safari: false)
        XCTAssertTrue(script.contains(#"(URL of tab 3 of window 2) as text is not "https://e.com/\"x\"" then return "moved""#), script)
        XCTAssertTrue(script.contains("set active tab index of window 2 to 3"))
        XCTAssertTrue(script.hasSuffix("return \"ok\""))
    }

    // MARK: Search answers at once

    /// A stand-in osascript: each list read waits `delay` seconds and
    /// answers one tab titled "Page <n>", n counting the reads.
    private func stubHost(delay: Double) throws -> (host: Host, log: URL) {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: bin) }
        let log = bin.appendingPathComponent("reads.log")
        let script = bin.appendingPathComponent("osascript")
        try """
        #!/bin/sh
        echo read >> '\(log.path)'
        n=$(wc -l < '\(log.path)' | tr -d ' ')
        sleep \(delay)
        printf '1\\t1\\tPage %s\\thttps://e.com/%s\\n' "$n" "$n"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let gate = CommandRunGate(root: bin.appendingPathComponent("runs", isDirectory: true), resolver: CommandResolver(directories: [bin.path]))
        let system = SimulatedSystem()
        system.simulate(apps: [RunningApp(id: "com.google.Chrome", name: "Google Chrome")])
        return (Host(self, system: system, runs: gate), log)
    }

    private func text(_ root: ViewNode?) -> String {
        root.map { TreeTextRenderer.render($0) } ?? "nothing"
    }

    private func reads(_ log: URL) -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    /// The view answers from the tabs in hand while it reads them again,
    /// then redraws with the fresh list: opening never waits on the browsers.
    func testSearchAnswersFromTheTabsInHandAndRedrawsWhenTheReadLands() async throws {
        let (host, log) = try stubHost(delay: 1.5)
        let session = try await host.session("BrowserTabs")
        // The launch read.
        let launched = await waitUntil { self.reads(log) >= 1 }
        XCTAssertTrue(launched)
        let first = try await session.openView("tabs")
        XCTAssertTrue(text(first.root).contains("Page 1"), text(first.root))

        try await Task.sleep(for: .seconds(2.1))
        let started = Date()
        let typed = try await session.updateView(first.session, query: CommandQuery(text: "page"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the search waited for the browsers")
        XCTAssertTrue(text(typed).contains("Page 1"), text(typed))
        let redrawn = await waitUntil(10) { await self.text(session.commandView(first.session)).contains("Page 2") }
        let shown = await text(session.commandView(first.session))
        XCTAssertTrue(redrawn, shown)
        XCTAssertEqual(reads(log), 2, "one read at launch and one behind the search")
        await session.stop()
    }

    @MainActor func testParseTabsReadsEachLine() async {
        let text = "1\t1\tStackbar\thttps://stackbar.app\n1\t2\tA\ttitle\twith tabs\thttps://example.com\n2\t1\tmissing value\thttps://x.dev\n"
        let tabs = BrowserTabs.parseTabs(text, browser: "Safari")
        XCTAssertEqual(tabs.map(\.title), ["Stackbar", "A\ttitle\twith tabs", "https://x.dev"])
        XCTAssertEqual(tabs.map(\.window), [1, 1, 2])
        XCTAssertEqual(tabs.map(\.index), [1, 2, 1])
    }

    @MainActor func testParseTabsSkipsLinesThatDidNotSplit() async {
        // What the old script printed: the word "tab" where a tab belonged.
        XCTAssertTrue(BrowserTabs.parseTabs("1tab1tabStackbartabhttps://stackbar.app\n", browser: "Safari").isEmpty)
    }

    // MARK: Profiles and bookmarks

    @MainActor func testProfilesComeFromLocalStateDefaultFirstThenTheBrowsersOrder() async {
        let state = Data(#"{"profile":{"info_cache":{"Profile 2":{"name":"Side"},"Profile 1":{"name":"Work"},"Default":{"name":"Person 1"},"../escape":{"name":"x"}},"profiles_order":["Profile 2","Default","Profile 1"]}}"#.utf8)
        let profiles = BrowserTabs.parseProfiles(state)
        XCTAssertEqual(profiles.map(\.folder), ["Default", "Profile 2", "Profile 1"], "a folder name that leaves the browser's folder is dropped")
        XCTAssertEqual(profiles.map(\.name), ["Person 1", "Side", "Work"])
    }

    @MainActor func testAnUnreadableLocalStateFallsBackToTheDefaultProfile() async {
        for data in [Data(), Data("{ not json".utf8), Data(#"{"profile":{"info_cache":{}}}"#.utf8)] {
            XCTAssertEqual(BrowserTabs.parseProfiles(data).map(\.folder), ["Default"])
        }
    }

    @MainActor func testAProfileWithNoNameIsCalledByItsFolder() async {
        let state = Data(#"{"profile":{"info_cache":{"Profile 3":{"name":"  "}}}}"#.utf8)
        XCTAssertEqual(BrowserTabs.parseProfiles(state).map(\.name), ["Profile 3"])
    }

    @MainActor func testBookmarksCarryTheirProfile() async {
        let file = Data(#"{"roots":{"bookmark_bar":{"type":"folder","name":"Bar","children":[{"type":"folder","name":"Docs","children":[{"type":"url","name":"Swift","url":"https://swift.org"}]},{"type":"url","name":"","url":"https://stackbar.app"},{"type":"url","name":"Local","url":"file:///tmp"}]}}}"#.utf8)
        let found = BrowserTabs.parseBookmarks(file, browser: "Google Chrome", profile: "Work")
        XCTAssertEqual(found.map(\.title), ["Swift", "https://stackbar.app"])
        XCTAssertEqual(found.map(\.folder), ["Bar › Docs", "Bar"])
        XCTAssertEqual(found.map(\.profile), ["Work", "Work"])
        XCTAssertNotEqual(found[0].id, BrowserTabs.Bookmark(title: "Swift", url: "https://swift.org", folder: "Bar › Docs", browser: "Google Chrome", profile: "Home").id)
    }

    /// Past the cap the panel says how many were left out instead of
    /// dropping them quietly; an address kept twice counts once.
    @MainActor func testKeptBookmarksAreCappedAndCountWhatWasLeftOut() async {
        let many = (0..<25).map { BrowserTabs.Bookmark(title: "\($0)", url: "https://e.com/\($0)", folder: "", browser: "Vivaldi") }
        let again = BrowserTabs.Bookmark(title: "dup", url: "https://e.com/0", folder: "", browser: "Google Chrome")
        let kept = BrowserTabs.kept(many + [again], limit: 20)
        XCTAssertEqual(kept.bookmarks.count, 20)
        XCTAssertEqual(kept.leftOut, 5)
        XCTAssertEqual(BrowserTabs.kept(many + [again]).leftOut, 0)
        XCTAssertEqual(BrowserTabs.counted(12345), "12,345")
    }

    @MainActor func testEveryChromiumBrowserGrantsItsWholeDataFolder() async {
        for browser in BrowserTabs.browsers where !browser.safari && browser.name != "Arc" {
            let folder = try? XCTUnwrap(browser.dataFolder)
            XCTAssertFalse(folder?.hasSuffix("/Default") ?? true, browser.name)
        }
        let manifest = BrowserTabs.manifest
        XCTAssertTrue(manifest.capabilities.contains(.files(paths: BrowserTabs.browsers.compactMap(\.dataFolder))))
    }
}
