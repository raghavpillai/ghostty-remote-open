# Ghostty Remote Open (`ghostty .` over SSH)

Opens a new local Ghostty window from a remote SSH session, similar to `code .` with VS Code.

## How it works

```
You (SSH'd into zealot-server)
  │
  │  ghostty .
  │
  ▼
~/.local/bin/ghostty (on zealot-server)
  │  Sends "zealot-server:/current/dir" to localhost:7681
  │
  ▼
SSH Reverse Tunnel (RemoteForward 7681)
  │  Forwards remote:7681 → local Mac:7681
  │
  ▼
~/.local/bin/ghostty-listener (on Mac, launchd service)
  │  Receives request, launches Ghostty binary
  │
  ▼
~/.local/bin/ghostty-ssh-open zealot-server /current/dir
  │  exec ssh zealot-server -t "cd /current/dir && exec $SHELL -l"
  │
  ▼
New Ghostty window opens, SSH'd to zealot-server at that directory
```

## Usage

From an SSH session on zealot-server:

```bash
ghostty .           # new window at current directory
ghostty /some/path  # new window at specific path
ghostty             # same as ghostty .
```

## All files

### Local Mac

#### 1. `~/.local/bin/ghostty-listener`

Python TCP server. Listens on port 7681 for `host:directory` messages and launches a Ghostty window for each request. Runs as a launchd service so it's always available.

```python
#!/usr/bin/env python3
"""Listener that opens new Ghostty windows for SSH remote requests.

Runs on the local Mac. Remote machines send requests via SSH reverse
port forwarding to open a new Ghostty window SSH'd to a specific
host and directory.

Protocol: single line "host:directory\n" over TCP.
"""

import socket
import subprocess
import os
import signal
import sys

PORT = 7681


def handle_request(data):
    data = data.strip()
    if ":" not in data:
        return
    host, directory = data.split(":", 1)
    if not host or not directory:
        return
    # Open a new Ghostty window SSH'd to the host at the directory.
    helper = os.path.expanduser("~/.local/bin/ghostty-ssh-open")
    subprocess.Popen([
        "/Applications/Ghostty.app/Contents/MacOS/ghostty",
        f"--command={helper} {host} {directory}",
    ])


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", PORT))
    sock.listen(5)

    while True:
        conn, _ = sock.accept()
        try:
            data = conn.recv(4096).decode("utf-8", errors="replace")
            handle_request(data)
        except Exception:
            pass
        finally:
            conn.close()


if __name__ == "__main__":
    main()
```

#### 2. `~/.local/bin/ghostty-ssh-open`

Helper script that the listener invokes. Runs the actual SSH session inside the new Ghostty window. Uses `ClearAllForwardings=yes` so the new window's SSH connection doesn't try to set up the reverse tunnel again (which would produce a warning since the original session already has it).

```bash
#!/bin/bash
# Helper script invoked by ghostty-listener.
# Opens an SSH session to the given host at the given directory.
HOST="$1"
DIR="$2"
exec ssh -o ClearAllForwardings=yes "$HOST" -t "cd '$DIR' && exec \$SHELL -l"
```

#### 3. `~/Library/LaunchAgents/com.ghostty.remote-listener.plist`

Launchd service that auto-starts `ghostty-listener` on login and keeps it running.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ghostty.remote-listener</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/Users/raghav/.local/bin/ghostty-listener</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/ghostty-listener.err</string>
</dict>
</plist>
```

#### 4. `~/.ssh/config` (relevant addition)

The `RemoteForward` line creates a reverse tunnel: anything connecting to port 7681 on zealot-server gets forwarded back to port 7681 on your Mac (where the listener is).

```
Host zealot-server
    HostName 192.168.91.106
    User raghav
    SetEnv TERM=xterm-256color
    RemoteForward 7681 127.0.0.1:7681
```

### Remote server (zealot-server)

#### 5. `~/.local/bin/ghostty`

The command you actually type. Resolves the target directory to an absolute path and sends it through the reverse tunnel via netcat.

```bash
#!/bin/bash
# Open a new Ghostty window on the local machine via reverse SSH tunnel.
# Usage: ghostty [directory]  (defaults to current directory)

dir="${1:-.}"
dir=$(cd "$dir" 2>/dev/null && pwd) || { echo "ghostty: cannot access '$1'"; exit 1; }

# Send request through the SSH reverse tunnel
echo "zealot-server:$dir" | nc -q0 127.0.0.1 7681 2>/dev/null
if [ $? -ne 0 ]; then
    echo "ghostty: could not connect to local listener on port 7681" >&2
    echo "  Make sure ghostty-listener is running and SSH has RemoteForward 7681" >&2
    exit 1
fi
echo "Opening Ghostty window at $dir"
```

## Adding another server

To add this to a different server (e.g. `gpu-server`):

1. Add `RemoteForward 7681 127.0.0.1:7681` to that host in `~/.ssh/config`
2. Copy the `ghostty` script to `~/.local/bin/ghostty` on the remote server
3. Change `zealot-server` in the script to the SSH host alias (e.g. `gpu-server`)

## Troubleshooting

**`ghostty: could not connect to local listener on port 7681`**
- Check the listener is running: `ps aux | grep ghostty-listener`
- Restart it: `launchctl kickstart -k gui/$(id -u)/com.ghostty.remote-listener`
- Check logs: `cat /tmp/ghostty-listener.err`

**`Warning: remote port forwarding failed for listen port 7681`**
- Harmless. Means another SSH session to the same server already has the tunnel. The existing tunnel still works.

**Window opens but doesn't connect**
- Check that `ghostty-ssh-open` is executable: `chmod +x ~/.local/bin/ghostty-ssh-open`
- Test it directly: `~/.local/bin/ghostty-ssh-open zealot-server /home/raghav`

## Design decisions

- **Direct binary invocation** (`/Applications/Ghostty.app/Contents/MacOS/ghostty`) instead of `open -na Ghostty.app` — avoids macOS permission prompts on every launch.
- **`ClearAllForwardings=yes`** on the helper SSH connection — prevents "remote port forwarding failed" warnings in new windows.
- **Separate helper script** (`ghostty-ssh-open`) — avoids argument quoting issues when passing complex SSH commands through Ghostty's `--command` flag.
- **Port 7681** — arbitrary choice, can be changed (update listener, SSH config, and remote script).
