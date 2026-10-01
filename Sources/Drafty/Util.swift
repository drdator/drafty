import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Performs a request and returns the body, throwing on non-2xx responses.
func http(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw AppError("HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    return data
}

extension String {
    var decodingEntities: String {
        [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")]
            .reduce(self) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    var strippingHTML: String {
        replacing(#/<(style|script)[^>]*>.*?</\1>/#.ignoresCase().dotMatchesNewlines(), with: "")
            .replacing(#/<br\s*/?>|</p>|</div>/#.ignoresCase(), with: "\n")
            .replacing(#/<[^>]+>/#, with: "")
            .decodingEntities
            .replacing(#/\n\s*\n\s*\n+/#, with: "\n\n")
    }
}

extension Data {
    init?(base64URL string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
