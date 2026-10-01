import AppKit
import CryptoKit
import Foundation
import Network

/// Finds inbox threads where the last message isn't yours, and replies in-thread.
actor Gmail {
    struct ReplyTo: Codable, Sendable {
        let threadId: String
        let to: String
        let subject: String
        let inReplyTo: String
        let references: String
    }

    private static let query = "in:inbox newer_than:2d -category:promotions -category:social -category:updates -category:forums"
    private static let api = "https://gmail.googleapis.com/gmail/v1/users/me"

    private let clientID: String
    private let clientSecret: String
    private let refreshToken: String
    private var accessToken = ""
    private var expiry = Date.distantPast
    private var email: String?

    init(clientID: String, clientSecret: String, refreshToken: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
    }

    func candidates() async throws -> [Candidate] {
        let email = try await myEmail()
        let list: ThreadList = try await get("threads", [.init(name: "q", value: Self.query), .init(name: "maxResults", value: "25")])
        var result: [Candidate] = []
        for ref in list.threads ?? [] {
            let thread: MailThread = try await get("threads/\(ref.id)", [.init(name: "format", value: "metadata")]
                + ["From", "To", "Reply-To", "Subject", "Message-ID", "References"].map { .init(name: "metadataHeaders", value: $0) })
            guard let last = thread.messages.last(where: { !$0.labels.contains("DRAFT") }),
                  !last.labels.contains("SENT") else { continue }

            let from = last.header("From") ?? ""
            let subject = last.header("Subject") ?? "(no subject)"
            let messageID = last.header("Message-ID") ?? ""
            let replyTo = ReplyTo(
                threadId: thread.id,
                to: last.header("Reply-To") ?? from,
                subject: subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)",
                inReplyTo: messageID,
                references: [last.header("References"), messageID].compactMap { $0 }.joined(separator: " ")
            )
            let message = Message(
                id: "gmail:\(thread.id):\(last.id)",
                source: .gmail,
                from: Self.displayName(from),
                title: subject,
                preview: last.snippet.decodingEntities,
                date: Date(timeIntervalSince1970: (Double(last.internalDate) ?? 0) / 1000),
                link: URL(string: "https://mail.google.com/mail/?authuser=\(email)#all/\(thread.id)"),
                target: .gmail(replyTo)
            )
            let threadID = thread.id
            let addressedToMe = (last.header("To") ?? "").localizedCaseInsensitiveContains(email)
            let why = addressedToMe
                ? "The email is addressed to the user."
                : "The user is only cc'd or got it through a list, not addressed in To."
            // Only colleagues: the reply would go to someone in your own domain.
            let colleague = Self.address(replyTo.to).lowercased().hasSuffix("@" + (email.split(separator: "@").last ?? "").lowercased())
            result.append(Candidate(message: message, why: why, canAutoReply: addressedToMe && colleague) { [self] in try await conversation(threadID) })
        }
        return result
    }

    func reply(_ text: String, to reply: ReplyTo) async throws {
        let to = reply.to.allSatisfy(\.isASCII) ? reply.to : Self.address(reply.to)
        var headers = ["To: \(to)", "Subject: =?UTF-8?B?\(Data(reply.subject.utf8).base64EncodedString())?="]
        if !reply.inReplyTo.isEmpty {
            headers += ["In-Reply-To: \(reply.inReplyTo)", "References: \(reply.references)"]
        }
        headers += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"]
        let mime = (headers + ["", Data(text.utf8).base64EncodedString(options: .lineLength76Characters)]).joined(separator: "\r\n")

        try await post("messages/send", Raw(raw: Data(mime.utf8).base64URL, threadId: reply.threadId))
        try await post("threads/\(reply.threadId)/modify", Modify(removeLabelIds: ["UNREAD"]))
    }

    private func conversation(_ threadID: String) async throws -> [ThreadMessage] {
        let thread: MailThread = try await get("threads/\(threadID)", [.init(name: "format", value: "full")])
        return thread.messages.filter { !$0.labels.contains("DRAFT") }.suffix(8).map { message in
            ThreadMessage(
                author: Self.displayName(message.header("From") ?? "Unknown"),
                date: Date(timeIntervalSince1970: (Double(message.internalDate) ?? 0) / 1000),
                text: String(Self.body(of: message).prefix(4000)),
                fromMe: message.labels.contains("SENT"))
        }
    }

    /// Your recently sent emails, newest first.
    func sentMessages(limit: Int = 40) async throws -> [String] {
        let list: MessageList = try await get("messages", [.init(name: "q", value: "in:sent newer_than:180d"), .init(name: "maxResults", value: "\(limit)")])
        var texts: [String] = []
        for ref in list.messages ?? [] {
            let message: Msg = try await get("messages/\(ref.id)", [.init(name: "format", value: "full")])
            texts.append("[Email to \(message.header("To") ?? "?")] \(message.header("Subject") ?? "")\n\(Self.body(of: message).prefix(2000))")
        }
        return texts
    }

    /// A message's text without the quoted history (earlier messages are in the thread anyway).
    private static func body(of message: Msg) -> String {
        (message.payload.text("text/plain") ?? message.payload.text("text/html")?.strippingHTML ?? message.snippet)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)  // also splits "\r\n", which is one Character
            .filter { !$0.hasPrefix(">") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func myEmail() async throws -> String {
        if let email { return email }
        let profile: Profile = try await get("profile")
        email = profile.emailAddress
        return profile.emailAddress
    }

    private func token() async throws -> String {
        if Date.now < expiry { return accessToken }
        let response = try await Self.requestToken([
            "client_id": clientID, "client_secret": clientSecret,
            "refresh_token": refreshToken, "grant_type": "refresh_token",
        ])
        accessToken = response.access_token
        expiry = .now.addingTimeInterval(Double(response.expires_in - 60))
        return accessToken
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var url = URLComponents(string: "\(Self.api)/\(path)")!
        url.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        return try JSONDecoder().decode(T.self, from: await http(request))
    }

    private func post(_ path: String, _ body: some Encodable) async throws {
        var request = URLRequest(url: URL(string: "\(Self.api)/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await http(request)
    }

    private static func displayName(_ header: String) -> String {
        guard let match = header.firstMatch(of: #/^\s*"?([^"<]*?)"?\s*<.*>/#), !match.1.isEmpty else { return header }
        return String(match.1)
    }

    private static func address(_ header: String) -> String {
        header.firstMatch(of: #/<([^>]+)>/#).map { String($0.1) } ?? header
    }

    // MARK: - OAuth (installed app flow with a loopback redirect and PKCE)

    /// Opens Google sign-in in the browser and returns a refresh token.
    static func authorize(clientID: String, clientSecret: String) async throws -> String {
        let verifier = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URL
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }

        enum Event { case ready(UInt16), code(String), failed(String) }
        let (events, sink) = AsyncStream.makeStream(of: Event.self)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: sink.yield(.ready(listener.port?.rawValue ?? 0))
            case .failed(let error): sink.yield(.failed(error.localizedDescription))
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                // Request line: "GET /?code=…&scope=… HTTP/1.1"
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let query = URLComponents(string: path)?.queryItems ?? []
                let code = query.first { $0.name == "code" }?.value
                let error = query.first { $0.name == "error" }?.value
                let body = code != nil ? "Gmail connected. You can close this tab." : "Sign-in failed: \(error ?? "no code")"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if let code { sink.yield(.code(code)) } else if let error { sink.yield(.failed(error)) }
            }
        }
        listener.start(queue: .main)

        var redirect = ""
        for await event in events {
            switch event {
            case .ready(let port):
                redirect = "http://127.0.0.1:\(port)"
                var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                auth.queryItems = [
                    .init(name: "client_id", value: clientID),
                    .init(name: "redirect_uri", value: redirect),
                    .init(name: "response_type", value: "code"),
                    .init(name: "scope", value: "https://www.googleapis.com/auth/gmail.modify"),
                    .init(name: "access_type", value: "offline"),
                    .init(name: "prompt", value: "consent"),
                    .init(name: "code_challenge", value: challenge),
                    .init(name: "code_challenge_method", value: "S256"),
                ]
                let url = auth.url!
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            case .code(let code):
                let response = try await requestToken([
                    "client_id": clientID, "client_secret": clientSecret, "code": code,
                    "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code",
                ])
                guard let refreshToken = response.refresh_token else { throw AppError("Google didn't return a refresh token") }
                return refreshToken
            case .failed(let message):
                throw AppError(message)
            }
        }
        throw AppError("Sign-in was cancelled")
    }

    private static func requestToken(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return try JSONDecoder().decode(TokenResponse.self, from: await http(request))
    }

    // MARK: - Wire types

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private struct Profile: Decodable {
        let emailAddress: String
    }

    private struct ThreadList: Decodable {
        let threads: [Ref]?
        struct Ref: Decodable { let id: String }
    }

    private struct MessageList: Decodable {
        let messages: [ThreadList.Ref]?
    }

    private struct MailThread: Decodable {
        let id: String
        let messages: [Msg]
    }

    private struct Msg: Decodable {
        let id: String
        let labelIds: [String]?
        let snippet: String
        let internalDate: String
        let payload: Part

        var labels: [String] { labelIds ?? [] }

        func header(_ name: String) -> String? {
            payload.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    private struct Part: Decodable {
        let mimeType: String
        let headers: [Header]?
        let body: Body?
        let parts: [Part]?

        struct Header: Decodable {
            let name: String
            let value: String
        }

        struct Body: Decodable {
            let data: String?
        }

        func text(_ type: String) -> String? {
            if mimeType == type, let encoded = body?.data, let data = Data(base64URL: encoded) {
                return String(decoding: data, as: UTF8.self)
            }
            return parts?.lazy.compactMap { $0.text(type) }.first
        }
    }

    private struct Raw: Encodable {
        let raw: String
        let threadId: String
    }

    private struct Modify: Encodable {
        let removeLabelIds: [String]
    }
}
