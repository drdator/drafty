import ServiceManagement
import SwiftUI

enum SortOrder: String {
    case priority, newest
}

struct ContentView: View {
    let inbox: Inbox
    @State private var showSettings = false
    @State private var showLog = false
    @AppStorage("sortOrder") private var sortOrder = SortOrder.priority
    @AppStorage("theme") private var theme = Theme.system

    private var sortedItems: [Item] {
        switch sortOrder {
        case .priority:
            inbox.items.sorted { ($0.priority ?? .medium, $0.message.date) > ($1.priority ?? .medium, $1.message.date) }
        case .newest:
            inbox.items.sorted { $0.message.date > $1.message.date }
        }
    }

    var body: some View {
        // Settings is the only page until something is connected, so there's nowhere to go back to then.
        let onPage = (showSettings || showLog) && inbox.isConfigured
        VStack(spacing: 0) {
            HStack {
                if onPage {
                    Button { showSettings = false; showLog = false } label: { Image(systemName: "chevron.left") }
                        .help("Back to messages")
                }
                Text(showSettings || !inbox.isConfigured ? "Settings" : showLog ? "Sent" : "Needs reply").font(.headline)
                Spacer()
                if inbox.checking { ProgressView().controlSize(.small) }
                if !onPage {
                    Menu {
                        Picker("Sort by", selection: $sortOrder) {
                            Text("Priority").tag(SortOrder.priority)
                            Text("Newest first").tag(SortOrder.newest)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Sort")
                }
                Button { Task { await inbox.check() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(inbox.checking || !inbox.isConfigured)
                Button { showLog.toggle(); showSettings = false } label: { Image(systemName: "clock.arrow.circlepath") }
                    .foregroundStyle(showLog ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .help("Sent replies")
                Button { showSettings.toggle(); showLog = false } label: { Image(systemName: "gearshape") }
                    .foregroundStyle(showSettings ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .help("Settings")
            }
            .buttonStyle(.borderless)
            .padding(12)
            Hairline()

            Group {
                if showSettings || !inbox.isConfigured {
                    SettingsView(inbox: inbox) {
                        showSettings = false
                        Task { await inbox.check() }
                    }
                } else if showLog {
                    SentLog(inbox: inbox)
                } else if inbox.items.isEmpty {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.circle")
                } else {
                    ScrollView {
                        // Cards on glass; flat sections divided by hairlines in the solid themes.
                        LazyVStack(spacing: theme.palette == nil ? 10 : 0) {
                            ForEach(sortedItems) { item in
                                ItemView(inbox: inbox, item: item)
                                if theme.palette != nil { Hairline() }
                            }
                        }
                        .padding(theme.palette == nil ? 12 : 0)
                    }
                }
            }
            // Fill the popover so the header stays at the top, even on a short page.
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Hairline()
            Text(inbox.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 440, height: 620)
        .background(theme.palette?.panel ?? .clear)
        .preferredColorScheme(theme.palette?.scheme)
        .environment(\.palette, theme.palette)
    }
}

struct ItemView: View {
    let inbox: Inbox
    let item: Item
    @State private var draft: String
    @State private var sending = false
    @State private var comment = ""
    @State private var redrafting = false
    @State private var showThread = false
    @AppStorage("toolAccess") private var toolAccess = ToolAccess.off
    @State private var error: String?
    @State private var unfilled: String?  // a [placeholder] the user is asked to confirm before sending
    @FocusState private var editing: Bool
    @Environment(\.palette) private var palette

    init(inbox: Inbox, item: Item) {
        self.inbox = inbox
        self.item = item
        _draft = State(initialValue: item.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageHeader(message: item.message, priority: item.priority, hasThread: item.thread != nil, showThread: $showThread)
            if showThread, let thread = item.thread {
                ThreadView(thread: thread)
            } else {
                Text(item.message.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text(item.reason).font(.callout).italic()

            TextEditor(text: $draft)
                .focused($editing)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 70, maxHeight: 160)
                .raised(palette)
                .disabled(redrafting)
                .onChange(of: draft) {
                    inbox.setDraft(item.id, draft)
                    unfilled = nil
                }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let unfilled {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("This draft still has \(unfilled).")
                    Spacer()
                    Button("Cancel") { self.unfilled = nil }
                        .themedButton(palette)
                    Button("Send anyway") {
                        self.unfilled = nil
                        send()
                    }
                    .themedButton(palette, prominent: true)
                }
                .font(.system(size: 12))
                .padding(8)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: Palette.radius))
            }
            if let sendAt = inbox.autoSendAt[item.id] {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        Image(systemName: "paperplane")
                        Text("Sending automatically in \(max(0, Int(sendAt.timeIntervalSince(context.date).rounded()))) s")
                        Spacer()
                        Button("Cancel") { inbox.cancelAutoReply(item.id) }
                            .themedButton(palette)
                    }
                    .font(.system(size: 12))
                    .padding(8)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Palette.radius))
                }
            }
            HStack(spacing: 8) {
                Button("Dismiss") { inbox.dismiss(item) }
                    .themedButton(palette)
                HStack(spacing: 4) {
                    TextField("Redraft with a comment…", text: $comment)
                        .textFieldStyle(.plain)
                        .onSubmit { redraft() }
                    if redrafting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button { redraft() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Redraft")
                        if toolAccess != .off {
                            Button { redraft(tools: toolAccess) } label: { Image(systemName: "wrench.and.screwdriver") }
                                .buttonStyle(.borderless)
                                .help(toolAccess == .full ? "Redraft with full access to your computer" : "Redraft, reading your files if useful")
                        }
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .raised(palette)
                .disabled(redrafting || sending)
                Button(sending ? "Sending…" : "Send") {
                    if let placeholder = draft.firstPlaceholder { unfilled = placeholder } else { send() }
                }
                    .themedButton(palette, prominent: true)
                    .disabled(sending || redrafting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    // Every item has a Send button, so ⌘↩ belongs to the one whose draft is being edited.
                    .keyboardShortcut(editing ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .help("Send (⌘↩)")
            }
        }
        .padding(palette == nil ? 12 : 16)
        .background {
            if palette == nil { RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)) }
        }
    }

    private func redraft(tools: ToolAccess = .off) {
        redrafting = true
        error = nil
        Task {
            do {
                draft = try await inbox.redraft(item, current: draft, comment: comment, tools: tools)
                comment = ""
            } catch {
                self.error = error.localizedDescription
            }
            redrafting = false
        }
    }

    private func send() {
        sending = true
        error = nil
        Task {
            do {
                try await inbox.send(item, text: draft)
            } catch {
                self.error = error.localizedDescription
                sending = false
            }
        }
    }
}

/// Sender, where it came from and when, with buttons for the thread and for opening it in Slack or Gmail.
struct MessageHeader: View {
    let message: Message
    var priority: Priority?
    let hasThread: Bool
    @Binding var showThread: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let priority, priority != .low {
                Circle()
                    .fill(priority == .high ? Color.red : Color.orange)
                    .frame(width: 7, height: 7)
                    .help("\(priority.rawValue.capitalized) priority")
            }
            Image(nsImage: message.source == .slack ? Logo.slack : Logo.gmail)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
            Text(message.from).fontWeight(.semibold).lineLimit(1)
            Text(message.title).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(message.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                .font(.caption)
                .foregroundStyle(.secondary)
            if hasThread {
                Button { showThread.toggle() } label: {
                    Image(systemName: showThread ? "text.bubble.fill" : "text.bubble")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .help(showThread ? "Hide thread" : "Show thread")
            }
            if let link = message.link {
                Link(destination: link) { Image(systemName: "arrow.up.forward.square") }
                    .help("Open in \(message.source == .slack ? "Slack" : "Gmail")")
            }
        }
    }
}

/// One message in a dry run: what auto-reply would send, or why it would leave it to you.
/// The slider and sources are applied live, so the results follow the settings.
struct DryRunRow: View {
    let result: DryRunResult
    let settings: Settings

    private var verdict: (sends: Bool, text: String) {
        let source = result.item.message.source
        guard settings.autoReplySources.includes(source) else {
            return (false, "Stays with you: \(source == .slack ? "Slack" : "email") isn't included")
        }
        switch result.outcome {
        case let .eligible(level, confidence) where settings.autoReplyLevel != .off && level <= settings.autoReplyLevel:
            return (true, "Would send · \(level.kind) · \(Int((confidence * 100).rounded()))% sure")
        case let .eligible(level, confidence):
            return (false, "Would send at \(level.label) or higher · \(Int((confidence * 100).rounded()))% sure")
        case let .kept(reason):
            return (false, "Stays with you: \(reason)")
        }
    }

    var body: some View {
        let verdict = verdict
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: verdict.sends ? "paperplane.fill" : "hand.raised")
                .foregroundStyle(verdict.sends ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(nsImage: result.item.message.source == .slack ? Logo.slack : Logo.gmail)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                    Text(result.item.message.from).fontWeight(.semibold).lineLimit(1)
                    Text(result.item.message.title).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.system(size: 12))
                if verdict.sends {
                    Text(result.item.draft)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: Palette.radius))
                }
                Text(verdict.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Replies sent from Drafty, by the user or on its own, newest first.
struct SentLog: View {
    let inbox: Inbox
    @Environment(\.palette) private var palette

    var body: some View {
        if inbox.sent.isEmpty {
            ContentUnavailableView(
                "Nothing sent yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Replies you send from Drafty show up here, and so do the ones it sends on its own."))
        } else {
            ScrollView {
                LazyVStack(spacing: palette == nil ? 10 : 0) {
                    ForEach(inbox.sent) { reply in
                        SentRow(reply: reply)
                        if palette != nil { Hairline() }
                    }
                }
                .padding(palette == nil ? 12 : 0)
            }
        }
    }
}

struct SentRow: View {
    let reply: SentReply
    @State private var showThread = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageHeader(message: reply.message, hasThread: true, showThread: $showThread)
            if showThread {
                ThreadView(thread: reply.thread)
            } else {
                Text(reply.message.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text(reply.reply)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: Palette.radius))
            }
            HStack(spacing: 6) {
                if let level = reply.level {
                    HStack(spacing: 3) { Image(systemName: "sparkles"); Text("Auto") }
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: Palette.radius))
                        .help("Drafty sent this on its own")
                    Text("\(reply.sentAt.formatted(date: .abbreviated, time: .shortened)) · \(level.kind) · \(Int((reply.confidence ?? 0) * 100))% sure")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sent \(reply.sentAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(palette == nil ? 12 : 16)
        .background {
            if palette == nil { RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)) }
        }
    }
}

