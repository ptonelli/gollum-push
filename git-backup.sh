#!/usr/bin/env sh
set -eu

# This script uses inotify to push a Gollum-managed repo when it changes.
# It assumes the working tree is always clean (no local commits are created).
# Requires: inotifywait (from inotify-tools)

WIKI_DIR="${WIKI_DIR:-/wiki}"
REMOTE_REPO="${REMOTE_REPO:-}"           # required
DEBOUNCE="${DEBOUNCE:-3}"                # seconds to batch events

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }

# Verify required environment variable
[ -n "$REMOTE_REPO" ] || { log "ERROR: REMOTE_REPO must be set"; exit 1; }

# Ensure inotifywait exists
command -v inotifywait >/dev/null 2>&1 || { log "ERROR: inotifywait not found (install inotify-tools)"; exit 1; }

# Change to the wiki directory
cd "$WIKI_DIR" 2>/dev/null || { log "ERROR: Cannot change to directory $WIKI_DIR"; exit 1; }
[ -d ".git" ] || { log "ERROR: $WIKI_DIR is not a git repository"; exit 1; }

log "Starting Git backup sidecar for Gollum wiki"
log "Wiki directory: $WIKI_DIR"
log "Remote repository: $REMOTE_REPO"

# Detect current branch (fallback to master)
BRANCH="${BRANCH:-$(git symbolic-ref --short HEAD 2>/dev/null || echo master)}"
log "Branch: $BRANCH"

# ----- SSH known_hosts setup (kept as-is) -----
# Extract Git server hostname from the repository URL
# Format: git@server:repo.git or git@server/repo.git
GIT_SERVER=$(echo "$REMOTE_REPO" | sed -n 's/git@\([^:]*\).*/\1/p')

if [ -z "$GIT_SERVER" ]; then
  log "ERROR: Could not extract Git server from REMOTE_REPO. Format should be git@server:repo.git"
  exit 1
fi

# Set up SSH known_hosts file if it doesn't exist
if [ ! -f "$HOME/.ssh/known_hosts" ] || ! grep -q "$GIT_SERVER" "$HOME/.ssh/known_hosts"; then
  log "Setting up SSH known_hosts for $GIT_SERVER"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keyscan -t rsa "$GIT_SERVER" >> "$HOME/.ssh/known_hosts" 2>/dev/null

  if [ $? -ne 0 ]; then
    log "WARNING: Failed to add $GIT_SERVER to known_hosts"
  else
    log "Added $GIT_SERVER to known_hosts file"
  fi
fi
# ----------------------------------------------

# Configure remote repository
configure_remote() {
  if git remote | grep -q "^origin$"; then
    CURRENT_URL=$(git remote get-url origin || true)
    if [ "$CURRENT_URL" != "$REMOTE_REPO" ]; then
      log "Remote origin exists but URL is different. Updating..."
      git remote set-url origin "$REMOTE_REPO"
      log "Updated origin URL to $REMOTE_REPO"
    else
      log "Remote origin already correctly configured"
    fi
  else
    log "Remote origin does not exist. Adding..."
    git remote add origin "$REMOTE_REPO"
    log "Added origin remote with URL $REMOTE_REPO"
  fi
}
configure_remote

sync_once() {
  # Keep local branch up-to-date and push; repo is assumed clean (Gollum commits).
  git fetch origin >/dev/null 2>&1 || log "WARNING: git fetch failed (network?)"

  if git push origin "$BRANCH"; then
    log "Push successful"
    return 0
  fi

  log "Push failed; attempting pull --rebase then push"
  if git pull --rebase --autostash origin "$BRANCH" >/dev/null 2>&1 && git push origin "$BRANCH"; then
    log "Push after rebase succeeded"
  else
    log "ERROR: Push still failing (conflicts or network). Manual intervention may be required."
    return 1
  fi
}

# Initial sync on start
sync_once || true

# Event loop using inotify
log "Using inotify; watching .git for new commits"
while true; do
  # Any commit updates files under .git; watching it avoids triggering on normal file edits
  inotifywait -r -q -e close_write,move,create,delete "$WIKI_DIR/.git" || true
  [ "$DEBOUNCE" -gt 0 ] && sleep "$DEBOUNCE"
  sync_once || true
done

