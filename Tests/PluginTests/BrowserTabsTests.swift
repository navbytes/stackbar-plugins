import Foundation
import XCTest
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
        }
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
