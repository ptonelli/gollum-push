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

log "Configuration:"
log "  Wiki directory: $WIKI_DIR"
log "  Remote repository: $REMOTE_REPO"

# ==============================================================================
# 1. SSH known_hosts setup (MOVED UP)
# Must be done BEFORE cloning
# ==============================================================================
GIT_SERVER=""
GIT_PORT=""

if echo "$REMOTE_REPO" | grep -q "^https://"; then
  log "HTTPS detected in REMOTE_REPO. Skipping SSH known_hosts setup."
elif echo "$REMOTE_REPO" | grep -q "^ssh://"; then
  # Format: ssh://[user@]host[:port]/repo.git
  GIT_SERVER=$(echo "$REMOTE_REPO" | sed -E 's#^ssh://(git@)?([^:/]+).*#\2#')
  GIT_PORT=$(echo "$REMOTE_REPO" | sed -nE 's#^ssh://.*:([0-9]+)/.*#\1#p')
else
  # Format: git@server:repo.git
  GIT_SERVER=$(echo "$REMOTE_REPO" | sed -n 's/.*git@\([^:]*\).*/\1/p')
fi

# Only run ssh-keyscan if we extracted a server hostname
if [ -n "$GIT_SERVER" ]; then
  # Set up SSH known_hosts file if it doesn't exist
  if [ ! -f "$HOME/.ssh/known_hosts" ] || ! grep -q "$GIT_SERVER" "$HOME/.ssh/known_hosts"; then
    log "Setting up SSH known_hosts for $GIT_SERVER ${GIT_PORT:+on port $GIT_PORT}"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # Use custom port if detected, otherwise default
    if [ -n "$GIT_PORT" ]; then
        # We use 'ssh' instead of 'keyscan' to trigger sslh protocol detection
        # strict checking=no writes the key to UserKnownHostsFile automatically
        ssh -p "$GIT_PORT" \
            -o HostKeyAlgorithms=ssh-rsa \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
            -o CheckHostIP=no \
            -o LogLevel=ERROR \
            -o BatchMode=yes \
            "git@$GIT_SERVER" true >/dev/null 2>&1 || true
    else
        ssh-keyscan -t rsa "$GIT_SERVER" >> "$HOME/.ssh/known_hosts" 2>/dev/null
    fi

    if [ $? -ne 0 ]; then
      log "WARNING: Failed to add $GIT_SERVER to known_hosts"
    else
      log "Added $GIT_SERVER to known_hosts file"
    fi
  fi
elif ! echo "$REMOTE_REPO" | grep -q "^https://"; then
  log "WARNING: Could not extract Git server from REMOTE_REPO for SSH setup."
fi

# ==============================================================================
# 2. Directory Check & Auto-Clone
# ==============================================================================

# Create directory if it doesn't exist
if [ ! -d "$WIKI_DIR" ]; then
  log "Directory $WIKI_DIR does not exist. Creating it..."
  mkdir -p "$WIKI_DIR"
fi

# Change to the wiki directory
cd "$WIKI_DIR" 2>/dev/null || { log "ERROR: Cannot change to directory $WIKI_DIR"; exit 1; }

# Check for .git, clone if missing
if [ ! -d ".git" ]; then
  log "No git repository found in $WIKI_DIR. Attempting to clone..."

  # Clone into current directory (.)
  # Note: This requires the directory to be empty (or almost empty)
  if git clone "$REMOTE_REPO" .; then
    log "Clone successful."
  else
    log "ERROR: Git clone failed. Check permissions or network."
    exit 1
  fi
fi

# ==============================================================================
# 3. Git Configuration & Loop
# ==============================================================================

# Detect current branch (fallback to master)
BRANCH="${BRANCH:-$(git symbolic-ref --short HEAD 2>/dev/null || echo master)}"
log "Branch detected: $BRANCH"

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
