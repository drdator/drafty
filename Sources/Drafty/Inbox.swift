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
    var draft: String
    var id: String { message.id }
}

struct Settings: Codable {
    var slackToken = ""
    var googleClientID = ""
    var googleClientSecret = ""
    var googleRefreshToken = ""
    var aboutMe = ""
}

@MainActor @Observable
final class Inbox {
    var settings = Settings() {
        didSet { makeClients(); save() }
    }
    var items: [Item] = [] {
        didSet { save() }
    }
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

    private struct Saved: Codable {
        var settings: Settings
        var items: [Item]
        var handled: [String: Date]
    }

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            settings = saved.settings
            items = saved.items
            handled = saved.handled
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
                    let item = Item(message: message, reason: verdict.reason, priority: verdict.priority, thread: thread, draft: verdict.draft)
                    added.append(item)
                    items.append(item)
                } else {
                    handled[message.id] = .now
                }
            } catch {
                errors.append("\(message.from): \(error.localizedDescription)")
            }
        }
        handled = handled.filter { $0.value > .now.addingTimeInterval(-14 * 86400) }
        notify(added)
        status = errors.first ?? "Checked \(Date.now.formatted(date: .omitted, time: .shortened))"
    }

    func send(_ item: Item, text: String) async throws {
        switch item.message.target {
        case let .slack(channel, threadTs):
            guard let slack else { throw AppError("Slack isn't connected") }
            try await slack.post(text, channel: channel, threadTs: threadTs)
        case let .gmail(replyTo):
            guard let gmail else { throw AppError("Gmail isn't connected") }
            try await gmail.reply(text, to: replyTo)
        }
        dismiss(item)
    }

    func dismiss(_ item: Item) {
        handled[item.id] = .now
        items.removeAll { $0.id == item.id }
    }

    /// Rewrites a draft with the current About you, taking the user's edits and comment into account.
    func redraft(_ item: Item, current: String, comment: String) async throws -> String {
        try await Claude(aboutMe: settings.aboutMe)
            .redraft(item.message, thread: item.thread ?? [ThreadMessage(author: item.message.from, date: item.message.date, text: item.message.preview, fromMe: false)],
                     current: current, comment: comment)
    }

    func setDraft(_ id: String, _ draft: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].draft = draft
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

    /// Settings hold API tokens, so the file is only readable by you.
    private func save() {
        do {
            let directory = Self.file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Saved(settings: settings, items: items, handled: handled)).write(to: Self.file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
