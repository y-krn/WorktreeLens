import XCTest
import WorktreeLensCore
@testable import WorktreeLensApp

@MainActor
final class CleanupRequestTests: XCTestCase {
    func testCleanUpRequestImmediatelyShowsPreparingAndPresentsPreview() async throws {
        let model = ApplicationModel(loadRepositories: false)
        let snapshot = RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [])
        model.selectedPath = snapshot.path
        model.snapshot = snapshot

        model.requestDeleteMergedBranches()

        XCTAssertTrue(model.isCleanupPreviewLoading)
        XCTAssertEqual(model.statusMessage, "Preparing cleanup…")
        try await waitForPreview(model)
        XCTAssertNotNil(model.cleanupPreview)
        XCTAssertEqual(model.statusMessage, "Nothing to clean up")
    }

    func testCleanUpRequestDuringExecutionShowsVisibleFeedback() {
        let model = ApplicationModel(loadRepositories: false)
        let snapshot = RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [])
        model.selectedPath = snapshot.path
        model.snapshot = snapshot
        model.cleanupExecutionState = .running

        model.requestDeleteMergedBranches()

        XCTAssertNil(model.cleanupPreview)
        XCTAssertEqual(model.statusMessage, "Cleanup already running")
    }

    func testCleanUpRequestRecoversCompletedStateWithoutPreview() async throws {
        let model = ApplicationModel(loadRepositories: false)
        let snapshot = RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [])
        model.selectedPath = snapshot.path
        model.snapshot = snapshot
        model.cleanupExecutionState = .completed(0)

        model.requestDeleteMergedBranches()

        XCTAssertTrue(model.isCleanupPreviewLoading)
        try await waitForPreview(model)
        XCTAssertNotNil(model.cleanupPreview)
        XCTAssertEqual(model.cleanupExecutionState, .idle)
    }

    func testCleanUpPreviewHidesBranchesThatAreNeverCandidates() {
        func group(_ name: String, allowed: Bool, reason: CleanupBlockReason?) -> CleanupPreviewGroup {
            CleanupPreviewGroup(branchName: name, expectedSHA: "sha", steps: [CleanupPreviewItem(id: "\(name):branch", target: name, allowed: allowed, reason: reason, step: .deleteBranch)])
        }
        let preview = CleanupPreview(operation: .deleteMergedBranches, repositoryPath: "/tmp/repository", items: [], groups: [
            group("main", allowed: false, reason: .defaultBranch),
            group("wip", allowed: false, reason: .unmergedBranch),
            group("dirty", allowed: false, reason: .dirtyWorktree),
            group("merged", allowed: true, reason: nil)
        ])

        XCTAssertEqual(preview.displayedGroups.map(\.branchName), ["dirty", "merged"])
    }

    private func waitForPreview(_ model: ApplicationModel) async throws {
        for _ in 0..<100 where model.cleanupPreview == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(model.cleanupPreview, "Cleanup preview request did not complete")
    }
}
