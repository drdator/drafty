import Foundation
import Observation
import UserNotifications

enum Source: String, Codable, Sendable {
    case slack, gmail
}

enum ReplyTarget: Codable, Sendable {
    case slack(channel: String, threadTs: String?)
    case gmail(Gmail.ReplyTo)
}

/// The latest message in a conversation that may need a reply. The id changes when a newer message arrives.
struct Message: Codable, Sendable, Identifiable {
    let id: String
    let source: Source
    let from: String
    let title: String
    let preview: String
    let date: Date
    let link: URL?
    let target: ReplyTarget

    /// Where a reply lands, used to limit auto-replies per conversation.
    var conversation: String {
        switch target {
        case let .slack(channel, threadTs): "slack:\(channel):\(threadTs ?? "")"
        case let .gmail(reply): "gmail:\(reply.threadId)"
        }
    }
}

/// One message in a conversation, as shown in the thread view and given to Claude.
struct ThreadMessage: Codable, Sendable {
    let author: String
    let date: Date
    let text: String
    let fromMe: Bool
}

/// A message found by a source. The thread is only fetched for messages we haven't triaged yet.
struct Candidate: Sendable {
    let message: Message
    let why: String  // how it reached the user (DM, mention, thread they're in, To or Cc), for Claude
    let canAutoReply: Bool  // a DM with a colleague or an email from your own domain: the only kind auto-reply may answer
    let thread: @Sendable () async throws -> [ThreadMessage]
}

enum Priority: String, Codable, Sendable, Comparable {
    case low, medium, high

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    static func < (a: Priority, b: Priority) -> Bool { a.rank < b.rank }
}

struct Item: Codable, Identifiable {
    let message: Message
    let reason: String
    let priority: Priority?  // nil for items saved before priorities existed
    var thread: [ThreadMessage]?  // the conversation the draft was based on; filled in on the next check if missing
    var why: String?  // as on Candidate; filled in on the next check if missing
    var canAutoReply: Bool?
    var draft: String
    var chat: [ThreadMessage]?  // the user's side chat with Claude about this item
    var id: String { message.id }

    /// The thread, or just the latest message for items saved before threads were kept.
    var messages: [ThreadMessage] {
        thread ?? [ThreadMessage(author: message.from, date: message.date, text: message.preview, fromMe: false)]
    }
}

/// How much Drafty may answer on its own. Each level includes the ones below it.
enum AutoReplyLevel: String, Codable, CaseIterable, Comparable {
    case off, acknowledgements, quickAnswers, routine

    static func < (a: AutoReplyLevel, b: AutoReplyLevel) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// One reply of this kind, as in "Jev is only 36% sure it's a quick answer".
    var kind: String {
        switch self {
        case .off: "Off"
        case .acknowledgements: "Acknowledgement"
        case .quickAnswers: "Quick answer"
        case .routine: "Routine"
        }
    }
}

enum AutoReplySources: String, Codable, CaseIterable {
    case slack, email, both

    func includes(_ source: Source) -> Bool {
        switch self {
        case .slack: source == .slack
        case .email: source == .gmail
        case .both: true
        }
    }
}

/// What auto-reply would do with an item, from the hard rules and Jev. The slider and sources are applied on top,
/// so a dry run stays current while the user adjusts them.
enum AutoReplyOutcome {
    case eligible(AutoReplyLevel, confidence: Double)  // Jev is sure enough, the sender isn't an agent, no rule blocks it
    case kept(String)  // stays with the user, and why
}

struct DryRunResult: Identifiable {
    let item: Item
    let outcome: AutoReplyOutcome
    var id: String { item.id }
}

/// A reply that went out from Drafty, kept so the user can see what was sent.
struct SentReply: Codable, Identifiable {
    let message: Message
    let thread: [ThreadMessage]  // including the reply that was sent
    let reply: String
    let level: AutoReplyLevel?  // set when Drafty sent it on its own
    let confidence: Double?
    let sentAt: Date
    var id: String { message.id }
}

struct Settings: Codable {
    var slackToken = ""
    var googleClientID = ""
    var googleClientSecret = ""
    var googleRefreshToken = ""
    var aboutMe = ""
    var jevKey = ""
    var autoReplyLevel = AutoReplyLevel.off
    var autoReplySources = AutoReplySources.slack
}

