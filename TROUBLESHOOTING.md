# Windrose Dedicated Server — Troubleshooting

Use this document when quick diagnostics are insufficient. For production setup and daily operations, see [README.md](README.md).

## Table of contents

- [Quick diagnostics](#quick-diagnostics)
- [Symptom table](#symptom-table)
- [Client cannot connect (quick checklist)](#client-cannot-connect-quick-checklist)
- [DNS check for game services](#dns-check-for-game-services)
- [ISP/network block playbook (3478 UDP/TCP)](#ispnetwork-block-playbook-3478-udptcp)
- [LAN clients fail, WAN clients work](#lan-clients-fail-wan-clients-work)
- [Choosing the right image](#choosing-the-right-image)

---

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

For quick player activity extraction from logs, use `./windrose activity history [lines]`.

For structured join/leave records, use `./windrose activity events [lines]`.
Events are appended as JSON lines to `./logs/player-events.log`.
The parser is best-effort and now prefers richer Windrose/UE markers such as `Login request`, prelogin/account verification, and account summary dumps when they are present.
Entries may also include an optional `name` field when the server log exposes a human-readable player name.
A persistent identity map is maintained in `./state/player-identities.tsv` and reused to improve name resolution for disconnect events.

Legacy aliases are still supported for backward compatibility: `./windrose player-history`, `./windrose player-events`.

---

## Symptom table

| Symptom | Fix |
|---------|-----|
| `wine: '/home/steam' is not owned by you` | Set `PUID` and `PGID` correctly in `.env`, then restart the container |
| `Server is already active for display 99` | Stale Xvfb lock — entrypoint removes it automatically on restart |
| `ERROR! Failed to install app` | Check SteamCMD logs and verify the app id and Steam login mode |
| Server not visible to players | Share the `InviteCode` from `ServerDescription.json` |
| Connection works on some networks but not others | The network or ISP may be blocking STUN/TURN traffic used by the game; check access to `*.windrose.support` on port `3478` over UDP/TCP |
| Remote clients connect, LAN clients fail after ~10 seconds | See the LAN ICE note below; this is usually Docker bridge NAT + routing mismatch |
| `Account verification failed`, `Turn session was expired`, `BL P2PGate disconnected` | Usually upstream TURN/P2P session/network issue; verify stable outbound access to `*.windrose.support` on UDP/TCP `3478`, avoid aggressive NAT/firewall timeouts, then retry reconnect |
| Config reset after restart | Edit JSON only when container is stopped |
| Players have issues after a game patch | Keep the dedicated server version updated to match the game version |

---

## Client cannot connect (quick checklist)

Use this first-line checklist before deeper debugging:

1. Restart the game client and Steam.
2. Restart the router and the client PC.
3. Disable VPN/proxy on the client.
4. Temporarily disable aggressive antivirus/firewall filtering.
5. Retry joining 3-5 times.

If the issue persists only on selected networks, continue with DNS and ISP checks below.

---

## DNS check for game services

Run these commands on the affected client machine:

```bash
nslookup r5coopapigateway-eu-release.windrose.support
nslookup r5coopapigateway-eu-release.windrose.support 8.8.8.8
```

How to interpret results:

- Expected: a normal IPv4 address is returned.
- `Non-existent domain`: local DNS/ISP may be filtering the domain.
- `Request timed out`: DNS resolver or local security tooling may be blocking requests.
- `127.0.0.1`: local override, VPN, or ISP spoofing is likely.
- IPv6-only answer: prefer IPv4 for this game flow.

---

## ISP/network block playbook (3478 UDP/TCP)

If failures repeat on one ISP/network, ask for a whitelist check with this template:

- Domains: `*.windrose.support`
- Port: `3478`
- Protocols: `UDP`, `TCP`
- Traffic type: `STUN/TURN` (NAT traversal)
- Purpose: legitimate game connectivity

Also test from a different network (for example mobile hotspot) to confirm whether the issue is network-specific.

---

## LAN clients fail, WAN clients work

If the server runs in Docker bridge mode on Linux and LAN clients are dropped after about 10 seconds, this is an ICE/STUN consent failure caused by Docker's MASQUERADE NAT rule rewriting the source IP on LAN-bound packets.

Typical symptoms:

- WAN clients connect, LAN clients fail after ~10 seconds
- Server logs contain: `Check consent was failed for IceControlling. Reach timeout 10000 ms`

### Fix — Part 1: bypass MASQUERADE on the Docker host

1. Find the container's internal IP:

	```bash
	docker inspect windrose | grep '"IPAddress"'
	```

2. Add a NAT bypass rule scoped to this container and your LAN subnet:

	```bash
	sudo iptables -t nat -I POSTROUTING -s <container_ip>/32 -d <lan_subnet>/24 -j RETURN
	# Example:
	sudo iptables -t nat -I POSTROUTING -s 172.17.0.2/32 -d 192.168.1.0/24 -j RETURN
	```

	Using `/32` scopes the rule to only this container; other containers are unaffected.

3. Persist the rule across reboots:

	```bash
	sudo apt-get install -y iptables-persistent
	sudo netfilter-persistent save
	```

> ⚠ **Caveat:** Container IP can change when the container is recreated. After `docker compose up`, verify the IP with `docker inspect` and update the iptables rule if needed.

### Fix — Part 2: add a route on the LAN client

The client must be able to route replies back to the container subnet.

**Windows** (elevated CMD or PowerShell):

```cmd
route add 172.17.0.0 MASK 255.255.0.0 <server_host_lan_ip> -p
```

**Linux**:

```bash
sudo ip route add 172.17.0.0/16 via <server_host_lan_ip>
```

**macOS**:

```bash
sudo route add -net 172.17.0.0/16 <server_host_lan_ip>
```

### Verify

After applying both parts, check server logs for successful ICE consent:

```bash
docker compose logs windrose | grep -i "Nominated\|Consented\|Succeeded"
```

Expected: `Nominated pair Succeeded` and `CheckConsent ... Consented pair ... Succeeded`.

> **Note:** For this repository's default (`network_mode: host`), Docker bridge NAT is bypassed entirely and this fix is not needed.

---

## Choosing the right image

- Try `staging` when stable Wine builds fail on a specific host with prefix or runtime compatibility issues.
- Try `debug` when you need extra tools and more verbose logging to investigate Wine, DNS, or network problems.
- Use `staging` only as a fallback for Wine compatibility issues on a specific host.
- Use `debug` when you need extra troubleshooting tools inside the image.
