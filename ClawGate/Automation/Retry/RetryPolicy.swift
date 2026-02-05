import Foundation

struct RetryPolicy {
    let maxAttempts: Int
    let initialDelayMs: Int

    init(maxAttempts: Int = 3, initialDelayMs: Int = 150) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelayMs = max(0, initialDelayMs)
    }

    func run<T>(_ action: () throws -> T) throws -> T {
        var currentDelay = initialDelayMs
        var lastError: Error?

        for _ in 1...maxAttempts {
            do {
                return try action()
            } catch {
                lastError = error
                if currentDelay > 0 {
                    Thread.sleep(forTimeInterval: Double(currentDelay) / 1000.0)
                }
                currentDelay *= 2
            }
        }

        throw lastError ?? NSError(domain: "RetryPolicy", code: 1)
    }
}
