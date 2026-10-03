# GitHub App 認証の運用

GitHub App Device Flow で認証し、PR 表示と Cleanup の検証を GitHub API へ直接送信します。GitHub CLI の認証状態や `gh` のインストールは不要です。

## GitHub App の登録とインストール

1. github.com の個人または組織の Developer settings → GitHub Apps から App を登録します。Desktop Device Flow 用に「Enable Device Flow」を有効にします。常設サーバーや Webhook は必要ありません。
2. Repository permissions は Pull requests、Issues、Checks、Actions、Contents、Commit statuses を **Read-only** に設定します。これらは後続の PR、closing issues、check runs、Actions、コミット確認で使用します。Metadata は GitHub App の標準 Read-only 権限です。Organization permissions と Account permissions は追加しません。
3. App をインストールし、Only select repositories で監視対象の repository だけを選択します。組織のポリシーによって管理者の承認が必要です。権限を変更した場合はインストール先で再承認します。
4. App settings の **Client ID** をコピーします。App ID ではありません。client secret と App private key はアプリに設定しません。Device Flow 由来の refresh token 更新にも client secret は不要です。
5. Worktree Lens の Settings → GitHub App Authentication に Client ID を入力し、Sign In を選択します。開いた `https://github.com/login/device` で画面の user code を入力し、App を承認します。組織で SAML SSO を使用する場合は、その組織の SAML セッションを開始してから認証します。
6. Verify API Read で認証済み `GET /user` を確認します。アカウントの読取成功は対象 repository の権限確認を意味しません。Cleanup は対象 repository と PR を別途検証し、取得失敗を「データなし」として扱いません。

認証を拒否した場合、期限が切れた場合、Cancel を選択した場合は自動的に新しい認証を開始しません。利用者が Sign In を再度選択します。失効したトークンは再認証が必要です。

## 保存と認証ライフサイクル

- Client ID は公開設定として UserDefaults の `githubAppClientID` に保存します。
- アクセストークン、refresh token、期限と認証主体は macOS Keychain の Generic Password にまとめて保存します。service は `com.ykrn.WorktreeLens.github.com.<clientID>`、account は `active-user` です。`kSecUseDataProtectionKeychain=true` を保存・読取・更新・削除の共通 query に設定し、Data Protection Keychain を使用します。同期を無効化し、`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` を指定します。
- github.com の単一有効アカウントを扱います。Client ID を変更して認証すると以前の provider をログアウトさせます。
- アクセストークンの期限の30秒前から更新します。同時の更新要求は一つの共有操作になり、refresh token の競合使用を防ぎます。共有操作の待機者は個別にキャンセル可能で、最後の待機者のキャンセルは実通信をキャンセルします。
- Sign Out は保存情報を削除し、実行中の認証と更新をキャンセルします。世代チェックにより、遅れて返ったレスポンスによる再保存を防ぎます。GitHub 側の App 承認を取り消す操作ではありません。必要なら GitHub Settings → Applications から承認を取り消します。
- `GitHubAuthState` は `GitHubAccount.identifier`（`github.com:<numeric user ID>`）と UUID revision を提供します。`changes()` は復元、認証、失効、ログアウトを通知します。後続キャッシュは revision 変更時に無効化してください。トークン更新で同じ主体の revision は変わりません。

## 注入と通信契約

`GitHubAuthenticationProviding` は UI と独立し、`GitHubAPIClient` に注入します。Device Flow provider には `GitHubTransport`、`GitHubClock`、`GitHubCredentialStore` を注入できます。アプリ全体で同じ `GitHubHTTPClient` を共有し、ホスト別キューを共有してください。

URLSession の async `data(for:)` へ呼出元のキャンセルが伝播します。各 host の実通信は一つ、待機要求は最大64件です。API と OAuth の URL は HTTPS の github.com / api.github.com に限定します。キャッシュと cookie 保存を無効化し、別 host または HTTP へのリダイレクトを拒否します。要求タイムアウトは30秒、URLSession のリソースタイムアウトは60秒です。