/// The conversation as chat bubbles: others on the left with an initial, yours on the right.
struct ThreadView: View {
    let thread: [ThreadMessage]
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(thread.enumerated()), id: \.offset) { _, message in
                    bubble(message)
                }
            }
            .padding(10)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: 280)
        .background(palette?.recessed ?? Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Palette.radius))
    }

    private func bubble(_ message: ThreadMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if message.fromMe {
                Spacer(minLength: 48)
            } else {
                Avatar(name: message.author)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(message.fromMe ? "You" : message.author).fontWeight(.semibold)
                    Text(Self.time(message.date)).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                Text(message.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background { background(fromMe: message.fromMe) }
            if !message.fromMe {
                Spacer(minLength: 24)
            }
        }
    }

    @ViewBuilder
    private func background(fromMe: Bool) -> some View {
        if let palette {
            ControlSurface(palette: palette, fill: fromMe ? Color.accentColor.opacity(palette.scheme == .dark ? 0.3 : 0.14) : nil)
        } else {
            RoundedRectangle(cornerRadius: Palette.radius)
                .fill(fromMe ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.background.opacity(0.7)))
        }
    }

    private static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// The sender's initial on a color that stays the same for the same name.
struct Avatar: View {
    let name: String
    private static let colors: [Color] = [.red, .orange, .green, .teal, .blue, .indigo, .purple, .pink]

