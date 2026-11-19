import StackbarKit
import Foundation

/// Slack in the menu bar and the palette: unread messages in the
/// conversations you watch, message search, a channel and people switcher,
/// sending a message, your status, snooze and presence, and your workspace's
/// custom emoji.
///
/// It talks to Slack's Web API with your own user token (`xoxp-…`), kept in
/// your Keychain as `SLACK_TOKEN`. The README has a Slack app manifest that
/// asks for exactly the scopes this plugin uses: create the app from it,
/// install it to your workspace and paste its User OAuth Token.
@main
final class Slack: StackbarPlugin {
    static let manifest = Manifest(
        id: "io.navbytes.stackbar.plugins.slack",
        name: "Slack",
        version: "1.0.1",
        summary: "Unread Slack conversations in the menu bar; search messages, jump to channels, send messages, set your status and snooze from the palette.",
        surfaces: [.menuBar, .panel, .settings],
        triggers: [.launch, .minutes(2), .wake],
        capabilities: [.network("slack.com"), .secret(name: "SLACK_TOKEN"), .userServer(secret: "SLACK_API_URL"), .openURLs(schemes: ["slack"])],
        minimumStackbar: "0.40.1",
        homepage: "https://github.com/navbytes/stackbar-plugins/tree/main/Productivity/Slack",
        accent: .violet,
        symbol: "number.square.fill"
    )

    // MARK: Previews

    static let previews: [PreviewScene<Slack>] = [
        PreviewScene("hero", "What's new in the conversations you watch") { plugin in
            plugin.sample()
        },
        PreviewScene("snoozed", "Snooze and status a click away") { plugin in
            plugin.sample()
            plugin.snoozedUntil = Date().addingTimeInterval(52 * 60)
            plugin.status = Status(text: "Focus time", emoji: ":headphones:", expiration: Date().addingTimeInterval(90 * 60))
        },
    ]

    func sample() {
        identity = Identity(user: "sam", userId: "U1", team: "Acme", teamId: "T1", url: "https://acme.slack.com/")
        directory = Directory(owner: "T1/U1", conversations: [
            Conversation(id: "D1", name: "Mei Tanaka", kind: .dm, userID: "U2"),
            Conversation(id: "C1", name: "eng-releases", kind: .channel, userID: nil),
            Conversation(id: "G1", name: "design-crit", kind: .group, userID: nil),
            Conversation(id: "C2", name: "general", kind: .channel, userID: nil),
        ], people: [Person(id: "U2", handle: "mei", name: "Mei Tanaka"), Person(id: "U3", handle: "ravi", name: "Ravi Kumar")], fetchedAt: Date())
        watched = ["D1", "C1", "G1", "C2"]
        let now = Date().timeIntervalSince1970
        func ts(_ minutesAgo: Double) -> String { String(format: "%.6f", now - minutesAgo * 60) }
        unread = [
            Unread(conversation: "D1", messages: [
                Message(ts: ts(3), user: "U2", text: "Can you look at the rollout doc before 3?"),
                Message(ts: ts(4), user: "U2", text: "Morning!"),
            ], more: false),
            Unread(conversation: "C1", messages: [
                Message(ts: ts(12), user: "U3", text: "2.14.0 is live on all regions :tada:"),
            ], more: false),
            Unread(conversation: "G1", messages: (0..<6).map { Message(ts: ts(40 + Double($0)), user: "U3", text: "New mocks for the settings page are up") }, more: false),
        ]
        loaded = true
    }

    // MARK: Model

    struct Identity: Codable, Equatable {
        let user: String
        let userId: String
        let team: String
        let teamId: String
        let url: String
    }

    enum Kind: String, Codable { case channel, group, dm, groupDM }

    struct Conversation: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let kind: Kind
        /// The other person in a direct message.
        let userID: String?

        var title: String {
            switch kind {
            case .channel, .group: return "#" + name
            case .dm, .groupDM: return name
            }
        }

