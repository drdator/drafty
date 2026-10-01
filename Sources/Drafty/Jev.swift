import Foundation

/// TypeSafe's Jev: fast structured decisions with calibrated confidence. It judges whether a reply Claude drafted
/// can go out without the user looking at it. It never writes anything itself.
struct Jev: Sendable {
    let key: String

    struct Decision: Sendable {
        let level: AutoReplyLevel?  // nil when the reply needs the user
        let confidence: Double
        let fromAgent: Double  // probability the latest message came from a bot or AI agent
    }

    private static let kinds: [String: (level: AutoReplyLevel?, description: String)] = [
        "acknowledgement": (.acknowledgements, "Says nothing new: thanks, ok, on it, a thumbs up"),
        "quick_answer": (.quickAnswers, "A short answer that is fully covered by the conversation"),
        "routine": (.routine, "A low-stakes reply to a colleague that commits the user to nothing new"),
        "needs_user": (nil, "Anything else: decisions, promises, dates, money, opinions about people, facts not in the conversation, or anything the user should check before it goes out"),
    ]

    func judge(_ message: Message, thread: [ThreadMessage], why: String, draft: String) async throws -> Decision {
        let line = { (message: ThreadMessage) in State.Line(from: message.fromMe ? "the user" : message.author, text: String(message.text.prefix(1000))) }
        let state = State(
            channel: message.source == .slack ? "Slack \(message.title)" : "Email: \(message.title)",
            how_it_reached_the_user: why,
            conversation: thread.suffix(10).map(line),
            latest_message: thread.last.map(line) ?? .init(from: message.from, text: message.preview),
            drafted_reply: draft)
        let questions = [
            "kind": Question(type: "choice", instructions: "What kind of reply is drafted_reply, the user's answer to latest_message?",
                             criteria: Self.kinds.mapValues(\.description)),
            // Asked about latest_message on its own, with both outcomes described: much sharper than a bare question.
            "from_agent": Question(
                type: "noul", instructions: "Was latest_message written by a bot, an assistant or an AI agent rather than typed by a person?",
                criteria: [
                    "true": "It says or shows it was written by a bot, assistant or AI agent (for example \"X's agent here\", a robot emoji, or an automated notification)",
                    "false": "A person wrote it themselves, even if it is short or informal",
                ]),
        ]

        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(state: state, questions: questions))
        let answers = try JSONDecoder().decode(Response.self, from: await http(request)).answers
        guard let kind = Self.kinds[answers.kind.choice] else { throw AppError("Unexpected answer \(answers.kind.choice)") }
        return Decision(level: kind.level, confidence: answers.kind.confidence, fromAgent: answers.from_agent.noul)
    }

    private struct State: Encodable {
        let channel: String
        let how_it_reached_the_user: String
        let conversation: [Line]
        let latest_message: Line
        let drafted_reply: String

        struct Line: Encodable {
            let from: String
            let text: String
        }
    }

    private struct Question: Encodable {
        let type: String
        let instructions: String
        let criteria: [String: String]?
    }

    private struct Request: Encodable {
        let model = "jev-latest"
        let state: State
        let questions: [String: Question]
    }

    private struct Response: Decodable {
        let answers: Answers

        struct Answers: Decodable {
            let kind: Choice
            let from_agent: Noul
        }

        struct Choice: Decodable {
            let choice: String
            let confidence: Double
        }

        struct Noul: Decodable {
            let noul: Double
        }
    }
}
