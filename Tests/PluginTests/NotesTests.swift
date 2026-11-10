import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class NotesTests: XCTestCase {
    private func editor(_ supervisor: PluginSupervisor) async -> EditorNode? {
        func find(_ node: ViewNode) -> EditorNode? {
            if case .editor(let editor) = node { return editor }
            return node.children.lazy.compactMap(find).first
        }
        return await supervisor.views[.window].flatMap(find)
    }

    /// Runs Create Note and waits for the window to show a new document.
    @discardableResult
    private func newNote(_ supervisor: PluginSupervisor) async throws -> String? {
        let before = await editor(supervisor)?.document
        guard case .message = await supervisor.runCommand("new", source: .palette) else { XCTFail("creates a note"); return nil }
        _ = await waitUntil(2) { await self.editor(supervisor).map { $0.document != before } ?? false }
        return await editor(supervisor)?.document
    }

    private func type(_ text: String, in supervisor: PluginSupervisor) async throws {
        _ = await waitUntil { await self.editor(supervisor) != nil }
        let current = await editor(supervisor)
        let editor = try XCTUnwrap(current, "the window shows an editor")
        await supervisor.event(editor.action, value: .text(text))
        let saved = await waitUntil { await self.editor(supervisor)?.text == text }
        XCTAssertTrue(saved, "the note keeps what was typed")
    }

    private func titles(_ supervisor: PluginSupervisor) async -> [String] {
        await supervisor.views[.panel]?.rows.map(\.title) ?? []
    }

    func testTypedNotesAreSavedListedAndKeptAcrossRestarts() async throws {
        let host = Host(self)
        var supervisor = try await host.start("Notes")
        await supervisor.setVisible(.window, true)
        await supervisor.setVisible(.panel, true)
        let first = try await newNote(supervisor)
        try await type("# Groceries\n- [x] lemons\n- [ ] coffee", in: supervisor)
        let second = try await newNote(supervisor)
        XCTAssertNotEqual(first, second, "a new note is a new document")
        try await type("Standup\nShipped the editor", in: supervisor)
        _ = await waitUntil { await self.titles(supervisor).count == 2 }
        let listed = await titles(supervisor)
        XCTAssertEqual(listed, ["Standup", "Groceries"], "the newest first, titles without Markdown")
        let groceries = await supervisor.views[.panel]?.rows.first { $0.title == "Groceries" }
        XCTAssertEqual(groceries?.accessories, [.badge("1/2", role: .secondary)], "ticked tasks out of all")

        await supervisor.stop()
        supervisor = try await host.start("Notes")
        await supervisor.setVisible(.panel, true)
        _ = await waitUntil { await self.titles(supervisor).count == 2 }
        let kept = await titles(supervisor)
        XCTAssertEqual(kept, ["Standup", "Groceries"])
        await supervisor.stop()
    }

    func testDeletedNotesLeaveTheListAndPinsLead() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Notes")
        await supervisor.setVisible(.window, true)
        await supervisor.setVisible(.panel, true)
        for text in ["Alpha", "Beta", "Gamma"] {
            try await newNote(supervisor)
            try await type(text, in: supervisor)
        }
        _ = await waitUntil { await self.titles(supervisor).count == 3 }
        func action(_ title: String, on note: String) async -> ActionID? {
            await supervisor.views[.panel]?.rows.first { $0.title == note }?.actions.first { $0.title == title }?.id
        }
        let pin = await action("Pin", on: "Alpha")
        await supervisor.event(try XCTUnwrap(pin))
        _ = await waitUntil { await self.titles(supervisor).first == "Alpha" }
        let pinned = await titles(supervisor)
        XCTAssertEqual(pinned, ["Alpha", "Gamma", "Beta"], "a pinned note leads")

        let delete = await action("Delete", on: "Gamma")
        await supervisor.event(try XCTUnwrap(delete))
        _ = await waitUntil { await self.titles(supervisor).count == 2 }
        let left = await titles(supervisor)
        XCTAssertEqual(left, ["Alpha", "Beta"])
        await supervisor.stop()
    }

    func testAnEmptyNewNoteIsReusedNotPiledUp() async throws {
        let host = Host(self)
        let supervisor = try await host.start("Notes")
        await supervisor.setVisible(.window, true)
        await supervisor.setVisible(.panel, true)
        let first = try await newNote(supervisor)
        let again = try await newNote(supervisor)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, again, "Create Note on an empty note stays on it")
        _ = await waitUntil { await !self.titles(supervisor).isEmpty }
        let listed = await titles(supervisor)
        XCTAssertEqual(listed, ["Untitled"])
        await supervisor.stop()
    }
}
