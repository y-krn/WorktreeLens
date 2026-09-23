import SwiftUI
import UniformTypeIdentifiers
import WorktreeLensCore

@main
struct WorktreeLensApp: App {
    @StateObject private var model = ApplicationModel()

    var body: some Scene {
        WindowGroup("Worktree Lens") {
            ContentView(model: model)
                .frame(minWidth: 1_240, minHeight: 760)
                .tint(Color(red: 0.10, green: 0.54, blue: 0.56))
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Register Repository…") { model.isImporterPresented = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

enum CleanupExecutionState: Equatable {
    case idle
    case running
    case completed(Int)
}

protocol GitHubDetailLoading: Sendable {
    func statusAsync(repositoryPath: String, branch: String, timeout: TimeInterval) async -> GitHubStatus
}

extension GitHubService: GitHubDetailLoading {}

@MainActor
final class ApplicationModel: ObservableObject {
    private struct RepositoryViewCache {
        var snapshot: RepositorySnapshot
        var sessionNotes: [String]
        var selection: RepositorySelection?
    }

    @Published var registeredPaths: [String]
    @Published var selectedPath: String?
    @Published var snapshot: RepositorySnapshot?
    @Published var selection: RepositorySelection?
    @Published var sessionNotes: [String] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var cleanupPreview: CleanupPreview?
    @Published var cleanupExecutionState: CleanupExecutionState = .idle
    @Published var isImporterPresented = false
    @Published var isLoading = false
    @Published var isCleanupPreviewLoading = false
    @Published var scanPhase: String?
    @Published var canCancelGitHub = false
    @Published var staleDays = 7

    let repositoryStore: RepositoryStore
    let git: GitService
    let sessions: SessionService
    let github: GitHubService
    private let detailLoader: any GitHubDetailLoading
    let scanner: any RepositoryScanning
    lazy var cleanup = CleanupService(git: git, sessions: sessions, github: github)
    private var viewCache: [String: RepositoryViewCache] = [:]
    private var refreshToken = UUID()
    private var refreshTask: Task<Void, Never>?
    private var githubDetailToken = UUID()
    private var githubDetailTask: Task<Void, Never>?
    private var cleanupPreviewToken = UUID()

    init(loadRepositories: Bool = true, repositoryStore: RepositoryStore = RepositoryStore(), git: GitService = GitService(), sessions: SessionService = SessionService(), github: GitHubService = GitHubService(), detailLoader: (any GitHubDetailLoading)? = nil, scanner injectedScanner: (any RepositoryScanning)? = nil) {
        self.repositoryStore = repositoryStore
        self.git = git
        self.sessions = sessions
        self.github = github
        self.detailLoader = detailLoader ?? github
        self.scanner = injectedScanner ?? RepositoryScanService(git: git, sessions: sessions, github: github)
        registeredPaths = repositoryStore.paths
        selectedPath = nil
        if loadRepositories, let path = registeredPaths.first { selectRepository(path: path) }
    }

    func register(url: URL) {
        repositoryStore.add(url.path)
        registeredPaths = repositoryStore.paths
        selectRepository(path: URL(fileURLWithPath: url.path).standardizedFileURL.path)
    }

    func removeSelectedRepository() {
        guard let selectedPath else { return }
        invalidateRepositoryTasks()
        viewCache.removeValue(forKey: selectedPath)
        repositoryStore.remove(selectedPath)
        registeredPaths = repositoryStore.paths
        self.selectedPath = nil
        clearVisibleRepository()
        if let nextPath = registeredPaths.first { selectRepository(path: nextPath) }
    }

    func selectRepository(path: String) {
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if selectedPath == canonicalPath { return }
        saveCurrentView()
        invalidateRepositoryTasks()
        selectedPath = canonicalPath
        errorMessage = nil
        statusMessage = nil
        if let cached = viewCache[canonicalPath] {
            snapshot = cached.snapshot
            sessionNotes = cached.sessionNotes
            selection = normalizedSelection(cached.selection, in: cached.snapshot)
            isLoading = false
            scanPhase = nil
            canCancelGitHub = false
            loadGitHubDetailForCurrentSelection()
        } else {
            clearVisibleRepository()
            refresh(path: canonicalPath)
        }
    }

    func refreshSelected() {
        guard let selectedPath else { return }
        refresh(path: selectedPath)
    }

    func refresh(path: String) {
        guard selectedPath == path else { return }
        saveCurrentView()
        refreshTask?.cancel()
        githubDetailTask?.cancel()
        githubDetailToken = UUID()
        let token = UUID()
        refreshToken = token
        isLoading = true
        scanPhase = "Scanning sessions…"
        canCancelGitHub = false
        let scanner = self.scanner
        refreshTask = Task.detached(priority: .userInitiated) {
            do {
                let discovery = scanner.scanSessions()
                let canReadGit = await MainActor.run {
                    guard self.refreshToken == token, self.selectedPath == path else { return false }
                    self.scanPhase = "Reading Git…"
                    return true
                }
                guard canReadGit else { return }
                let local = try scanner.readGit(repositoryPath: path, discovery: discovery)
                let canLoadGitHub = await MainActor.run {
                    guard self.refreshToken == token, self.selectedPath == path else { return false }
                    let previousSelection = self.snapshot?.path == local.snapshot.path ? self.selection : nil
                    self.snapshot = local.snapshot
                    self.sessionNotes = local.sessionNotes
                    self.selection = self.normalizedSelection(previousSelection, in: local.snapshot)
                    self.errorMessage = nil
                    self.saveCurrentView()
                    self.canCancelGitHub = true
                    let total = local.snapshot.branches.contains { !$0.isDetachedGroup } ? 1 : 0
                    self.scanPhase = "Loading GitHub 0/\(total)…"
                    return true
                }
                guard canLoadGitHub else { return }
                let enriched = await scanner.enrichGitHub(local: local) { completed, total in
                    Task { @MainActor in
                        guard self.refreshToken == token else { return }
                        self.scanPhase = "Loading GitHub \(completed)/\(total)…"
                    }
                }
                await MainActor.run {
                    guard self.refreshToken == token, self.selectedPath == path else { return }
                    self.snapshot = enriched
                    self.selection = self.normalizedSelection(self.selection, in: enriched)
                    self.isLoading = false
                    self.canCancelGitHub = false
                    self.scanPhase = nil
                    self.statusMessage = Task.isCancelled ? "GitHub loading cancelled" : nil
                    self.saveCurrentView()
                    self.loadGitHubDetailForCurrentSelection()
                }
            } catch {
                await MainActor.run {
                    guard self.refreshToken == token, self.selectedPath == path else { return }
                    self.snapshot = nil
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    self.canCancelGitHub = false
                    self.scanPhase = nil
                }
            }
        }
    }

    func cancelGitHub() {
        guard canCancelGitHub else { return }
        refreshTask?.cancel()
    }

    func branch(for worktree: WorktreeInfo) -> BranchInfo? {
        snapshot?.branches.first { $0.worktrees.contains { $0.id == worktree.id } }
    }

    var selectedBranchID: String? {
        guard let snapshot, let selection else { return nil }
        return selection.branchID(in: snapshot)
    }

    var selectedWorktreeID: String? {
        guard let snapshot, let selection else { return nil }
        return selection.worktreeID(in: snapshot)
    }

    func selectBranch(id: String) {
        guard snapshot?.branches.contains(where: { $0.id == id }) == true else {
            selection = nil
            return
        }
        selection = .branch(id)
        saveCurrentView()
    }

    func selectWorktree(id: String) {
        guard let snapshot, snapshot.branches.flatMap(\.worktrees).contains(where: { $0.id == id }) else {
            selection = nil
            return
        }
        selection = .worktree(id)
        saveCurrentView()
    }

    func selectionDidChange() {
        loadGitHubDetailForCurrentSelection()
    }

    private func loadGitHubDetailForCurrentSelection() {
        guard !isLoading,
              let path = selectedPath,
              let snapshot,
              snapshot.path == path,
              let branchID = selectedBranchID,
              let branch = snapshot.branches.first(where: { $0.id == branchID }),
              !branch.github.isLoaded else { return }

        githubDetailTask?.cancel()
        let token = UUID()
        githubDetailToken = token
        let refreshToken = self.refreshToken
        let detailLoader = self.detailLoader
        githubDetailTask = Task.detached(priority: .utility) {
            let status = await detailLoader.statusAsync(repositoryPath: path, branch: branch.name, timeout: GitHubService.requestTimeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.githubDetailToken == token,
                      self.refreshToken == refreshToken,
                      self.selectedPath == path,
                      self.selectedBranchID == branchID,
                      self.snapshot?.path == path else { return }
                guard let snapshot = self.snapshot,
                      let index = snapshot.branches.firstIndex(where: { $0.id == branchID }) else { return }
                var branches = snapshot.branches
                branches[index] = branches[index].withGitHubStatus(status)
                self.snapshot = RepositorySnapshot(path: snapshot.path, defaultBranch: snapshot.defaultBranch, branches: branches, refreshedAt: snapshot.refreshedAt)
                self.saveCurrentView()
            }
        }
    }

    private func invalidateRepositoryTasks() {
        refreshTask?.cancel()
        githubDetailTask?.cancel()
        refreshToken = UUID()
        githubDetailToken = UUID()
        refreshTask = nil
        githubDetailTask = nil
    }

    private func clearVisibleRepository() {
        snapshot = nil
        selection = nil
        sessionNotes = []
        isLoading = false
        scanPhase = nil
        canCancelGitHub = false
    }

    private func saveCurrentView() {
        guard !isLoading, let selectedPath, let snapshot, snapshot.path == selectedPath else { return }
        viewCache[selectedPath] = RepositoryViewCache(snapshot: snapshot, sessionNotes: sessionNotes, selection: selection)
    }

    private func normalizedSelection(_ selection: RepositorySelection?, in snapshot: RepositorySnapshot) -> RepositorySelection? {
        if let selection, let branchID = selection.branchID(in: snapshot) {
            switch selection {
            case .branch:
                return .branch(branchID)
            case .worktree(let worktreeID):
                return snapshot.branches.flatMap(\.worktrees).contains { $0.id == worktreeID } ? .worktree(worktreeID) : .branch(branchID)
            }
        }
        return snapshot.branches.first.flatMap { branch in
            branch.worktrees.first.map { .worktree($0.id) } ?? .branch(branch.id)
        }
    }

    func selectedWorktree() -> WorktreeInfo? {
        guard let selectedWorktreeID else { return nil }
        return snapshot?.branches.flatMap(\.worktrees).first { $0.id == selectedWorktreeID }
    }

    func selectedBranch() -> BranchInfo? {
        guard let selectedBranchID else { return nil }
        return snapshot?.branches.first { $0.id == selectedBranchID }
    }

    func requestCleanupAfterMenuDismissal(_ request: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async(execute: request)
    }

    func requestRemoveSelectedWorktree() {
        guard canRequestCleanup(), let path = selectedPath, let snapshot, snapshot.path == path, let worktree = selectedWorktree() else { return }
        let cleanup = self.cleanup
        requestPreview { cleanup.previewRemoveWorktree(snapshot: snapshot, path: worktree.path) }
    }

    func requestDeleteSelectedBranch() {
        guard canRequestCleanup(), let path = selectedPath, let snapshot, snapshot.path == path, let branch = selectedBranch() else { return }
        let cleanup = self.cleanup
        requestPreview { cleanup.previewDeleteBranch(snapshot: snapshot, name: branch.name) }
    }

    func requestPrune() {
        guard canRequestCleanup(), let path = selectedPath, let snapshot, snapshot.path == path else { return }
        let cleanup = self.cleanup
        requestPreview { cleanup.previewPrune(snapshot: snapshot) }
    }

    func requestDeleteMergedBranches() {
        guard canRequestCleanup(), let path = selectedPath, let snapshot, snapshot.path == path else { return }
        let cleanup = self.cleanup
        requestPreview { cleanup.previewMergedBranches(snapshot: snapshot) }
    }

    func requestRemoveStaleWorktrees() {
        guard canRequestCleanup(), let path = selectedPath, let snapshot, snapshot.path == path else { return }
        let days = staleDays
        let cleanup = self.cleanup
        requestPreview { cleanup.previewStaleWorktrees(snapshot: snapshot, staleDays: days) }
    }

    func requestDeleteRemoteGoneBranches() {
        guard canRequestCleanup(), let path = selectedPath, let snapshot, snapshot.path == path else { return }
        let cleanup = self.cleanup
        requestPreview { cleanup.previewRemoteGoneBranches(snapshot: snapshot) }
    }

    func executeCleanup(_ preview: CleanupPreview) {
        guard cleanupExecutionState == .idle, !isCleanupPreviewLoading, cleanupPreview?.id == preview.id else { return }
        cleanupExecutionState = .running
        let cleanup = self.cleanup
        Task.detached(priority: .userInitiated) {
            let completed = cleanup.execute(preview)
            await MainActor.run {
                guard self.cleanupPreview?.id == preview.id else { return }
                self.cleanupExecutionState = .completed(completed.count)
                self.statusMessage = completed.isEmpty ? "Completed 0 target(s) — no changes after final guard" : "Completed \(completed.count) target(s)"
                self.refreshSelected()
            }
        }
    }

    func cancelCleanupPreview() {
        guard cleanupExecutionState == .idle else { return }
        cleanupPreviewToken = UUID()
        cleanupPreview = nil
        cleanupExecutionState = .idle
    }

    func closeCleanupPreview() {
        guard case .completed = cleanupExecutionState else { return }
        cleanupPreview = nil
        cleanupExecutionState = .idle
    }

    private func requestPreview(_ operation: @escaping @Sendable () -> CleanupPreview) {
        if cleanupExecutionState == .running {
            statusMessage = "Cleanup already running"
            return
        }
        if case .completed = cleanupExecutionState, cleanupPreview == nil {
            cleanupExecutionState = .idle
        }
        guard cleanupExecutionState == .idle else {
            statusMessage = "Close the current cleanup preview first"
            return
        }
        let token = UUID()
        cleanupPreviewToken = token
        isCleanupPreviewLoading = true
        statusMessage = "Preparing cleanup…"
        Task.detached(priority: .userInitiated) {
            let preview = operation()
            await MainActor.run {
                guard self.cleanupPreviewToken == token else { return }
                self.isCleanupPreviewLoading = false
                self.cleanupExecutionState = .idle
                self.cleanupPreview = preview
                if preview.operation == .deleteRemoteGoneBranches, preview.groups.isEmpty {
                    self.statusMessage = "No remote-gone branches found"
                } else {
                    self.statusMessage = nil
                }
            }
        }
    }

    private func canRequestCleanup() -> Bool {
        if cleanupExecutionState == .running {
            statusMessage = "Cleanup already running"
            return false
        }
        if case .completed = cleanupExecutionState, cleanupPreview == nil {
            cleanupExecutionState = .idle
        }
        guard let path = selectedPath, let snapshot, snapshot.path == path else {
            statusMessage = "Cleanup unavailable: no current repository snapshot"
            return false
        }
        return true
    }
}

struct ContentView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        HSplitView {
            repositorySidebar.frame(minWidth: 240, idealWidth: 270, maxWidth: 330)
            treePanel.frame(minWidth: 580)
            inspectorPanel.frame(minWidth: 340, idealWidth: 390, maxWidth: 470)
        }
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.register(url: url) }
        }
        .alert("Worktree Lens", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $model.cleanupPreview) { preview in
            CleanupConfirmationView(preview: preview, model: model)
                .interactiveDismissDisabled(model.cleanupExecutionState != .idle)
        }
    }

    private var repositorySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Repositories", systemImage: "shippingbox")
                    .font(.headline)
                Spacer()
                Button { model.isImporterPresented = true } label: { Image(systemName: "plus") }
                    .help("Register repository")
            }
            .padding()
            Divider()
            List(selection: Binding(get: { model.selectedPath }, set: { path in
                if let path { model.selectRepository(path: path) }
            })) {
                ForEach(model.registeredPaths, id: \.self) { path in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 3)
                    .tag(Optional(path))
                    .contextMenu {
                        Button("Remove Registration", role: .destructive) {
                            model.selectRepository(path: path)
                            model.removeSelectedRepository()
                        }
                    }
                }
            }
            if model.registeredPaths.isEmpty {
                EmptyStateView(title: "No repository", systemImage: "folder.badge.plus", message: "Register a local Git repository")
                    .padding()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var treePanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.snapshot?.name ?? "Worktree Lens")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    if let snapshot = model.snapshot {
                        Text("Default branch: \(snapshot.defaultBranch ?? "Unknown")")
                            .font(.caption)
                            .foregroundStyle(snapshot.defaultBranch == nil ? .orange : .secondary)
                    } else {
                        Text("Register a repository to begin")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let scanPhase = model.scanPhase { Text(scanPhase).font(.caption).foregroundStyle(.secondary) }
                if model.isLoading || model.isCleanupPreviewLoading { ProgressView().controlSize(.small) }
                if model.canCancelGitHub { Button("Cancel GitHub") { model.cancelGitHub() } }
                Button { model.refreshSelected() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Menu { cleanupMenu } label: { Label("Cleanup", systemImage: "trash") }
            }
            .padding()
            Divider()
            if let snapshot = model.snapshot {
                List(selection: $model.selection) {
                    Section {
                        ForEach(snapshot.branches) { branch in
                            DisclosureGroup {
                                ForEach(branch.worktrees) { worktree in
                                    DisclosureGroup {
                                        ForEach(worktree.sessions) { session in
                                            SessionTreeRow(session: session)
                                        }
                                    } label: {
                                        WorktreeRow(worktree: worktree)
                                    }
                                    .tag(RepositorySelection.worktree(worktree.id))
                                }
                            } label: {
                                BranchRow(branch: branch)
                                    .contentShape(Rectangle())
                                    .tag(RepositorySelection.branch(branch.id))
                                    .onTapGesture { model.selectBranch(id: branch.id) }
                            }
                        }
                    } header: {
                        Text("Repo → Branch → Worktree → Session")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: model.selection) { _ in model.selectionDidChange() }
            } else {
                EmptyStateView(title: "No snapshot", systemImage: "arrow.triangle.2.circlepath", message: "Refresh after registering a Git repository")
            }
            if !model.sessionNotes.isEmpty {
                DisclosureGroup("Read-only session scan") {
                    ForEach(model.sessionNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            if let statusMessage = model.statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
        }
    }

    private var cleanupMenu: some View {
        Group {
            Button("Remove Selected Worktree…") { model.requestCleanupAfterMenuDismissal { model.requestRemoveSelectedWorktree() } }
                .disabled(model.selectedWorktree() == nil)
            Button("Delete Selected Branch…") { model.requestCleanupAfterMenuDismissal { model.requestDeleteSelectedBranch() } }
                .disabled(model.selectedBranch() == nil)
            Divider()
            Button("Prune Worktree Metadata…") { model.requestCleanupAfterMenuDismissal { model.requestPrune() } }
            Button("Clean Up Merged Branches…") { model.requestCleanupAfterMenuDismissal { model.requestDeleteMergedBranches() } }
            Button("Delete Stale Worktrees (\(model.staleDays)d)…") { model.requestCleanupAfterMenuDismissal { model.requestRemoveStaleWorktrees() } }
            Button("Clean Up Merged Remote-gone Branches…") { model.requestCleanupAfterMenuDismissal { model.requestDeleteRemoteGoneBranches() } }
            Divider()
            Stepper("Stale threshold: \(model.staleDays) days", value: $model.staleDays, in: 1...365)
        }
    }

    private var inspectorPanel: some View {
        ScrollView {
            if let worktree = model.selectedWorktree() {
                WorktreeDetail(worktree: worktree, branch: model.branch(for: worktree), defaultBranch: model.snapshot?.defaultBranch)
            } else if let branch = model.selectedBranch() {
                BranchDetail(branch: branch, defaultBranch: model.snapshot?.defaultBranch)
            } else {
                EmptyStateView(title: "Select a branch or worktree", systemImage: "sidebar.right", message: nil)
            }
        }
        .padding()
    }
}

struct BranchRow: View {
    let branch: BranchInfo

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: branch.isDetachedGroup ? "scissors" : (branch.isDefaultBranch ? "star" : "arrow.triangle.branch"))
                .foregroundStyle(branch.isDetachedGroup ? .orange : (branch.isDefaultBranch ? .yellow : (branch.isMerged ? .green : .blue)))
            VStack(alignment: .leading, spacing: 3) {
                Text(branch.name).fontWeight(.semibold)
                if branch.isDetachedGroup {
                    Text("Branch unavailable · detached HEAD").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(branch.sha.prefix(8)) · Δdefault +\(branch.defaultAhead) / -\(branch.defaultBehind)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Badge(text: branch.mergeStatus, color: branch.isMerged ? .green : .orange)
            if branch.remoteGone { Badge(text: "remote gone", color: .orange) }
        }
        .padding(.vertical, 3)
    }
}

struct WorktreeRow: View {
    let worktree: WorktreeInfo

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: worktree.isDetached ? "scissors" : (worktree.isClean ? "checkmark.seal" : "exclamationmark.triangle"))
                .foregroundStyle(worktree.isDetached ? .orange : (worktree.isClean ? .green : .orange))
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: worktree.path).lastPathComponent).fontWeight(.medium)
                Text(worktree.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !worktree.isClean { Badge(text: "dirty", color: .orange) }
            if !worktree.sessions.isEmpty { Text("\(worktree.sessions.count)").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}

struct SessionTreeRow: View {
    let session: SessionRecord
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(activityColor).frame(width: 7, height: 7)
            Text(session.provider.rawValue).font(.caption.weight(.semibold))
            Text(session.title).lineLimit(1)
            Spacer()
            Text(session.activity.rawValue).font(.caption2).foregroundStyle(activityColor)
            if let updatedAt = session.updatedAt { Text(updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary) }
            if let url = session.url { Button("Open") { openURL(url) }.buttonStyle(.link).font(.caption2) }
        }
        .padding(.leading, 22)
        .padding(.vertical, 2)
    }

    private var activityColor: Color {
        switch session.activity {
        case .active: return .red
        case .inactive: return .secondary
        case .unknown: return .orange
        }
    }
}