        var symbol: String {
            switch kind {
            case .channel: return "number"
            case .group: return "lock"
            case .dm: return "person"
            case .groupDM: return "person.2"
            }
        }
    }

    struct Person: Codable, Equatable, Identifiable {
        let id: String
        let handle: String
        let name: String
    }

    /// Who the token belongs to, their conversations and the workspace's
    /// people, kept between launches and fetched again every six hours.
    struct Directory: Codable, Equatable {
        var owner = ""
        var conversations: [Conversation] = []
        var people: [Person] = []
        var fetchedAt: Date?
    }

    struct Message: Codable, Equatable, Identifiable {
        var id: String { ts }
        let ts: String
        let user: String?
        let text: String
    }

    /// A watched conversation's messages since you last read it, newest first.
    struct Unread: Equatable, Identifiable {
        var id: String { conversation }
        let conversation: String
        let messages: [Message]
        /// Slack has more than it sent.
        let more: Bool
    }

    struct Found: Equatable, Identifiable {
        var id: String { channelID + "/" + ts }
        let ts: String
        let text: String
        let user: String
        let channelID: String
        let channelName: String
        let permalink: String
    }

    struct Status: Equatable {
        let text: String
        let emoji: String
        let expiration: Date?
    }

    struct Emoji: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let alias: String?
    }

    // MARK: State

    @Stored("directory") var directory = Directory()
    /// The conversations whose unread messages the menu bar counts, by id.
    @Stored("watched") var watched: [String] = []
    /// The newest message already seen in each watched conversation, so only
    /// newer ones notify.
    @Stored("seen") var seen: [String: String] = [:]
    @Stored("openIn") var openIn = "Slack app"
    @Stored("notify") var notifyNew = false
    @Stored("customServer") var customServer = false

    var identity: Identity?
    var unread: [Unread] = []
    var status: Status?
    var snoozedUntil: Date?
    var problem: String?
    var loaded = false
    var refreshedAt: Date?
    var settingsNote: String?

    var found: [Found] = []
    var foundText: String?
    var searchProblem: String?
    var emoji: [Emoji] = []
    var emojiProblem: String?
    var sendProblem: String?
    var sent: String?
    var statusProblem: String?

    let theme = Theme.violet
    static let maxWatched = 30
    static let missingToken = "Add your Slack user token (SLACK_TOKEN)"

    // MARK: API

    struct Envelope: Decodable {
        let ok: Bool
        let error: String?
        let needed: String?
    }

    struct Page: Decodable { let nextCursor: String? }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// slack.com's API, or the one the user named (GovSlack, a company gateway).
    func apiBase() async throws -> String {
        guard customServer else { return "https://slack.com/api" }
        var text = try await Stackbar.secret("SLACK_API_URL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { throw HostError("Add your Slack server (SLACK_API_URL), or pick slack.com in Settings") }
        if !text.contains("://") { text = "https://" + text }
        return text.hasSuffix("/api") ? text : text + "/api"
    }

    /// One Web API method, sent as a form like Slack's own clients do.
    /// Slack answers failures with HTTP 200 and `ok: false`.
    func call<T: Decodable>(_ method: String, _ fields: [String: String] = [:], as type: T.Type = T.self) async throws -> T {
        guard let token = try await Stackbar.secret("SLACK_TOKEN")?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw HostError(Self.missingToken)
        }
        let response = try await Stackbar.http(HTTPRequest(url: try await apiBase() + "/" + method, method: "POST", headers: [
            "Authorization": "Bearer " + token, "Content-Type": "application/x-www-form-urlencoded",
        ], body: Data(Self.form(fields).utf8), timeout: 15))
        if response.status == 429 {
            let wait = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
            throw HostError("Slack is limiting requests; try again in \(wait ?? "a few") seconds")
        }
        guard (200..<300).contains(response.status) else { throw HostError("Slack answered \(response.status)") }
        let envelope = try Self.decoder.decode(Envelope.self, from: response.body)
        guard envelope.ok else { throw HostError(Self.explain(envelope.error ?? "unknown_error", needed: envelope.needed)) }
        return try Self.decoder.decode(T.self, from: response.body)
    }

    struct Done: Decodable {}

    static func form(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&")
    }

    static func explain(_ code: String, needed: String?) -> String {
        switch code {
        case "not_authed", "invalid_auth", "token_revoked", "token_expired", "account_inactive":
            return "Slack rejected the token (\(code)); set a new SLACK_TOKEN"
        case "missing_scope":
            return "The token is missing the \(needed ?? "needed") scope: add it to your Slack app, reinstall it and paste the new token"
        case "ratelimited":
            return "Slack is limiting requests; try again in a minute"
        case "channel_not_found":
            return "Slack can't find that conversation"
        case "not_in_channel":
            return "You're not in that channel"
        default:
            return "Slack said \(code)"
        }
    }

    /// No token yet: a setup prompt, not a failure.
    var needsToken: Bool { problem == Self.missingToken }

    // MARK: Refresh

    /// For a view: waits only for the first refresh; after that it answers
    /// from what is in hand and, when older than `maxAge`, refreshes behind
    /// it (the view redraws when it lands).
    func refresh(maxAge: TimeInterval) async throws {
        if loaded, let at = refreshedAt, Date().timeIntervalSince(at) < maxAge { return }
        guard loaded else { return try await Stackbar.refresh() }
        if !Stackbar.isRefreshing { Task { try? await Stackbar.refresh() } }
    }

    func refresh() async throws {
        refreshedAt = Date()
        do {
            struct Auth: Decodable { let user: String; let userId: String; let team: String; let teamId: String; let url: String }
            let auth = try await call("auth.test", as: Auth.self)
            let me = Identity(user: auth.user, userId: auth.userId, team: auth.team, teamId: auth.teamId, url: auth.url)
            let owner = me.teamId + "/" + me.userId
            if !directory.owner.isEmpty, directory.owner != owner {
                // Another account: its conversations and what it has seen start over.
                directory = Directory()
                watched = []
                seen = [:]
                unread = []
            }
            identity = me
            if directory.owner != owner || (directory.fetchedAt.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true) {
                try await loadDirectory(owner: owner)
            }
            try await loadUnread()
            await loadStatus()
            problem = nil
        } catch {
            problem = "\(error)"
        }
        loaded = true
    }

    func loadDirectory(owner: String) async throws {
        struct Conversations: Decodable {
            struct Item: Decodable {
                let id: String
                let name: String?
                let user: String?
                let isIm: Bool?
                let isMpim: Bool?
                let isPrivate: Bool?
            }
            let channels: [Item]
            let responseMetadata: Page?
        }
        struct People: Decodable {
            struct Member: Decodable {
                struct Profile: Decodable { let displayName: String?; let realName: String? }
                let id: String
                let name: String
                let deleted: Bool?
                let realName: String?
                let profile: Profile?
            }
            let members: [Member]
            let responseMetadata: Page?
        }
        var people: [Person] = []
        var cursor = ""
        for _ in 0..<10 {
            let page = try await call("users.list", ["limit": "200", "cursor": cursor], as: People.self)
            people += page.members.filter { $0.deleted != true }.map { member in
                let name = [member.profile?.realName, member.realName, member.profile?.displayName].compactMap { $0 }.first { !$0.isEmpty } ?? member.name
                return Person(id: member.id, handle: member.name, name: name)
            }
            guard let next = page.responseMetadata?.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        let names = Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var conversations: [Conversation] = []
        cursor = ""
        for _ in 0..<10 {
            let page = try await call("users.conversations", [
                "types": "public_channel,private_channel,mpim,im", "exclude_archived": "true", "limit": "200", "cursor": cursor,
            ], as: Conversations.self)
            for item in page.channels {
                if item.isIm == true {
                    guard let user = item.user, let name = names[user] else { continue }
                    conversations.append(Conversation(id: item.id, name: name, kind: .dm, userID: user))
                } else if item.isMpim == true {
                    conversations.append(Conversation(id: item.id, name: Self.groupName(item.name ?? item.id), kind: .groupDM, userID: nil))
                } else {
                    conversations.append(Conversation(id: item.id, name: item.name ?? item.id, kind: item.isPrivate == true ? .group : .channel, userID: nil))
                }
            }
            guard let next = page.responseMetadata?.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        directory = Directory(owner: owner, conversations: conversations.sorted { $0.name.lowercased() < $1.name.lowercased() }, people: people, fetchedAt: Date())
    }

    /// `mpdm-mei--ravi--sam-1` is a group message with Mei, Ravi and Sam.
    static func groupName(_ name: String) -> String {
        guard name.hasPrefix("mpdm-") else { return name }
        var body = String(name.dropFirst(5))
        if let dash = body.lastIndex(of: "-"), body[body.index(after: dash)...].allSatisfy(\.isNumber) { body = String(body[..<dash]) }
        return body.components(separatedBy: "--").joined(separator: ", ")
    }

    /// Each watched conversation's messages since you last read it, from
    /// other people. Two requests each, so at most thirty are watched.
    func loadUnread() async throws {
        struct Info: Decodable { struct Channel: Decodable { let id: String; let lastRead: String? }; let channel: Channel }
        struct History: Decodable {
            struct Item: Decodable { let ts: String; let user: String?; let text: String?; let subtype: String?; let botId: String?; let username: String? }
            let messages: [Item]
            let hasMore: Bool?
        }
        let me = identity?.userId
        var found: [Unread] = []
        for id in watched.prefix(Self.maxWatched) {
            let info: Info
            do {
                info = try await call("conversations.info", ["channel": id], as: Info.self)
            } catch let error as HostError where "\(error)".contains("can't find") {
                continue
            }
            var fields = ["channel": id, "limit": "15"]
            if let lastRead = info.channel.lastRead, (Double(lastRead) ?? 0) > 0 { fields["oldest"] = lastRead }
            let history = try await call("conversations.history", fields, as: History.self)
            let messages = history.messages.filter { item in
                item.user != me && !Self.quietSubtypes.contains(item.subtype ?? "")
            }.map { Message(ts: $0.ts, user: $0.user ?? $0.username ?? $0.botId, text: $0.text ?? "") }
            if !messages.isEmpty { found.append(Unread(conversation: id, messages: messages, more: history.hasMore ?? false)) }
        }
        unread = found.sorted { (Double($0.messages[0].ts) ?? 0) > (Double($1.messages[0].ts) ?? 0) }
        noticeNew()
    }

    /// Joins, leaves and topic changes aren't news.
    static let quietSubtypes: Set<String> = ["channel_join", "channel_leave", "group_join", "group_leave", "channel_topic", "channel_purpose", "channel_name"]

    func noticeNew() {
        var next = seen
        defer { seen = next }
        for item in unread {
            let newest = item.messages[0].ts
            guard let before = seen[item.conversation] else { next[item.conversation] = newest; continue }
            next[item.conversation] = (Double(newest) ?? 0) > (Double(before) ?? 0) ? newest : before
            guard notifyNew else { continue }
            let fresh = item.messages.filter { (Double($0.ts) ?? 0) > (Double(before) ?? 0) }
            guard let latest = fresh.first, let conversation = conversation(item.conversation) else { continue }
            let who = latest.user.flatMap { personName($0) } ?? "Someone"
            let title = conversation.kind == .dm ? who : "\(who) in \(conversation.title)"
            let body = fresh.count > 1 ? "\(plain(latest.text)) (+\(fresh.count - 1) more)" : plain(latest.text)
            // A notification button opens only web links itself, so it runs
            // a command, which may open the Slack app.
            Stackbar.notify(title, body: body, actions: [NotificationAction("Open", command: "open-conversation", arguments: ["id": conversation.id])])
        }
    }

    func loadStatus() async {
        struct Profile: Decodable { struct Body: Decodable { let statusText: String?; let statusEmoji: String?; let statusExpiration: Double? }; let profile: Body }
        struct Snooze: Decodable { let snoozeEnabled: Bool?; let snoozeEndtime: Double? }
        if let profile = try? await call("users.profile.get", as: Profile.self).profile {
            let text = profile.statusText ?? "", emoji = profile.statusEmoji ?? ""
            status = text.isEmpty && emoji.isEmpty ? nil : Status(text: text, emoji: emoji, expiration: profile.statusExpiration.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
        }
        if let dnd = try? await call("dnd.info", as: Snooze.self) {
            snoozedUntil = dnd.snoozeEnabled == true ? dnd.snoozeEndtime.map { Date(timeIntervalSince1970: $0) } : nil
        }
    }

    // MARK: Names and text

    func conversation(_ id: String) -> Conversation? { directory.conversations.first { $0.id == id } }
    func personName(_ id: String) -> String? { directory.people.first { $0.id == id }?.name }

    /// Slack's mrkdwn as plain text: `<@U1>` is @Mei Tanaka, `<#C1|general>`
    /// is #general, `<https://x|label>` is the label.
    func plain(_ text: String) -> String {
        let people = Dictionary(directory.people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let channels = Dictionary(directory.conversations.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return Self.plain(text, people: people, channels: channels)
    }

    static func plain(_ text: String, people: [String: String], channels: [String: String]) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            out += rest[..<open]
            let inner = rest[rest.index(after: open)..<close]
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.first ?? "", label = parts.count > 1 ? parts[1] : nil
            if target.hasPrefix("@") {
                out += "@" + (label ?? people[String(target.dropFirst())] ?? String(target.dropFirst()))
            } else if target.hasPrefix("#") {
                out += "#" + (label ?? channels[String(target.dropFirst())] ?? String(target.dropFirst()))
            } else if target.hasPrefix("!subteam") {
                out += label ?? "@team"
            } else if target.hasPrefix("!") {
                out += "@" + (label ?? String(target.dropFirst()))
            } else {
                out += label ?? target
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
            .split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    static func ago(_ ts: String) -> String {
        let minutes = Int((Date().timeIntervalSince1970 - (Double(ts) ?? 0)) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / 60 / 24)d"
    }

    // MARK: Links

    var preferApp: Bool { openIn == "Slack app" }

    /// The conversation in the Slack app, or in the browser.
    func link(_ conversation: Conversation) -> String {
        let team = identity?.teamId ?? ""
        if preferApp { return "slack://channel?team=\(team)&id=\(conversation.id)" }
        return "https://app.slack.com/client/\(team)/\(conversation.id)"
    }

    func link(person: Person) -> String {
        if let dm = directory.conversations.first(where: { $0.userID == person.id }) { return link(dm) }
        let team = identity?.teamId ?? ""
        return preferApp ? "slack://user?team=\(team)&id=\(person.id)" : "https://app.slack.com/client/\(team)/\(person.id)"
    }

    /// A message's permalink opens in the browser, which hands it to the app.
    func open(_ url: String) {
        Stackbar.open(url)
    }

    // MARK: Actions

    func markRead(_ item: Unread) async throws {
        try await markRead(item.conversation, ts: item.messages[0].ts)
    }

    func markRead(_ conversation: String, ts: String) async throws {
        _ = try await call("conversations.mark", ["channel": conversation, "ts": ts], as: Done.self)
        unread.removeAll { $0.conversation == conversation }
    }

    var markAllConfirm: Confirm { "mark \(unread.count) conversations as read" }

    func markAllRead() async {
        var done = 0
        for item in unread {
            do {
                try await markRead(item)
                done += 1
            } catch {
                Stackbar.hud("Marked \(done), then: \(error)", isError: true)
                return
            }
        }
        Stackbar.hud("Marked \(done) as read")
    }

    func watch(_ id: String) {
        guard !watched.contains(id) else { return }
        guard watched.count < Self.maxWatched else {
            Stackbar.hud("Watching \(Self.maxWatched) already; remove one first", isError: true)
            return
        }
        watched.append(id)
    }

    func unwatch(_ id: String) {
        watched.removeAll { $0 == id }
        unread.removeAll { $0.conversation == id }
        seen[id] = nil
    }

    /// `#general`, `general`, `@mei` or `Mei Tanaka`: the conversation it names.
    func resolve(_ text: String) -> Conversation? {
        var name = text.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix("#") || name.hasPrefix("@") { name.removeFirst() }
        guard !name.isEmpty else { return nil }
        if let match = directory.conversations.first(where: { $0.name.lowercased() == name }) { return match }
        if let person = directory.people.first(where: { $0.handle.lowercased() == name || $0.name.lowercased() == name }) {
            return directory.conversations.first { $0.userID == person.id }
        }
        return nil
    }

    /// Posts `text` to a conversation, opening a direct message first when
    /// it goes to a person you haven't written to.
    func send(_ text: String, to target: String) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { sendProblem = "Write a message first"; return }
        var channel = target
        if target.hasPrefix("U") || target.hasPrefix("W") {
            if let dm = directory.conversations.first(where: { $0.userID == target }) {
                channel = dm.id
            } else {
                struct Opened: Decodable { struct Channel: Decodable { let id: String }; let channel: Channel }
                do {
                    channel = try await call("conversations.open", ["users": target], as: Opened.self).channel.id
                } catch {
                    sendProblem = "\(error)"
                    return
                }
            }
        }
        do {
            _ = try await call("chat.postMessage", ["channel": channel, "text": body], as: Done.self)
            sendProblem = nil
            sent = "Sent to \(destinationName(target))"
            Stackbar.hud(sent ?? "Sent")
        } catch {
            sendProblem = "\(error)"
        }
    }

    func destinationName(_ id: String) -> String {
        if let conversation = conversation(id) { return conversation.title }
        return personName(id) ?? id
    }

    /// Where a message can go: your conversations, then people you haven't
    /// written to yet.
    var destinations: [(id: String, title: String, symbol: String)] {
        let written = Set(directory.conversations.compactMap(\.userID))
        return directory.conversations.map { ($0.id, $0.title, $0.symbol) }
            + directory.people.filter { !written.contains($0.id) && $0.id != identity?.userId }.map { ($0.id, $0.name, "person") }
    }

    func setStatus(text: String, emoji: String, minutes: Int?) async throws {
        let expiration = minutes.map { Int(Date().timeIntervalSince1970) + $0 * 60 } ?? 0
        let profile: [String: Any] = ["status_text": text, "status_emoji": emoji, "status_expiration": expiration]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys]), as: UTF8.self)
        do {
            _ = try await call("users.profile.set", ["profile": json], as: Done.self)
            status = text.isEmpty && emoji.isEmpty ? nil : Status(text: text, emoji: emoji, expiration: minutes.map { Date().addingTimeInterval(Double($0) * 60) })
            statusProblem = nil
            Stackbar.hud(text.isEmpty && emoji.isEmpty ? "Status cleared" : "Status set: \(Self.emojiGlyph(emoji)) \(text)")
        } catch {
            statusProblem = "\(error)"
            throw error
        }
    }

    /// Snoozes notifications for `minutes`, or ends a snooze for nil.
    func snooze(minutes: Int?) async throws {
        if let minutes {
            _ = try await call("dnd.setSnooze", ["num_minutes": "\(minutes)"], as: Done.self)
            snoozedUntil = Date().addingTimeInterval(Double(minutes) * 60)
            Stackbar.hud("Slack snoozed until \(Self.clock(snoozedUntil!))")
        } else {
            _ = try await call("dnd.endSnooze", as: Done.self)
            snoozedUntil = nil
            Stackbar.hud("Slack notifications on")
        }
    }

    static let snoozeChoices = ["20 minutes", "1 hour", "2 hours", "4 hours", "8 hours", "Until tomorrow", "Turn off"]

    /// Minutes for a snooze choice; nil turns snooze off. "Until tomorrow"
    /// is 9:00 tomorrow.
    static func snoozeMinutes(_ choice: String, now: Date = Date()) -> Int? {
        switch choice {
        case "20 minutes": return 20
        case "1 hour": return 60
        case "2 hours": return 120
        case "4 hours": return 240
        case "8 hours": return 480
        case "Until tomorrow":
            let calendar = Calendar.current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
            return max(1, Int(nine.timeIntervalSince(now) / 60))
        default: return nil
        }
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    struct Preset: Identifiable {
        var id: String { text }
        let text: String
        let emoji: String
        let minutes: Int?
        let until: String
    }

    static let presets = [
        Preset(text: "In a meeting", emoji: ":spiral_calendar_pad:", minutes: 60, until: "1 hour"),
        Preset(text: "Focus time", emoji: ":headphones:", minutes: 120, until: "2 hours"),
        Preset(text: "Commuting", emoji: ":bus:", minutes: 30, until: "30 minutes"),
        Preset(text: "Lunch", emoji: ":knife_fork_plate:", minutes: 60, until: "1 hour"),
        Preset(text: "Working remotely", emoji: ":house_with_garden:", minutes: nil, until: "Don't clear"),
        Preset(text: "Out sick", emoji: ":face_with_thermometer:", minutes: nil, until: "Don't clear"),
        Preset(text: "On vacation", emoji: ":palm_tree:", minutes: nil, until: "Don't clear"),
    ]

    static let glyphs = [
        ":spiral_calendar_pad:": "🗓️", ":headphones:": "🎧", ":bus:": "🚌", ":knife_fork_plate:": "🍽️",
        ":house_with_garden:": "🏡", ":face_with_thermometer:": "🤒", ":palm_tree:": "🌴",
    ]

    static func emojiGlyph(_ code: String) -> String { glyphs[code] ?? code }

    static let expiryChoices = ["Don't clear", "30 minutes", "1 hour", "4 hours", "Today"]

    static func expiryMinutes(_ choice: String, now: Date = Date()) -> Int? {
        switch choice {
        case "30 minutes": return 30
        case "1 hour": return 60
        case "4 hours": return 240
        case "Today":
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
            return max(1, Int(end.timeIntervalSince(now) / 60))
        default: return nil
        }
    }

    func search(_ text: String) async {
        let term = text.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { found = []; searchProblem = nil; foundText = nil; return }
        if term == foundText, searchProblem == nil { return }
        try? await Task.sleep(for: .milliseconds(250))
        struct Reply: Decodable {
            struct Messages: Decodable {
                struct Match: Decodable {
                    struct Channel: Decodable { let id: String; let name: String? }
                    let ts: String
                    let text: String?
                    let user: String?
                    let username: String?
                    let channel: Channel
                    let permalink: String
                }
                let matches: [Match]
            }
            let messages: Messages
        }
        do {
            let reply = try await call("search.messages", ["query": term, "count": "20", "sort": "timestamp", "sort_dir": "desc"], as: Reply.self)
            found = reply.messages.matches.map { match in
                let channel = conversation(match.channel.id)?.title ?? match.channel.name.map { $0.hasPrefix("mpdm-") ? Self.groupName($0) : "#" + $0 } ?? ""
                let who = match.user.flatMap { personName($0) } ?? match.username ?? ""
                return Found(ts: match.ts, text: plain(match.text ?? ""), user: who, channelID: match.channel.id, channelName: channel, permalink: match.permalink)
            }
            searchProblem = nil
            foundText = term
        } catch {
            found = []
            searchProblem = "\(error)"
            foundText = nil
        }
    }

    func loadEmoji() async {
        guard emoji.isEmpty else { return }
        struct Reply: Decodable { let emoji: [String: String] }
        do {
            let reply = try await call("emoji.list", as: Reply.self)
            emoji = reply.emoji.map { name, value in
                Emoji(name: name, alias: value.hasPrefix("alias:") ? String(value.dropFirst(6)) : nil)
            }.sorted { $0.name < $1.name }
            emojiProblem = nil
        } catch {
            emojiProblem = "\(error)"
        }
    }

    /// The directory, fetched first when the palette opens before any refresh.
    func ensureDirectory() async throws {
        if directory.conversations.isEmpty || identity == nil { try await Stackbar.refresh() }
    }

    // MARK: Rows

    func row(_ item: Unread) -> Row {
        let conversation = conversation(item.conversation)
        let latest = item.messages[0]
        let who = latest.user.flatMap { personName($0) }
        let subtitle = (conversation?.kind == .dm || who == nil ? "" : who! + ": ") + plain(latest.text)
        let count = item.more ? "\(item.messages.count)+" : "\(item.messages.count)"
        return Row(conversation?.title ?? item.conversation, subtitle: subtitle, symbol: conversation?.symbol ?? "number", key: "unread-" + item.conversation)
            .badge(count + " · " + Self.ago(latest.ts), role: conversation?.kind == .dm ? .accent : .secondary)
            .preview(text: item.messages.reversed().map { message in
                (message.user.flatMap { personName($0) } ?? "Someone") + ": " + plain(message.text)
            }.joined(separator: "\n"), caption: conversation?.title)
            .action("Open in Slack") {
                if let conversation { self.open(self.link(conversation)) }
            }
            .action("Mark as Read", shortcut: "cmd+r") { try await self.markRead(item) }
            .navigate("Reply…", to: "compose", arguments: ["to": item.conversation], shortcut: "cmd+k")
    }

    func row(_ conversation: Conversation) -> Row {
        var row = Row(conversation.title, symbol: conversation.symbol, key: "conversation-" + conversation.id)
        if watched.contains(conversation.id) { row = row.badge("Watching") }
        return row
            .action("Open in Slack") { self.open(self.link(conversation)) }
            .navigate("Send Message…", to: "compose", arguments: ["to": conversation.id], shortcut: "cmd+k")
            .action(watched.contains(conversation.id) ? "Stop Watching" : "Watch for Unread", shortcut: "cmd+w") {
                if self.watched.contains(conversation.id) { self.unwatch(conversation.id) } else { self.watch(conversation.id); try await Stackbar.refresh() }
            }
            .action("Copy Link", shortcut: "cmd+shift+c") { Stackbar.copy("https://app.slack.com/client/\(self.identity?.teamId ?? "")/\(conversation.id)") }
    }

    func row(_ person: Person) -> Row {
        Row(person.name, subtitle: "@" + person.handle, symbol: "person", key: "person-" + person.id)
            .action("Open in Slack") { self.open(self.link(person: person)) }
            .navigate("Send Message…", to: "compose", arguments: ["to": person.id], shortcut: "cmd+k")
    }

    func row(_ match: Found) -> Row {
        Row(match.text.isEmpty ? "(no text)" : match.text, subtitle: [match.channelName, match.user, Self.ago(match.ts)].filter { !$0.isEmpty }.joined(separator: " · "), symbol: "text.bubble", key: "found-" + match.id)
            .preview(text: match.text, caption: match.channelName)
            .action("Open in Slack") { self.open(match.permalink) }
            .action("Copy Link", shortcut: "cmd+shift+c") { Stackbar.copy(match.permalink) }
            .action("Copy Text", shortcut: "cmd+c") { Stackbar.copy(match.text) }
            .navigate("Reply in Channel…", to: "compose", arguments: ["to": match.channelID], shortcut: "cmd+k")
    }

    // MARK: Surfaces

    var unreadCount: Int { unread.reduce(0) { $0 + $1.messages.count } }
    var directCount: Int { unread.filter { conversation($0.conversation)?.kind == .dm || conversation($0.conversation)?.kind == .groupDM }.reduce(0) { $0 + $1.messages.count } }

    var menuBar: ViewContent {
        if needsToken || !loaded {
            Label("", symbol: "number").role(.secondary)
        } else if problem != nil {
            Label("", symbol: "number").role(.warning)
        } else if unreadCount > 0 {
            Label("\(unreadCount)", symbol: snoozedUntil == nil ? "bubble.left.fill" : "moon.zzz.fill").role(directCount > 0 ? .warning : .primary)
        } else {
            Label("", symbol: snoozedUntil == nil ? "number" : "moon.zzz").role(.secondary)
        }
    }

    var subtitle: String {
        var parts = [identity?.team ?? "Slack"]
        if let status { parts.append("\(Self.emojiGlyph(status.emoji)) \(status.text)".trimmingCharacters(in: .whitespaces)) }
        return parts.joined(separator: " · ")
    }

    var panel: ViewContent {
        VStack(spacing: Space.m) {
            if !loaded {
                PanelHeader("Slack", subtitle: "Checking…", symbol: "number", theme: theme)
            } else if needsToken {
                EmptyState("Connect Slack", symbol: "key.fill", message: "Create a Slack app from the manifest in this plugin's README, install it to your workspace and paste its User OAuth Token (xoxp-…). Stackbar keeps it in your Keychain.", theme: theme) {
                    ActionButton("Add Token", symbol: "key.fill", theme: theme, prominent: true) { try await Stackbar.refresh() }
                    ActionButton("Open Setup Guide", symbol: "book", theme: theme) { Stackbar.open(Self.manifest.homepage ?? "") }
                }
            } else if let problem, identity == nil {
                EmptyState("Can't reach Slack", symbol: "exclamationmark.triangle.fill", message: problem, theme: .critical) {
                    ActionButton("Try Again", symbol: "arrow.clockwise", theme: theme) { try await Stackbar.refresh() }
                }
            } else {
                PanelHeader(unreadCount == 0 ? "All caught up" : "\(unreadCount) unread", subtitle: subtitle, symbol: "number", theme: theme) {
                    IconButton("arrow.clockwise", label: "Refresh", theme: theme) { try await Stackbar.refresh() }
                }
                if let problem { Banner(problem) }
                if let until = snoozedUntil {
                    Banner("Notifications snoozed until \(Self.clock(until))", symbol: "moon.zzz.fill", theme: .info) {
                        ActionButton("Turn On", theme: theme, key: "end-snooze") { try await self.snooze(minutes: nil) }
                    }
                }
                if watched.isEmpty {
                    EmptyState("Watch a few conversations", symbol: "eye", message: "Pick up to \(Self.maxWatched) channels and people in Settings, or use Open Slack Channel and press ⌘W. Their unread messages show here and in the menu bar.", theme: theme)
                } else if unread.isEmpty {
                    EmptyState("Nothing unread", symbol: "checkmark.circle", message: "In the \(watched.count) conversations you watch.", theme: .success)
                } else {
                    Section("Unread") {
                        ForEach(unread) { item in self.row(item) }
                        if unread.count > 1 {
                            ActionButton("Mark All as Read", symbol: "checkmark.circle", theme: theme, key: "mark-all", confirm: markAllConfirm) { await self.markAllRead() }
                        }
                    }
                }
                HStack(spacing: Space.s) {
                    if snoozedUntil == nil {
                        ActionButton("Snooze 1 Hour", symbol: "moon.zzz", theme: theme, key: "snooze-hour") { try await self.snooze(minutes: 60) }
                    }
                    if status != nil {
                        ActionButton("Clear Status", symbol: "xmark.circle", theme: theme, key: "clear-status") { try await self.setStatus(text: "", emoji: "", minutes: nil) }
                    }
                    Spacer()
                }
            }
        }
    }

    var settings: ViewContent {
        Section("Watched conversations") {
            Text("Their unread messages show in the menu bar and the panel. At most \(Self.maxWatched); each takes two requests every two minutes.").style(.caption)
            ForEach(watched.map { id in (id: id, title: conversation(id)?.title ?? id) }.map(WatchedRow.init)) { item in
                Row(item.title, symbol: self.conversation(item.id)?.symbol ?? "number", key: "watched-" + item.id)
                    .action("Remove") { self.unwatch(item.id) }
            }
            TextField("Add #channel or @person", key: "add-watched") { text in
                if let match = self.resolve(text) {
                    self.watch(match.id)
                    self.settingsNote = nil
                    try await Stackbar.refresh()
                } else {
                    self.settingsNote = self.directory.conversations.isEmpty ? "Add your token first" : "No channel or direct message called \(text)"
                }
            }
            if let settingsNote { Text(settingsNote).role(.warning).style(.caption) }
        }
        Section("Open links in") {
            Picker("Open links in", options: ["Slack app", "Browser"], selection: openIn, style: .segmented) { self.openIn = $0 }
        }
        Section("Notifications") {
            Toggle("Notify about new messages in watched conversations", isOn: notifyNew) { self.notifyNew = $0 }
            Text("Off by default, since Slack's own app notifies too. Checked every two minutes.").style(.caption)
        }
        Section("Server") {
            Picker("Server", options: ["slack.com", "Other"], selection: customServer ? "Other" : "slack.com", style: .segmented) { choice in
                self.customServer = choice == "Other"
                try await Stackbar.refresh()
            }
            if customServer {
                Text("Stackbar asks for the server's address once (SLACK_API_URL), such as slack-gov.com for GovSlack or your company's Slack API gateway.").style(.caption)
            }
        }
        Section("Token") {
            Text("Create a Slack app from the manifest in this plugin's README, install it to your workspace and paste the User OAuth Token (xoxp-…). Stackbar keeps it in your Keychain as SLACK_TOKEN; change or clear it below.").style(.caption)
            if let problem { Text(problem).role(.warning).style(.caption) }
        }
    }

    struct WatchedRow: Identifiable { let id: String; let title: String }

    // MARK: Commands

    var commands: [Command] {
        Command("search", title: "Search Slack Messages", symbol: "magnifyingglass", keywords: ["slack", "message", "find"])
            .view(search: { invocation in await self.search(invocation.text) }) { invocation in
                if invocation.text.trimmingCharacters(in: .whitespaces).count < 2 {
                    ContentUnavailableView("Search your Slack messages", symbol: "magnifyingglass", message: "Slack's own search: in:#channel, from:@person, after:2026-01-01 and quotes work.")
                } else if let problem = self.searchProblem, self.found.isEmpty {
                    ContentUnavailableView("Can't search Slack", symbol: "exclamationmark.triangle", message: problem)
                } else if self.found.isEmpty {
                    ContentUnavailableView("No messages match", symbol: "magnifyingglass")
                } else {
                    List(self.found) { match in self.row(match) }
                }
            }
            .alias("sl")
        Command("open", title: "Open Slack Channel", symbol: "number", keywords: ["slack", "channel", "dm", "person", "switch"])
            .view(search: { _ in try await self.ensureDirectory() }) { _ in
                if let problem = self.problem, self.directory.conversations.isEmpty {
                    ContentUnavailableView("Can't reach Slack", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(searchable: true) {
                        ForEach(self.directory.conversations) { conversation in self.row(conversation) }
                        ForEach(self.directory.people.filter { person in !self.directory.conversations.contains { $0.userID == person.id } && person.id != self.identity?.userId }) { person in self.row(person) }
                    }
                }
            }
        Command("open-conversation", title: "Open Slack Conversation") { invocation in
            guard let conversation = self.conversation(invocation["id"] ?? "") else { return .failure("Slack doesn't list that conversation") }
            return .open(url: self.link(conversation), app: nil)
        }
        .argument("id", placeholder: "Conversation ID")
        .stackbarOnly()
        Command("unread", title: "Slack Unread Messages", symbol: "bubble.left", keywords: ["slack", "unread", "new"])
            .view(search: { _ in try await self.refresh(maxAge: 15) }) { _ in
                if let problem = self.problem, self.unread.isEmpty {
                    ContentUnavailableView("Can't reach Slack", symbol: "exclamationmark.triangle", message: problem)
                } else if self.watched.isEmpty {
                    ContentUnavailableView("No watched conversations", symbol: "eye", message: "Open Slack Channel, then ⌘W on the ones you want here.")
                } else if self.unread.isEmpty {
                    ContentUnavailableView("Nothing unread", symbol: "checkmark.circle")
                } else {
                    List(searchable: true) {
                        ForEach(self.unread) { item in self.row(item) }
                        if self.unread.count > 1 {
                            Row("Mark All as Read", symbol: "checkmark.circle", key: "mark-all")
                                .action("Mark All as Read", confirm: self.markAllConfirm) { await self.markAllRead() }
                        }
                    }
                }
            }
        Command("send", title: "Send Slack Message", symbol: "paperplane", keywords: ["slack", "message", "dm", "post", "write"])
            .view(search: { _ in try await self.ensureDirectory() }) { _ in
                if let problem = self.problem, self.directory.conversations.isEmpty {
                    ContentUnavailableView("Can't reach Slack", symbol: "exclamationmark.triangle", message: problem)
                } else {
                    List(self.destinations.map { Destination(id: $0.id, title: $0.title, symbol: $0.symbol) }, searchable: true) { destination in
                        Row(destination.title, symbol: destination.symbol, key: "to-" + destination.id)
                            .navigate("Write Message", to: "compose", arguments: ["to": destination.id])
                    }
                }
            }
        Command("compose", title: "Slack Message").argument("to", placeholder: "Channel or person ID")
            .view { invocation in
                let target = invocation["to"] ?? ""
                Form(submit: "Send", key: "compose-" + target) {
                    FormField.multiline("Message to \(self.destinationName(target))", name: "text", placeholder: "Slack formatting works: *bold*, _italic_, `code`")
                } onSubmit: { values in
                    try await self.send(values.string("text") ?? "", to: target)
                }
                if let problem = self.sendProblem { Banner(problem) }
                if let sent = self.sent { Banner(sent, symbol: "checkmark.circle.fill", theme: .success) }
            }
            .stackbarOnly()
        Command("status", title: "Set Slack Status", symbol: "face.smiling", keywords: ["slack", "status", "away", "meeting"])
            .view(search: { _ in if self.identity == nil { try await Stackbar.refresh() } }) { _ in
                List {
                    ForEach(Self.presets) { preset in
                        Row("\(Self.emojiGlyph(preset.emoji)) \(preset.text)", subtitle: preset.until, key: "preset-" + preset.text)
                            .action("Set Status") { try await self.setStatus(text: preset.text, emoji: preset.emoji, minutes: preset.minutes) }
                    }
                    if let status = self.status {
                        Row("Clear Status", subtitle: "Now: \(Self.emojiGlyph(status.emoji)) \(status.text)", symbol: "xmark.circle", key: "clear")
                            .action("Clear Status") { try await self.setStatus(text: "", emoji: "", minutes: nil) }
                    }
                }
                Form(submit: "Set Custom Status", key: "custom-status") {
                    FormField.text("Status", name: "text", value: self.status?.text ?? "")
                    FormField.text("Emoji", name: "emoji", value: self.status?.emoji ?? ":speech_balloon:")
                    FormField.picker("Clear after", name: "expiry", options: Self.expiryChoices, selection: "Don't clear")
                } onSubmit: { values in
                    var emoji = (values.string("emoji") ?? "").trimmingCharacters(in: .whitespaces)
                    if !emoji.isEmpty, !emoji.hasPrefix(":") { emoji = ":" + emoji + ":" }
                    try await self.setStatus(text: values.string("text") ?? "", emoji: emoji, minutes: Self.expiryMinutes(values.string("expiry") ?? ""))
                }
                if let problem = self.statusProblem { Banner(problem) }
            }
        Command("clear-status", title: "Clear Slack Status", symbol: "xmark.circle", keywords: ["slack", "status"]) { _ in
            try await self.setStatus(text: "", emoji: "", minutes: nil)
            return .message("Slack status cleared")
        }
        Command("snooze", title: "Snooze Slack Notifications", symbol: "moon.zzz", keywords: ["slack", "dnd", "do not disturb", "pause"]) { invocation in
            let choice = invocation["for"] ?? "1 hour"
            try await self.snooze(minutes: Self.snoozeMinutes(choice))
            if let until = self.snoozedUntil { return .message("Slack snoozed until \(Self.clock(until))") }
            return .message("Slack notifications on")
        }
        .argument("for", required: false, default: "1 hour", options: Self.snoozeChoices)
        Command("presence", title: "Set Slack Presence", symbol: "circle.lefthalf.filled", keywords: ["slack", "away", "active", "online"]) { invocation in
            let away = invocation["presence"] == "Away"
            _ = try await self.call("users.setPresence", ["presence": away ? "away" : "auto"], as: Done.self)
            return .message(away ? "You show as away in Slack" : "Slack sets your presence automatically")
        }
        .argument("presence", required: false, default: "Away", options: ["Away", "Automatic"])
        Command("emoji", title: "Search Slack Emoji", symbol: "face.smiling.inverse", keywords: ["slack", "emoji", "custom", "reaction"])
            .view(search: { _ in await self.loadEmoji() }) { _ in
                if let problem = self.emojiProblem, self.emoji.isEmpty {
                    ContentUnavailableView("Can't load emoji", symbol: "exclamationmark.triangle", message: problem)
                } else if self.emoji.isEmpty {
                    ContentUnavailableView("No custom emoji", symbol: "face.smiling", message: "Your workspace hasn't added any yet.")
                } else {
                    List(Array(self.emoji.prefix(5000)), searchable: true) { item in
                        Row(":\(item.name):", subtitle: item.alias.map { "Alias of :\($0):" }, key: "emoji-" + item.name)
                            .action("Copy") { Stackbar.copy(":\(item.name):") }
                    }
                }
            }
    }

    struct Destination: Identifiable { let id: String; let title: String; let symbol: String }
}