読取 GET はネットワーク障害、5xx、rate limit に対し最大2回再試行します。OAuth POST と GraphQL POST は自動再試行しません。OAuth refresh はサーバーが処理済みか不明な失敗があるため、POST の無条件再実行を避けます。Retry-After と primary rate limit reset の遅い方を守ります。secondary rate limit の待機情報がない場合は60秒から指数的に待機します。最後の失敗後も host の待機期限を保持します。

REST / GraphQL とも Bearer、`Accept: application/vnd.github+json`、`X-GitHub-Api-Version: 2026-03-10` を設定します。キュー待機、rate limit 待機、各 retry 後の実送信直前に認証を再取得します。アカウント revision が変わった要求は送信しません。通信中に期限が切れたトークンの401は、有効な refresh token を保持し、次の要求で更新します。期限内の401や更新不能な資格情報は再認証要求、明示的な403の権限不足は permissionDenied、原因を特定できない403は forbiddenUnknown、404は notFoundOrInaccessible です。404だけで不存在と断定しません。ネットワーク障害と rate limit は独立したエラーです。GraphQL の HTTP 200 は data と errors を保持し、部分成功と全失敗を区別できます。

秘密情報をログへ出力する処理はありません。資格情報の description / debugDescription は redacted とし、サーバーの OAuth error_description、HTTP 本文、GraphQL message、URLSession 詳細診断をエラー表示へ転記しません。transport を追加する場合も Authorization と OAuth 本文をログへ記録しないでください。

## 検証

`swift build`、`swift test` と既存 CI の Swift build and tests を実行します。新しいテストは transport、clock、credential store を注入し、認証成功、拒否、期限切れ、slow_down、キャンセル、失効、更新競合、HTTP エラー、rate limit、GraphQL 部分成功を確認します。URLProtocol の開始と停止通知で実 URLSession task のキャンセルを検証し、固定 sleep は使いません。

実環境検証には登録済み App の Client ID、Device Flow 有効化、インストールと必要な組織承認が必要です。PR には実環境確認の有無と未確認項目を明記してください。資格情報不足を取得成功や「対象データなし」として扱いません。

## 署名した実アプリでの Keychain 検証

Data Protection Keychain のアクセスには、署名したアプリの app identifier entitlement と、それを承認する provisioning profile が必要です。Xcode の Signing & Capabilities で開発チームを選択してください。`WorktreeLens.entitlements` は `AppIdentifierPrefix` と bundle identifier からアプリ固有のアクセス主体を指定し、署名チームをリポジトリに固定しません。無署名の SwiftPM executable からの Keychain 操作はサポートしません。

```sh
WORKTREELENS_SIGNING_TEAM=YOUR_TEAM_ID scripts/verify-github-keychain.sh
```

スクリプトは実アプリ target の署名済み Debug build と entitlements を確認し、ランダムな専用 service の合成資格情報で保存・読取・更新・削除を実行します。保存属性が `WhenUnlockedThisDeviceOnly`、同期無効であることも確認します。検証レコードと一時 build は削除します。検証用コードは `KEYCHAIN_VERIFICATION` を指定した build にだけ含まれ、通常の Debug / Release build には入りません。`WORKTREELENS_VERIFICATION_CONFIGURATION=Release` を追加すると、署名した Release build でも同じ実操作を検証できます。実 GitHub token と既存の Keychain 項目は操作しません。

Xcode は設定済み開発者アカウントで provisioning profile を準備します。開発端末の登録が必要な場合は失敗します。Apple Developer の端末登録枠を消費するため、登録を承認した場合だけ `WORKTREELENS_ALLOW_DEVICE_REGISTRATION=1` を追加して実行してください。

## 参照

- [GitHub App Device Flow](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app#using-the-device-flow-to-generate-a-user-access-token)
- [Device Flow 由来 refresh token の更新](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens#refreshing-a-user-access-token-with-a-refresh-token)
- [REST API best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)

- [Apple: macOS Keychain の API と backend](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- [Apple: Keychain のアクセス主体と entitlements](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