struct BranchDetail: View {
    let branch: BranchInfo
    let defaultBranch: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Branch").font(.system(.title2, design: .rounded).weight(.bold))
            LabeledContent("Name", value: branch.name)
            LabeledContent("SHA", value: String(branch.sha.prefix(12)))
            LabeledContent("Default", value: branch.isDefaultBranch ? "Yes" : (defaultBranch ?? "Unknown"))
            LabeledContent("Merge status", value: branch.mergeStatus)
            LabeledContent("Default diff", value: "+\(branch.defaultAhead) / -\(branch.defaultBehind)")
            Divider()
            GitHubDetail(status: branch.github)
        }
    }
}

struct WorktreeDetail: View {
    let worktree: WorktreeInfo
    let branch: BranchInfo?
    let defaultBranch: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Worktree").font(.system(.title2, design: .rounded).weight(.bold))
            LabeledContent("Path", value: worktree.path)
            LabeledContent("HEAD", value: String(worktree.head.prefix(12)))
            LabeledContent("Branch", value: worktree.branch ?? "Detached HEAD")
            LabeledContent("Status", value: worktree.isClean ? "Clean" : "Dirty")
            LabeledContent("Default diff", value: "+\(worktree.defaultAhead) / -\(worktree.defaultBehind)")
            if !worktree.isClean { Text("staged \(worktree.stagedCount) · unstaged \(worktree.unstagedCount) · untracked \(worktree.untrackedCount)").font(.caption).foregroundStyle(.orange) }
            if let defaultBranch { Text("Compared with \(defaultBranch)").font(.caption).foregroundStyle(.secondary) }
            Divider()
            Text("Sessions").font(.headline)
            if worktree.sessions.isEmpty {
                Text("No explicit session path evidence").foregroundStyle(.secondary)
            } else {
                ForEach(worktree.sessions) { SessionDetail(session: $0) }
            }
            if let branch { GitHubDetail(status: branch.github) }
        }
    }
}

