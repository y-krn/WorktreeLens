#!/bin/bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/WorktreeLens installer tests.XXXXXX")"
REMOTE="$TEST_ROOT/origin.git"
SEED="$TEST_ROOT/seed"
FAKE_BIN="$TEST_ROOT/fake bin"
PASS_COUNT=0

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_abort() {
  local name="$1"
  shift
  if "$@" >"$TEST_ROOT/$name.log" 2>&1; then
    fail "$name should abort"
  fi
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS %s\n' "$name"
}

mkdir -p "$FAKE_BIN"
git init --bare --initial-branch=main "$REMOTE" >/dev/null
git init --initial-branch=main "$SEED" >/dev/null
git -C "$SEED" config user.name "Installer Tests"
git -C "$SEED" config user.email installer-tests@example.invalid
printf 'fixture\n' > "$SEED/fixture.txt"
mkdir -p "$SEED/scripts"
cp "$REPO_ROOT/scripts/install-local.sh" "$SEED/scripts/install-local.sh"
git -C "$SEED" add fixture.txt
git -C "$SEED" add scripts/install-local.sh
git -C "$SEED" commit -m initial >/dev/null
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -u origin main >/dev/null

cat > "$FAKE_BIN/xcodebuild" <<'SH'
#!/bin/bash
set -euo pipefail
[[ "${WORKTREE_LENS_TEST_BUILD:-success}" == success ]] || exit 41
derived_data=""
while (($#)); do
  if [[ "$1" == -derivedDataPath ]]; then derived_data="$2"; shift 2; else shift; fi
done
app="$derived_data/Build/Products/Release/WorktreeLens.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
printf '#!/bin/sh\nexit 0\n' > "$contents/MacOS/WorktreeLens"
chmod +x "$contents/MacOS/WorktreeLens"
identifier="com.ykrn.WorktreeLens"
[[ "${WORKTREE_LENS_TEST_INVALID_BUNDLE:-0}" == 1 ]] && identifier="invalid.bundle"
/usr/libexec/PlistBuddy \
  -c 'Add :CFBundlePackageType string APPL' \
  -c "Add :CFBundleIdentifier string $identifier" \
  -c 'Add :CFBundleExecutable string WorktreeLens' \
  -c 'Add :CFBundleIconName string AppIcon' \
  "$contents/Info.plist"
touch "$contents/Resources/Assets.car"
SH

cat > "$FAKE_BIN/swift" <<'SH'
#!/bin/bash
[[ "${WORKTREE_LENS_TEST_RUNNING_APP:-0}" != 1 ]]
SH

cat > "$FAKE_BIN/ditto" <<'SH'
#!/bin/bash
set -euo pipefail
cp -R "$1" "$2"
SH

cat > "$FAKE_BIN/mv" <<'SH'
#!/bin/bash
set -euo pipefail
args=("$@")
if [[ "${args[0]}" == -- ]]; then args=("${args[@]:1}"); fi
if [[ "${WORKTREE_LENS_TEST_FAIL_REPLACEMENT:-0}" == 1 && "${args[0]}" == *'/.WorktreeLens.install.'*'/WorktreeLens.app' && "${args[1]}" == "$WORKTREE_LENS_INSTALL_DESTINATION" ]]; then
  exit 44
fi
exec /bin/mv "$@"
SH

cat > "$FAKE_BIN/lsregister" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$FAKE_BIN"/*

new_checkout() {
  local name="$1"
  local checkout="$TEST_ROOT/$name repo"
  git clone "$REMOTE" "$checkout" >/dev/null 2>&1
  printf '%s\n' "$checkout"
}

make_old_app() {
  local destination="$1"
  mkdir -p "$destination/Contents"
  printf 'old app\n' > "$destination/Contents/old-marker"
}

checkout="$(new_checkout dirty)"
touch "$checkout/untracked.txt"
expect_abort dirty-repo env PATH="$FAKE_BIN:$PATH" WORKTREE_LENS_INSTALL_DESTINATION="$TEST_ROOT/destination/WorktreeLens.app" WORKTREE_LENS_LSREGISTER="$FAKE_BIN/lsregister" bash "$checkout/scripts/install-local.sh"
[[ ! -e "$TEST_ROOT/destination/WorktreeLens.app" ]] || fail 'dirty guard touched destination'

checkout="$(new_checkout non-main)"
git -C "$checkout" switch -c topic >/dev/null
expect_abort non-main env PATH="$FAKE_BIN:$PATH" WORKTREE_LENS_INSTALL_DESTINATION="$TEST_ROOT/destination/WorktreeLens.app" WORKTREE_LENS_LSREGISTER="$FAKE_BIN/lsregister" bash "$checkout/scripts/install-local.sh"

checkout="$(new_checkout non-ff)"
printf 'local change\n' > "$checkout/local.txt"
git -C "$checkout" add local.txt
git -C "$checkout" commit -m local >/dev/null
printf 'remote change\n' > "$SEED/remote.txt"
git -C "$SEED" add remote.txt
git -C "$SEED" commit -m remote >/dev/null
git -C "$SEED" push origin main >/dev/null
expect_abort non-ff env PATH="$FAKE_BIN:$PATH" WORKTREE_LENS_INSTALL_DESTINATION="$TEST_ROOT/destination/WorktreeLens.app" WORKTREE_LENS_LSREGISTER="$FAKE_BIN/lsregister" bash "$checkout/scripts/install-local.sh"

checkout="$(new_checkout build-failure)"
destination="$TEST_ROOT/build failure destination/WorktreeLens.app"
mkdir -p "$(dirname -- "$destination")"
make_old_app "$destination"
expect_abort build-failure env PATH="$FAKE_BIN:$PATH" WORKTREE_LENS_TEST_BUILD=fail WORKTREE_LENS_INSTALL_DESTINATION="$destination" WORKTREE_LENS_LSREGISTER="$FAKE_BIN/lsregister" bash "$checkout/scripts/install-local.sh"
[[ -f "$destination/Contents/old-marker" ]] || fail 'build failure changed existing app'

checkout="$(new_checkout invalid-bundle)"
destination="$TEST_ROOT/invalid bundle destination/WorktreeLens.app"
mkdir -p "$(dirname -- "$destination")"
make_old_app "$destination"
expect_abort invalid-bundle env PATH="$FAKE_BIN:$PATH" WORKTREE_LENS_TEST_INVALID_BUNDLE=1 WORKTREE_LENS_INSTALL_DESTINATION="$destination" WORKTREE_LENS_LSREGISTER="$FAKE_BIN/lsregister" bash "$checkout/scripts/install-local.sh"
[[ -f "$destination/Contents/old-marker" ]] || fail 'invalid bundle changed existing app'

checkout="$(new_checkout running-app)"
destination="$TEST_ROOT/running app destination/WorktreeLens.app"
mkdir -p "$(dirname -- "$destination")"
make_old_app "$destination"
expect_abort running-app-timeout env PATH="$FAKE_BIN:$PATH" WORKTREE_LENS_TEST_RUNNING_APP=1 WORKTREE_LENS_INSTALL_DESTINATION="$destination" WORKTREE_LENS_LSREGISTER="$FAKE_BIN/lsregister" bash "$checkout/scripts/install-local.sh"
[[ -f "$destination/Contents/old-marker" ]] || fail 'running app timeout changed existing app'

checkout="$(new_checkout rollback)"
destination="$TEST_ROOT/rollback destination/WorktreeLens.app"
mkdir -p "$(dirname -- "$destination")"
make_old_app "$destination"
expect_abort replacement-failure env PATH="$FAKE_BIN:$PATH" WORKTREE_LENS_TEST_FAIL_REPLACEMENT=1 WORKTREE_LENS_INSTALL_DESTINATION="$destination" WORKTREE_LENS_LSREGISTER="$FAKE_BIN/lsregister" bash "$checkout/scripts/install-local.sh"
[[ -f "$destination/Contents/old-marker" ]] || fail 'replacement failure did not restore old app'

checkout="$(new_checkout success)"
printf 'remote update\n' > "$SEED/fast-forward.txt"
git -C "$SEED" add fast-forward.txt
git -C "$SEED" commit -m 'advance main for installer test' >/dev/null
git -C "$SEED" push origin main >/dev/null
destination="$TEST_ROOT/install path with spaces/WorktreeLens.app"
mkdir -p "$(dirname -- "$destination")"
[[ "$destination" != /Applications/WorktreeLens.app ]] || fail 'test destination must not be production path'
env PATH="$FAKE_BIN:$PATH" WORKTREE_LENS_INSTALL_DESTINATION="$destination" WORKTREE_LENS_LSREGISTER="$FAKE_BIN/lsregister" bash "$checkout/scripts/install-local.sh" > "$TEST_ROOT/success.log" 2>&1 || { cat "$TEST_ROOT/success.log" >&2; fail 'success install failed'; }
[[ -x "$destination/Contents/MacOS/WorktreeLens" ]] || fail 'success install missing executable'
[[ -f "$destination/Contents/Resources/Assets.car" ]] || fail 'success install missing icon assets'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$destination/Contents/Info.plist")" == AppIcon ]] || fail 'success install lost icon name'
[[ -f "$checkout/fast-forward.txt" ]] || fail 'success install did not fast-forward repository'
grep -q "Installed: $destination" "$TEST_ROOT/success.log" || fail 'success output omitted installed path'
grep -q "Commit: $(git -C "$checkout" rev-parse HEAD)" "$TEST_ROOT/success.log" || fail 'success output omitted installed commit'
PASS_COUNT=$((PASS_COUNT + 1))
printf 'PASS success-install-path-with-spaces-and-fast-forward\n'
printf 'All %s installer tests passed.\n' "$PASS_COUNT"
