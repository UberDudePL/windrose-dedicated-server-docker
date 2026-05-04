# Windrose Dedicated Server — Docker

![GitHub Stars](https://img.shields.io/github/stars/UberDudePL/windrose-dedicated-server-docker)
![License](https://img.shields.io/github/license/UberDudePL/windrose-dedicated-server-docker)
![Version](https://img.shields.io/github/v/release/UberDudePL/windrose-dedicated-server-docker)
![Docker Pulls](https://img.shields.io/docker/pulls/uberdudepl/windrose-dedicated-server-docker)

Windrose dedicated server for Linux using Docker, SteamCMD and Wine, with persistent saves, backups, diagnostics and optional Discord/Gotify notifications.

Self-hosted and production-friendly setup with first-time setup helper, world switching, health checks and 24/7 operation support.

> **No port forwarding required** — players join via **Invite Code** from `ServerDescription.json`.

---

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [First-time setup (recommended)](#first-time-setup-recommended)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Volumes](#volumes)
- [Multiple worlds](#multiple-worlds)
- [How players join](#how-players-join)
- [In-game visibility (official)](#in-game-visibility-official)
- [Useful commands](#useful-commands)
- [Quick diagnostics](#quick-diagnostics)
- [Activity notifications: Discord, Gotify, or both](#activity-notifications-discord-gotify-or-both)
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

Additional documents:

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — full symptom table, diagnostics playbooks, network debugging
- [DEVELOPMENT.md](DEVELOPMENT.md) — local builds, image channels, CI workflows

---

## Features

- Dockerized Windrose dedicated server on Linux (Wine + Xvfb, headless)
- Automatic game install/update via SteamCMD with optional `UPDATE_ON_START` toggle
- Persistent data by default (`./data`, `./steam-home`) for saves, config, and Steam/Wine state
- Simple operator-first configuration through `.env` and optional JSON auto-patching
- Stable helper commands for start/stop/restart/logs/diagnostics and world management
- Save transfer workflow with explicit `WorldIslandId` mapping and versioned world paths
- Built-in backup tooling (`./windrose backup`, cron installer, retention controls)
- Optional Discord/Gotify activity notifications (or both at once) plus notifier test command
- Multiple image channels (`stable`, `latest`, `staging`, `debug`) for operations and troubleshooting
- Production-friendly defaults: host networking, restart policy, healthcheck, and log rotation

---

## Requirements

| Component      | Minimum                                                   |
| -------------- | --------------------------------------------------------- |
| OS             | Ubuntu 22.04+ / Debian 12+ (Linux host)                   |
| Docker         | 24.x+                                                     |
| Docker Compose | v2.x (`docker compose`)                                   |
| RAM            | 8 GB (2 players) · 12 GB (4 players) · 16 GB (10 players) |
| Disk           | 35 GB SSD                                                 |

---

## First-time setup (recommended)

If this is your first run, use the interactive helper first. It creates `.env`, asks for key settings, optionally configures backup cron, and can start the server immediately.

```bash
# 1. Clone and enter the repository
git clone https://github.com/UberDudePL/windrose-dedicated-server-docker.git
cd windrose-dedicated-server-docker

# 2. Make helper scripts executable
chmod +x ./windrose ./serverctl.sh

# 3. Run interactive setup
./windrose setup
```

What `./windrose setup` asks:

1. Start automatically after setup (`Y/n`)
2. Server name
3. Invite code (optional, alphanumeric, minimum 6 chars)
4. Optional server password
5. Max players
6. Enable automatic backup cron (`y/N`)
7. Backup cron schedule (default: `0 6 * * *`, daily at 06:00)
8. Backup format (`tar.gz` or `zip`)
9. Backup scope (`full`, `save`, `both`)
10. Discord upload for save backups (`y/N`)
11. Discord webhook URL (only if upload is enabled)

If invite code is left empty, the server generates it automatically on first successful start.
When setup starts the server automatically, it tries to show the generated code.
When setup does not start the server, check the generated code later in `data/R5/ServerDescription.json`.

Behavior and safety notes:

- Setup is one-off by design: if `.env` already exists, setup exits with a clear message.
- Setup runs a host precheck before questions: Docker in PATH, Docker Compose v2, RAM >= 8 GB, free disk >= 8 GB.
- `PUID` and `PGID` are auto-detected from the current host user.
- If backup upload is enabled and scope is `full`, scope is adjusted to `both`.
- If `crontab` is missing, setup continues and warns instead of failing.
- Before auto-start, setup runs preflight checks (`docker compose config`) and warns if `PORT` or `QUERYPORT` are already in use.

After setup, use:

```bash
./windrose status
./windrose logs
```

---

## Quick start

Production mode uses the published GHCR image by default. Most users only need this mode and can ignore the development override file.

If this is your first run, prefer [First-time setup (recommended)](#first-time-setup-recommended).

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
Stable: ghcr.io/uberdudepl/windrose-dedicated-server-docker:v1.6.2
Latest: ghcr.io/uberdudepl/windrose-dedicated-server-docker:latest
Staging fallback: ghcr.io/uberdudepl/windrose-dedicated-server-docker:staging
Debug tools: ghcr.io/uberdudepl/windrose-dedicated-server-docker:debug
```

Set the image version in `.env` with:

```dotenv
IMAGE_REPOSITORY=ghcr.io/uberdudepl/windrose-dedicated-server-docker
IMAGE_TAG=v1.6.2
```

### Image variants

- `latest` / version tags: stable Wine build for normal use.
- `staging`: fallback image using Wine Staging plus `winetricks` prewarm (`win10`, `vcrun2022`) for host-specific Wine issues.
- `debug`: stable Wine build plus extra diagnostic tools (`dnsutils`, `file`, `iproute2`, `lsof`, `strace`) and more verbose Wine logging.

Use the stable channel unless you are actively diagnosing host-specific startup problems.

For local development, builds, and CI workflows, see [DEVELOPMENT.md](DEVELOPMENT.md).

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
P2P_PROXY_ADDRESS=127.0.0.1  # Keep default unless players connect over LAN
# Direct connection (alternative to invite code, requires port forwarding)
USE_DIRECT_CONNECTION=false
DIRECT_CONNECTION_SERVER_PORT=7777
DIRECT_CONNECTION_PROXY_ADDRESS=0.0.0.0
USER_SELECTED_REGION=        # Leave empty for auto-detect (SEA, CIS, EU)
PORT=7777
QUERYPORT=7778
MULTIHOME=0.0.0.0
```

Set `NO_COLOR=1` to disable ANSI colors in helper/CLI output.

### `docker-compose.yml` overrides

| Variable                          | Default     | Description                                                                                                                |
| --------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------------- |
| `CONTAINER_NAME`                  | `windrose`  | Change only if you run more than one server on the same host                                                               |
| `HOSTNAME`                        | `localhost` | Internal container hostname used by ICE candidate discovery; keep `localhost` unless custom name resolves inside container |
| `IMAGE_REPOSITORY`                | GHCR repo   | Published image repository                                                                                                 |
| `IMAGE_TAG`                       | `v1.6.2`    | Stable image tag to run                                                                                                    |
| `PUID`                            | `1000`      | User id used for mounted files                                                                                             |
| `PGID`                            | `1000`      | Group id used for mounted files                                                                                            |
| `UPDATE_ON_START`                 | `true`      | Update and validate server files on startup                                                                                |
| `GENERATE_SETTINGS`               | `true`      | Auto-patch `ServerDescription.json` from env values                                                                        |
| `INVITE_CODE`                     | empty       | Invite code shown to players. Leave empty to use direct connection instead                                                 |
| `SERVER_NAME`                     | empty       | Display name of the server                                                                                                 |
| `SERVER_NOTE`                     | empty       | Short public server note/description                                                                                       |
| `SERVER_PASSWORD`                 | empty       | Leave empty for a public server                                                                                            |
| `MAX_PLAYERS`                     | `4`         | Maximum number of simultaneous players                                                                                     |
| `P2P_PROXY_ADDRESS`               | `127.0.0.1` | Internal socket proxy address. Change to LAN IP if players connect from the same network                                   |
| `USE_DIRECT_CONNECTION`           | `false`     | Set to `true` to allow players to connect directly via IP instead of invite code. Requires port forwarding.                |
| `DIRECT_CONNECTION_SERVER_PORT`   | `7777`      | Port used for direct connection (TCP and UDP). Only applies when `USE_DIRECT_CONNECTION=true`                              |
| `DIRECT_CONNECTION_PROXY_ADDRESS` | `0.0.0.0`   | Proxy address for direct connection. Only applies when `USE_DIRECT_CONNECTION=true`                                        |
| `USER_SELECTED_REGION`            | empty       | Connection service region: `SEA`, `CIS`, `EU`. Leave empty to auto-detect. `EU` covers both EU and NA regions              |
| `PORT`                            | `7777`      | Game port (UDP)                                                                                                            |
| `QUERYPORT`                       | `7778`      | Query port (UDP)                                                                                                           |
| `WINDROSE_APP_ID`                 | `4129620`   | Steam AppID                                                                                                                |
| `STEAM_LOGIN`                     | `anonymous` | SteamCMD login                                                                                                             |

---

## Volumes

| Host path      | Container path | Contents                    |
| -------------- | -------------- | --------------------------- |
| `./data`       | `/data`        | Server files, saves, config |
| `./steam-home` | `/home/steam`  | Wine prefix, SteamCMD cache |

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

### Gameplay difficulty

Gameplay difficulty is stored per world in `WorldDescription.json` and is not controlled by `docker-compose.yml` environment variables.

1. Stop the server:

   ```bash
   ./windrose stop
   ```

2. Find the active world ID from `data/R5/ServerDescription.json`:

   ```text
   ServerDescription_Persistent.WorldIslandId
   ```

3. Edit this file for that active world:

   ```text
   data/R5/Saved/SaveProfiles/Default/RocksDB/<GameVersion>/Worlds/<WorldIslandId>/WorldDescription.json
   ```

4. Set the preset fields in `WorldDescription.json`. Reference values per preset:

   **Easy**
   - `WorldPresetType = "Easy"`
   - `MobHealthMultiplier = 0.7`, `MobDamageMultiplier = 0.6`
   - `ShipsHealthMultiplier = 0.7`, `ShipsDamageMultiplier = 0.6`
   - `BoardingDifficultyMultiplier = 0.7`
   - `CombatDifficulty = Easy`
   - `EasyExplore = true` _(disables map markers — shown as "Immersive exploration" in-game; despite the name, this makes exploration harder)_

   **Medium** (default)
   - `WorldPresetType = "Medium"`
   - All multipliers = `1.0`
   - `CombatDifficulty = Normal`
   - `EasyExplore = false`

   **Hard**
   - `WorldPresetType = "Hard"`
   - `MobHealthMultiplier = 1.5`, `MobDamageMultiplier = 1.25`
   - `ShipsHealthMultiplier = 1.5`, `ShipsDamageMultiplier = 1.25`
   - `BoardingDifficultyMultiplier = 1.5`
   - `CombatDifficulty = Hard`
   - `EasyExplore = false`

5. Start the server:

   ```bash
   ./windrose start
   ```

Tip: if values do not apply, verify the edited world ID is the same as `ServerDescription_Persistent.WorldIslandId`.

### Make one world persist across restarts

To keep the same game world instead of generating new ones:

1. Keep persistent host binds for `/data` and `/home/steam` (do not change them between deployments).
2. Always keep `ServerDescription_Persistent.WorldIslandId` set to an existing world folder name.
3. Do not rename world folders.
4. Stop the server before editing `ServerDescription.json` or `WorldDescription.json`.
5. Restart after edits and verify logs.

If a new world keeps appearing:

- Check that `WorldIslandId` points to a folder that exists under `.../RocksDB/<GameVersion>/Worlds/`.
- Run `./windrose worlds-check` to detect broken or placeholder entries.
- Re-select the intended world with `./windrose switch`.

### World consistency guardrails

To avoid accidental new-world generation and confusing config drift, keep these values aligned:

1. `ServerDescription_Persistent.WorldIslandId`
2. The selected world folder name under `.../Worlds/<WorldIslandId>`
3. `WorldDescription.IslandId` inside that world's `WorldDescription.json`

If any of these mismatch, the server may generate a new world and rewrite IDs on startup.

### Preset vs custom behavior

- `WorldPresetType` should be one of `Easy`, `Medium`, or `Hard` for preset mode.
- If you change individual `WorldSettings` values, the world can switch to `Custom` on next launch.
- For predictable outcomes, either:
  - Use preset values only, or
  - Intentionally manage a full custom profile and treat `WorldPresetType` as `Custom`.

### Custom preset parameters

> **Note:** It is generally easier to configure these settings in-game first, then copy the resulting values from your local save file to the server.

| Parameter                          | Default  |         Range          | Description                                                                                        |
| :--------------------------------- | :------: | :--------------------: | :------------------------------------------------------------------------------------------------- |
| `CoopQuests`                       |  `true`  |           —            | Auto-completes co-op quests for all active players                                                 |
| `EasyExplore`                      | `false`  |           —            | Disables map markers ("Immersive exploration" in-game). Despite the name, makes exploration harder |
| `MobHealthMultiplier`              |  `1.0`   |      `0.2`–`5.0`       | Enemy health multiplier                                                                            |
| `MobDamageMultiplier`              |  `1.0`   |      `0.2`–`5.0`       | Enemy damage multiplier                                                                            |
| `ShipHealthMultiplier`             |  `1.0`   |      `0.4`–`5.0`       | Enemy ship health multiplier                                                                       |
| `ShipDamageMultiplier`             |  `1.0`   |      `0.2`–`2.5`       | Enemy ship damage multiplier                                                                       |
| `BoardingDifficultyMultiplier`     |  `1.0`   |      `0.2`–`5.0`       | Enemy sailors needed to win boarding                                                               |
| `Coop_StatsCorrectionModifier`     |  `1.0`   |      `0.0`–`2.0`       | Scales enemy health by active player count                                                         |
| `Coop_ShipStatsCorrectionModifier` |  `0.0`   |      `0.0`–`2.0`       | Scales enemy ship health by active player count                                                    |
| `CombatDifficulty`                 | `Normal` | `Easy`/`Normal`/`Hard` | Boss aggression level                                                                              |

### Safe config edit workflow

Use this sequence every time you change server/world JSON files:

1. Stop server.
2. Back up config/save files.
3. Edit files.
4. Start server.
5. Verify loaded values in logs and in active JSON.

This avoids partial writes, tool/UI overwrites, and startup-time regeneration surprises.

---

## How players join

1. Start the server once and wait until it is healthy
2. Open `data/R5/ServerDescription.json` and copy the `InviteCode` value
3. Share that code with players — they use it in-game under **Join via Code**
4. Invite codes are case-sensitive and should be at least 6 characters long
5. No port forwarding is required for the normal invite-code flow

The server still binds internal game and query ports, mainly for local binding and advanced or multi-instance setups.

---

## In-game visibility (official)

Based on official Windrose documentation and Steam announcements:

- Players can join via invite code in-game: **Play -> Connect to Server**.
- There is a **Show Server Info** section in the in-game **Esc** menu.
- `ServerName` is intended to help identify the correct server when invite codes are similar.

What is not clearly documented as visible in dedicated-server UI:

- Detailed world difficulty internals (for example `WorldPresetType`, combat tags, and multipliers).

Treat those as file-based settings in `WorldDescription.json` and verify with logs/file values when needed.

Official references:

- https://playwindrose.com/dedicated-server-guide/
- https://steamcommunity.com/app/3041230/announcements/

---

## Useful commands

```bash
# First-time interactive setup (.env, backup options, optional auto-start)
./windrose setup

# Start
docker compose up -d

# Stop
docker compose stop

# Restart helper flow
./windrose restart

# Helper status overview
./windrose status

# JSON snapshot for monitoring integrations
./windrose status-json

# Full operator preflight checks
./windrose doctor

# Create a diagnostics bundle (default: 300 log lines)
./windrose diagnostics

# View live logs
docker compose logs -f windrose

# Helper log shortcut
./windrose logs

# Best-effort player activity lines from recent logs
./windrose activity history

# Structured join/leave events (JSONL)
./windrose activity events

# List worlds
./windrose worlds

# Detect orphan/broken world entries
./windrose worlds-check

# Switch to another world interactively
./windrose switch

# Start or inspect activity notifications
./windrose notify
./windrose notify status
./windrose notify test

# Create a backup or install the backup cron helper
./windrose backup
./windrose install-backup-cron

# Pull the latest published image tag
./windrose pull

# Update helper flow (safe pull -> up; use --force-down for full recreate)
./windrose update

# Show detailed update log (default: last 120 lines)
./windrose update-log

# Stop and remove the stack
./windrose down

# Check server process inside container
docker compose exec windrose pgrep -a WindroseServer

# Container status + health
docker compose ps

# Optional system-wide install target
./windrose install /usr/local/bin/windrosectl
```

## Quick diagnostics

Use these commands for a fast operational check:

```bash
# 1) Basic container and health status
./windrose status

# 2) Full host/runtime preflight
./windrose doctor

# 3) World integrity check (orphan/broken entries)
./windrose worlds-check

# 4) Recent critical network/auth errors from current log file
docker compose logs --no-color --tail 400 windrose | grep -Ei "account verification failed|turn session was expired|p2pgate disconnected|server authorization failed|login finished with error"

# 5) Create diagnostics bundle for incident review
./windrose diagnostics
```

If command `3` returns lines repeatedly, check outbound connectivity and firewall/NAT behavior for `*.windrose.support` on UDP/TCP `3478`.

For a machine-readable snapshot, use `./windrose status-json`.

`./windrose status` shows a compact operator dashboard: container state and health, currently online players (parsed from the last 24 hours of container logs), last activity event timestamp, backup age, and notifier status. It does not require the `notify` background process to be running — player data is read directly from container logs. Using a 24-hour log window means players active for many hours will still appear correctly.

`./windrose activity status` is a focused diagnostic tool for player activity: it shows how many log lines were scanned, how many join/leave events were matched, and the full list of online players without a display cap. Use it when you want to verify the parser is working or diagnose a mismatch between expected and reported online counts. You can pass a custom line count: `./windrose activity status 8000`.

For quick player activity extraction from logs, use `./windrose activity history [lines]`.

For structured join/leave records, use `./windrose activity events [lines]`.
Events are appended as JSON lines to `./logs/player-events.log`.
The parser is best-effort and now prefers richer Windrose/UE markers such as `Login request`, prelogin/account verification, and account summary dumps when they are present.
Entries may also include an optional `name` field when the server log exposes a human-readable player name.
A persistent identity map is maintained in `./state/player-identities.tsv` and reused to improve name resolution for disconnect events.

Legacy aliases are still supported for backward compatibility: `./windrose player-history`, `./windrose player-events`.

For deeper investigation, extended symptom table, and network playbooks, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Activity notifications: Discord, Gotify, or both

A basic log watcher is included for best-effort player activity notifications.

1. Choose a notification backend in `.env`:

```dotenv
NOTIFY_PROVIDER=auto
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
GOTIFY_URL=https://gotify.example.com
GOTIFY_TOKEN=your_app_token
GOTIFY_PRIORITY=5
```

Provider modes:

- `auto`: prefers Gotify when it is configured, otherwise falls back to Discord
- `discord`: sends only to Discord
- `gotify`: sends only to Gotify
- `both`: sends to Discord and Gotify for every event

1. Test the webhook once before long-term use:

```bash
./windrose notify test
```

1. Start the watcher:

```bash
./windrose notify
```

1. Check watcher status and effective backend:

```bash
./windrose notify status
```

The helper asks whether to run in background mode. If you start it in background mode, running `./windrose notify` again detects the running watcher and offers to stop it.

Background logs are written to:

```text
./logs/notify.log
```

At the moment this is log-based and best-effort. Disconnect events are easier to detect reliably than joins, so treat it as a lightweight helper rather than a perfect audit system.
When available, the notifier also uses `./state/player-identities.tsv` to resolve player names for disconnect lines that do not contain a name directly.

---

## Save transfer and world selection

World saves live under:

```text
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

   ```text
   data/R5/Saved/SaveProfiles/Default/RocksDB/<game-version>/Worlds/
   ```

   Example using `scp` from a local machine (copy folder as-is):

   ```bash
   scp -r "./EC10598E83A14ED04D9C44CBFBF3F4B1" user@yourserver:/windrose/data/R5/Saved/SaveProfiles/Default/RocksDB/<version>/Worlds/
   ```

   Use the copied folder name exactly. Do not rename world folders.

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

Use the built-in helper for a safer backup flow. It briefly stops the server, creates a timestamped archive, and starts it again if it was running. If the activity notifier (`./windrose notify`) was active before the backup, it is restarted automatically afterwards.

```bash
# Create a manual backup
./windrose backup

# Install a host cron job running daily at 06:00
./windrose install-backup-cron

# Or provide your own schedule
./windrose install-backup-cron "0 3 * * *"
```

Backups are stored in `backups` by default and old archives are pruned after 7 days. You can change that in `.env` with `BACKUP_DIR` and `BACKUP_RETENTION_DAYS`. Relative paths in `BACKUP_DIR` are resolved relative to the repository directory, not the current working directory.

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

After each archive is created, the script runs an integrity test (`tar -tzf` or `zip -T`) and fails fast if verification does not pass.

If you use `BACKUP_FORMAT=zip`, the script checks whether `zip` is available.
In an interactive shell it asks whether it should install `zip`; in cron/non-interactive mode it exits with a clear error.

The installed cron job appends logs to `backups/backup.log`.

Before creating an archive, the backup script checks whether any players are currently online by reading recent container logs. If players are detected, the backup is aborted and a notification is sent via the configured provider (Discord or Gotify). To skip this check (for example in a maintenance window where you know the state), set:

```dotenv
BACKUP_SKIP_ONLINE_CHECK=true
```

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

The backup script also checks for available disk space before creating an archive. It estimates the required space as 1.5× the size of the data directory plus a 2 GB safety margin. If the target disk does not have enough free space, the backup is aborted with a clear error. The check runs against the filesystem where `BACKUP_DIR` is mounted.

---

## Directory structure

```text
windrose/
├── Dockerfile          # Ubuntu 22.04 + Wine + SteamCMD
├── docker-compose.yml  # Service definition
├── scripts/            # Canonical runtime scripts used by container
├── .env                # Environment variables (do not commit with secrets)
├── data/               # Persistent server files and saves (created on first run)
│   └── R5/
│       ├── ServerDescription.json
│       └── Saved/
├── steam-home/         # Wine prefix and SteamCMD state (created on first run)
├── backups/            # Archive files only (tar.gz, zip) from backup operations
├── logs/               # Log files (update, backup, player activity)
├── state/              # Metadata (player identities, event deduplication)
└── diagnostics/        # Diagnostics bundles (tar.gz archives)
```

**Migration note:** If you are upgrading from an older version with a combined `backups/` folder, run the included `migrate-folders.sh` script once to reorganize files:

```bash
./migrate-folders.sh
```

This moves log files, state files, and diagnostics to their respective folders while keeping backup archives in `backups`. The script is safe to run multiple times.

---

## Troubleshooting

For the full symptom table, diagnostics playbooks, and network troubleshooting, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Common quick fixes:

| Symptom                                              | Fix                                                                   |
| ---------------------------------------------------- | --------------------------------------------------------------------- |
| `wine: '/home/steam' is not owned by you`            | Set `PUID` and `PGID` correctly in `.env`, then restart the container |
| `Server is already active for display 99`            | Stale Xvfb lock — entrypoint removes it automatically on restart      |
| Config reset after restart                           | Edit JSON only when container is stopped                              |
| Server not visible to players                        | Share the `InviteCode` from `ServerDescription.json`                  |
| Players have issues after a game patch               | Keep the dedicated server version updated to match the game version   |
| Server fails to start or crashes silently in Proxmox | Set CPU type to `host` in the VM/LXC settings (see below)             |

### Proxmox VM and LXC

If you are hosting this server inside a Proxmox VM or LXC container, set the CPU type to `host` in the Proxmox configuration for that VM or container.

Proxmox's default CPU types (for example `kvm64`) omit instruction sets that Wine and the server binary may depend on. This can cause the server to fail to start, crash at runtime, or fail silently with no useful log output.

In the Proxmox web UI: VM → Hardware → Processors → Type → `host`.

Using `host` CPU type passes the physical CPU's full instruction set through to the VM, which is required for Wine to run the dedicated server binary reliably.

---

## Image versions

- Most users should keep `IMAGE_TAG=v1.6.2` for a stable server.
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
- Canonical runtime scripts are under `/opt/windrose/scripts/*`; root-level script files are compatibility wrappers
- Compatibility wrappers are kept for backward compatibility and may be removed in a future major release after deprecation notice

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
./windrose notify test
```

### How do I update safely on production?

Pull the latest repository changes first, then refresh the selected image tag and recreate the container:

```bash
git pull
./windrose update
```

`./windrose update` writes detailed command output to `backups/update.log` and keeps three rotated history files (`update.log.1`, `update.log.2`, `update.log.3`).

Use `./windrose update-log [lines]` to quickly inspect recent update details from the active log file.

### What is the difference between stable and latest?

Use a pinned version tag such as `v1.6.2` for production stability. Use `latest` only when you want the newest changes for testing.
For developer image channels (dev, dev-staging, dev-debug), see [DEVELOPMENT.md](DEVELOPMENT.md).

## Practical operator guides

### Initial host setup and first launch

1. Clone and enter the repository:

   ```bash
   git clone https://github.com/UberDudePL/windrose-dedicated-server-docker.git
   cd windrose-dedicated-server-docker
   ```

2. Create `.env` and adjust only required values:

   ```bash
   cp .env.example .env
   nano .env
   ```

   Set at least `PUID`, `PGID`, and optional server identity values (`SERVER_NAME`, `INVITE_CODE`).

3. Run first launch:

   ```bash
   ./windrose setup
   ```

4. Verify running state before inviting players:

   ```bash
   ./windrose status
   ./windrose logs
   ```

### Save migration and world switch safety

1. Create a backup first:

   ```bash
   ./windrose backup
   ```

2. Stop server before any manual save copy/edit:

   ```bash
   ./windrose stop
   ```

3. Validate worlds and active world mapping:

   ```bash
   ./windrose worlds
   ./windrose worlds-check
   ```

4. Switch world with helper (recommended):

   ```bash
   ./windrose switch
   ```

5. Use prune in safe order:

   ```bash
   ./windrose worlds-prune
   ./windrose worlds-prune --apply
   ```

   Default mode is dry-run. `--apply` requires confirmation in interactive shell and never removes the active world.

### Failed update recovery

1. Check update status and details:

   ```bash
   ./windrose status
   ./windrose update-log 200
   ```

2. Keep mounts and compose defaults unchanged (`./data`, `./steam-home`, ports, and network settings).

3. Roll back to a known-good Git ref only if needed, then restart:

   ```bash
   git checkout <known-good-tag-or-commit>
   ./windrose update --force-down
   ```

4. If startup still fails, generate diagnostics bundle for review:

   ```bash
   ./windrose diagnostics
   ```

### Rollback for script path migration

If you need to roll back this script layout migration, use this short procedure:

1. Check out the previous known-good ref and rebuild:

   ```bash
   git checkout <known-good-tag-or-commit>
   docker compose build --no-cache windrose
   ```

2. Recreate the service:

   ```bash
   docker compose up -d windrose
   ```

3. Verify health and status:

   ```bash
   ./windrose status
   ./windrose doctor
   ```

This rollback does not require data migration and keeps existing save paths unchanged (`./data`, `./steam-home`).

## Release checklist

1. Pick the new stable version (example: `v1.6.0`).
2. Update version bump points before tagging:
   - `.env.example`: set `IMAGE_TAG=v1.6.0`
   - `README.md`: update all stable version references (`IMAGE_TAG` default examples, quick start snippets, stable guidance lines)
3. Verify old stable version references are gone from `.env.example` and `README.md`.
4. Verify behavior locally before publishing:

   ```bash
   bash -n serverctl.sh backup.sh notify.sh
   ./windrose status
   ./windrose worlds-prune
   ./windrose notify status
   ```

5. Commit docs/version changes and push them to `main` first.
6. Run a manual approval checkpoint for script layout migration changes before tagging:
   - Confirm compose parity checks passed.
   - Confirm rollback procedure was tested and documented.
   - Confirm root compatibility wrappers delegate correctly.
7. After `main` contains the version bump commit and manual approval is recorded, create and push the release tag.
8. Publish the GitHub release notes for that tag.
9. If a tag was created too early, move it to the latest `main` commit before publishing release notes.

---

## Issues and suggestions

If you hit a bug or want a new feature, please open an issue in the GitHub repository.

---

## Support

If this project saved you time and you want to support further maintenance, you can use:

- Ko-fi: [https://ko-fi.com/uberdudepl](https://ko-fi.com/uberdudepl)
- PayPal: [https://paypal.me/uberdudepl](https://paypal.me/uberdudepl)
- Revolut: [https://revolut.me/uberdudepl](https://revolut.me/uberdudepl)

---

## License

MIT — see [LICENSE](LICENSE)
