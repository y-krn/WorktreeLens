import Foundation

public final class RepositoryStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "registeredRepositories"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var paths: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public func add(_ path: String) {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !paths.contains(canonical) else { return }
        defaults.set(paths + [canonical], forKey: key)
    }

    public func remove(_ path: String) {
        defaults.set(paths.filter { $0 != path }, forKey: key)
    }

    /// Removes worktrees already contained in the default branch after each refresh. Off unless the user opts in.
    public var autoRemoveMergedWorktrees: Bool {
        get { defaults.bool(forKey: "autoRemoveMergedWorktrees") }
        set { defaults.set(newValue, forKey: "autoRemoveMergedWorktrees") }
    }
}
