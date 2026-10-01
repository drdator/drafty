import Foundation

/// Finds DMs and @mentions you haven't answered, and posts replies as you. Uses a user token (xoxp-…).
actor Slack {
    private static let lookbackDays = 2.0

    private let token: String
    private var me: String?
    private var names: [String: String] = [:]

    init(token: String) {
        self.token = token
    }

    func candidates() async throws -> [Candidate] {
        let me = try await myID()
        let after = Date.now.addingTimeInterval(-Self.lookbackDays * 86400).formatted(.iso8601.year().month().day())
        async let dms = search("to:me after:\(after)")
        async let mentions = search("<@\(me)> after:\(after)")
        async let mine = search("from:me after:\(after)")

        // A conversation is answered if your latest message in it is newer than theirs.
        var answered: [String: String] = [:]
        for message in try await mine {
            answered[message.key] = max(answered[message.key] ?? "", message.ts)
        }
        var latest: [String: Match] = [:]
        for message in try await dms + mentions
        where message.user != nil && message.user != me && message.user != "USLACKBOT" && message.ts > latest[message.key]?.ts ?? "" {
            latest[message.key] = message
        }

        var result: [Candidate] = []
        for message in latest.values where message.ts > answered[message.key] ?? "" {
            result.append(await candidate(message))
        }
        return result
    }

    func post(_ text: String, channel: String, threadTs: String?) async throws {
        var request = URLRequest(url: URL(string: "https://slack.com/api/chat.postMessage")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Post(channel: channel, text: text, thread_ts: threadTs))
        _ = try unwrap(await http(request), as: Envelope.self)
    }

    private func candidate(_ match: Match) async -> Candidate {
        let (channel, threadTs, ts, isDM) = (match.channel.id, match.threadTs, match.ts, match.isDM)
        let message = Message(
            id: "slack:\(match.key):\(ts)",
            source: .slack,
            from: await name(match.user ?? ""),
            title: isDM ? (match.channel.is_mpim == true ? "Group DM" : "DM") : "#\(match.channel.name ?? channel)",
            preview: await readable(match.text),
            date: Date(timeIntervalSince1970: Double(ts) ?? 0),
            link: URL(string: match.permalink),
            // Reply in the thread if there is one; channel mentions get a new thread, DMs a plain message.
            target: .slack(channel: channel, threadTs: threadTs ?? (isDM ? nil : ts))
        )
        return Candidate(message: message) { [self] in
            try await transcript(channel: channel, threadTs: threadTs, latest: ts)
        }
    }

    private func transcript(channel: String, threadTs: String?, latest: String) async throws -> String {
        let me = try await myID()
        var messages: [Msg]
        if let threadTs {
            let thread = try await call("conversations.replies", ["channel": channel, "ts": threadTs, "limit": "100"], as: History.self).messages
            messages = Array(thread.prefix(1) + thread.dropFirst().suffix(29))
        } else {
            let history = try await call("conversations.history", ["channel": channel, "latest": latest, "inclusive": "true", "limit": "15"], as: History.self)
            messages = history.messages.reversed()
        }

        var lines: [String] = []
        for message in messages {
            let who: String
            if let user = message.user {
                who = user == me ? "The user" : await name(user)
            } else {
                who = message.username ?? "Bot"
            }
            let time = Date(timeIntervalSince1970: Double(message.ts) ?? 0).formatted(date: .abbreviated, time: .shortened)
            lines.append("[\(time)] \(who): \(await readable(message.text ?? ""))")
        }
        return lines.joined(separator: "\n")
    }

    private func search(_ query: String) async throws -> [Match] {
        try await call("search.messages", ["query": query, "sort": "timestamp", "count": "100"], as: Search.self).messages.matches
    }

    private func myID() async throws -> String {
        if let me { return me }
        let id = try await call("auth.test", [:], as: AuthTest.self).user_id
        me = id
        return id
    }

    private func name(_ id: String) async -> String {
        if let cached = names[id] { return cached }
        guard let info = try? await call("users.info", ["user": id], as: UserInfo.self) else { return id }
        let name = [info.user.profile.display_name, info.user.profile.real_name, info.user.name]
            .compactMap { $0 }.first { !$0.isEmpty } ?? id
        names[id] = name
        return name
    }

    /// Replaces <@U123> mentions with names and unescapes Slack's entities.
    private func readable(_ text: String) async -> String {
        var result = text
        for mention in text.matches(of: #/<@([A-Z0-9]+)(?:\|[^>]*)?>/#) {
            let who = await name(String(mention.1))
            result = result.replacingOccurrences(of: String(mention.0), with: "@\(who)")
        }
        return result.decodingEntities
    }

    private func call<T: Decodable>(_ method: String, _ params: [String: String], as type: T.Type) async throws -> T {
        var url = URLComponents(string: "https://slack.com/api/\(method)")!
        url.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try unwrap(await http(request), as: type)
    }

    /// Slack answers errors with HTTP 200 and `ok: false`.
    private func unwrap<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.ok else { throw AppError(envelope.error ?? "request failed") }
        return try JSONDecoder().decode(type, from: data)
    }

    private struct Match: Decodable, Sendable {
        let ts: String
        let text: String
        let user: String?
        let permalink: String
        let channel: Channel

        struct Channel: Decodable, Sendable {
            let id: String
            let name: String?
            let is_im: Bool?
            let is_mpim: Bool?
        }

        var isDM: Bool { channel.is_im == true || channel.is_mpim == true || channel.id.hasPrefix("D") }
        var threadTs: String? { URLComponents(string: permalink)?.queryItems?.first { $0.name == "thread_ts" }?.value }
        /// The conversation a reply would land in: a thread, a DM, or a new thread on a channel message.
        var key: String { "\(channel.id):\(threadTs ?? (isDM ? "" : ts))" }
    }

    private struct Envelope: Decodable {
        let ok: Bool
        let error: String?
    }

    private struct Search: Decodable {
        let messages: Matches
        struct Matches: Decodable { let matches: [Match] }
    }

    private struct History: Decodable {
        let messages: [Msg]
    }

    private struct Msg: Decodable {
        let ts: String
        let text: String?
        let user: String?
        let username: String?
    }

    private struct UserInfo: Decodable {
        let user: User
        struct User: Decodable {
            let name: String
            let profile: Profile
        }
        struct Profile: Decodable {
            let display_name: String?
            let real_name: String?
        }
    }

    private struct AuthTest: Decodable {
        let user_id: String
    }

    private struct Post: Encodable {
        let channel: String
        let text: String
        let thread_ts: String?
    }
}
