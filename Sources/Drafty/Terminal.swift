import AppKit

/// Opens Claude Code in a new terminal window, started with a prompt about a message and the user's draft, so they
/// can dig into it with their own setup: skills, MCP servers and permissions. Ghostty if it's installed, else Terminal.
enum Terminal {
    static func openClaude(about message: Message, draft: String) async throws {
        // The prompt goes through a file, so no message text is ever typed into the shell. It's removed once read.
        let file = FileManager.default.temporaryDirectory.appending(path: "drafty-\(UUID().uuidString).txt")
        try Data(prompt(message, draft: draft).utf8).write(to: file)
        let command = "claude \"$(cat '\(file.path)' && rm '\(file.path)')\""

        // Arguments reach the script as argv, so nothing needs escaping for AppleScript.
        let ghostty = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil
        let script = ghostty
            ? """
            on run argv
                set {workingDirectory, startInput} to argv
                tell application "Ghostty"
                    activate
                    new window with configuration {initial working directory:workingDirectory, initial input:startInput & linefeed}
                end tell
            end run
            """
            : """
            on run argv
                set {workingDirectory, startInput} to argv
                tell application "Terminal"
                    activate
                    do script "cd " & quoted form of workingDirectory & " && " & startInput
                end tell
            end run
            """
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script, FileManager.default.homeDirectoryForCurrentUser.path, command]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        var output = Data()
        for try await byte in stderr.fileHandleForReading.bytes {
            output.append(byte)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: file)
            let reason = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError(reason.contains("-1743")
                ? "Drafty isn't allowed to control \(ghostty ? "Ghostty" : "Terminal"). Allow it in System Settings → Privacy & Security → Automation."
                : "Couldn't open a terminal: \(reason)")
        }
    }

    private static func prompt(_ message: Message, draft: String) -> String {
        var prompt = switch message.target {
        case let .slack(channel, threadTs): "Read Slack channel \(channel)\(threadTs.map { " (thread \($0))" } ?? "") for context."
        case let .gmail(reply): "Read Gmail thread \(reply.threadId) (\"\(reply.subject)\") for context."
        }
        prompt += " I'm replying to the latest message from \(message.from)."
        if !draft.isEmpty {
            prompt += " My draft so far:\n\n\(draft)"
        }
        return prompt
    }

}
