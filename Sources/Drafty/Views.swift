import ServiceManagement
import SwiftUI

enum SortOrder: String {
    case priority, newest
}

struct ContentView: View {
    let inbox: Inbox
    @State private var showSettings = false
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
        VStack(spacing: 0) {
            HStack {
                Text("Needs reply").font(.headline)
                Spacer()
                if inbox.checking { ProgressView().controlSize(.small) }
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
                Button { Task { await inbox.check() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(inbox.checking || !inbox.isConfigured)
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
            }
            .buttonStyle(.borderless)
            .padding(12)
            Hairline()

            if showSettings || !inbox.isConfigured {
                SettingsView(inbox: inbox) {
                    showSettings = false
                    Task { await inbox.check() }
                }
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
    @State private var error: String?
    @Environment(\.palette) private var palette

    init(inbox: Inbox, item: Item) {
        self.inbox = inbox
        self.item = item
        _draft = State(initialValue: item.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let priority = item.priority, priority != .low {
                    Circle()
                        .fill(priority == .high ? Color.red : Color.orange)
                        .frame(width: 7, height: 7)
                        .help("\(priority.rawValue.capitalized) priority")
                }
                Image(nsImage: item.message.source == .slack ? Logo.slack : Logo.gmail)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text(item.message.from).fontWeight(.semibold).lineLimit(1)
                Text(item.message.title).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(item.message.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let link = item.message.link {
                    Link(destination: link) { Image(systemName: "arrow.up.forward.square") }
                        .help("Open in \(item.message.source == .slack ? "Slack" : "Gmail")")
                }
            }
            Text(item.message.preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text(item.reason).font(.callout).italic()

            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 70, maxHeight: 160)
                .raised(palette)
                .onChange(of: draft) { inbox.setDraft(item.id, draft) }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Dismiss") { inbox.dismiss(item) }
                    .themedButton(palette)
                Spacer()
                Button(sending ? "Sending…" : "Send") { send() }
                    .themedButton(palette, prominent: true)
                    .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(palette == nil ? 12 : 16)
        .background {
            if palette == nil { RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)) }
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

struct SettingsView: View {
    @Bindable var inbox: Inbox
    let done: () -> Void
    @State private var connecting: Task<Void, Never>?
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("theme") private var theme = Theme.system
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                section("Appearance") {
                    ThemePicker(selection: $theme)
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
                        .frame(height: 64)
                        .raised(palette)
                    Text("Who you are and how you like to write. Used when drafting replies.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                section("Claude") {
                    Text(Claude.executable == nil
                         ? "Claude Code not found. Install it and run `claude` once to log in."
                         : "Drafts are written by Claude Code (`claude -p`) with your subscription.")
                        .foregroundStyle(Claude.executable == nil ? Color.red : Color.secondary)
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

/// Brand logos as SVG, so there are no image assets to bundle.
@MainActor
private enum Logo {
    static let slack = NSImage(data: Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 122.8 122.8"><path fill="#e01e5a" d="M25.8 77.6c0 7.1-5.8 12.9-12.9 12.9S0 84.7 0 77.6s5.8-12.9 12.9-12.9h12.9v12.9zm6.5 0c0-7.1 5.8-12.9 12.9-12.9s12.9 5.8 12.9 12.9v32.3c0 7.1-5.8 12.9-12.9 12.9s-12.9-5.8-12.9-12.9V77.6z"/><path fill="#36c5f0" d="M45.2 25.8c-7.1 0-12.9-5.8-12.9-12.9S38.1 0 45.2 0s12.9 5.8 12.9 12.9v12.9H45.2zm0 6.5c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9H12.9C5.8 58.1 0 52.3 0 45.2s5.8-12.9 12.9-12.9h32.3z"/><path fill="#2eb67d" d="M97 45.2c0-7.1 5.8-12.9 12.9-12.9s12.9 5.8 12.9 12.9-5.8 12.9-12.9 12.9H97V45.2zm-6.5 0c0 7.1-5.8 12.9-12.9 12.9s-12.9-5.8-12.9-12.9V12.9C64.7 5.8 70.5 0 77.6 0s12.9 5.8 12.9 12.9v32.3z"/><path fill="#ecb22e" d="M77.6 97c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9-12.9-5.8-12.9-12.9V97h12.9zm0-6.5c-7.1 0-12.9-5.8-12.9-12.9s5.8-12.9 12.9-12.9h32.3c7.1 0 12.9 5.8 12.9 12.9s-5.8 12.9-12.9 12.9H77.6z"/></svg>"##.utf8))!

    static let gmail = NSImage(data: Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="52 42 88 66"><path fill="#4285f4" d="M58 108h14V74L52 59v43c0 3.32 2.69 6 6 6"/><path fill="#34a853" d="M120 108h14c3.32 0 6-2.69 6-6V59l-20 15"/><path fill="#fbbc04" d="M120 48v26l20-15v-8c0-7.42-8.47-11.65-14.4-7.2"/><path fill="#ea4335" d="M72 74V48l24 18 24-18v26L96 92"/><path fill="#c5221f" d="M52 51v8l20 15V48l-5.6-4.2c-5.94-4.45-14.4-.22-14.4 7.2"/></svg>"##.utf8))!
}
