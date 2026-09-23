#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
INSTALL_PATH="${WORKTREE_LENS_INSTALL_DESTINATION:-/Applications/WorktreeLens.app}"
INSTALL_PARENT="$(dirname -- "$INSTALL_PATH")"
APP_NAME="WorktreeLens.app"
BUNDLE_ID="com.ykrn.WorktreeLens"
LSREGISTER="${WORKTREE_LENS_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
DERIVED_DATA=""
STAGE_DIR=""
BACKUP_PATH=""
OLD_MOVED=0
NEW_INSTALLED=0
COMMITTED=0

fail() {
  printf 'install-local: %s\n' "$*" >&2
  exit 1
}

rollback() {
  local original_status=$?
  trap - EXIT INT TERM

  if [[ "$COMMITTED" -eq 0 ]]; then
    if [[ "$NEW_INSTALLED" -eq 1 && -e "$INSTALL_PATH" ]]; then
      if ! rm -rf -- "$INSTALL_PATH"; then
        printf 'install-local: rollback failed removing %s\n' "$INSTALL_PATH" >&2
      fi
    fi
    if [[ "$OLD_MOVED" -eq 1 && -e "$BACKUP_PATH" ]]; then
      if mv -- "$BACKUP_PATH" "$INSTALL_PATH"; then
        printf 'install-local: previous app restored\n' >&2
      else
        printf 'install-local: rollback failed; previous app remains at %s\n' "$BACKUP_PATH" >&2
      fi
    fi
  fi

  [[ -z "$STAGE_DIR" || ! -d "$STAGE_DIR" ]] || rm -rf -- "$STAGE_DIR"
  [[ -z "$DERIVED_DATA" || ! -d "$DERIVED_DATA" ]] || rm -rf -- "$DERIVED_DATA"
  exit "$original_status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd -- "$REPO_ROOT"

[[ "$(git status --porcelain --untracked-files=all)" == "" ]] || fail "working tree must be clean"
[[ "$(git branch --show-current)" == "main" ]] || fail "checked-out branch must be main"

git fetch origin || fail "git fetch origin failed"
git merge-base --is-ancestor HEAD origin/main || fail "local main cannot fast-forward to origin/main"
git pull --ff-only || fail "git pull --ff-only failed"

DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/WorktreeLens-DerivedData.XXXXXX")" || fail "could not create temporary DerivedData directory"
xcodebuild \
  -project "$REPO_ROOT/WorktreeLens.xcodeproj" \
  -scheme WorktreeLens \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  clean build || fail "native Release build failed"

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME"
INFO_PLIST="$BUILT_APP/Contents/Info.plist"
[[ -d "$BUILT_APP" ]] || fail "built app missing: $BUILT_APP"
[[ -x "$BUILT_APP/Contents/MacOS/WorktreeLens" ]] || fail "app executable missing or not executable"
[[ -f "$INFO_PLIST" ]] || fail "app Info.plist missing"
[[ -f "$BUILT_APP/Contents/Resources/Assets.car" ]] || fail "app Assets.car missing"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null
}
[[ "$(plist_value CFBundlePackageType)" == APPL ]] || fail "CFBundlePackageType must be APPL"
[[ "$(plist_value CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "CFBundleIdentifier must be $BUNDLE_ID"
[[ "$(plist_value CFBundleExecutable)" == WorktreeLens ]] || fail "CFBundleExecutable must be WorktreeLens"
[[ "$(plist_value CFBundleIconName)" == AppIcon ]] || fail "CFBundleIconName must be AppIcon"

[[ -d "$INSTALL_PARENT" ]] || fail "install destination parent does not exist: $INSTALL_PARENT"
STAGE_DIR="$(mktemp -d "$INSTALL_PARENT/.WorktreeLens.install.XXXXXX")" || fail "cannot stage app on destination filesystem; check permissions for $INSTALL_PARENT"
CANDIDATE_PATH="$STAGE_DIR/$APP_NAME"
ditto "$BUILT_APP" "$CANDIDATE_PATH" || fail "could not stage app; check permissions for $INSTALL_PARENT"

QUIT_HELPER="$STAGE_DIR/request-normal-quit.swift"
cat > "$QUIT_HELPER" <<'SWIFT'
import AppKit
import Foundation

let bundleID = CommandLine.arguments[1]
let timeout = Double(CommandLine.arguments[2]) ?? 5
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
guard !apps.isEmpty else { exit(0) }
for app in apps where !app.terminate() {
    fputs("normal quit request failed\n", stderr)
    exit(2)
}
let deadline = Date().addingTimeInterval(timeout)
while Date() < deadline {
    if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { exit(0) }
    Thread.sleep(forTimeInterval: 0.2)
}
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
    exit(0)
}
fputs("app did not quit within \(timeout) seconds\n", stderr)
exit(1)
SWIFT
if ! swift "$QUIT_HELPER" "$BUNDLE_ID" 5; then
  fail "running Worktree Lens did not quit normally; existing installation unchanged"
fi

if [[ -e "$INSTALL_PATH" ]]; then
  BACKUP_PATH="$STAGE_DIR/previous-$APP_NAME"
  mv -- "$INSTALL_PATH" "$BACKUP_PATH" || fail "cannot move existing app; check permissions for $INSTALL_PATH"
  OLD_MOVED=1
fi

mv -- "$CANDIDATE_PATH" "$INSTALL_PATH" || fail "cannot install app; check permissions for $INSTALL_PATH"
NEW_INSTALLED=1
touch "$INSTALL_PATH" || fail "cannot refresh installed app timestamp; check permissions for $INSTALL_PATH"
"$LSREGISTER" -f "$INSTALL_PATH" || fail "LaunchServices registration failed"

COMMITTED=1
if [[ "$OLD_MOVED" -eq 1 ]]; then
  rm -rf -- "$BACKUP_PATH" || printf 'install-local: warning: old app backup remains at %s\n' "$BACKUP_PATH" >&2
fi
printf 'Installed: %s\nCommit: %s\n' "$INSTALL_PATH" "$(git rev-parse HEAD)"
