import Foundation
import Logging

private let logger = Logger(label: "Hermit.RateLimiter")

/// A token-bucket rate limiter that controls the maximum request throughput.
///
/// Callers `await` ``acquire()`` before each HTTP request. If the token bucket has capacity,
/// the call returns immediately. If not, the task suspends for the time required to earn
/// another token, then retries.
///
/// The limiter uses `Task.sleep` exclusively — it never blocks a thread, making it safe
/// to use inside `TaskGroup` workers running on NIO event-loop threads.
actor RateLimiter {
    /// The configured throughput ceiling.
    private let requestsPerSecond: Double

    /// Current token count. One token grants permission to send one request.
    private var tokens: Double

    /// The clock instant of the most recent refill, used to compute elapsed time.
    private var lastRefill: ContinuousClock.Instant = .now

    /// Creates a new rate limiter.
    ///
    /// - Parameter requestsPerSecond: The maximum number of requests allowed per second.
    init(requestsPerSecond: Double) {
        self.requestsPerSecond = requestsPerSecond
        // Start with a full bucket so the first burst of requests is not throttled.
        self.tokens = requestsPerSecond
    }

    /// Waits until a request token is available, then consumes one token.
    ///
    /// If a token is available immediately, this returns without suspending. Otherwise,
    /// the calling task sleeps for the duration needed to earn one token.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while sleeping.
    func acquire() async throws {
        refill()
        logger.trace("Rate limiter acquire called", metadata: ["tokens": "\(tokens)", "limit": "\(requestsPerSecond)"])
        if tokens >= 1 {
            // Token available — consume it and return immediately.
            tokens -= 1
            logger.trace("Token available, proceeding immediately", metadata: ["remaining": "\(tokens)"])
            return
        }
        let sleepDuration = 1.0 / requestsPerSecond
        logger.trace("No token available, sleeping", metadata: ["seconds": "\(sleepDuration)"])
        try await Task.sleep(for: .seconds(sleepDuration))
        refill()
        tokens = max(0, tokens - 1)
        logger.trace("Woke from sleep, token consumed", metadata: ["remaining": "\(tokens)"])
    }

    /// Adds tokens proportional to the time elapsed since the last refill.
    ///
    /// Capped at `requestsPerSecond` to prevent burst accumulation during idle periods.
    private func refill() {
        let now = ContinuousClock.now
        let elapsed = lastRefill.duration(to: now)
        // Convert the Duration to a Double in seconds for arithmetic.
        let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) * 1e-18
        tokens = min(requestsPerSecond, tokens + seconds * requestsPerSecond)
        lastRefill = now
        logger.trace("Tokens refilled", metadata: ["tokens": "\(tokens)", "elapsed": "\(seconds)"])
    }
}