struct SessionDetail: View {
    let session: SessionRecord
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(session.provider.rawValue).font(.caption.bold()); Text(session.activity.rawValue).font(.caption2).foregroundStyle(.secondary) }
            Text(session.title)
            if let updatedAt = session.updatedAt { Text("Updated \(updatedAt, style: .relative)").font(.caption).foregroundStyle(.secondary) }
            Text(session.evidence).font(.caption2).foregroundStyle(.secondary)
            if let url = session.url { Button("Open session") { openURL(url) }.buttonStyle(.link) }
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct GitHubDetail: View {
    let status: GitHubStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub").font(.headline)
            if let error = status.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if !status.isLoaded {
                Text(status.mergeEvidenceLoaded ? "Merge evidence loaded · Branch details load on selection" : "GitHub details unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Issue \(status.issues.count) · PR \(status.pullRequests.count) · Actions \(status.actions.count)").font(.caption)
                ForEach(status.pullRequests) { pr in
                    Text("PR #\(pr.number) · \(pr.state)\(pr.mergedAt == nil ? "" : " · merged")").font(.caption)
                    if let base = pr.baseRefName, let head = pr.headRefName {
                        Text("    \(head) → \(base) · SHA \(String((pr.headRefOid ?? "unknown").prefix(12)))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(status.actions) { run in
                    Text("Action · \(run.name) · \(run.conclusion ?? run.status)").font(.caption)
                }
                ForEach(status.issues) { issue in
                    Text("Issue #\(issue.number) · \(issue.title)").font(.caption)
                }
            }
        }
    }
}

