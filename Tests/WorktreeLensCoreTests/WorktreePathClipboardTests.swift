import XCTest
@testable import WorktreeLensApp
import WorktreeLensCore

final class WorktreePathClipboardTests: XCTestCase {
    private final class RecordingClipboard: ClipboardWriting {
        private(set) var writtenString: String?

        func write(_ string: String) {
            writtenString = string
        }
    }

    func testCopyWritesWorktreePathUnchanged() {
        let path = "/Users/me/Worktrees/feature branch/"
        let worktree = WorktreeInfo(id: "feature", path: path, branch: "feature", head: "abc", isBare: false, isLocked: false, isClean: true, stagedCount: 0, unstagedCount: 0, untrackedCount: 0, lastActivity: nil)
        let clipboard = RecordingClipboard()

        WorktreePathClipboard.copy(worktree, to: clipboard)

        XCTAssertEqual(clipboard.writtenString, path)
    }
}
