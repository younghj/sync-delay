#!/bin/zsh
# Merge the latest upstream (leviholliday/sync-delay) into this fork, rebuild, install, and push.
#
#   ./update-from-upstream.sh               merge, build, install to /Applications, push
#   ./update-from-upstream.sh --no-install  merge and build only
#   ./update-from-upstream.sh --no-push     don't push to the fork
#
# If the merge has conflicts it stops before building, so the installed app is untouched.
# Resolve the conflicts, commit, and run the script again.
set -euo pipefail
cd "${0:A:h}"

install=1 push=1
for arg in "$@"; do
  case $arg in
    --no-install) install=0 ;;
    --no-push) push=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

app_name="Sync Delay.app"
dest="/Applications/$app_name"
branch=$(git branch --show-current)

if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
  echo "You have uncommitted changes. Commit or stash them first." >&2
  exit 1
fi
if git ls-files -u | grep -q .; then
  echo "A merge is still in progress. Resolve the conflicts and commit first." >&2
  exit 1
fi

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/leviholliday/sync-delay.git
echo "Fetching upstream…"
git fetch upstream

if git merge-base --is-ancestor upstream/main HEAD; then
  echo "Already includes everything from upstream/main."
else
  echo "Merging upstream/main into $branch…"
  if ! git merge --no-edit upstream/main; then
    echo >&2
    echo "Merge conflicts in:" >&2
    git diff --name-only --diff-filter=U | sed 's/^/  /' >&2
    echo "Resolve them, commit, then run this script again. The installed app was not changed." >&2
    exit 2
  fi
fi

./build-app.sh

if (( install )); then
  if pgrep -x SyncDelay >/dev/null; then
    echo "Quitting the running Sync Delay…"
    osascript -e 'tell application id "local.syncdelay.app" to quit' 2>/dev/null || pkill -x SyncDelay || true
    for _ in {1..25}; do pgrep -x SyncDelay >/dev/null || break; sleep 0.2; done
  fi
  echo "Installing to $dest…"
  rm -rf "$dest"
  ditto "$app_name" "$dest"
  open "$dest"
fi

if (( push )); then
  echo "Pushing $branch to your fork…"
  git push origin "$branch"
  # Keep the fork's copy of upstream current too.
  git push origin upstream/main:refs/heads/upstream-main 2>/dev/null || true
fi

echo "Done. Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' SyncDelay-Info.plist)"
