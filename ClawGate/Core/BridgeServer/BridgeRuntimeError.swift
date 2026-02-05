import Foundation

struct BridgeRuntimeError: Error {
    let code: String
    let message: String
    let retriable: Bool
    let failedStep: String?
    let details: String?

    func asPayload() -> ErrorPayload {
        ErrorPayload(code: code, message: message, retriable: retriable, failedStep: failedStep, details: details)
    }
}