struct CleanupConfirmationView: View {
    let preview: CleanupPreview
    @ObservedObject var model: ApplicationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Confirm cleanup").font(.system(.title2, design: .rounded).weight(.bold))
            Text(preview.operation.rawValue).foregroundStyle(.secondary)
            if preview.operation == .deleteRemoteGoneBranches, preview.groups.isEmpty {
                Text("No remote-gone branches found")
                    .font(.headline)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    if preview.groups.isEmpty {
                        ForEach(preview.items) { item in
                            cleanupItem(item)
                        }
                    } else {
                        ForEach(preview.groups) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(group.branchName).font(.headline)
                                ForEach(group.steps) { item in
                                    cleanupItem(item)
                                }
                            }
                        }
                    }
                }
            }
            Text("Allowed \(allowedCount) / total \(totalCount). Final guards run again immediately before each operation.")
                .font(.caption).foregroundStyle(.secondary)
            executionStatus
            actionArea
        }
        .padding(22)
        .frame(width: 600, height: 470)
    }

    @ViewBuilder
    private var executionStatus: some View {
        switch model.cleanupExecutionState {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                Text("Running cleanup…")
            }
        case .completed(let count):
            VStack(alignment: .leading, spacing: 4) {
                Text("Completed \(count) target(s)")
                if count == 0 {
                    Text("No changes after final guard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        HStack {
            Spacer()
            switch model.cleanupExecutionState {
            case .idle:
                Button("Cancel") { model.cancelCleanupPreview() }
                Button("Run allowed targets") { model.executeCleanup(preview) }
                    .buttonStyle(.borderedProminent)
                    .disabled(allowedCount == 0)
            case .running:
                Button("Cancel") { model.cancelCleanupPreview() }
                    .disabled(true)
            case .completed:
                Button("Close") { model.closeCleanupPreview() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var allowedCount: Int {
        preview.groups.isEmpty ? preview.allowedItems.count : preview.groups.filter(\.allowed).count
    }

    private var totalCount: Int {
        preview.groups.isEmpty ? preview.items.count : preview.groups.count
    }

    @ViewBuilder
    private func cleanupItem(_ item: CleanupPreviewItem) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: item.allowed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(item.allowed ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                if let step = item.step { Text(step.rawValue).font(.subheadline.weight(.semibold)) }
                Text(item.target).lineLimit(2)
                if let detail = item.detail { Text(detail).font(.caption).foregroundStyle(item.allowed ? .green : .secondary) }
                if let reason = item.reason { Text(reason.message).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.12), in: Capsule())
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
