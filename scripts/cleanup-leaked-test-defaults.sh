#!/bin/bash
# One-off cleanup for preference domains leaked by older RepositoryViewCacheTests runs.
# Lists matches by default; pass --delete to remove them.
set -euo pipefail

shopt -s nullglob
files=("$HOME"/Library/Preferences/RepositoryViewCacheTests-*.plist)
echo "${#files[@]} leaked RepositoryViewCacheTests domain(s)"
[ ${#files[@]} -eq 0 ] && exit 0

if [ "${1:-}" != "--delete" ]; then
    printf '%s\n' "${files[@]}"
    echo "Re-run with --delete to remove them."
    exit 0
fi

for file in "${files[@]}"; do
    defaults delete "$(basename "$file" .plist)" 2>/dev/null || true
    rm -f "$file"
done
echo "Removed ${#files[@]} domain(s)."
