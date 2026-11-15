import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_RecentProjects

final class RecentProjectsTests: XCTestCase {
    /// Settings offers the installed editors as the default, and keeps the
    /// one picked.
    func testDefaultEditorListsInstalledEditors() async throws {
        let system = SimulatedSystem()
        system.applications = ["Xcode": "com.apple.dt.Xcode", "Zed": "dev.zed.Zed", "Safari": "com.apple.Safari"]
        let supervisor = try await Host(self, system: system).start("RecentProjects")
        XCTAssertTrue(supervisor.manifest.surfaces.contains(.settings))

        let settings = await supervisor.views[.settings]
        let picker = try XCTUnwrap(settings?.pickers.first)
        XCTAssertEqual(picker.options, ["Where it was last opened", "Zed", "Xcode"])
        XCTAssertEqual(picker.selection, "Where it was last opened")

        await supervisor.press(picker.action, value: .text("Zed"))
        let picked = await supervisor.views[.settings]?.pickers.first?.selection
        XCTAssertEqual(picked, "Zed")

        await supervisor.press(picker.action, value: .text("Where it was last opened"))
        let reset = await supervisor.views[.settings]?.pickers.first?.selection
        XCTAssertEqual(reset, "Where it was last opened")
        await supervisor.stop()
    }

    /// VS Code 1.118 keeps its recent list in ~/.vscode-shared, so the plugin
    /// asks to read it as well as the old Application Support folder.
    func testReadsVSCodeSharedStorage() async throws {
        let supervisor = try await Host(self, system: SimulatedSystem()).start("RecentProjects")
        let paths = supervisor.manifest.capabilities.flatMap { capability -> [String] in
            if case .files(let paths) = capability { return paths }
            return []
        }
        XCTAssertTrue(paths.contains("~/.vscode-shared/sharedStorage"))
        XCTAssertTrue(paths.contains("~/Library/Application Support/Code/User/globalStorage"))
        // The forks get the same shared folder for when they rebase on 1.118,
        // and Zed's database folders are read too.
        for folder in ["~/.cursor-shared/sharedStorage", "~/.windsurf-shared/sharedStorage", "~/.vscode-oss-shared/sharedStorage", "~/.vscode-insiders-shared/sharedStorage",
                       "~/Library/Application Support/Cursor/User/globalStorage", "~/Library/Application Support/Code - Insiders/User/globalStorage",
                       "~/Library/Application Support/Zed/db/0-stable", "~/Library/Application Support/Zed/db/0-preview"] {
            XCTAssertTrue(paths.contains(folder), folder)
        }
        await supervisor.stop()
    }

    @MainActor func testRemoteEntriesAreCountedNotListed() async {
        let json = #"{"entries":[{"folderUri":"file:///Users/me/app"},{"folderUri":"vscode-remote://ssh-remote+box/home/me/api"},{"workspace":{"configPath":"vscode-remote://dev-container+1/w.code-workspace"}}]}"#
        XCTAssertEqual(RecentProjects.parse(json, editor: "VS Code").map(\.path), ["/Users/me/app"])
        XCTAssertEqual(RecentProjects.remoteCount(json), 2)
    }

    /// What `sqlite3 -json` prints for Zed's `workspaces.paths`: one row a
    /// workspace, its folders one a line.
    @MainActor func testZedWorkspacesAreReadByTheirFirstFolder() async {
        let json = #"[{"paths":"/Users/me/zed-app"},{"paths":"/Users/me/mono/web\n/Users/me/mono/api"},{"paths":""},{"paths":null},{"paths":"relative/path"}]"#
        let projects = RecentProjects.parseZed(json, editor: "Zed")
        XCTAssertEqual(projects.map(\.path), ["/Users/me/zed-app", "/Users/me/mono/web"])
        XCTAssertEqual(projects.map(\.kind), [.folder, .folder])
        XCTAssertEqual(projects.map(\.editor), ["Zed", "Zed"])
    }

    @MainActor func testAnEmptyOrDamagedZedAnswerListsNothing() async {
        for text in ["", "\n", "[]", "not json", #"{"paths":"/x"}"#] {
            XCTAssertTrue(RecentProjects.parseZed(text, editor: "Zed").isEmpty, text)
        }
    }

    /// Zed opens a project with the app; the VS Code family by its link.
    @MainActor func testZedOpensWithTheAppAndTheVSCodeFamilyByLink() async {
        XCTAssertNil(RecentProjects.app(named: "Zed")?.scheme)
        XCTAssertEqual(RecentProjects.app(named: "Zed")?.bundleID, "dev.zed.Zed")
        XCTAssertEqual(RecentProjects.app(named: "VS Code Insiders")?.scheme, "vscode-insiders")
        XCTAssertEqual(RecentProjects.apps.filter { $0.name == "Zed" }.count, 1, "listed once")
    }
}

extension ViewNode {
    /// Pickers anywhere below, as (options, selection, action).
    var pickers: [(options: [String], selection: String?, action: ActionID)] {
        tree.compactMap { node in
            if case .picker(_, let options, let selection, _, let action) = node { return (options, selection, action) }
            return nil
        }
    }
}
