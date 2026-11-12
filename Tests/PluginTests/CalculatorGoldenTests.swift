import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol
@testable import Plugin_Calculator

/// Sums people type into a launcher, with the answer a calculator must give.
/// A wrong sum is the one thing a user never forgives, so every case here
/// runs through the real plugin, as the palette asks it.
final class CalculatorGoldenTests: XCTestCase {
    private static let golden: [(String, String?)] = [
        // Precedence, signs and brackets.
        ("2+3*4", "14"), ("(2+3)*4", "20"), ("10-2-3", "5"), ("100/10/2", "5"), ("-5+3", "-2"),
        ("2*-3", "-6"), ("-(2+3)", "-5"), ("((1+2)*(3+4))", "21"), ("8/3*3", "8"),
        // Powers.
        ("2^10", "1024"), ("2^3^2", "512"), ("-2^2", "-4"),
        // Floats a person expects to be exact.
        ("0.1+0.2", "0.3"), ("1/3*3", "1"), ("0.1*3", "0.3"), ("1.5*1.5", "2.25"), ("10/4", "2.5"),
        // Big and small.
        ("1000000*1000000", "1000000000000"), ("1/8", "0.125"), ("7/2", "3.5"),
        // Functions and constants a calculator row offers.
        ("sqrt(16)", "4"), ("pi*2", "6.283185307"),
        // Spaces and the multiplication sign people paste.
        ("2 + 2", "4"), ("3 × 4", "12"), ("12 ÷ 4", "3"),
        // Not sums: no row, never a wrong one.
        ("1/0", nil), ("2+", nil), ("()", nil), ("hello", nil), ("1..2", nil),
    ]

    func testEverydaySumsGiveTheRightAnswer() async throws {
        let host = Host(self)
        let session = try await host.session("Calculator")
        var misses: [String] = []
        for (text, expected) in Self.golden {
            let opened = try await session.openView("calculate", query: CommandQuery(text: text))
            let title = opened.root?.rows.first { $0.title.hasPrefix(text) }?.title
            let want = expected.map { "\(text) = \($0)" }
            if title != want { misses.append("\"\(text)\": expected \(want ?? "no answer"), got \(title ?? "no answer")") }
        }
        await session.stop()
        XCTAssert(misses.isEmpty, "\(misses.count) of \(Self.golden.count) sums wrong:\n" + misses.joined(separator: "\n"))
    }
}
