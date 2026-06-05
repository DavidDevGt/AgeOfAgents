# Deployment Guide

This document covers building, configuring, and running Gulag Arena in every
supported environment: local development, bare-metal server, and Docker.

---

## Table of Contents

1. [Build](#build)
2. [Configuration](#configuration)
3. [Running the Server](#running-the-server)
4. [Running the Client](#running-the-client)
5. [Docker](#docker)
6. [Firewall](#firewall)
7. [Monitoring](#monitoring)

---

## Build

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Go | ≥ 1.24 | <https://go.dev/dl/> |
| LÖVE | 11.5 | <https://love2d.org/> |
| make | any | system package manager |

### Backend

```bash
# Development binary (current platform)
make build

# Cross-compile for all platforms
make build-all

# Output: dist/server-linux-amd64, dist/server-darwin-amd64, dist/server-windows-amd64.exe
```

Manual equivalent:

```bash
cd backend
go build -ldflags="-s -w" -o ../dist/server ./cmd/server
```

### Client

```bash
# Package as a .love archive (platform-independent)
make package

# Output: dist/gulag-arena.love
# Run with: love dist/gulag-arena.love
```

Manual equivalent:

```bash
cd <repo-root>
zip -r dist/gulag-arena.love main.lua conf.lua src/
```

---

## Configuration

### Server (environment variables)

The server reads these at startup. Command-line flags override environment
variables.

| Variable | Flag | Default | Description |
|----------|------|---------|-------------|
| `SERVER_ADDR` | `-addr` | `:40000` | UDP bind address (`host:port`) |
| `SERVER_MODE` | `-mode` | `1` | Game mode: `1` = 1v1, `2` = 2v2 |
| `SERVER_DEBUG` | `-debug` | `false` | Verbose logging: round transitions, kills, per-5s stats |

> **Note:** Rate limiting and structured JSON logging are not yet implemented.
> See [PLAN.md](PLAN.md) Phase 2–3 for the roadmap.

#### Examples

```bash
# Default: 1v1 on port 40000
./dist/server-linux-amd64

# 2v2 on a custom port with verbose logs
SERVER_ADDR=:40001 SERVER_MODE=2 SERVER_DEBUG=true ./dist/server-linux-amd64

# Equivalent via flags
./dist/server-linux-amd64 -addr :40001 -mode 2 -debug
```

### Client

The client hardcodes the server address at the top of `main.lua`:

```lua
-- main.lua (lines 1–4)
local HOST = "127.0.0.1"
local PORT = 40000
```

Edit these values before packaging when connecting to a remote server. A
configuration UI is planned in [PLAN.md](PLAN.md) Phase 2 and 4.

---

## Running the Server

### Systemd service (Linux)

Create `/etc/systemd/system/gulag-arena.service`:

```ini
[Unit]
Description=Gulag Arena Game Server
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/gulag-arena-server -addr :40000 -mode 1
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

```bash
sudo cp dist/server-linux-amd64 /usr/local/bin/gulag-arena-server
sudo chmod +x /usr/local/bin/gulag-arena-server
sudo systemctl daemon-reload
sudo systemctl enable --now gulag-arena
sudo systemctl status gulag-arena
```

### macOS (launchd)

Create `~/Library/LaunchAgents/com.gulagarena.server.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gulagarena.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/gulag-arena-server</string>
        <string>-addr</string>
        <string>:40000</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.gulagarena.server.plist
```

---

## Running the Client

```bash
# From the repo root (development)
love .

# From a packaged archive
love dist/gulag-arena.love

# On Windows (LÖVE installed to default path)
"C:\Program Files\LOVE\love.exe" dist\gulag-arena.love
```

---

## Docker

### Build the image

```bash
docker build -t gulag-arena-server ./backend
```

Dockerfile reference (create at `backend/Dockerfile` if not present):

```dockerfile
FROM golang:1.24-alpine AS builder
WORKDIR /build
COPY . .
RUN go build -ldflags="-s -w" -o server ./cmd/server

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /build/server /usr/local/bin/server
EXPOSE 40000/udp
ENTRYPOINT ["server"]
```

### Run in Docker

```bash
# 1v1, default port
docker run -d --name gulag-arena \
  -p 40000:40000/udp \
  gulag-arena-server

# 2v2, custom port, verbose logs
docker run -d --name gulag-arena-2v2 \
  -p 40001:40001/udp \
  -e SERVER_ADDR=:40001 \
  -e SERVER_MODE=2 \
  -e SERVER_DEBUG=true \
  gulag-arena-server -addr :40001 -mode 2 -debug
```

### docker-compose (local development)

```yaml
# docker-compose.yml
version: "3.9"
services:
  server:
    build:
      context: ./backend
    ports:
      - "40000:40000/udp"
    environment:
      SERVER_DEBUG: "true"
    restart: unless-stopped
```

```bash
docker compose up -d
docker compose logs -f server
```

---

## Firewall

The server requires **UDP port 40000** (or whichever `-addr` specifies) to be
reachable from clients.

```bash
# ufw (Ubuntu/Debian)
sudo ufw allow 40000/udp
sudo ufw reload

# firewalld (RHEL/Fedora)
sudo firewall-cmd --add-port=40000/udp --permanent
sudo firewall-cmd --reload

# iptables (manual)
sudo iptables -A INPUT -p udp --dport 40000 -j ACCEPT
```

For clients behind NAT: UDP hole punching is not implemented. Players on
separate networks require either port forwarding on the server side or a relay.
See [PLAN.md](PLAN.md) Phase 6 for the matchmaking roadmap.

---

## Monitoring

The server logs to stdout by default. With `-debug` it also logs:

- Round transitions (intro → active → overtime → roundend → matchend)
- Kill events (attacker → victim, weapon)
- Per-5-second stats: tick/s, snap/s, kB/s in, kB/s out, packet/s, session count

Redirect logs to a file:

```bash
./server -debug 2>&1 | tee server.log
```

Prometheus metrics endpoint and Grafana dashboard are planned in
[PLAN.md](PLAN.md) Phase 7. Until then, the primary observability tool is the
client-side **F1 debug overlay**:

| Metric | Location |
|--------|---------|
| Client FPS | F1 overlay, top line |
| RTT (smoothed) | F1 overlay, top line |
| Snapshot rate | F1 overlay, `net:` line |
| Bytes/s | F1 overlay, `net:` line |
| Player states | F1 overlay, player list |
