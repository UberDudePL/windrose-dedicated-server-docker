# Windrose Dedicated Server — Docker

Self-hosted dedicated server for [Windrose](https://store.steampowered.com/app/2700940/Windrose/) running on Linux via Docker, SteamCMD and Wine.

> **No port forwarding required** — players join via **Invite Code** from `ServerDescription.json`.

---

## Features

- Automatic server download and update via SteamCMD
- Optional update-on-start toggle for faster restarts
- Wine + Xvfb headless runtime (no desktop required)
- Persistent saves and config via bind-mounted volumes
- Optional env-driven patching for server name, password, invite code, and max players
- PUID and PGID support for better host permission compatibility
- `restart: unless-stopped` — survives host reboots automatically
- Healthcheck watching the server process
- Log rotation (20 MB × 5 files)
- Anonymous SteamCMD login by default

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
Stable: ghcr.io/uberdudepl/windrose-dedicated-server-docker:v1.0.3
Latest: ghcr.io/uberdudepl/windrose-dedicated-server-docker:latest
```

Set the image version in `.env` with:

```dotenv
IMAGE_REPOSITORY=ghcr.io/uberdudepl/windrose-dedicated-server-docker
IMAGE_TAG=v1.0.3
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

Copy `.env.example` to `.env` and change only the values you need.

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
| `HOSTNAME` | `windrose` | Internal container hostname |
| `IMAGE_REPOSITORY` | GHCR repo | Published image repository |
| `IMAGE_TAG` | `v1.0.3` | Stable image tag to run |
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

# Pull the selected image tag and recreate the container
docker compose pull && docker compose up -d

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
./windrose update
./windrose notify
```

Optional system-wide install:

```bash
sudo ln -sf "$PWD/windrose" /usr/local/bin/windrosectl
windrosectl start
```

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

2. Start the watcher in a separate shell:

```bash
./windrose notify
```

At the moment this is log-based and best-effort. Disconnect events are easier to detect reliably than joins, so treat it as a lightweight helper rather than a perfect audit system.

---

## Save transfer and world selection

- World saves live under `data/R5/Saved/SaveProfiles/Default/RocksDB/<game-version>/Worlds/`
- To move an existing world onto the dedicated server, copy the whole world folder and set `WorldIslandId` in `ServerDescription.json` to that folder name
- Do not rename world folders — the database relies on those IDs

---

## Backup saves

```bash
# Manual backup
tar -czf windrose-backup-$(date +%F).tar.gz data/R5/Saved

# Cron — every 6 hours (add via crontab -e)
0 */6 * * * tar --warning=no-file-changed -czf /root/windrose-backup-$(date +\%F-\%H).tar.gz /path/to/windrose/data/R5/Saved

# Delete backups older than 7 days
find /root/windrose-backup-* -mtime +7 -delete
```

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
| Config reset after restart | Edit JSON only when container is stopped |
| Players have issues after a game patch | Keep the dedicated server version updated to match the game version |

---

## Image versions

- Most users should keep `IMAGE_TAG=v1.0.3` for a stable server.
- Use `latest` only for testing.
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
