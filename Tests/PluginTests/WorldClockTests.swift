import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class WorldClockTests: XCTestCase {
    private let addField: ActionID = "field/Add a city or time zone, like Tokyo"

    func testFindsCitiesByTheirCommonNames() async throws {
        let host = Host(self)
        let session = try await host.session("WorldClock")
        let expected: [(query: String, zone: String)] = [
            ("time in mumbai", "Asia/Kolkata"),
            ("san francisco", "America/Los_Angeles"),
            ("time in nyc", "America/New_York"),
            ("bangalore time", "Asia/Kolkata"),
            ("time in são paulo", "America/Sao_Paulo"),
            ("time in pst", "America/Los_Angeles"),
            ("beijing", "Asia/Shanghai"),
            ("tokyo?", "Asia/Tokyo"),
        ]
        for (query, zone) in expected {
            let opened = try await session.openView("time-in", query: CommandQuery(text: query))
            XCTAssertEqual(opened.root?.rows.first?.key, zone, query)
        }
        for query in ["sf", "eat", "hello"] {
            let opened = try await session.openView("time-in", query: CommandQuery(text: query))
            XCTAssertEqual(opened.root?.rows.count ?? 0, 0, "\(query) is not a city")
        }
        await session.stop()
    }

    func testAddsACityByItsCommonName() async throws {
        let host = Host(self)
        let supervisor = try await host.start("WorldClock")

        // Kolkata is a starting city, and Mumbai is in that zone, so it's refused until Kolkata goes.
        await supervisor.press(addField, value: .text("Mumbai"))
        var settings = await supervisor.views[.settings].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(settings.contains("Kolkata is already in your list"), settings)

        await supervisor.press("row/zone-Asia/Kolkata/Remove")
        await supervisor.press(addField, value: .text("Mumbai"))
        let times = await supervisor.callTool("times").text
        XCTAssertTrue(times.contains("Mumbai: "), times)

        await supervisor.press(addField, value: .text("Atlantis"))
        settings = await supervisor.views[.settings].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(settings.contains("No city or time zone called “Atlantis”"), settings)
        let unchanged = await supervisor.callTool("times").text
        XCTAssertEqual(unchanged, times, "a city that isn't found changes nothing")
        await supervisor.stop()
    }

    func testRemovingTheMenuBarCityMovesTheMenuBar() async throws {
        let host = Host(self)
        let supervisor = try await host.start("WorldClock")
        let before = await supervisor.views[.menuBar].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertTrue(before.contains("London"), before)

        await supervisor.press("row/zone-Europe/London/Remove")
        let bar = await supervisor.views[.menuBar].map { TreeTextRenderer.render($0) } ?? ""
        XCTAssertFalse(bar.contains("London"), bar)
        XCTAssertTrue(bar.contains("Los Angeles"), "the next city takes the menu bar: \(bar)")
        await supervisor.stop()
    }

    func testCopiesEveryCitysTime() async throws {
        let host = Host(self)
        let session = try await host.session("WorldClock")
        guard case .copy(let text) = try await session.runCommand("copy-times") else {
            return XCTFail("copy-times copies the times")
        }
        XCTAssertTrue(text.contains("London") && text.contains("here"), text)
        await session.stop()
    }
}
