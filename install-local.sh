#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing ghostty-listener (local Mac)..."

mkdir -p "$HOME/.local/bin"

cp "$SCRIPT_DIR/ghostty-listener" "$HOME/.local/bin/ghostty-listener"
chmod +x "$HOME/.local/bin/ghostty-listener"

cp "$SCRIPT_DIR/ghostty-ssh-open" "$HOME/.local/bin/ghostty-ssh-open"
chmod +x "$HOME/.local/bin/ghostty-ssh-open"

# Install launchd service
cp "$SCRIPT_DIR/com.ghostty.remote-listener.plist" "$HOME/Library/LaunchAgents/com.ghostty.remote-listener.plist"

# Load/reload the service
launchctl bootout "gui/$(id -u)/com.ghostty.remote-listener" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.ghostty.remote-listener.plist"

echo "==> ghostty-listener is running."
echo ""
echo "Next steps:"
echo "  1. Add 'RemoteForward 7681 127.0.0.1:7681' to your SSH host in ~/.ssh/config"
echo "  2. Install ghostty-remote on your server (copy ghostty-remote to ~/.local/bin/ghostty)"
echo "  3. Set GHOSTTY_SSH_HOST on the server to your SSH config alias"
