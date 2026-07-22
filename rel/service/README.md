# User Service Installation

Each Sigma release archive contains these files under `sigma/service/`:

- `sigma.service`: a systemd user unit for Linux.
- `com.gsmlg.sigma.plist`: a LaunchAgent template for macOS.
- `sigma-user-service`: the shared launcher used by both service managers.

The instructions use `~/.local/share/sigma` for the release and
`~/.config/sigma/env` for runtime configuration. Sigma stores its application
state separately under `~/.pi/agent/`.

## Install the release

Download the archive and matching `.sha256` file for your operating system and
CPU architecture from the GitHub Release page. Set `archive` to the downloaded
archive name, verify it, and extract it:

```bash
archive="sigma-v<VERSION>-linux-amd64.tar.gz"
sha256sum --check "${archive}.sha256"
mkdir -p "$HOME/.local/share"
tar -xzf "$archive" -C "$HOME/.local/share"
```

On macOS, use `shasum` for verification:

```bash
archive="sigma-v<VERSION>-macos-arm64.tar.gz"
shasum -a 256 --check "${archive}.sha256"
mkdir -p "$HOME/.local/share"
tar -xzf "$archive" -C "$HOME/.local/share"
```

Create the environment file required by the production release:

```bash
mkdir -p "$HOME/.config/sigma"
umask 077
printf 'SECRET_KEY_BASE=%s\nPHX_SERVER=true\nPORT=4580\n' \
  "$(openssl rand -hex 64)" > "$HOME/.config/sigma/env"
```

Change `PORT` in that file if port `4580` is already in use. Provider
credentials can be configured after startup in Sigma's settings UI.

## Linux with systemd

Install and start the unit for the current user. These commands do not require
root access:

```bash
mkdir -p "$HOME/.config/systemd/user"
install -m 0644 \
  "$HOME/.local/share/sigma/service/sigma.service" \
  "$HOME/.config/systemd/user/sigma.service"
systemctl --user daemon-reload
systemctl --user enable --now sigma.service
systemctl --user status sigma.service
```

Follow logs with:

```bash
journalctl --user --unit sigma.service --follow
```

The unit starts at login. To run it after boot without an interactive login,
enable lingering for your account with `loginctl enable-linger "$USER"` if your
system permits it.

## macOS with launchd

The plist contains an `@HOME@` placeholder because launchd does not expand shell
variables in plist path values. Render it for the current user, then bootstrap
the LaunchAgent:

```bash
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Sigma"
plist="$HOME/Library/LaunchAgents/com.gsmlg.sigma.plist"
sed "s|@HOME@|$HOME|g" \
  "$HOME/.local/share/sigma/service/com.gsmlg.sigma.plist" > "$plist"
chmod 600 "$plist"
plutil -lint "$plist"
launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
launchctl enable "gui/$(id -u)/com.gsmlg.sigma"
launchctl kickstart -k "gui/$(id -u)/com.gsmlg.sigma"
launchctl print "gui/$(id -u)/com.gsmlg.sigma"
```

Follow logs with:

```bash
tail -F "$HOME/Library/Logs/Sigma/stdout.log" \
  "$HOME/Library/Logs/Sigma/stderr.log"
```

## Verify and manage Sigma

Open <http://localhost:4580> or check the endpoint from a terminal:

```bash
curl --fail --silent --show-error http://localhost:4580/ >/dev/null
```

After changing `~/.config/sigma/env`, restart the service:

```bash
# Linux
systemctl --user restart sigma.service

# macOS
launchctl kickstart -k "gui/$(id -u)/com.gsmlg.sigma"
```

Stop and disable automatic startup with:

```bash
# Linux
systemctl --user disable --now sigma.service

# macOS
launchctl bootout "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.gsmlg.sigma.plist"
```
