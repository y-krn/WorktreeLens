import XCTest
import WorktreeLensCore
@testable import WorktreeLensApp

@MainActor
final class CleanupRequestTests: XCTestCase {
    func testRemoteGoneMenuRequestImmediatelyShowsPreparingAndPresentsPreview() async throws {
        let model = ApplicationModel(loadRepositories: false)
        let snapshot = RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [])
        model.selectedPath = snapshot.path
        model.snapshot = snapshot

        model.requestDeleteRemoteGoneBranches()

        XCTAssertTrue(model.isCleanupPreviewLoading)
        XCTAssertEqual(model.statusMessage, "Preparing cleanup…")
        try await waitForPreview(model)
        XCTAssertNotNil(model.cleanupPreview)
        XCTAssertEqual(model.statusMessage, "No remote-gone branches found")
    }

    func testRemoteGoneRequestDuringExecutionShowsVisibleFeedback() {
        let model = ApplicationModel(loadRepositories: false)
        let snapshot = RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [])
        model.selectedPath = snapshot.path
        model.snapshot = snapshot
        model.cleanupExecutionState = .running

        model.requestDeleteRemoteGoneBranches()

        XCTAssertNil(model.cleanupPreview)
        XCTAssertEqual(model.statusMessage, "Cleanup already running")
    }

    func testRemoteGoneRequestRecoversCompletedStateWithoutPreview() async throws {
        let model = ApplicationModel(loadRepositories: false)
        let snapshot = RepositorySnapshot(path: "/tmp/repository", defaultBranch: "main", branches: [])
        model.selectedPath = snapshot.path
        model.snapshot = snapshot
        model.cleanupExecutionState = .completed(0)

        model.requestDeleteRemoteGoneBranches()

        XCTAssertTrue(model.isCleanupPreviewLoading)
        try await waitForPreview(model)
        XCTAssertNotNil(model.cleanupPreview)
        XCTAssertEqual(model.cleanupExecutionState, .idle)
    }

    private func waitForPreview(_ model: ApplicationModel) async throws {
        for _ in 0..<100 where model.cleanupPreview == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(model.cleanupPreview, "Cleanup preview request did not complete")
    }
}
