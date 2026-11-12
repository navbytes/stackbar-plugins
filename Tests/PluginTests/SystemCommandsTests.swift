import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class SystemCommandsTests: XCTestCase {
    func testADestructiveRowAsksStackbarForASecondClick() async throws {
        let host = Host(self)
        let supervisor = try await host.start("SystemCommands")
        let panel = await supervisor.views[.panel]
        let row = try XCTUnwrap(panel?.rows.first { $0.title == "Restart" })
        let action = try XCTUnwrap(row.actions.first)
        XCTAssertEqual(action.role, .critical)
        XCTAssertEqual(action.confirm, "restart the Mac", "Stackbar holds the first click and asks")
        let lock = try XCTUnwrap(panel?.rows.first { $0.title == "Lock Screen" })
        XCTAssertNil(lock.actions.first?.confirm, "harmless commands run at once")

        // The press Stackbar lets through, the second, runs it.
        await supervisor.press(action.id)
        XCTAssertEqual(host.system.performed, [.restart])
        await supervisor.stop()
    }

    /// From the palette, nothing that loses work runs on the first Return:
    /// each destructive command opens a "… Now" row and waits; the rest run
    /// at once, and only the one asked for.
    func testFromThePaletteOnlyHarmlessCommandsRunAtOnce() async throws {
        let destructive = ["empty-trash", "quit-other-apps", "log-out", "restart", "shut-down"]
        let harmless: [(String, SystemAction)] = [
            ("lock-screen", .lockScreen), ("sleep", .sleep), ("sleep-displays", .sleepDisplays), ("screen-saver", .startScreenSaver),
            ("toggle-dark-mode", .toggleDarkMode), ("hide-other-apps", .hideOtherApps), ("eject-disks", .ejectDisks),
        ]
        let host = Host(self)
        let session = try await host.session("SystemCommands")
        for id in destructive {
            let opened = try await session.openView(id)
            let row = try XCTUnwrap(opened.root?.rows.first, id)
            XCTAssertTrue(row.title.hasSuffix(" Now"), "\(id) asks with a row that says what happens")
            XCTAssertEqual(host.system.performed, [], "\(id) ran on the first Return")
        }
        for (id, action) in harmless {
            _ = try await session.runCommand(id)
            XCTAssertEqual(host.system.performed.last, action, id)
        }
        XCTAssertEqual(host.system.performed, harmless.map(\.1), "each ran once, and nothing else did")
        await session.stop()
    }
}
