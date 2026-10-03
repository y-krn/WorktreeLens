# Worktree Lens

Worktree Lens は、Git worktree、ブランチ、関連セッションを確認する macOS アプリです。SwiftUI の画面は `Sources/WorktreeLensApp/WorktreeLensApp.swift` にあり、SwiftPM と Xcode の両方から同じ実装を利用します。共有ロジックは `WorktreeLensCore` が提供します。

## ビルドとテスト

SwiftPM でビルドとテストを実行します。

```sh
swift build
swift test
```

macOS アプリは Xcode の `WorktreeLens` scheme からビルドします。

```sh
xcodebuild \
  -project WorktreeLens.xcodeproj \
  -scheme WorktreeLens \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Xcode では `WorktreeLens.xcodeproj` を開き、`My Mac` を選んで `WorktreeLens` scheme を Run します。生成物は `WorktreeLens.app` です。

GitHub App の Device Flow 認証と設定手順は [GitHub App 認証の運用](docs/github-app-authentication.md) を参照してください。既存の PR 表示と Cleanup の GitHub CLI 経路は後続の移行まで維持します。
