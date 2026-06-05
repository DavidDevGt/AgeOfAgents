# Contributing to Gulag Arena

Thank you for taking the time to contribute. This document covers everything you
need to set up your environment, follow the project conventions, and submit
quality changes.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Repository Layout](#repository-layout)
3. [Development Setup](#development-setup)
4. [Running Locally](#running-locally)
5. [Testing](#testing)
6. [Code Style](#code-style)
7. [Commit Convention](#commit-convention)
8. [Pull Request Checklist](#pull-request-checklist)
9. [Architecture Constraints](#architecture-constraints)

---

## Prerequisites

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| Go | 1.24 | Backend compilation and tests |
| LÖVE | 11.5 | Client runtime |
| golangci-lint | 1.57 | Go static analysis |
| luacheck | 1.1 | Lua static analysis (optional) |
| make | any | Build automation |

Install Go: <https://go.dev/dl/>  
Install LÖVE: <https://love2d.org/>  
Install golangci-lint: `go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest`

---

## Repository Layout

```
backend/
  cmd/server/main.go       Entry point; flags: -addr, -mode, -debug
  internal/game/           Pure simulation (no networking, no I/O)
    arena.go               Static map geometry (walls, covers)
    collision.go           Circle-vs-AABB physics
    grenade.go             Projectile mechanics
    player.go              Player state + input consumption
    raycast.go             Hitscan weapon logic
    vec.go                 2D vector math
    weapon.go              Weapon definitions and instance state
    world.go               World simulation, match state machine, bot AI
    world_test.go          Integration tests
  internal/netcode/
    protocol.go            UDP text codec (encode/decode)
    server.go              UDP server, session management, tick loop

src/                       LÖVE client (Lua)
  core/                    OOP helper, 2D vector
  entities/                Bullet tracers, debris particles
  net/                     UDP connection wrapper, protocol parser
  render/                  Procedural texture generators
  render.lua               World and HUD rendering
  ui/                      UI state machine (menus, HUD, overlays)
main.lua                   App entry point, state machine (MENU→PLAY)
conf.lua                   LÖVE window configuration

docs/
  ARCHITECTURE.md          Design decisions and trade-off rationale
  PROTOCOL.md              UDP protocol specification (source of truth)
```

---

## Development Setup

```bash
git clone https://github.com/daviddevgt/ageofagents.git
cd ageofagents

# Verify backend compiles and tests pass
cd backend && go test ./... && cd ..

# Verify client syntax (requires luacheck)
luacheck src/ main.lua conf.lua
```

---

## Running Locally

**Terminal 1 — backend:**

```bash
# 1v1 (default)
go run ./backend/cmd/server

# 2v2 with verbose logging
go run ./backend/cmd/server -mode 2 -debug
```

**Terminal 2 — client:**

```bash
love .
```

Press **Enter** on the main menu to connect. The client connects to `localhost:40000`
by default. To connect to a different host, edit `HOST` and `PORT` at the top of
`main.lua`.

---

## Testing

```bash
# All tests
cd backend && go test ./...

# With race detector
cd backend && go test -race ./...

# Specific package
cd backend && go test ./internal/game/...

# With verbose output
cd backend && go test -v ./...
```

Tests live in `backend/internal/game/world_test.go`. When adding new game
mechanics, add a corresponding test that exercises the full `world.Step()` loop —
unit-testing individual functions in isolation tends to miss interaction bugs.

---

## Code Style

### Go

- Run `gofmt -w .` before committing (enforced by CI).
- Run `golangci-lint run ./...` and fix all warnings.
- Keep functions short. If a function body needs a comment to explain what it
  does, consider splitting it.
- No `panic` in non-test code. Return errors or fail gracefully.
- No allocations in the hot path (inside `Step()` or `broadcast()`). Reuse
  buffers; pre-allocate slices.

### Lua

- Follow the existing style: local functions, no globals beyond module tables.
- Run `luacheck src/ main.lua conf.lua` and resolve all warnings.
- No table allocation inside `love.update()` or `love.draw()`.
- Keep `ui_manager.lua` and `render.lua` as pure presentation layers — no game
  logic.

### Protocol changes

Any change to `protocol.go` or `netclient.lua` that modifies the wire format
**must** update `docs/PROTOCOL.md` in the same commit. Protocol and documentation
must always be in sync.

---

## Commit Convention

This project uses [Conventional Commits](https://www.conventionalcommits.org/).

```
<type>(<scope>): <short summary>

[optional body]

[optional footer]
```

**Types:**

| Type | When to use |
|------|-------------|
| `feat` | New user-facing feature |
| `fix` | Bug fix |
| `perf` | Performance improvement |
| `refactor` | Code change with no behaviour change |
| `test` | Adding or fixing tests |
| `docs` | Documentation only |
| `build` | Build scripts, Makefile, dependencies |
| `ci` | CI/CD configuration |
| `chore` | Miscellaneous (license, gitignore, tooling) |

**Scopes** (optional but encouraged): `server`, `client`, `protocol`, `game`,
`arena`, `docs`, `ci`.

**Examples:**

```
feat(game): add weapon swap animation state
fix(protocol): correct D event field order (victim before killer)
perf(server): replace snapshot string builder with bytes.Buffer
docs(protocol): add K, G, T message types to spec
test(game): add contested-capture reset test
```

Breaking changes append `!` after the type: `feat(protocol)!: ...` and include a
`BREAKING CHANGE:` footer.

---

## Pull Request Checklist

Before requesting review:

- [ ] `go test ./...` passes with no failures
- [ ] `golangci-lint run ./...` reports no issues
- [ ] No new allocations added to the simulation hot path
- [ ] If the wire protocol changed: `docs/PROTOCOL.md` updated in same commit
- [ ] If a new game mechanic added: integration test added
- [ ] `CHANGELOG.md` entry added under `[Unreleased]`
- [ ] Commits follow the Conventional Commits format above

---

## Architecture Constraints

These constraints exist for good reasons. Violating them requires explicit
discussion in the PR:

1. **Server is the only authority.** The client must not infer game state beyond
   interpolating positions. No client-side hit detection. No client-side damage
   calculation.

2. **No allocations in hot path.** The simulation loop runs at 60 Hz. Heap
   allocations inside `Step()`, `broadcast()`, or `readLoop()` cause GC pauses
   visible as frame spikes. Use pre-allocated pools and slice reslicing.

3. **Single main loop.** All mutations to `world` and `sessions` happen in the
   main goroutine. The read goroutine only writes to the `incoming` channel.
   Adding a second goroutine that writes to `world` is a data race.

4. **Text protocol over UDP.** The format is pipe-delimited ASCII lines. Do not
   introduce binary fields — the Lua client (LuaJIT, no `string.pack`) cannot
   parse them without FFI overhead that exceeds the bandwidth savings.

5. **Full snapshots, not deltas.** Every snapshot contains the complete dynamic
   state. This keeps packet loss transparent to the simulation and eliminates
   the need for per-client acknowledged sequence numbers.
