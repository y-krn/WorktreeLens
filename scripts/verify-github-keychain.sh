#!/bin/bash
set -euo pipefail

# Uses the actual app target and signing entitlements with an isolated synthetic Keychain record.
# Set the team explicitly; do not commit a developer's team or identity to the project.
: "${WORKTREELENS_SIGNING_TEAM:?Set WORKTREELENS_SIGNING_TEAM to your Apple development team ID}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/worktreelens-keychain.XXXXXX")"
trap 'rm -r "$verification_dir"' EXIT
provisioning_args=(-allowProvisioningUpdates)
# Device registration consumes an Apple Developer device slot; opt in explicitly.
if [[ "${WORKTREELENS_ALLOW_DEVICE_REGISTRATION:-0}" == "1" ]]; then
    provisioning_args+=(-allowProvisioningDeviceRegistration)
fi
xcodebuild "${provisioning_args[@]}" -project "$repo_root/WorktreeLens.xcodeproj" -scheme WorktreeLens \
    -configuration "${WORKTREELENS_VERIFICATION_CONFIGURATION:-Debug}" -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$verification_dir" \
    DEVELOPMENT_TEAM="$WORKTREELENS_SIGNING_TEAM" CODE_SIGN_IDENTITY='Apple Development' \
    OTHER_SWIFT_FLAGS='$(inherited) -DKEYCHAIN_VERIFICATION' build > "$verification_dir/build.log" 2>&1 || {
    tail -60 "$verification_dir/build.log"
    exit 1
}
app_path="$verification_dir/Build/Products/${WORKTREELENS_VERIFICATION_CONFIGURATION:-Debug}/WorktreeLens.app"
codesign --verify --strict "$app_path"
codesign -d --entitlements - "$app_path"
"$app_path/Contents/MacOS/WorktreeLens" --verify-github-keychain