extension Settings {
    /// Missing keys fall back to their defaults, so adding a setting never throws away the saved ones.
    init(from decoder: any Decoder) throws {
        self.init()
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        slackToken = try saved.decodeIfPresent(String.self, forKey: .slackToken) ?? slackToken
        googleClientID = try saved.decodeIfPresent(String.self, forKey: .googleClientID) ?? googleClientID
        googleClientSecret = try saved.decodeIfPresent(String.self, forKey: .googleClientSecret) ?? googleClientSecret
        googleRefreshToken = try saved.decodeIfPresent(String.self, forKey: .googleRefreshToken) ?? googleRefreshToken
        aboutMe = try saved.decodeIfPresent(String.self, forKey: .aboutMe) ?? aboutMe
        jevKey = try saved.decodeIfPresent(String.self, forKey: .jevKey) ?? jevKey
        autoReplyLevel = try saved.decodeIfPresent(AutoReplyLevel.self, forKey: .autoReplyLevel) ?? autoReplyLevel
        autoReplySources = try saved.decodeIfPresent(AutoReplySources.self, forKey: .autoReplySources) ?? autoReplySources
    }
}

@MainActor @Observable
final class Inbox {
    var settings = Settings() {
        didSet { makeClients(); save() }
    }
    var items: [Item] = [] {
        didSet { save() }
    }
    var sent: [SentReply] = [] {
        didSet { save() }
    }
    /// The item whose draft came back from a Claude Code session most recently, until the user edits it.
    var fromClaudeCode: String?
    /// Items that will be sent automatically at the given time unless cancelled.
    var autoSendAt: [String: Date] = [:]
    var dryRun: [DryRunResult]?
    var dryRunning = false
    var status = ""
    var checking = false

    var isConfigured: Bool {
        !settings.slackToken.isEmpty || !settings.googleRefreshToken.isEmpty
    }

    /// Messages that were triaged as not needing a reply, dismissed or answered, so we never look at them twice.
    @ObservationIgnored private var handled: [String: Date] = [:]
    @ObservationIgnored private var slack: Slack?
    @ObservationIgnored private var gmail: Gmail?

    private static let file = URL.applicationSupportDirectory.appending(path: "Drafty/state.json")
    private static let checkInterval = Duration.seconds(180)
    private static let maxTriagePerCheck = 20
    private static let autoReplyDelay = 60.0
    private static let autoReplyConfidence = 0.9

