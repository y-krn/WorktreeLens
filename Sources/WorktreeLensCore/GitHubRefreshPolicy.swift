import Foundation

public struct GitHubRefreshPolicy: Sendable {
    public var activeCIInterval: TimeInterval
    public var stableInterval: TimeInterval
    public var maximumInterval: TimeInterval
    public var staleAfter: TimeInterval
    public var failureRetryInterval: TimeInterval
    public var jitterFraction: Double

    public init(activeCIInterval: TimeInterval = 20, stableInterval: TimeInterval = 60,
                maximumInterval: TimeInterval = 900, staleAfter: TimeInterval = 120,
                failureRetryInterval: TimeInterval = 30, jitterFraction: Double = 0.1) {
        self.activeCIInterval = max(1, activeCIInterval)
        self.stableInterval = max(1, stableInterval)
        self.maximumInterval = max(self.stableInterval, maximumInterval)
        self.staleAfter = max(1, staleAfter)
        self.failureRetryInterval = max(1, failureRetryInterval)
        self.jitterFraction = min(max(0, jitterFraction), 0.5)
    }

    public func needsRefresh(_ status: GitHubStatus, localSHA: String, now: Date) -> Bool {
        if status.localSHA != localSHA { return true }
        let states = [status.pullRequestFetch, status.issueFetch, status.checkFetch, status.actionFetch]
        if status.isLoaded && states.allSatisfy({ $0.phase == .notRequested }) { return false }
        let incomplete = !status.isLoaded || states.contains {
            $0.phase != .loaded || $0.stale || $0.fetchedAt == nil
        }
        if incomplete {
            let attempts = states.compactMap(\.lastAttemptAt)
            guard let latestAttempt = attempts.max() else { return true }
            if now.timeIntervalSince(latestAttempt) < failureRetryInterval,
               status.isLoaded || states.contains(where: { $0.phase == .failed || $0.phase == .incomplete }) {
                return false
            }
            return true
        }
        let fetchedAt = states.compactMap(\.fetchedAt).min() ?? .distantPast
        return now.timeIntervalSince(fetchedAt) >= staleAfter
    }

    public func nextInterval(for status: GitHubStatus, unchangedPolls: Int, jitter: Double = 0) -> TimeInterval {
        let base: TimeInterval
        if hasActiveCI(status) {
            base = activeCIInterval
        } else {
            let exponent = min(max(unchangedPolls, 0), 16)
            base = min(maximumInterval, stableInterval * pow(2, Double(exponent)))
        }
        let boundedJitter = min(max(jitter, -1), 1) * jitterFraction
        return min(maximumInterval, max(1, base * (1 + boundedJitter)))
    }

    public func fingerprint(_ status: GitHubStatus) -> String {
        let prs = status.pullRequests.sorted { $0.number < $1.number }.map {
            "pr:\($0.number):\($0.state):\($0.headRefOid ?? ""): \($0.mergedAt?.timeIntervalSince1970 ?? 0)"
        }
        let issues = status.issues.sorted { $0.id < $1.id }.map { "issue:\($0.id):\($0.state)" }
        let checks = status.checks.sorted { $0.id < $1.id }.map { "check:\($0.id):\($0.sha):\($0.result)" }
        let actions = status.actions.sorted { $0.id < $1.id }.map {
            "action:\($0.id):\($0.status):\($0.conclusion ?? ""):current=\($0.isCurrent)"
        }
        return (prs + issues + checks + actions).joined(separator: "|")
    }

    public func hasActiveCI(_ status: GitHubStatus) -> Bool {
        let active = Set(["queued", "in_progress", "waiting", "requested", "pending"])
        return status.actions.contains { $0.isCurrent && active.contains($0.status.lowercased()) } ||
            status.checks.contains { check in
                ["PENDING", "IN_PROGRESS", "QUEUED"].contains(check.result.uppercased()) &&
                (status.localSHA == nil || check.sha == status.localSHA)
            }
    }
}
