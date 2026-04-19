# Windrose Dedicated Server — Docker

Self-hosted dedicated server for [Windrose](https://store.steampowered.com/app/2700940/Windrose/) running on Linux via Docker, SteamCMD and Wine.

> **No port forwarding required** — players join via **Invite Code** from `ServerDescription.json`.

---

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Volumes](#volumes)
- [Multiple worlds](#multiple-worlds)
- [How players join](#how-players-join)
- [Useful commands](#useful-commands)
- [Optional helper launcher](#optional-helper-launcher)
- [Quick diagnostics](#quick-diagnostics)
- [Activity notifications: Discord or Gotify](#activity-notifications-discord-or-gotify)
- [Save transfer and world selection](#save-transfer-and-world-selection)
- [Backup saves](#backup-saves)
- [Directory structure](#directory-structure)
- [Troubleshooting](#troubleshooting)
- [Image versions](#image-versions)
- [Technical notes](#technical-notes)
- [FAQ](#faq)
- [Issues and suggestions](#issues-and-suggestions)
- [Support](#support)
- [License](#license)

---

## Features

- Dockerized Windrose dedicated server on Linux (Wine + Xvfb, headless)
- Automatic game install/update via SteamCMD with optional `UPDATE_ON_START` toggle
- Persistent data by default (`./data`, `./steam-home`) for saves, config, and Steam/Wine state
- Simple operator-first configuration through `.env` and optional JSON auto-patching
- Stable helper commands for start/stop/restart/logs/diagnostics and world management
- Save transfer workflow with explicit `WorldIslandId` mapping and versioned world paths
- Built-in backup tooling (`./windrose backup`, cron installer, retention controls)
- Optional Discord/Gotify activity notifications plus notifier test command
- Multiple image channels (`stable`, `latest`, `staging`, `debug`) for operations and troubleshooting
- Production-friendly defaults: host networking, restart policy, healthcheck, and log rotation

---

## Requirements

| Component | Minimum |
|-----------|---------|
| OS        | Ubuntu 22.04+ / Debian 12+ (Linux host) |
| Docker    | 24.x+ |
| Docker Compose | v2.x (`docker compose`) |
| RAM       | 8 GB (16 GB recommended for 4 players) |
| Disk      | 8 GB free for game files |

---

## Quick start

Production mode uses the published GHCR image by default. Most users only need this mode and can ignore the development override file.

```bash
# 1. Clone the repository
git clone https://github.com/UberDudePL/windrose-dedicated-server-docker.git
cd windrose-dedicated-server-docker

# 2. Copy the example environment file
cp .env.example .env

# 3. Edit basic values if needed
nano .env

# 4. Pull the published image
docker compose pull

# 5. Start the server (downloads game files on first run ~3 GB)
docker compose up -d

# 6. Follow logs
docker compose logs -f windrose
```

Recommended image tags:

```text
Stable: ghcr.io/uberdudepl/windrose-dedicated-server-docker:v1.2.2
Latest: ghcr.io/uberdudepl/windrose-dedicated-server-docker:latest
Staging fallback: ghcr.io/uberdudepl/windrose-dedicated-server-docker:staging
Debug tools: ghcr.io/uberdudepl/windrose-dedicated-server-docker:debug
```

Set the image version in `.env` with:

```dotenv
IMAGE_REPOSITORY=ghcr.io/uberdudepl/windrose-dedicated-server-docker
IMAGE_TAG=v1.2.2
```

### Optional: development mode

Most users can skip this section. Use the dev override only when you want to test local changes to the image or startup scripts:

```bash
# Build locally and start with the dev override
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build

# Restart after editing entrypoint.sh
docker compose -f docker-compose.yml -f docker-compose.dev.yml restart windrose

# Stop the dev stack
docker compose -f docker-compose.yml -f docker-compose.dev.yml down
```

The default [docker-compose.yml](docker-compose.yml) is for stable published images, while [docker-compose.dev.yml](docker-compose.dev.yml) is for local development.

### Image variants

- `latest` / version tags: stable Wine build for normal use.
- `staging`: fallback image using Wine Staging plus `winetricks` prewarm (`win10`, `vcrun2022`) for host-specific Wine issues.
- `debug`: stable Wine build plus extra diagnostic tools (`dnsutils`, `file`, `iproute2`, `lsof`, `strace`) and more verbose Wine logging.
- `dev`, `dev-staging`, `dev-debug`: automatically published developer channels from the `main` branch.

Use the stable channel unless you are actively diagnosing host-specific startup problems.

### Build and release workflows

- [`.github/workflows/ci.yml`](.github/workflows/ci.yml): validates shell syntax and builds the stable, staging, and debug images in CI.
- [`.github/workflows/docker-developer.yml`](.github/workflows/docker-developer.yml): publishes developer images from `main`.
- [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml): publishes release images from version tags.

### Local smoke build commands

Use these commands when you want to verify all image variants locally before pushing changes:

```bash
# stable
docker build \
	--build-arg WINE_FLAVOR=stable \
	--build-arg ENABLE_WINETRICKS=false \
	--build-arg INSTALL_DEBUG_TOOLS=false \
	--build-arg DEFAULT_WINEDEBUG=-all \
	-t windrose-smoke:stable .

# staging
docker build \
	--build-arg WINE_FLAVOR=staging \
	--build-arg ENABLE_WINETRICKS=true \
	--build-arg WINETRICKS_PACKAGES='win10 vcrun2022' \
	--build-arg INSTALL_DEBUG_TOOLS=false \
	--build-arg DEFAULT_WINEDEBUG=-all \
	-t windrose-smoke:staging .

# debug
docker build \
	--build-arg WINE_FLAVOR=stable \
	--build-arg ENABLE_WINETRICKS=false \
	--build-arg INSTALL_DEBUG_TOOLS=true \
	--build-arg DEFAULT_WINEDEBUG='warn+timestamp' \
	-t windrose-smoke:debug .
```

---

## Configuration

### Common server settings

You can set the most common values directly in `.env`:

```dotenv
SERVER_NAME=My Windrose Server
SERVER_NOTE=Friendly co-op server
SERVER_PASSWORD=
MAX_PLAYERS=4
INVITE_CODE=
```

If you prefer manual editing, stop the server first and edit `data/R5/ServerDescription.json` directly.

> Important: edit JSON files only while the server is stopped, or your changes may be overwritten.

### Environment variables (`.env`)

Copy `.env.example` to `.env` and adjust to your needs. Use `.env.dev.example` for local development and notifier testing.

```dotenv
PUID=1000                    # Host user id for mounted files
PGID=1000                    # Host group id for mounted files
STEAM_LOGIN=anonymous        # SteamCMD login
STEAM_PASS=                  # Leave empty for anonymous login
WINDROSE_APP_ID=4129620      # Steam AppID for Windrose Dedicated Server
UPDATE_ON_START=true         # Set false to skip update on container restart
GENERATE_SETTINGS=true       # Set false to skip env-based JSON patching
INVITE_CODE=                 # Optional invite code
SERVER_NAME=                 # Optional server name
SERVER_NOTE=                 # Optional public server note/description
SERVER_PASSWORD=             # Optional password
MAX_PLAYERS=4                # Recommended for stability
P2P_PROXY_ADDRESS=127.0.0.1  # Keep default unless you know you need a change
PORT=7777
QUERYPORT=7778
MULTIHOME=0.0.0.0
```

### `docker-compose.yml` overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `CONTAINER_NAME` | `windrose` | Change only if you run more than one server on the same host |
| `HOSTNAME` | `localhost` | Internal container hostname used by ICE candidate discovery; keep `localhost` unless custom name resolves inside container |
| `IMAGE_REPOSITORY` | GHCR repo | Published image repository |
| `IMAGE_TAG` | `v1.2.2` | Stable image tag to run |
| `PUID` | `1000` | User id used for mounted files |
| `PGID` | `1000` | Group id used for mounted files |
| `UPDATE_ON_START` | `true` | Update and validate server files on startup |
| `GENERATE_SETTINGS` | `true` | Auto-patch `ServerDescription.json` from env values |
| `INVITE_CODE` | empty | Invite code shown to players |
| `SERVER_NAME` | empty | Display name of the server |
| `SERVER_NOTE` | empty | Short public server note/description |
| `SERVER_PASSWORD` | empty | Leave empty for a public server |
| `MAX_PLAYERS` | `4` | Maximum number of simultaneous players |
| `P2P_PROXY_ADDRESS` | `127.0.0.1` | Internal socket proxy address |
| `PORT` | `7777` | Game port (UDP) |
| `QUERYPORT` | `7778` | Query port (UDP) |
| `WINDROSE_APP_ID` | `4129620` | Steam AppID |
| `STEAM_LOGIN` | `anonymous` | SteamCMD login |

---

## Volumes

| Host path | Container path | Contents |
|-----------|---------------|----------|
| `./data`  | `/data`       | Server files, saves, config |
| `./steam-home` | `/home/steam` | Wine prefix, SteamCMD cache |

## Multiple worlds

Windrose stores each world under the save database path:

```text
data/R5/Saved/SaveProfiles/Default/RocksDB/<GameVersion>/Worlds/<WorldIslandId>
```

The active world is selected by `ServerDescription.json`:

```json
ServerDescription_Persistent.WorldIslandId
```

Use the helper command to switch interactively:

```bash
./windrose switch
```

To only list available worlds without changing anything:

```bash
./windrose worlds
```

To detect orphan or broken world directories:

```bash
./windrose worlds-check
```

What it does:

- Lists all worlds found under the current RocksDB save version.
- Marks the currently selected world.
- Lets you switch to an existing world or create a new one.
- When creating a new world, it can store a display name and sync it into `WorldDescription.json` after the game creates the metadata file.
- Stops the server first if it is running, updates `WorldIslandId`, then starts it again.
- Hides stale placeholder entries (for example directories with only `.windrose-world-name`) unless that placeholder is currently selected.

Important:

- Do not rename world folders. The save database relies on those IDs.
- If you create a new world, the server initializes its data on the next start.
- World discovery is version-specific, so the command uses the latest directory found under `RocksDB/`.

---

## How players join

1. Start the server once and wait until it is healthy
2. Open `data/R5/ServerDescription.json` and copy the `InviteCode` value
3. Share that code with players — they use it in-game under **Join via Code**
4. Invite codes are case-sensitive and should be at least 6 characters long
5. No port forwarding is required for the normal invite-code flow

The server still binds internal game and query ports, mainly for local binding and advanced or multi-instance setups.

---

## Useful commands

```bash
# Start
docker compose up -d

# Stop
docker compose stop

# View live logs
docker compose logs -f windrose

# List worlds
./windrose worlds

# Detect orphan/broken world entries
./windrose worlds-check

# Switch to another world interactively
./windrose switch

# Update helper flow (down -> pull with progress -> up)
./windrose update

# Check server process inside container
docker compose exec windrose pgrep -a WindroseServer

# Container status + health
docker compose ps
```

## Optional helper launcher

For easier day-to-day use, this repo also includes a small helper launcher.

```bash
chmod +x ./windrose ./serverctl.sh

./windrose start
./windrose stop
./windrose restart
./windrose status
./windrose logs
./windrose worlds
./windrose worlds-check
./windrose update
./windrose notify
./windrose test-notify
./windrose backup
./windrose install-backup-cron
```

Optional system-wide install:

```bash
./windrose install /usr/local/bin/windrosectl
windrosectl start
```

If you want the plain command name instead, install it as `/usr/local/bin/windrose`.

---

## Quick diagnostics

Use these commands for a fast operational check:

```bash
# 1) Basic container and health status
./windrose status

# 2) World integrity check (orphan/broken entries)
./windrose worlds-check

# 3) Recent critical network/auth errors from current log file
tail -400 ./chat | grep -Ei "account verification failed|turn session was expired|p2pgate disconnected|server authorization failed|login finished with error"
```

If command `3` returns lines repeatedly, check outbound connectivity and firewall/NAT behavior for `*.windrose.support` on UDP/TCP `3478`.

---

## Activity notifications: Discord or Gotify

A basic log watcher is included for best-effort player activity notifications.

1. Choose a notification backend in `.env`:

```dotenv
NOTIFY_PROVIDER=auto
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
GOTIFY_URL=https://gotify.example.com
GOTIFY_TOKEN=your_app_token
GOTIFY_PRIORITY=5
```

If `NOTIFY_PROVIDER=auto`, the script prefers Gotify when it is configured, otherwise it falls back to Discord.

2. Test the webhook once before long-term use:

```bash
./windrose test-notify
```

3. Start the watcher:

```bash
./windrose notify
```

The helper asks whether to run in background mode. If you start it in background mode, running `./windrose notify` again detects the running watcher and offers to stop it.

Background logs are written to:

```text
./backups/notify.log
```

At the moment this is log-based and best-effort. Disconnect events are easier to detect reliably than joins, so treat it as a lightweight helper rather than a perfect audit system.

---

## Save transfer and world selection

World saves live under:

```
data/R5/Saved/SaveProfiles/Default/RocksDB/<game-version>/Worlds/
```

Each world is a folder named with its world ID (for example `EC10598E83A14ED04D9C44CBFBF3F4B1`). The server loads the world whose ID matches `WorldIslandId` in `ServerDescription.json`.

### Transfer a save from singleplayer or another server

⚠ Always back up your saves first. Also shut down both the dedicated server and the game client before copying files.

1. **Stop the dedicated server**:
   ```bash
   ./windrose stop
   ```

2. **Locate the source world folder** on the machine that currently has the save:
   - Steam: `C:\Users\{UserName}\AppData\Local\R5\Saved\SaveProfiles\{YourProfile}\RocksDB\{GameVersion}\Worlds\{WorldID}`
   - EGS: `C:\Users\{UserName}\AppData\Local\R5\Saved\SaveProfiles\{YourProfile}\RocksDB\{GameVersion}\Worlds\{WorldID}`
   - Stove: `C:\Users\{UserName}\AppData\Local\R5\Saved\SaveProfiles\StoveDefault\RocksDB\{GameVersion}\Worlds\{WorldID}`
   - Example: `C:\Users\YarrHarrPirate\AppData\Local\R5\Saved\SaveProfiles\76561199699067790\RocksDB\0.8.0\Worlds\EC10598E83A14ED04D9C44CBFBF3F4B1`

3. **Copy the entire world folder** to the dedicated server data directory, preserving the folder name exactly:
   ```
   data/R5/Saved/SaveProfiles/Default/RocksDB/<game-version>/Worlds/
   ```
   Example using `scp` from a local machine (copy folder as-is):
   ```bash
   scp -r "./EC10598E83A14ED04D9C44CBFBF3F4B1" user@yourserver:/windrose/data/R5/Saved/SaveProfiles/Default/RocksDB/<version>/Worlds/
   ```

4. **Set the world ID** in `data/R5/ServerDescription.json`:
   ```json
   "WorldIslandId": "EC10598E83A14ED04D9C44CBFBF3F4B1"
   ```
   Use the copied folder name exactly. Do not rename world folders.

5. **Start the server:**
   ```bash
   ./windrose start
   ```

6. **Verify** — check logs to confirm the correct world loaded:
   ```bash
   ./windrose logs
   ```

7. **Server to client transfer**: reverse the same steps in the opposite direction. If the game asks, choose **local** saves.

> **Note:** The `<game-version>` path segment is version-specific (for example `0.8.0`). Use the exact version directory that contains your world.

---

## Backup saves

Use the built-in helper for a safer backup flow. It briefly stops the server, creates a timestamped archive, and starts it again if it was running.

```bash
# Create a manual backup
./windrose backup

# Install a host cron job running every 6 hours
./windrose install-backup-cron

# Or provide your own schedule
./windrose install-backup-cron "0 3 * * *"
```

Backups are stored in `./backups` by default and old archives are pruned after 7 days. You can change that in `.env` with `BACKUP_DIR` and `BACKUP_RETENTION_DAYS`.

You can choose what gets archived in `.env`:

```dotenv
BACKUP_SCOPE=full
```

Supported values:
- `full` (default): archive full `R5` directory
- `save`: archive only save data (`R5/Saved` and `R5/ServerDescription.json` when present)
- `both`: create both full and save archives in one run

You can choose the archive format in `.env`:

```dotenv
BACKUP_FORMAT=tar.gz
```

Supported values:
- `tar.gz` (default)
- `zip` (more convenient to open on Windows)

If you use `BACKUP_FORMAT=zip`, the script checks whether `zip` is available.
In an interactive shell it asks whether it should install `zip`; in cron/non-interactive mode it exits with a clear error.

The installed cron job appends logs to `./backups/backup.log`.

You can also enable backup result notifications in `.env`:

```dotenv
BACKUP_NOTIFY_SUCCESS=false
BACKUP_NOTIFY_FAIL=true
```

When enabled, backup status notifications use the same backend as `./windrose notify` (`NOTIFY_PROVIDER`, Discord, or Gotify).

You can also upload the backup archive directly to a Discord channel after each successful backup:

```dotenv
BACKUP_DISCORD_UPLOAD=false
```

When set to `true`, Discord upload depends on `BACKUP_SCOPE`:
- `save` or `both`: upload the newest `windrose-backup-save-*` archive (`.tar.gz` or `.zip`)
- `full`: skip upload intentionally

Files larger than 25 MB are skipped with a warning (Discord free tier limit).

---

## Directory structure

```
windrose/
├── Dockerfile          # Ubuntu 22.04 + Wine + SteamCMD
├── docker-compose.yml  # Service definition
├── entrypoint.sh       # SteamCMD update + server start logic
├── .env                # Environment variables (do not commit with secrets)
├── data/               # Persistent server files and saves (created on first run)
│   └── R5/
│       ├── ServerDescription.json
│       └── Saved/
└── steam-home/         # Wine prefix and SteamCMD state (created on first run)
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `wine: '/home/steam' is not owned by you` | Set `PUID` and `PGID` correctly in `.env`, then restart the container |
| `Server is already active for display 99` | Stale Xvfb lock — entrypoint removes it automatically on restart |
| `ERROR! Failed to install app` | Check SteamCMD logs and verify the app id and Steam login mode |
| Server not visible to players | Share the `InviteCode` from `ServerDescription.json` |
| Connection works on some networks but not others | The network or ISP may be blocking STUN/TURN traffic used by the game; check access to `*.windrose.support` on port `3478` over UDP/TCP |
| `Account verification failed`, `Turn session was expired`, `BL P2PGate disconnected` | Usually upstream TURN/P2P session/network issue; verify stable outbound access to `*.windrose.support` on UDP/TCP `3478`, avoid aggressive NAT/firewall timeouts, then retry reconnect |
| Config reset after restart | Edit JSON only when container is stopped |
| Players have issues after a game patch | Keep the dedicated server version updated to match the game version |

---

## Image versions

- Most users should keep `IMAGE_TAG=v1.2.2` for a stable server.
- Use `latest` only for testing.
- Use `staging` only as a fallback for Wine compatibility issues on a specific host.
- Use `debug` when you need extra troubleshooting tools inside the image.
- To upgrade later, change `IMAGE_TAG` in `.env`, then run:

```bash
docker compose pull
docker compose up -d
```

---

## Technical notes

- Supports configurable `PUID` and `PGID` to align mounted volumes with the host
- `network_mode: host` — no Docker NAT, direct network access
- Xvfb provides a headless X display required by Wine
- `stop_grace_period: 90s` — allows the server to save before shutdown
- Optional env-based patching can update `ServerDescription.json` automatically
- Healthcheck can fail on recent fatal runtime log patterns, not just missing process state

---

## FAQ

### How do I transfer a savegame to the server?

See the [Save transfer and world selection](#save-transfer-and-world-selection) section. In short: back up first, stop both server and client, copy the full world folder into `data/R5/Saved/SaveProfiles/Default/RocksDB/<version>/Worlds/`, set `WorldIslandId` to the exact folder name, then start the server.

### How do players join the server?

Start the server once, wait until it is healthy, then open `data/R5/ServerDescription.json` and share the `InviteCode` value with players.

### Why is the first start so slow?

The first launch needs to download and prepare SteamCMD, Wine runtime files, and the dedicated server files. This can take several minutes depending on your network and the upstream mirrors.

### Why do I get permission denied errors?

This usually means the mounted host directories are owned by a different user than the container expects. Check `PUID` and `PGID` in your `.env`, then restart the container.

### How do I test Discord or Gotify integration?

Use the built-in test command before you start the watcher:

```bash
./windrose test-notify
```

### How do I update safely on production?

Pull the latest repository changes first, then refresh the selected image tag and recreate the container:

```bash
git pull
./windrose update
```

`./windrose update` writes detailed command output to `./backups/update.log` and keeps three rotated history files (`update.log.1`, `update.log.2`, `update.log.3`).

### What is the difference between stable and latest?

Use a pinned version tag such as `v1.2.2` for production stability. Use `latest` only when you want the newest changes for testing.

### When should I try `staging` or `debug`?

- Try `staging` when stable Wine builds fail on a specific host with prefix or runtime compatibility issues.
- Try `debug` when you need extra tools and more verbose logging to investigate Wine, DNS, or network problems.

---

## Issues and suggestions

If you hit a bug or want a new feature, please open an issue in the GitHub repository.

---

## Support

If this project saved you time and you want to support further maintenance, you can use:

- Ko-fi: https://ko-fi.com/uberdudepl
- PayPal: https://paypal.me/uberdudepl
- Revolut: https://revolut.me/uberdudepl

---

## License

MIT — see [LICENSE](LICENSE)
