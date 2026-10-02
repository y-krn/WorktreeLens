import AppKit
import WorktreeLensCore

protocol ClipboardWriting {
    func write(_ string: String)
}

struct SystemClipboardWriter: ClipboardWriting {
    func write(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

enum WorktreePathClipboard {
    static func copy(_ worktree: WorktreeInfo, to clipboard: any ClipboardWriting) {
        clipboard.write(worktree.path)
    }
}
