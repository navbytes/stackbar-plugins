import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class FileSearchTests: XCTestCase {
    func testOpenAndShowInFinderReachTheHost() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("plan-b4.txt")
        try Data("x".utf8).write(to: file)
        let host = Host(self)
        host.system.simulatedFiles = [FoundFile(path: file.path, name: "plan-b4.txt", folder: "~/tmp", lastUsed: Date())]
        let session = try await host.session("FileSearch")
        let opened = try await session.openView("search", query: CommandQuery(text: "plan"))
        let row = try XCTUnwrap(opened.root?.rows.first)
        try await session.event(try XCTUnwrap(row.actions.first { $0.title == "Open" }).id)
        let opening = await waitUntil { host.opened.all.contains { $0.url.hasSuffix("plan-b4.txt") } }
        XCTAssertTrue(opening, "\(host.opened.all)")
        try await session.event(try XCTUnwrap(row.actions.first { $0.title == "Show in Finder" }).id)
        let revealing = await waitUntil { host.opened.all.contains { $0.url.contains(folder.lastPathComponent) && !$0.url.hasSuffix("plan-b4.txt") } }
        XCTAssertTrue(revealing, "\(host.opened.all)")
        await session.stop()
    }

    func testGoingBackOverASearchAnswersFromMemory() async throws {
        let host = Host(self)
        host.system.simulatedFiles = [FoundFile(path: "/Users/you/Documents/Q3 plan.pdf", name: "Q3 plan.pdf", folder: "~/Documents", lastUsed: Date())]
        let session = try await host.session("FileSearch")
        let opened = try await session.openView("search", query: CommandQuery(text: "plan"))
        XCTAssertEqual(opened.root?.rows.map(\.title), ["Q3 plan.pdf"])
        // Spotlight would now find nothing, but a search typed again soon is answered from memory.
        host.system.simulatedFiles = []
        let again = try await session.updateView(opened.session, query: CommandQuery(text: "Plan"))
        XCTAssertEqual(again?.rows.map(\.title), ["Q3 plan.pdf"])
        let other = try await session.updateView(opened.session, query: CommandQuery(text: "invoice"))
        XCTAssertEqual(other?.rows.count, 0, "a new search still asks Spotlight")
        await session.stop()
    }

    // MARK: Scenarios (trust-first 3.1)

    /// Fewer than three letters asks for more instead of searching the disk.
    func testShortTextAsksForMoreAndAnEmptyResultSaysSo() async throws {
        let host = Host(self)
        let session = try await host.session("FileSearch")
        let short = try await session.openView("search", query: CommandQuery(text: "pl"))
        XCTAssertEqual(short.root?.rows.count ?? 0, 0)
        XCTAssertTrue("\(String(describing: short.root))".contains("Type a file name"), "\(String(describing: short.root))")
        let none = try await session.updateView(short.session, query: CommandQuery(text: "zzzqqq"))
        XCTAssertEqual(none?.rows.count ?? 0, 0)
        XCTAssertTrue("\(String(describing: none))".contains("No files found"), "\(String(describing: none))")
        await session.stop()
    }

    /// Every word must be in the name; the most recently used comes first;
    /// a folder is drawn as one.
    func testEveryWordMustMatchAndRecentComesFirst() async throws {
        let host = Host(self)
        let session = try await host.session("FileSearch")
        let opened = try await session.openView("search", query: CommandQuery(text: "plan"))
        XCTAssertEqual(opened.root?.rows.map(\.title), ["Q3 plan.pdf", "Plans", "plan sketch.png"])
        let folder = try XCTUnwrap(opened.root?.rows.first { $0.title == "Plans" })
        XCTAssertEqual(folder.subtitle, "~/Documents")
        let both = try await session.updateView(opened.session, query: CommandQuery(text: "q3 plan"))
        XCTAssertEqual(both?.rows.map(\.title), ["Q3 plan.pdf"])
        await session.stop()
    }

    /// ⌘K's Copy Path copies the whole path, and what was opened shows in
    /// the panel's "Opened lately", newest first, once each.
    func testCopyPathAndOpenedLately() async throws {
        // Opening asks the host, which opens only files that exist.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let files = try ["README.md", "invoice-2026-10.pdf"].map { name in
            let file = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: file)
            return FoundFile(path: file.path, name: name, folder: "~/tmp", lastUsed: Date())
        }
        let host = Host(self)
        host.system.simulatedFiles = files
        let session = try await host.session("FileSearch")
        let opened = try await session.openView("search", query: CommandQuery(text: "readme"))
        let readme = try XCTUnwrap(opened.root?.rows.first)
        try await session.event(try XCTUnwrap(readme.actions.first { $0.title == "Copy Path" }).id)
        let copied = await waitUntil { host.copies.all == [files[0].path] }
        XCTAssertTrue(copied, "\(host.copies.all)")
        await session.closeView(opened.session)

        for (count, text) in ["readme", "invoice", "readme"].enumerated() {
            let view = try await session.openView("search", query: CommandQuery(text: text))
            let row = try XCTUnwrap(view.root?.rows.first)
            try await session.event(try XCTUnwrap(row.actions.first { $0.title == "Open" }).id)
            // The palette closes on Return once the action is handled.
            let handled = await waitUntil { host.opened.all.count > count }
            XCTAssertTrue(handled, text)
            await session.closeView(view.session)
        }
        let listed = await waitUntil {
            await session.view(.panel)?.rows.map(\.title) == ["README.md", "invoice-2026-10.pdf"]
        }
        let panel = await session.view(.panel)
        XCTAssertTrue(listed, "\(panel?.rows.map(\.title) ?? [])")
        await session.stop()
    }
}