    private struct Saved: Codable {
        var settings: Settings
        var items: [Item]
        var handled: [String: Date]
        var sent: [SentReply]?
    }

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            settings = saved.settings
            items = saved.items
            handled = saved.handled
            sent = saved.sent ?? []
        }
        makeClients()
    }

    func start() {
        Task {
            while true {
                await check()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func check() async {
        guard isConfigured, !checking else { return }
        checking = true
        defer { checking = false }

        var found: [Candidate] = []
        var fetched: Set<Source> = []
        var errors: [String] = []
        if let slack {
            do { found += try await slack.candidates(); fetched.insert(.slack) }
            catch { errors.append("Slack: \(error.localizedDescription)") }
        }
        if let gmail {
            do { found += try await gmail.candidates(); fetched.insert(.gmail) }
            catch { errors.append("Gmail: \(error.localizedDescription)") }
        }

        // Conversations that moved on (you replied elsewhere, a newer message arrived, it was archived) drop out.
        let current = Set(found.map(\.message.id))
        items.removeAll { fetched.contains($0.message.source) && !current.contains($0.id) }

        for candidate in found where items.contains(where: { $0.id == candidate.message.id && $0.thread == nil }) {
            let thread = try? await candidate.thread()
            if let index = items.firstIndex(where: { $0.id == candidate.message.id }) {
                items[index].thread = thread
            }
        }

        for candidate in found {
            guard let index = items.firstIndex(where: { $0.id == candidate.message.id }), items[index].canAutoReply == nil else { continue }
            items[index].why = candidate.why
            items[index].canAutoReply = candidate.canAutoReply
        }

        let known = Set(items.map(\.id))
        let fresh = found
            .filter { handled[$0.message.id] == nil && !known.contains($0.message.id) }
            .sorted { $0.message.date > $1.message.date }
            .prefix(Self.maxTriagePerCheck)
        let claude = Claude(aboutMe: settings.aboutMe)
        var added: [Item] = []
        // One at a time: each is a claude process, and items show up as soon as they're drafted.
        for (index, candidate) in fresh.enumerated() {
            let message = candidate.message
            status = "Reading \(index + 1) of \(fresh.count)…"
            do {
                let thread = try await candidate.thread()
                let verdict = try await claude.triage(message, thread: thread, why: candidate.why)
                if verdict.needsReply {
                    let item = Item(message: message, reason: verdict.reason, priority: verdict.priority, thread: thread,
                                    why: candidate.why, canAutoReply: candidate.canAutoReply, draft: verdict.draft)
                    added.append(item)
                    items.append(item)
                    await considerAutoReply(item)
                } else {
                    handled[message.id] = .now
                }
            } catch {
                errors.append("\(message.from): \(error.localizedDescription)")
            }
        }
        handled = handled.filter { $0.value > .now.addingTimeInterval(-14 * 86400) }
        notify(added.filter { autoSendAt[$0.id] == nil })
        status = errors.first ?? "Checked \(Date.now.formatted(date: .omitted, time: .shortened))"
    }

    func send(_ item: Item, text: String, auto: (level: AutoReplyLevel, confidence: Double)? = nil) async throws {
        switch item.message.target {
        case let .slack(channel, threadTs):
            guard let slack else { throw AppError("Slack isn't connected") }
            try await slack.post(text, channel: channel, threadTs: threadTs)
        case let .gmail(replyTo):
            guard let gmail else { throw AppError("Gmail isn't connected") }
            try await gmail.reply(text, to: replyTo)
        }
        let reply = ThreadMessage(author: "You", date: .now, text: text, fromMe: true)
        let entry = SentReply(message: item.message, thread: (item.thread ?? []) + [reply], reply: text,
                              level: auto?.level, confidence: auto?.confidence, sentAt: .now)
        sent = Array(([entry] + sent).prefix(200))
        dismiss(item)
    }

    func dismiss(_ item: Item) {
        handled[item.id] = .now
        items.removeAll { $0.id == item.id }
    }

    /// Rewrites a draft with the current About you, taking the user's edits, chat and comment into account.
    func redraft(_ item: Item, current: String, comment: String, tools: ToolAccess = .off) async throws -> String {
        try await Claude(aboutMe: settings.aboutMe)
            .redraft(item.message, thread: item.messages, current: current, comment: comment,
                     chat: items.first { $0.id == item.id }?.chat ?? [], tools: tools)
    }

    /// Asks Claude about an item in its side chat, or gives it context for the next draft.
    func ask(_ item: Item, _ question: String, tools: ToolAccess = .off) async throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        cancelAutoReply(item.id)  // the user is working on it
        items[index].chat = (items[index].chat ?? []) + [ThreadMessage(author: "You", date: .now, text: question, fromMe: true)]
        let current = items[index]
        do {
            let answer = try await Claude(aboutMe: settings.aboutMe)
                .chat(about: current.message, thread: current.messages, draft: current.draft, chat: current.chat ?? [], tools: tools)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].chat?.append(ThreadMessage(author: "Claude", date: .now, text: answer, fromMe: false))
            }
        } catch {
            // Take the question back out, so the user can send it again.
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].chat?.removeLast() }
            throw error
        }
    }

    /// Has Claude rewrite About you from the user's own recent Slack messages and sent email.
    func writeAboutMe() async {
        status = "Reading your messages…"
        do {
            var samples: [String] = []
            if let slack { samples += try await slack.myMessages() }
            if let gmail { samples += try await gmail.sentMessages() }
            guard !samples.isEmpty else { throw AppError("Found no messages you've written") }
            status = "Describing your style from \(samples.count) messages…"
            settings.aboutMe = try await Claude(aboutMe: settings.aboutMe).describeStyle(samples: samples)
            status = "About you updated from \(samples.count) of your messages"
        } catch {
            status = "About you: \(error.localizedDescription)"
        }
    }

    func setDraft(_ id: String, _ draft: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].draft != draft else { return }
        items[index].draft = draft
        cancelAutoReply(id)  // the user is working on it
        if fromClaudeCode == id { fromClaudeCode = nil }
    }

    /// Makes a reply written in a Claude Code session the item's draft. False when the item is gone.
    func useReply(_ text: String, for id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        cancelAutoReply(id)
        items[index].draft = text
        fromClaudeCode = id
        return true
    }

    func cancelAutoReply(_ id: String) {
        guard autoSendAt.removeValue(forKey: id) != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["auto:\(id)"])
    }

    private func considerAutoReply(_ item: Item) async {
        guard settings.autoReplyLevel != .off, settings.autoReplySources.includes(item.message.source),
              case let .eligible(level, confidence) = await autoReplyOutcome(item), level <= settings.autoReplyLevel
        else { return }
        scheduleAutoReply(item, level: level, confidence: confidence)
    }

    /// Checks every item in the list as auto-reply would, without sending anything.
    func runDryRun() async {
        dryRunning = true
        defer { dryRunning = false }
        var results: [DryRunResult] = []
        for item in items.sorted(by: { $0.message.date > $1.message.date }) {
            results.append(DryRunResult(item: item, outcome: await autoReplyOutcome(item)))
        }
        dryRun = results
    }

    /// The hard rules come first, in code, so no message can talk its way past them. Then Jev judges the draft.
    private func autoReplyOutcome(_ item: Item) async -> AutoReplyOutcome {
        let anHourAgo = Date.now.addingTimeInterval(-3600)
        guard !settings.jevKey.isEmpty else { return .kept("No Jev key") }
        guard let allowed = item.canAutoReply else { return .kept("Not known until the next check") }
        guard allowed else {
            return .kept(item.message.source == .slack ? "Not a DM with a colleague" : "Not an email to you from your own domain")
        }
        if item.priority == .high { return .kept("High priority") }
        if item.draft.isEmpty { return .kept("No draft") }
        if let placeholder = item.draft.firstPlaceholder { return .kept("The draft has \(placeholder)") }
        if sent.contains(where: { $0.level != nil && $0.message.conversation == item.message.conversation && $0.sentAt > anHourAgo }) {
            return .kept("Already auto-replied in this conversation within the hour")
        }

        let percent = { (value: Double) in "\(Int((value * 100).rounded()))%" }
        do {
            let decision = try await Jev(key: settings.jevKey).judge(item.message, thread: item.thread ?? [], why: item.why ?? "", draft: item.draft)
            if decision.fromAgent >= 0.5 { return .kept("From a bot or agent (\(percent(decision.fromAgent)))") }
            guard let level = decision.level else { return .kept("Needs you (Jev is \(percent(decision.confidence)) sure)") }
            guard decision.confidence >= Self.autoReplyConfidence else {
                return .kept("Jev is only \(percent(decision.confidence)) sure it's a \(level.kind.lowercased())")
            }
            return .eligible(level, confidence: decision.confidence)
        } catch {
            return .kept("Jev failed: \(error.localizedDescription)")
        }
    }

    private func scheduleAutoReply(_ item: Item, level: AutoReplyLevel, confidence: Double) {
        autoSendAt[item.id] = .now.addingTimeInterval(Self.autoReplyDelay)
        notifyAutoReply(item)
        Task {
            try? await Task.sleep(for: .seconds(Self.autoReplyDelay))
            guard autoSendAt.removeValue(forKey: item.id) != nil,
                  let current = items.first(where: { $0.id == item.id })
            else { return }
            do {
                try await send(current, text: current.draft, auto: (level, confidence))
            } catch {
                status = "Auto-reply to \(current.message.from) failed: \(error.localizedDescription)"
            }
        }
    }

    func connectGmail() async {
        do {
            settings.googleRefreshToken = try await Gmail.authorize(
                clientID: settings.googleClientID, clientSecret: settings.googleClientSecret)
            status = "Gmail connected"
        } catch {
            status = "Gmail: \(error.localizedDescription)"
        }
    }

    private func makeClients() {
        slack = settings.slackToken.isEmpty ? nil : Slack(token: settings.slackToken)
        gmail = settings.googleRefreshToken.isEmpty ? nil : Gmail(
            clientID: settings.googleClientID,
            clientSecret: settings.googleClientSecret,
            refreshToken: settings.googleRefreshToken)
    }

    private func notify(_ added: [Item]) {
        guard let first = added.first else { return }
        let content = UNMutableNotificationContent()
        if added.count == 1 {
            content.title = "\(first.message.from) · \(first.message.title)"
            content.body = first.reason
        } else {
            content.title = "\(added.count) messages need a reply"
            content.body = added.map(\.message.from).joined(separator: ", ")
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func notifyAutoReply(_ item: Item) {
        let content = UNMutableNotificationContent()
        content.title = "Auto-replying to \(item.message.from) in \(Int(Self.autoReplyDelay)) s"
        content.body = item.draft
        content.categoryIdentifier = "autoReply"
        content.userInfo = ["item": item.id]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "auto:\(item.id)", content: content, trigger: nil))
    }

    /// Settings hold API tokens, so the file is only readable by you.
    private func save() {
        do {
            let directory = Self.file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Saved(settings: settings, items: items, handled: handled, sent: sent))
                .write(to: Self.file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
