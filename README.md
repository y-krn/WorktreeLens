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

## ローカルインストール

クリーンな `main` checkout で、Xcode に設定済みの Apple 開発チームを指定してインストールします。インストーラーは最新 `origin/main` へ fast-forward した後、署名した Release アプリを作成します。

```sh
WORKTREELENS_SIGNING_TEAM=YOUR_TEAM_ID make install
```

Data Protection Keychain を使用するため、Apple Development 証明書と、アプリの entitlements を承認する provisioning profile が必要です。`WORKTREELENS_SIGNING_IDENTITY` で証明書を指定できます（既定値: `Apple Development`）。チーム未指定時は、ビルドや既存アプリの置換前に設定方法を表示して停止します。無署名ビルドはコンパイル確認用であり、Keychain 認証を利用するインストールには使いません。

Xcode による profile 更新は許可しますが、開発端末登録は自動では行いません。登録枠の使用を承認した場合だけ `WORKTREELENS_ALLOW_DEVICE_REGISTRATION=1` を追加してください。既存の clean/main 確認、通常終了要求、置換と rollback 手順は維持しています。
