# Gulag Arena

[![CI](https://github.com/daviddevgt/ageofagents/actions/workflows/ci.yml/badge.svg)](https://github.com/daviddevgt/ageofagents/actions/workflows/ci.yml)
[![Go](https://img.shields.io/badge/Go-1.24-00ADD8?logo=go)](https://go.dev)
[![LÖVE](https://img.shields.io/badge/LÖVE-11.5-pink?logo=lua)](https://love2d.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Top-down 1v1 / 2v2 tactical shooter. The Go backend is the single source of
truth: physics, damage, rounds, overtime, and bot AI all run server-side at
60 Hz. The LÖVE client sends input and renders interpolated snapshots — no
client-side game logic.

```
┌─────────────────┐   UDP ASCII   ┌──────────────────────────┐
│  Client (LÖVE)  │  ── I|... ──► │  Server (Go)             │
│                 │               │  · simulation @ 60 Hz    │
│  · input        │  ◄── S|... ── │  · snapshots  @ 30 Hz    │
│  · interpolate  │   snapshots   │  · authoritative physics  │
│  · render       │               │  · bot AI                 │
└─────────────────┘               └──────────────────────────┘
```

---

## Quick Start

**Requirements:** [Go 1.24+](https://go.dev/dl/) and [LÖVE 11.5](https://love2d.org/).

```bash
# Terminal 1 — start the server (1v1, port 40000)
cd backend && go run ./cmd/server

# Terminal 2 — start the client
love .
```

Press **Enter** on the menu to connect. You play as the blue team; empty slots
are controlled by bots.

### Other server modes

```bash
# 2v2
go run ./cmd/server -mode 2

# Verbose logging (round transitions, kills, per-5s network stats)
go run ./cmd/server -debug

# Custom port
go run ./cmd/server -addr :40001
```

### Connecting to a remote server

Edit `HOST` and `PORT` at the top of `main.lua` before launching the client.
A configuration UI is on the roadmap ([PLAN.md](PLAN.md), Phase 2).

---

## Controls

| Action | Input |
|--------|-------|
| Move | `W A S D` |
| Aim | Mouse |
| Fire | Left click |
| Aim Down Sights | Right click |
| Reload | `R` |
| Swap weapon | `Q` |
| Debug overlay | `F1` |

---

## Game Rules

- **Loadout** is random and symmetric — all players get the same weapons each round.
- **100 HP**, no regeneration.
- **Round timer**: 40 seconds. Eliminate the opposing team to win early.
- **Overtime**: when the timer expires, a flag spawns at the center. Stand
  inside its radius for 3 uncontested seconds to win the round.
- **Sudden death**: if overtime expires without a capture, the team with higher
  total HP wins.
- **Match**: best of 7 (first team to 4 round wins).

### Loadouts

| Name | Primary | Secondary |
|------|---------|-----------|
| Cazador | Rifle de Precisión (95 dmg, bolt-action) | Cuchillo (100 dmg, melee) |
| Asaltante | Rifle de Asalto (22 dmg, auto) | Granada de Humo |
| Sigiloso | Pistola (34 dmg, semi) | Cuchillo |
| Bombardero | Pistola | Granada de Humo |

---

## Architecture

```
backend/
  cmd/server/main.go          Entry point and CLI flags
  internal/game/              Pure simulation — no I/O, no networking
    world.go                  World state, Step(), bot AI, match logic
    player.go                 Player state, input consumption, physics
    weapon.go                 Weapon definitions and instance state
    arena.go                  Map geometry (walls, destructible covers)
    collision.go              Circle-vs-AABB movement and slide
    raycast.go                Hitscan with wall and cover intersection
    grenade.go                Projectile physics and smoke detonation
    world_test.go             Integration tests
  internal/netcode/
    protocol.go               UDP text codec (encode/decode)
    server.go                 UDP server, session management, tick loop

src/                          LÖVE client
  net/netclient.lua           Protocol parser, interpolation, input
  render.lua                  World and HUD rendering (procedural sprites)
  ui/ui_manager.lua           Menus, killfeed, hitmarkers, vignette
```

Key design decisions are documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
The full wire protocol is in [docs/PROTOCOL.md](docs/PROTOCOL.md).

---

## Building

```bash
# Run tests
make test

# Build server binary (current platform)
make build

# Cross-compile for Linux, macOS, Windows
make build-all

# Package the client as a .love archive
make package

# Clean build artifacts
make clean
```

See [DEPLOY.md](DEPLOY.md) for Docker, systemd, and firewall configuration.

---

## Tests

```bash
cd backend && go test ./...
```

Six integration tests covering: loadout symmetry, damage and elimination,
overtime flag capture, contested-capture reset, and sudden-death by HP.

---

## Documentation

| Document | Contents |
|----------|---------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Design decisions, concurrency model, trade-off rationale |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | Complete UDP wire protocol specification |
| [DEPLOY.md](DEPLOY.md) | Build, configuration, Docker, monitoring |
| [RUNBOOK.md](RUNBOOK.md) | Operational troubleshooting procedures |
| [PLAN.md](PLAN.md) | 10-phase production roadmap |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Development workflow and conventions |
| [CHANGELOG.md](CHANGELOG.md) | Version history |

---

## License

[MIT](LICENSE)
