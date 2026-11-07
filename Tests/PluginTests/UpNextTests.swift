import Foundation
import XCTest
import StackbarHostCore
import StackbarProtocol

final class UpNextTests: XCTestCase {
    func testFindsTheMeetingAndItsLink() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "a", title: "Planning", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400), notes: "Join Zoom Meeting\nhttps://acme.zoom.us/j/987654321?pwd=xyz.", calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "b", title: "Declined thing", start: now.addingTimeInterval(300), end: now.addingTimeInterval(900), location: "https://meet.google.com/aaa-bbbb-ccc", calendar: "Work", participation: .declined),
        ]))
        let supervisor = try await host.start("UpNext")
        let menu = await supervisor.views[.menuBar]?.plainText ?? ""
        XCTAssertTrue(menu.contains("Planning") && !menu.contains("Declined thing"), "a declined meeting is skipped even when it's sooner: \(menu)")
        let next = await supervisor.callTool("next_meeting")
        XCTAssertTrue(next.text.contains("https://acme.zoom.us/j/987654321?pwd=xyz"), "trailing punctuation is trimmed: \(next.text)")
        let rows = await supervisor.views[.panel]?.rows.map(\.title) ?? []
        XCTAssertEqual(rows.first, "Planning", "the next meeting is the first row, so Return joins it: \(rows)")
        XCTAssertFalse(rows.contains("Declined thing"))
        await supervisor.stop()
    }

    func testAReminderHasAJoinButton() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(90), end: now.addingTimeInterval(1800), location: "https://meet.google.com/abc-defg-hij", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let posted = await waitUntil(5) { !host.notifications.all.isEmpty }
        XCTAssertTrue(posted, "a meeting in 90 seconds is reminded about")
        XCTAssertEqual(host.notifications.all.first?.actions.map(\.url), ["https://meet.google.com/abc-defg-hij", ""])
        XCTAssertEqual(host.notifications.all.first?.actions.last, NotificationAction("Snooze 5 Min", command: "snooze", arguments: ["event": "soon"]))
        await supervisor.stop()
    }

    func testQuickAddAndSnooze() async throws {
        let now = Date()
        let system = SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(90), end: now.addingTimeInterval(1800), calendar: "Work", participation: .accepted, attendees: 3),
        ])
        let host = Host(self, system: system)
        let session = try await host.session("UpNext")
        let lunch = try await addFromView("Lunch with Sam tomorrow 1pm for 45m", session, system)
        assertAdded(lunch, "Lunch with Sam", at(13, 0, day: 1, from: now), minutes: 45, "Lunch with Sam tomorrow 1pm for 45m")

        let offsite = try await addFromView("Offsite fri", session, system)
        XCTAssertEqual(offsite?.title, "Offsite")
        XCTAssertEqual(offsite?.isAllDay, true, "a day without a time is all day")
        let untitled = try await addFromView("tomorrow 3pm", session, system)
        XCTAssertNil(untitled, "a time without a title adds nothing")

        guard case .message(let snoozed) = try await session.runCommand("snooze", arguments: ["event": "soon"]) else { return XCTFail("snooze answers") }
        XCTAssertEqual(snoozed, "Reminding you about Sync in 5 min")
    }

    func testDialsInAndCoversTheScreen() async throws {
        let now = Date()
        let notes = "Join Zoom Meeting\nhttps://acme.zoom.us/j/123456789\n\nOne tap mobile\n+16465588656,,123456789# US (New York)"
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "z", title: "Board call", start: now.addingTimeInterval(30), end: now.addingTimeInterval(1800), notes: notes, calendar: "Work", participation: .accepted, attendees: 5),
        ]))
        let supervisor = try await host.start("UpNext")
        let dial = "tel:+16465588656,,123456789%23"

        // The meeting's row can call in: its Call in action opens the number.
        let rows = await supervisor.views[.panel]?.rows ?? []
        let row = try XCTUnwrap(rows.first { $0.title == "Board call" })
        let callIn = try XCTUnwrap(row.actions.first { $0.title.hasPrefix("Call in") })
        await supervisor.press(callIn.id)
        XCTAssertTrue(host.opened.all.contains { $0.url == dial }, "\(host.opened.all)")
        XCTAssertTrue(host.alerts.all.isEmpty, "the full-screen alert is off by default")

        // The setting has no key, so its title is the only way to find it.
        let toggle = await supervisor.views[.settings]?.toggles.first { $0.title.contains("Cover the screen") }
        await supervisor.press(try XCTUnwrap(toggle, "no full-screen toggle in settings").action, value: .bool(true))
        let before = await supervisor.settledCount
        await supervisor.refresh()
        _ = await waitUntil { await supervisor.settledCount > before }
        let shown = await waitUntil(5) { !host.alerts.all.isEmpty }
        XCTAssertTrue(shown, "a meeting starting within a minute covers the screen")
        XCTAssertEqual(host.alerts.all.first?.title, "Board call")
        XCTAssertEqual(host.alerts.all.first?.actions.map(\.url), ["zoommtg://acme.zoom.us/join?action=join&confno=123456789", dial], "join in the Zoom app, then call in")
        await supervisor.stop()
    }

    func testCountsMeetingHoursOnceAndChartsTheWeek() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "a", title: "Planning", start: now.addingTimeInterval(600), end: now.addingTimeInterval(4200), calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "b", title: "Overlapping", start: now.addingTimeInterval(2400), end: now.addingTimeInterval(6000), calendar: "Home", participation: .accepted, attendees: 2),
        ]))
        let supervisor = try await host.start("UpNext")
        // 10 min → 100 min overlapping 40 → 100 min: 1.5 hours once, not 2.
        let today = Calendar.current.isDate(now.addingTimeInterval(6000), inSameDayAs: now)
        let rendered = await supervisor.views[.window]
        let window = try XCTUnwrap(rendered)
        let week = try XCTUnwrap(window.charts.first { $0.kind == .bar }, "the window charts the week's meeting load")
        XCTAssertEqual(week.values.count, 7)
        if today {
            XCTAssertEqual(week.values.first, 1.5)
            let header = await supervisor.views[.panel]?.tree.contains { node in
                if case .text(let text, _, _) = node { return text.contains("· 1h 30m · Free until ") }
                return false
            }
            XCTAssertEqual(header, true, "the panel's header says today's hours, and how long you're free")
            let clashes = await supervisor.views[.panel]?.tree.filter { node in
                if case .row(let row) = node { return row.accessories.contains(.badge("Clashes", role: .warning)) }
                return false
            }.count
            XCTAssertEqual(clashes, 2, "both overlapping meetings are flagged")
            let byCalendar = window.charts.first { $0.kind == .donut }
            XCTAssertEqual(byCalendar?.values.sorted(), [1, 1], "today split by calendar")
        }
        await supervisor.stop()
    }

    func testAPlainHttpLinkBeforeAnHttpsOneIsFound() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "a", title: "Planning", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400), notes: "Join http://acme.zoom.us/j/987654321 (agenda: https://example.com/agenda)", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let next = await supervisor.callTool("next_meeting")
        XCTAssertTrue(next.text.contains("http://acme.zoom.us/j/987654321"), next.text)
        await supervisor.stop()
    }

    // MARK: Add event

    func testAddEventReadsTimesAndTheirWords() async throws {
        let now = Date()
        let system = SimulatedSystem(events: [])
        let session = try await Host(self, system: system).session("UpNext")
        let cases: [(text: String, title: String, start: Date, minutes: Double)] = [
            ("Call with Ana at 5 pm", "Call with Ana", nextAt(17, 0, from: now), 60),
            ("Lunch at 12", "Lunch", nextAt(12, 0, from: now), 60),
            ("Lunch at 13", "Lunch", nextAt(13, 0, from: now), 60),
            ("Standup 10.30am", "Standup", nextAt(10, 30, from: now), 60),
            ("Dentist 12/11 9:30am", "Dentist 12/11", nextAt(9, 30, from: now), 60),
            ("Call Ana at 9:30 for 2 hrs", "Call Ana", nextAt(9, 30, from: now), 120),
            ("Call at the office tomorrow 3pm", "Call at the office", at(15, 0, day: 1, from: now), 60),
            ("3D printing review tomorrow 3pm", "3D printing review", at(15, 0, day: 1, from: now), 60),
        ]
        for (text, title, start, minutes) in cases {
            assertAdded(try await addFromView(text, session, system), title, start, minutes: minutes, text)
        }
        let untitled = try await addFromView("tomorrow 3pm", session, system)
        XCTAssertNil(untitled, "\"tomorrow 3pm\" has no title")
    }

    func testAddEventReadsLengths() async throws {
        let now = Date()
        let system = SimulatedSystem(events: [])
        let session = try await Host(self, system: system).session("UpNext")
        let cases: [(text: String, title: String, start: Date, minutes: Double)] = [
            ("Sync tomorrow 3pm for 30 minutes", "Sync", at(15, 0, day: 1, from: now), 30),
            ("Workshop tomorrow 9am for 1h30", "Workshop", at(9, 0, day: 1, from: now), 90),
            ("Call Ana tomorrow 2pm 45 min", "Call Ana", at(14, 0, day: 1, from: now), 45),
            ("Call tomorrow 2pm for 1 hour", "Call", at(14, 0, day: 1, from: now), 60),
            ("Demo tomorrow 4pm for 1.5 hours", "Demo", at(16, 0, day: 1, from: now), 90),
            ("Call tomorrow 2pm 30min", "Call", at(14, 0, day: 1, from: now), 30),
            ("Lunch with Sam tomorrow 1pm for 45m", "Lunch with Sam", at(13, 0, day: 1, from: now), 45),
        ]
        for (text, title, start, minutes) in cases {
            assertAdded(try await addFromView(text, session, system), title, start, minutes: minutes, text)
        }
    }

    func testAddEventDayWordsCountOnlyAtTheEndOfThePhrase() async throws {
        let now = Date()
        let system = SimulatedSystem(events: [])
        let session = try await Host(self, system: system).session("UpNext")

        // "sat" is in the title here: "tomorrow" is the day.
        assertAdded(try await addFromView("Review sat scores tomorrow 9am", session, system), "Review sat scores", at(9, 0, day: 1, from: now), minutes: 60, "Review sat scores tomorrow 9am")
        assertAdded(try await addFromView("Dentist fri 9:30", session, system), "Dentist", nextWeekday(6, 9, 30, from: now), minutes: 60, "Dentist fri 9:30")
        assertAdded(try await addFromView("Lunch fri at 12 for 30 minutes", session, system), "Lunch", nextWeekday(6, 12, 0, from: now), minutes: 30, "Lunch fri at 12 for 30 minutes")

        let offsite = try await addFromView("Offsite fri", session, system)
        XCTAssertEqual(offsite?.isAllDay, true)
        XCTAssertEqual(offsite?.start, Calendar.current.startOfDay(for: weekdayDay(6, from: now)), "all day on that Friday")

        let next = try await addFromView("Offsite next monday", session, system)
        XCTAssertEqual(next?.isAllDay, true)
        XCTAssertEqual(next.map { Calendar.current.component(.weekday, from: $0.start) }, 2, "a Monday")
        XCTAssertGreaterThan(next?.start ?? now, now)
    }

    func testAWeekdayWhoseTimeHasPassedRollsAWeekForward() async throws {
        let now = Date()
        let calendar = Calendar.current
        let system = SimulatedSystem(events: [])
        let session = try await Host(self, system: system).session("UpNext")
        // Today's weekday, at an hour that has already passed.
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let today = names[calendar.component(.weekday, from: now) - 1]
        let past = max(0, calendar.component(.hour, from: now) - 1)
        let added = try await addFromView("Dentist \(today) \(past):00", session, system)
        assertAdded(added, "Dentist", at(past, 0, day: 7, from: now), minutes: 60, "Dentist \(today) \(past):00")
    }

    func testAddEventShowsEachCalendarDefaultFirstAndSavesToThePickedOne() async throws {
        let now = Date()
        let system = SimulatedSystem(events: [])
        let session = try await Host(self, system: system).session("UpNext")
        let opened = try await session.openView("add-event", query: CommandQuery(text: "Lunch tomorrow 1pm"))
        XCTAssertEqual(opened.root?.rows.map(\.key), ["work", "home"], "one row per writable calendar, the default first")
        XCTAssertTrue(opened.root?.rows.first?.title.contains("· Work") == true, "each row previews the event on its calendar")
        let home = try XCTUnwrap(opened.root?.rows.last?.actions.first?.id)
        try await session.event(home)
        await session.closeView(opened.session)
        let saved = try await system.calendarEvents(from: now, to: now.addingTimeInterval(3 * 86_400)).first { $0.title == "Lunch" }
        XCTAssertEqual(saved?.calendar, "Home", "the row's calendar gets the event")
    }

    func testTheAddEventViewReadsTheTextFromALink() async throws {
        let session = try await Host(self, system: SimulatedSystem(events: [])).session("UpNext")
        // An old link passes its text as an argument, not as typed text.
        let opened = try await session.openView("add-event", query: CommandQuery(arguments: ["text": "Dentist tomorrow 9am"]))
        XCTAssertEqual(opened.root?.rows.first?.title.hasPrefix("Dentist — Tomorrow "), true, "the link's text is previewed")
        await session.closeView(opened.session)
    }

    // MARK: Auto-join

    func testAutoJoinOpensTheMeetingYoureInInItsApp() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(10), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/111222333", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        try await turnOn(supervisor, "Open the call when it starts")
        await reread(supervisor)
        let joined = await waitUntil(5) { !host.opened.all.isEmpty }
        XCTAssertTrue(joined, "the meeting starting in ten seconds is joined")
        XCTAssertEqual(host.opened.all.first?.url, "zoommtg://acme.zoom.us/join?action=join&confno=111222333", "in the Zoom app, as the Open Zoom setting says")
        await supervisor.stop()
    }

    func testAutoJoinSkipsATentativeOrPendingMeeting() async throws {
        for participation in [CalendarEvent.Participation.tentative, .pending] {
            let now = Date()
            let host = Host(self, system: SimulatedSystem(events: [
                CalendarEvent(id: "maybe", title: "Maybe", start: now.addingTimeInterval(10), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/111", calendar: "Work", participation: participation, attendees: 3),
            ]))
            let supervisor = try await host.start("UpNext")
            try await turnOn(supervisor, "Open the call when it starts")
            await reread(supervisor)
            XCTAssertTrue(host.opened.all.isEmpty, "a \(participation) meeting is never joined for you")
            await supervisor.stop()
        }
    }

    func testAManualJoinHoldsBackAutoJoinForAMinute() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "later", title: "Later", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200), location: "https://acme.zoom.us/j/222", calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "soon", title: "Soon", start: now.addingTimeInterval(10), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/333", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        try await turnOn(supervisor, "Open the call when it starts")
        // Join the later one by hand; the next one starts in ten seconds.
        try await pressAction("Join on Zoom", onRow: "Later", supervisor)
        await reread(supervisor)
        XCTAssertEqual(host.opened.all.map(\.url), ["zoommtg://acme.zoom.us/join?action=join&confno=222"], "Soon isn't joined a moment after a join")
        await supervisor.stop()
    }

    // MARK: Alerts, reminders and links

    func testMeetingsStartingTogetherShareOneFullScreenAlert() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "a", title: "Board call", start: now.addingTimeInterval(20), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/444", calendar: "Work", participation: .accepted, attendees: 5),
            CalendarEvent(id: "b", title: "Design review", start: now.addingTimeInterval(40), end: now.addingTimeInterval(1800), location: "https://meet.google.com/abc-defg-hij", calendar: "Work", participation: .accepted, attendees: 4),
        ]))
        let supervisor = try await host.start("UpNext")
        try await turnOn(supervisor, "Cover the screen")
        await reread(supervisor)
        let shown = await waitUntil(5) { !host.alerts.all.isEmpty }
        XCTAssertTrue(shown, "two meetings starting within a minute cover the screen")
        XCTAssertEqual(host.alerts.all.count, 1, "one alert for both: the host allows one a minute")
        XCTAssertEqual(host.alerts.all.first?.title, "2 meetings starting")
        let body = host.alerts.all.first?.body ?? ""
        XCTAssertTrue(body.contains("Board call") && body.contains("Design review"), "the body lists each meeting: \(body)")
        XCTAssertEqual(host.alerts.all.first?.actions.map(\.url), ["zoommtg://acme.zoom.us/join?action=join&confno=444", "https://meet.google.com/abc-defg-hij"], "a Join for each")
        await supervisor.stop()
    }

    func testLaunchingJustBeforeAStartGivesOneNudge() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "now", title: "Stand-in", start: now.addingTimeInterval(15), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/999", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let posted = await waitUntil(5) { !host.notifications.all.isEmpty }
        XCTAssertTrue(posted)
        await reread(supervisor)
        XCTAssertEqual(host.notifications.all.map(\.title), ["Stand-in is starting"], "the nudge replaces the 'in 1 min' reminder when both are due")
        await supervisor.stop()
    }

    func testWrappedAndSchemeLessLinksJoin() async throws {
        let now = Date()
        let links: [(title: String, notes: String, confno: String)] = [
            ("Safe Links", "https://nam04.safelinks.protection.outlook.com/?url=https%3A%2F%2Facme.zoom.us%2Fj%2F111%3Fpwd%3Dabc&data=05%7C01&reserved=0", "111"),
            ("urldefense v3", "https://urldefense.com/v3/__https://acme.zoom.us/j/222__;!!ABC!xyz$", "222"),
            ("urldefense v2", "https://urldefense.proofpoint.com/v2/url?u=https-3A__acme.zoom.us_j_333&d=DwMFAg&c=abc", "333"),
            ("Google redirect", "https://www.google.com/url?q=https%3A%2F%2Facme.zoom.us%2Fj%2F444&sa=D", "444"),
            ("Bare Zoom", "Dial in: acme.zoom.us/j/555", "555"),
        ]
        var events = links.enumerated().map { index, link in
            CalendarEvent(id: link.title, title: link.title, start: now.addingTimeInterval(TimeInterval(3600 * (index + 1))), end: now.addingTimeInterval(TimeInterval(3600 * (index + 1) + 1800)), notes: link.notes, calendar: "Work", participation: .accepted, attendees: 3)
        }
        events.append(CalendarEvent(id: "meet", title: "Bare Meet", start: now.addingTimeInterval(3600 * 9), end: now.addingTimeInterval(3600 * 9 + 1800), location: "meet.google.com/abc-defg-hij", calendar: "Work", participation: .accepted, attendees: 3))
        let host = Host(self, system: SimulatedSystem(events: events))
        let supervisor = try await host.start("UpNext")
        for link in links {
            try await pressAction("Join on Zoom", onRow: link.title, supervisor)
            XCTAssertTrue(host.opened.all.contains { $0.url.contains("confno=\(link.confno)") }, "\(link.title) joins its meeting: \(host.opened.all)")
        }
        try await pressAction("Join on Google Meet", onRow: "Bare Meet", supervisor)
        XCTAssertTrue(host.opened.all.contains { $0.url == "https://meet.google.com/abc-defg-hij" }, "\(host.opened.all)")
        await supervisor.stop()
    }

    func testAHiddenMeetingLeavesTheCountdownUntilShownAgain() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "near", title: "Near", start: now.addingTimeInterval(20 * 60), end: now.addingTimeInterval(50 * 60), location: "https://acme.zoom.us/j/555", calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "later", title: "Later", start: now.addingTimeInterval(50 * 60), end: now.addingTimeInterval(80 * 60), calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let before = await supervisor.views[.menuBar]?.plainText ?? ""
        XCTAssertTrue(before.contains("Near"), before)

        try await pressAction("Hide from Countdown", onRow: "Near", supervisor)
        let hidden = await supervisor.views[.menuBar]?.plainText ?? ""
        XCTAssertTrue(hidden.contains("Later") && !hidden.contains("Near"), "the countdown moves on: \(hidden)")
        let rows = await supervisor.views[.panel]?.rows.map(\.title) ?? []
        XCTAssertTrue(rows.contains("Near"), "the meeting is still in the list")

        try await pressAction("Show Again", onRow: "Near", supervisor)
        let shown = await supervisor.views[.menuBar]?.plainText ?? ""
        XCTAssertTrue(shown.contains("Near"), "shown again: \(shown)")
        await supervisor.stop()
    }

    func testTheWidgetJoinsTheFocusedMeeting() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/888", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let widgetTree = await supervisor.views[.widget]
        let widget = try XCTUnwrap(widgetTree)
        XCTAssertTrue(widget.actions.contains(ActionID("button/join-widget")), "the widget has a Join button")
        await supervisor.press(ActionID("button/join-widget"))
        let joined = await waitUntil(5) { !host.opened.all.isEmpty }
        XCTAssertTrue(joined)
        XCTAssertEqual(host.opened.all.first?.url, "zoommtg://acme.zoom.us/join?action=join&confno=888")
        await supervisor.stop()
    }

    func testAMeetingPastMidnightIsListedOnce() async throws {
        let now = Date()
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "late", title: "Late call", start: midnight.addingTimeInterval(-30 * 60), end: midnight.addingTimeInterval(30 * 60), location: "https://acme.zoom.us/j/777", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let supervisor = try await host.start("UpNext")
        let rows = await supervisor.views[.panel]?.rows ?? []
        XCTAssertEqual(rows.filter { $0.key == "late" }.count, 1, "under Today only: Tomorrow lists what starts that day")
        await supervisor.stop()
    }

    // MARK: Today's meetings, snooze, commands and tools

    func testTodaysMeetingsSortTimedFirstAndSearchEveryField() async throws {
        let now = Date()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "allday", title: "Offsite", start: dayStart, end: calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart, isAllDay: true, calendar: "Work", participation: .none),
            CalendarEvent(id: "planning", title: "Planning", start: now.addingTimeInterval(30 * 60), end: now.addingTimeInterval(60 * 60), location: "Room 4", notes: "https://acme.zoom.us/j/666", calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "standup", title: "Standup", start: now.addingTimeInterval(5 * 60), end: now.addingTimeInterval(20 * 60), calendar: "Home", participation: .accepted, attendees: 2),
            CalendarEvent(id: "cafe", title: "Café review", start: now.addingTimeInterval(15 * 60), end: now.addingTimeInterval(25 * 60), calendar: "Team", participation: .accepted, attendees: 2),
        ]))
        let session = try await host.session("UpNext")
        func titles(_ query: String) async throws -> [String] {
            let opened = try await session.openView("agenda", query: CommandQuery(text: query))
            await session.closeView(opened.session)
            return opened.root?.rows.map(\.title) ?? []
        }
        let all = try await titles("")
        let room = try await titles("room")
        let home = try await titles("home")
        let zoom = try await titles("zoom")
        let cafe = try await titles("CAFE")
        let accented = try await titles("café")
        XCTAssertEqual(all, ["Standup", "Café review", "Planning", "Offsite"], "timed meetings first, by start, then all-day")
        XCTAssertEqual(room, ["Planning"], "matches the place")
        XCTAssertEqual(home, ["Standup"], "matches the calendar")
        XCTAssertEqual(zoom, ["Planning"], "matches the call service")
        XCTAssertEqual(cafe, ["Café review"], "ignores case and accents")
        XCTAssertEqual(accented, ["Café review"], "and accents in the query")
    }

    func testTodaysMeetingsReadsTheCalendarAtMostEvery30Seconds() async throws {
        let now = Date()
        let system = SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), calendar: "Work", participation: .accepted, attendees: 3),
        ])
        let session = try await Host(self, system: system).session("UpNext")
        // A meeting added after the launch read, that the search would find: typing mustn't read the calendar again.
        system.simulate(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), calendar: "Work", participation: .accepted, attendees: 3),
            CalendarEvent(id: "late", title: "Late add", start: now.addingTimeInterval(90), end: now.addingTimeInterval(1800), calendar: "Work", participation: .accepted, attendees: 3),
        ])
        let opened = try await session.openView("agenda", query: CommandQuery(text: ""))
        let first = try await session.updateView(opened.session, query: CommandQuery(text: "l"))
        XCTAssertEqual(first?.rows.map(\.key) ?? [], [], "the first keystroke doesn't read the calendar again")
        let second = try await session.updateView(opened.session, query: CommandQuery(text: "la"))
        XCTAssertEqual(second?.rows.map(\.key) ?? [], [], "nor does the next one, within 30 seconds of the read")
        await session.closeView(opened.session)
    }

    func testSnoozingAMeetingThatIsGoneChangesNothing() async throws {
        let host = Host(self, system: SimulatedSystem(events: []))
        let session = try await host.session("UpNext")
        guard case .failure(let message) = try await session.runCommand("snooze", arguments: ["event": "gone"]) else {
            return XCTFail("a meeting that's gone can't be snoozed")
        }
        XCTAssertEqual(message, "That meeting is no longer on your calendar")
    }

    func testTheJoinHotkeyJoinsTheNextMeeting() async throws {
        let now = Date()
        let host = Host(self, system: SimulatedSystem(events: [
            CalendarEvent(id: "soon", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800), location: "https://acme.zoom.us/j/999", calendar: "Work", participation: .accepted, attendees: 3),
        ]))
        let session = try await host.session("UpNext")
        let manifest = await session.manifest
        XCTAssertEqual(manifest?.hotkey, "ctrl+option+j")
        XCTAssertEqual(manifest?.hotkeyCommand, "join-next", "the hotkey runs join-next, with no arguments")
        guard case .message = try await session.runCommand("join-next") else { return XCTFail("join-next joins") }
        XCTAssertEqual(host.opened.all.first?.url, "zoommtg://acme.zoom.us/join?action=join&confno=999")
    }

    func testAgentToolsWaitForPermission() async throws {
        let session = try await Host(self, system: SimulatedSystem(events: [])).session("UpNext")
        let tools = await session.tools()
        XCTAssertEqual(Set(tools.map(\.name)), ["next_meeting", "agenda", "join_next"])
        XCTAssertTrue(tools.allSatisfy(\.optIn), "agents only get them once the user allows it")
    }

    // MARK: Helpers

    /// Adds `text` through the add-event view as the palette does: the row's
    /// first action saves it to the default calendar. Returns the event saved,
    /// or nil when the view had no row.
    private func addFromView(_ text: String, _ session: PluginSession, _ system: SimulatedSystem) async throws -> CalendarEvent? {
        let from = Date().addingTimeInterval(-86_400)
        let to = Date().addingTimeInterval(60 * 86_400)
        let before = Set(try await system.calendarEvents(from: from, to: to).map(\.id))
        let opened = try await session.openView("add-event", query: CommandQuery(text: text))
        if let action = opened.root?.rows.first?.actions.first?.id {
            try await session.event(action)
        }
        await session.closeView(opened.session)
        return try await system.calendarEvents(from: from, to: to).first { !before.contains($0.id) }
    }

    private func assertAdded(_ added: CalendarEvent?, _ title: String, _ start: Date, minutes: Double, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let added else { return XCTFail("nothing was added for \"\(text)\"", file: file, line: line) }
        XCTAssertEqual(added.title, title, text, file: file, line: line)
        XCTAssertEqual(added.start, start, text, file: file, line: line)
        XCTAssertEqual(added.end.timeIntervalSince(added.start), minutes * 60, text, file: file, line: line)
    }

    /// `hour`:`minute` on the day `dayOffset` days from `now` (0 is today).
    private func at(_ hour: Int, _ minute: Int, day dayOffset: Int = 0, from now: Date) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? now
    }

    /// A bare time as the add-event view picks it: today if still ahead, else tomorrow.
    private func nextAt(_ hour: Int, _ minute: Int, from now: Date) -> Date {
        let today = at(hour, minute, from: now)
        return today >= now ? today : at(hour, minute, day: 1, from: now)
    }

    /// The next `weekday` (1 is Sunday) at the time, today included while it's still ahead.
    private func nextWeekday(_ weekday: Int, _ hour: Int, _ minute: Int, from now: Date) -> Date {
        let ahead = (weekday - Calendar.current.component(.weekday, from: now) + 7) % 7
        let candidate = at(hour, minute, day: ahead, from: now)
        return candidate >= now ? candidate : at(hour, minute, day: ahead + 7, from: now)
    }

    /// The day of the next `weekday`, today included.
    private func weekdayDay(_ weekday: Int, from now: Date) -> Date {
        let ahead = (weekday - Calendar.current.component(.weekday, from: now) + 7) % 7
        return Calendar.current.date(byAdding: .day, value: ahead, to: now) ?? now
    }

    /// Switches on the settings toggle whose title contains `text`.
    private func turnOn(_ supervisor: PluginSupervisor, _ text: String) async throws {
        let toggle = await supervisor.views[.settings]?.toggles.first { $0.title.contains(text) }
        await supervisor.press(try XCTUnwrap(toggle, "no \(text) toggle in settings").action, value: .bool(true))
    }

    /// Presses the action titled `title` on the panel row titled `row`.
    private func pressAction(_ title: String, onRow row: String, _ supervisor: PluginSupervisor) async throws {
        let rows = await supervisor.views[.panel]?.rows ?? []
        let node = try XCTUnwrap(rows.first { $0.title == row }, "no row \(row) in the panel")
        let action = try XCTUnwrap(node.actions.first { $0.title == title }, "no \(title) action on \(row)")
        await supervisor.press(action.id)
    }

    /// Reads the calendar again and waits until the plugin has handled it.
    private func reread(_ supervisor: PluginSupervisor) async {
        let before = await supervisor.settledCount
        await supervisor.refresh()
        _ = await waitUntil { await supervisor.settledCount > before }
    }
}