    var body: some View {
        let seed = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        Circle()
            .fill(Self.colors[seed % Self.colors.count].gradient)
            .frame(width: 22, height: 22)
            .overlay(Text(name.prefix(1).uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
    }
}

struct SettingsView: View {
    @Bindable var inbox: Inbox
    let done: () -> Void
    @State private var connecting: Task<Void, Never>?
    @State private var writingAboutMe = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("theme") private var theme = Theme.system
    @AppStorage("toolAccess") private var toolAccess = ToolAccess.off
    @State private var pendingToolAccess: ToolAccess?
    @Environment(\.palette) private var palette

    private static let autoReplyRules = """
        Only DMs with colleagues and email from your own domain. Never high priority, never a draft with a \
        [placeholder], never to a bot or agent, at most once an hour per conversation, and only when Jev is at \
        least 90% sure. Each one waits 60 s so you can cancel it, and is listed under the clock icon.
        """

    private var autoReplyStep: Binding<Double> {
        Binding(
            get: { Double(AutoReplyLevel.allCases.firstIndex(of: inbox.settings.autoReplyLevel)!) },
            set: { inbox.settings.autoReplyLevel = AutoReplyLevel.allCases[Int($0.rounded())] })
    }

    /// More access only takes effect after the warning is accepted; less access applies right away.
    private var toolAccessSelection: Binding<ToolAccess> {
        Binding(
            get: { pendingToolAccess ?? toolAccess },
            set: { level in
                if level > toolAccess {
                    pendingToolAccess = level
                } else {
                    toolAccess = level
                    pendingToolAccess = nil
                }
            })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                section("Appearance") {
                    Segmented(selection: $theme, options: Theme.allCases) { $0.label }
                }
                section("Slack") {
                    field("Token") { SecureField("xoxp-…", text: $inbox.settings.slackToken) }
                }
                section("Gmail") {
                    field("Client ID") { TextField("…apps.googleusercontent.com", text: $inbox.settings.googleClientID) }
                    field("Secret") { SecureField("GOCSPX-…", text: $inbox.settings.googleClientSecret) }
                    HStack {
                        Text(connecting != nil ? "Waiting for browser…" : inbox.settings.googleRefreshToken.isEmpty ? "Not connected" : "Connected")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let connecting {
                            Button("Cancel") { connecting.cancel() }
                                .themedButton(palette)
                        } else {
                            Button(inbox.settings.googleRefreshToken.isEmpty ? "Connect" : "Reconnect") {
                                connecting = Task {
                                    await inbox.connectGmail()
                                    connecting = nil
                                }
                            }
                            .themedButton(palette)
                            .disabled(inbox.settings.googleClientID.isEmpty || inbox.settings.googleClientSecret.isEmpty)
                        }
                    }
                }
                section("About you") {
                    TextEditor(text: $inbox.settings.aboutMe)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 140)
                        .raised(palette)
                        .disabled(writingAboutMe)
                    HStack(alignment: .top) {
                        Text("Who you are and how you like to write. Used when drafting replies.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(writingAboutMe ? "Reading your messages…" : "Auto-generate") {
                            writingAboutMe = true
                            Task {
                                await inbox.writeAboutMe()
                                writingAboutMe = false
                            }
                        }
                        .themedButton(palette)
                        .disabled(writingAboutMe || !inbox.isConfigured)
                        .help("Claude describes how you write from your recent Slack messages and sent email. Replaces the text above.")
                    }
                }
                section("Claude") {
                    Text(Claude.executable == nil
                         ? "Claude Code not found. Install it and run `claude` once to log in."
                         : "Drafts are written by Claude Code (`claude -p`) with your subscription.")
                        .foregroundStyle(Claude.executable == nil ? Color.red : Color.secondary)
                }
                section("Redraft with tools") {
                    Segmented(selection: toolAccessSelection, options: ToolAccess.allCases) { $0.label }
                    if let pending = pendingToolAccess {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(pending.warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Spacer()
                                Button("Cancel") { pendingToolAccess = nil }
                                    .themedButton(palette)
                                Button(pending == .full ? "Allow full access" : "Allow reading files") {
                                    toolAccess = pending
                                    pendingToolAccess = nil
                                }
                                .themedButton(palette, prominent: true)
                            }
                        }
                        .padding(10)
                        .background(Color.orange.opacity(pending == .full ? 0.22 : 0.14), in: RoundedRectangle(cornerRadius: Palette.radius))
                    } else {
                        Text(toolAccess.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                section("Auto-reply") {
                    HStack(spacing: 12) {
                        Slider(value: autoReplyStep, in: 0...Double(AutoReplyLevel.allCases.count - 1), step: 1)
                        Text(inbox.settings.autoReplyLevel.label)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 110, alignment: .trailing)
                    }
                    Text(inbox.settings.autoReplyLevel.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Segmented(selection: $inbox.settings.autoReplySources, options: AutoReplySources.allCases) { $0.label }
                    field("Jev key") { SecureField("TypeSafe API key", text: $inbox.settings.jevKey) }
                    if inbox.settings.autoReplyLevel != .off && inbox.settings.jevKey.isEmpty {
                        Text("Auto-reply stays off until you add a Jev key.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(Self.autoReplyRules)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        Button(inbox.dryRunning ? "Checking…" : "Dry run") { Task { await inbox.runDryRun() } }
                            .themedButton(palette)
                            .disabled(inbox.dryRunning || inbox.items.isEmpty || inbox.settings.jevKey.isEmpty)
                        Text("See what it would send for the messages in your list right now, without sending anything.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let results = inbox.dryRun {
                        ForEach(results) { DryRunRow(result: $0, settings: inbox.settings) }
                    }
                }
                HStack {
                    Toggle("Open at login", isOn: $openAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: openAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                inbox.status = "Open at login: \(error.localizedDescription)"
                            }
                        }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                        .themedButton(palette)
                    Button("Done", action: done)
                        .themedButton(palette, prominent: true)
                        .disabled(!inbox.isConfigured)
                }
                .padding(16)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// An input with its label inside the field, Paper style.
    private func field(_ label: String, @ViewBuilder input: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            input().textFieldStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .raised(palette)
    }
}

extension AutoReplyLevel {
    var label: String {
        switch self {
        case .off: "Off"
        case .acknowledgements: "Acknowledgements"
        case .quickAnswers: "Quick answers"
        case .routine: "Routine"
        }
    }

    var explanation: String {
        switch self {
        case .off: "Drafty never sends anything on its own."
        case .acknowledgements: "Sends replies that say nothing new, like “tack”, “kollar” or 👍."
        case .quickAnswers: "Also short answers fully covered by the conversation, like “funkar för mig” or “fixat nu”."
        case .routine: "Also low-stakes replies to colleagues that don't commit you to anything new."
        }
    }
}

extension AutoReplySources {
    var label: String {
        switch self {
        case .slack: "Slack"
        case .email: "Email"
        case .both: "Both"
        }
    }
}

extension ToolAccess {
    var label: String {
        switch self {
        case .off: "Off"
        case .readFiles: "Read files"
        case .full: "Full access"
        }
    }

    var explanation: String {
        switch self {
        case .off: "Redrafts only see the conversation."
        case .readFiles: "The wrench next to ↻ redrafts with read-only access to your home folder: no shell, no writing, no network. Automatic checks never use tools."
        case .full: "The wrench next to ↻ redrafts with Claude Code's full access and no permission checks. Automatic checks never use tools."
        }
    }

    var warning: String {
        switch self {
        case .off: ""
        case .readFiles: "Claude will be able to read any file in your home folder, including keys and tokens like ~/.ssh and Drafty's own settings, while it reads messages other people wrote. A message written to trick it could get file contents into a draft. It can't run commands or send anything itself, so read drafts before you send them."
        case .full: "Claude will run with every permission check skipped (‑‑dangerously‑skip‑permissions). It can run any command, change or delete files and use the network, while it reads messages that anyone can send you. A message written to trick it could make it run commands or upload your files without asking you. Only allow this if you accept that risk."
        }
    }
}

/// Brand logos as SVG, so there are no image assets to bundle.
@MainActor
private enum Logo {
    static let slack = NSImage(data: Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 122.8 122.8"><path fill="#e01e5a" d="M25.8 77.6c0 7.1-5.8 12.9-12.9 12.9S0 84.7 0 77.6s5.8-12.9 12.9-12.9h12.9v12.9zm6.5 0c0-7.1 5.8-12.9 12.9-12.9s12.9 5.8 12.9 12.9v32.3c0 7.1-5.8 12.9-12.9 12.9s-12.9-5.8-12.9-12.9V77.6z"/><path fill="#36c5f0" d="M45.2 25.8c-7.1 0-12.9-5.8-12.9-12.9S38.1 0 45.2 0s12.9 5.8 12.9 12.9v12.9H45.2zm0 6.5c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9H12.9C5.8 58.1 0 52.3 0 45.2s5.8-12.9 12.9-12.9h32.3z"/><path fill="#2eb67d" d="M97 45.2c0-7.1 5.8-12.9 12.9-12.9s12.9 5.8 12.9 12.9-5.8 12.9-12.9 12.9H97V45.2zm-6.5 0c0 7.1-5.8 12.9-12.9 12.9s-12.9-5.8-12.9-12.9V12.9C64.7 5.8 70.5 0 77.6 0s12.9 5.8 12.9 12.9v32.3z"/><path fill="#ecb22e" d="M77.6 97c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9-12.9-5.8-12.9-12.9V97h12.9zm0-6.5c-7.1 0-12.9-5.8-12.9-12.9s5.8-12.9 12.9-12.9h32.3c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9H77.6z"/></svg>"##.utf8))!

    static let gmail = NSImage(data: Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="52 42 88 66"><path fill="#4285f4" d="M58 108h14V74L52 59v43c0 3.32 2.69 6 6 6"/><path fill="#34a853" d="M120 108h14c3.32 0 6-2.69 6-6V59l-20 15"/><path fill="#fbbc04" d="M120 48v26l20-15v-8c0-7.42-8.47-11.65-14.4-7.2"/><path fill="#ea4335" d="M72 74V48l24 18 24-18v26L96 92"/><path fill="#c5221f" d="M52 51v8l20 15V48l-5.6-4.2c-5.94-4.45-14.4-.22-14.4 7.2"/></svg>"##.utf8))!
}
