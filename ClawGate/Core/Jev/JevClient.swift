import Foundation

/// One question sent to Jev (TypeSafe's typed-decision API) for a single
/// call. `noul` is the only question type Jev answers today — a confidence
/// in 0...1 — but the shape is kept generic (`type` as a string, rather than
/// a case-per-type struct) so a future `choice` type slots in without
/// changing every caller that only ever asks `noul` questions.
struct JevQuestion: Encodable, Equatable {
    var type: String
    var instructions: String
    var criteria: [String: String]?

    static func noul(_ instructions: String, yes: String, no: String) -> JevQuestion {
        JevQuestion(type: "noul", instructions: instructions, criteria: ["true": yes, "false": no])
    }
}

struct JevUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
}

struct JevResult: Equatable {
    var answers: [String: Double]
    var invalid: [String]
    var usage: JevUsage
    var model: String
    var latencyMs: Int
}

enum JevError: Error, Equatable {
    case keyUnreadable
    case breakerOpen
    case timeout
    case network
    case badJSON
    case contract
    case http(Int)
    case unexpected
}

/// The outcome of a no-token key check against `/v1/models`.
enum JevKeyCheck: Equatable {
    case valid
    case invalid
    case unreachable(String)
}

/// A synchronous client for `POST /v1/systemone`, following the same
/// URLSession+DispatchSemaphore pattern `VoicevoxSynthesizer` uses: the
/// callers on this side of the app (Gateway dispatch, ambient window
/// processing) are already off the main thread and want a plain `throws`
/// call, not a completion handler to thread through.
struct JevClient {
    static let model = "jev-1.13.0"

    var endpoint = URL(string: "https://api.typesafe.ai")!
    var timeout: TimeInterval = 10
    /// Injected so tests never touch the real key file; production reads the
    /// key fresh from `JevKeyStore` on every call rather than caching it.
    var keyProvider: () throws -> String = { try JevKeyStore().load() }

    /// Never logs the key, `state`, or the raw response body — only
    /// `JevKeyStore.tag(of:)` is safe to put in a log line.
    func ask(state: String, questions: [String: JevQuestion]) throws -> JevResult {
        let key = try keyProvider()
        let body = try Self.buildBody(state: state, questions: questions)
        let start = Date()

        var (data, status, retryAfter) = try send(body: body, key: key)
        if status == 429 {
            // The only retryable case, and only once: a hot loop hammering a
            // rate-limited endpoint helps nobody, but a single transient 429
            // is worth one more try.
            let wait = retryAfter.map { min($0, 5) } ?? 0.5
            Thread.sleep(forTimeInterval: wait)
            (data, status, retryAfter) = try send(body: body, key: key)
        }
        guard (200...299).contains(status) else { throw JevError.http(status) }

        let parsed = try Self.parse(data, requestedModel: Self.model, questionIds: Set(questions.keys))
        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
        return JevResult(answers: parsed.answers, invalid: parsed.invalid,
                         usage: parsed.usage, model: parsed.model, latencyMs: latencyMs)
    }

    /// A key check that consumes no tokens: `GET /v1/models` with the same
    /// bearer header, read only for its status code.
    func verifyKey() -> JevKeyCheck {
        guard let key = try? keyProvider() else { return .unreachable("keyUnreadable") }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        var outcome: JevKeyCheck = .unreachable("no response")
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                outcome = .unreachable((error as NSError).localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200...299: outcome = .valid
                case 401, 403: outcome = .invalid
                default: outcome = .unreachable("http \(http.statusCode)")
                }
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 5) == .success else {
            return .unreachable("timeout")
        }
        return outcome
    }

    // MARK: - Pure, testable pieces

    /// The exact wire body: three top-level keys, and always the pinned
    /// model constant — never a caller-supplied string, so a stray
    /// "jev-latest" can never slip in and change behavior underneath us.
    static func buildBody(state: String, questions: [String: JevQuestion]) throws -> Data {
        struct Body: Encodable {
            var state: String
            var model: String
            var questions: [String: JevQuestion]
        }
        return try JSONEncoder().encode(Body(state: state, model: Self.model, questions: questions))
    }

    /// Parses a `/v1/systemone` response without any networking, so this is
    /// the one function the tests exercise directly. `questionIds` is the set
    /// actually asked for — validation walks that set (not whatever ids the
    /// response happens to include), so an id Jev silently dropped ends up in
    /// `invalid` rather than just disappearing.
    static func parse(_ data: Data, requestedModel: String,
                      questionIds: Set<String>) throws -> (answers: [String: Double],
                                                            invalid: [String],
                                                            usage: JevUsage,
                                                            model: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JevError.badJSON
        }
        guard let rawAnswers = json["answers"] as? [String: Any] else {
            throw JevError.contract
        }

        var answers: [String: Double] = [:]
        var invalid: [String] = []
        for id in questionIds {
            guard let entry = rawAnswers[id] as? [String: Any],
                  (entry["type"] as? String) == "noul",
                  let value = noulValue(entry["noul"]), value.isFinite, (0...1).contains(value) else {
                invalid.append(id)
                continue
            }
            answers[id] = value
        }

        let usageObj = json["usage"] as? [String: Any]
        let usage = JevUsage(inputTokens: (usageObj?["input_tokens"] as? Int) ?? 0,
                             outputTokens: (usageObj?["output_tokens"] as? Int) ?? 0)
        let model = (json["model"] as? String) ?? requestedModel
        return (answers, invalid.sorted(), usage, model)
    }

    /// Reads a JSON number as a `Double` without letting a JSON boolean
    /// (which also bridges through `NSNumber`) pass as one.
    private static func noulValue(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber:
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        default: return nil
        }
    }

    // MARK: - Transport

    private func send(body: Data, key: String) throws -> (Data, Int, Double?) {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/systemone"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout

        var outcome: Result<(Data, Int, Double?), Error> = .failure(JevError.unexpected)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                    outcome = .failure(JevError.timeout)
                } else {
                    outcome = .failure(JevError.network)
                }
            } else {
                let http = response as? HTTPURLResponse
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                outcome = .success((data ?? Data(), http?.statusCode ?? 0, retryAfter))
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 5) == .success else {
            throw JevError.timeout
        }
        return try outcome.get()
    }
}
