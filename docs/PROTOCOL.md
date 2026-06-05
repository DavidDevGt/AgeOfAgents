# Gulag Arena — UDP Protocol Specification

**Version:** 1.1  
**Last updated:** 2026-06-05  
**Source of truth:** `backend/internal/netcode/protocol.go` and `src/net/netclient.lua`

> This document describes the protocol **as implemented**. Aspirational
> features are marked **[TODO: PlanX]** with a reference to the roadmap phase
> in [PLAN.md](../PLAN.md). Do not treat TODO items as implemented.

---

## Overview

Gulag Arena uses a custom text-over-UDP protocol. Design axioms:

| Constraint | Rationale |
|------------|-----------|
| **Text (pipe-delimited ASCII)** | LuaJIT lacks `string.pack`; text parsing with `string.gmatch` adds < 0.5 ms per frame and eliminates endianness issues |
| **Full snapshots, not deltas** | A lost UDP packet leaves no gap; the next snapshot (33 ms later) has the complete state |
| **30 Hz snapshots, 60 Hz simulation** | Client interpolates at 60 FPS between the two most recent snapshots; halves bandwidth vs. 60 Hz snapshots |
| **Server-authoritative** | The server runs all physics and damage; the client cannot influence game state beyond sending input |

---

## Transport

- **Protocol:** UDP (RFC 768)
- **Server bind:** `0.0.0.0:40000` (default; configurable via `-addr`)
- **Client:** ephemeral port, any address
- **Max payload:** 1472 bytes (Ethernet MTU 1500 − 20 IP − 8 UDP). Current
  snapshots are 350–500 bytes; well within one datagram.
- **Reliability:** none. The design tolerates up to ~5% packet loss gracefully.
- **Ordering:** not guaranteed. Input flancs are OR-accumulated across
  out-of-order packets; snapshots are self-contained so ordering does not matter.

---

## Session Lifecycle

```
Client                              Server
  │                                    │
  │──── "J" ──────────────────────────►│  assignSlot(), send Welcome
  │◄─── "W|..." ───────────────────────│  (static map geometry, sent once)
  │                                    │
  │──── "I|..." ──────────────────────►│  every ~16 ms (60 Hz input)
  │◄─── "S|...\nF|...\nP|..." ─────────│  every ~33 ms (30 Hz snapshot)
  │                                    │
  │──── "Q|..." ──────────────────────►│  every 500 ms (RTT probe)
  │◄─── "q|..." ───────────────────────│  echo of timestamp
  │                                    │
  │──── "B" ───────────────────────────►│  graceful disconnect
  │                                    │
  │  (or 5 s silence → server timeout) │
```

---

## Message Reference

### Client → Server

---

#### `J` — Join

```
J
```

Request a player slot. The server replaces the first bot-controlled slot with
the client's address. If no bot slot is available, the server replies `FULL`
and drops the message.

On re-send (client retry before welcome arrives), the server re-sends the
welcome without assigning a new slot.

---

#### `I` — Input

```
I|seq|mx|my|aim|btn
```

Sent every frame (~60 Hz). Fields:

| Field | Type | Range | Encoding | Notes |
|-------|------|-------|----------|-------|
| `seq` | uint32 | 0–4 294 967 295 (wraps) | decimal | Monotonically increasing; not yet used for de-duplication |
| `mx` | int | −1, 0, 1 | decimal | Horizontal movement: A=−1, D=+1, neither=0 |
| `my` | int | −1, 0, 1 | decimal | Vertical movement: W=−1, S=+1 (Y-down screen) |
| `aim` | float64 | [0, 2π) | `%.4f` (4 dp) | `atan2(mouse_y − player_y, mouse_x − player_x)` |
| `btn` | uint8 | 0–31 | decimal | Bitmask; see table below |

Button bitmask (LSB first):

| Bit | Mask | Name | Semantics |
|-----|------|------|-----------|
| 0 | `0x01` | FIRE | Level: held this frame |
| 1 | `0x02` | FIRE_PRESSED | Edge: pressed this frame (1 frame wide) |
| 2 | `0x04` | ADS | Level: aiming down sights |
| 3 | `0x08` | RELOAD | Edge: reload requested this frame |
| 4 | `0x10` | SWAP | Edge: weapon swap requested this frame |
| 5–7 | — | reserved | Must be 0 |

Edge bits (`FIRE_PRESSED`, `RELOAD`, `SWAP`) are OR-accumulated on the server
across all input packets arriving in the same tick, preventing lost presses when
packets arrive out of order.

Wire example:
```
I|1042|1|0|2.3562|3
```
(`mx`=1, `my`=0, `aim`=135°, `btn`=3 → FIRE+FIRE_PRESSED)

---

#### `Q` — Ping

```
Q|timestamp
```

| Field | Encoding | Notes |
|-------|----------|-------|
| `timestamp` | `%.4f` (Unix epoch, seconds) | `love.timer.getTime()` |

Sent every 500 ms. The server echoes the timestamp unchanged (see `q` response
below). The client measures RTT and updates a smoothed estimate:

```lua
rtt = (rtt > 0) and (rtt * 0.7 + sample * 0.3) or sample   -- ms
```

---

#### `B` — Bye (client → server)

```
B
```

Graceful disconnect. The server returns the slot to bot control and removes the
session. If lost on UDP, the 5-second inactivity timeout handles cleanup.

---

### Server → Client

---

#### `W` — Welcome

Sent exactly once in response to `J`. Contains the static map geometry needed
for rendering and collision (the client does not simulate collisions, but uses
this for camera clipping and cover rendering).

```
W|playerID|mode|bx|by|bw|bh
WALL|x|y|w|h
WALL|x|y|w|h
...
BOX|id|x|y|w|h|maxhp
BOX|id|x|y|w|h|maxhp
...
```

Lines are separated by `\n`. All coordinates are 1-decimal floats.

| Field | Notes |
|-------|-------|
| `playerID` | 1–8; index into `world.Players` (1-based) |
| `mode` | `1` = 1v1, `2` = 2v2 |
| `bx/by/bw/bh` | Arena bounding box |
| WALL `x/y/w/h` | Static indestructible wall rectangle |
| BOX `id` | Cover ID (1-based, stable for the session) |
| BOX `maxhp` | Full HP at round start; used by client to scale damage cracks |

---

#### `FULL` — Server full

Sent when no bot slot is available to displace. The client should show an error
and not retry until the user requests reconnection.

---

#### Snapshot

One UDP datagram per snapshot; lines separated by `\n`. The datagram always
contains all sections in this order: `S`, `F`, `P` (×N), then zero or more
event lines (`K`, `G`, `T`, `D`, `H`, `C`, `B`).

---

##### `S` — Match state

```
S|gamePhase|phase|roundTime|score1|score2|roundN|loadout|roundWinner|matchOver|matchWinner|introTimer|endTimer
```

| Index | Field | Type | Values |
|-------|-------|------|--------|
| 2 | `gamePhase` | string | `waiting` `intro` `active` `overtime` `roundend` `matchend` |
| 3 | `phase` | string | `idle` `active` `overtime` `ended` (inner match-state phase) |
| 4 | `roundTime` | float, 1 dp | Seconds remaining in the round (counts down from 40) |
| 5 | `score1` | int | Round wins for team 1 (blue) |
| 6 | `score2` | int | Round wins for team 2 (red) |
| 7 | `roundN` | int | Current round number (1-based) |
| 8 | `loadout` | string | `Cazador` `Asaltante` `Sigiloso` `Bombardero` or `-` |
| 9 | `roundWinner` | int | −1 = none, 0 = draw, 1 = blue, 2 = red |
| 10 | `matchOver` | bool | `1` if the match has ended |
| 11 | `matchWinner` | int | `0` none, `1` blue, `2` red |
| 12 | `introTimer` | float, 2 dp | Countdown to round start (0 when not in `intro`) |
| 13 | `endTimer` | float, 2 dp | Countdown to round-end banner dismissal |

**`gamePhase` state machine:**

```
waiting ──(first join)──► intro ──(2.5 s)──► active
                                                 │
                              ◄──(team wiped)────┤
                              ▼                  │
                           roundend ◄──(40 s + capture/timeout)── overtime
                              │
                    (4 wins?)─┼─yes──► matchend ──(6 s)──► intro (new match)
                              │
                             no──► intro (next round)
```

---

##### `F` — Flag

```
F|active|x|y|r|capFrac|capTeam|overtimeLeft
```

| Index | Field | Type | Notes |
|-------|-------|------|-------|
| 2 | `active` | bool | `1` = flag is on the field (overtime only) |
| 3 | `x` | float, 1 dp | Center X of the capture zone |
| 4 | `y` | float, 1 dp | Center Y |
| 5 | `r` | float, 1 dp | Capture zone radius (pixels) |
| 6 | `capFrac` | float, 2 dp | Capture progress [0.0, 1.0] |
| 7 | `capTeam` | int | `0` = neutral, `1` = blue capturing, `2` = red |
| 8 | `overtimeLeft` | float, 1 dp | Seconds remaining in overtime; 0 when not in overtime |

---

##### `P` — Player

One line per player (all 2 or 4 players are always included):

```
P|id|team|x|y|aim|hp|alive|state|slot|wname|ammo|mag|reloading|reserve
```

| Index | Field | Type | Notes |
|-------|-------|------|-------|
| 2 | `id` | int | 1–8, matches `playerID` from `W` |
| 3 | `team` | int | `1` = blue, `2` = red |
| 4 | `x` | float, 1 dp | Authoritative position X |
| 5 | `y` | float, 1 dp | Authoritative position Y |
| 6 | `aim` | float, 3 dp | Heading in radians [0, 2π) |
| 7 | `hp` | float, 1 dp | Current HP [0.0, 100.0] |
| 8 | `alive` | bool | `0` = dead |
| 9 | `state` | string | `idle` `walking` `firing` `aiming` `dead` |
| 10 | `slot` | string | Active weapon slot name (e.g. `primary`, `secondary`) |
| 11 | `wname` | string | Active weapon name (e.g. `Rifle de Asalto`) or `-` |
| 12 | `ammo` | int | Rounds in the magazine |
| 13 | `mag` | int | Magazine capacity |
| 14 | `reloading` | bool | `1` if reload animation is in progress |
| 15 | `reserve` | int | Rounds remaining in the reserve (backpack) |

The client interpolates `x`/`y` to produce smooth `rpos` using exponential
smoothing (`k = 1 − e^(−22·dt)`). Position jumps > 140 px (respawn) are
snapped immediately without interpolation.

---

##### `K` — Smoke cloud (active)

One line per active smoke cloud:

```
K|x|y|r
```

The complete set of active smokes is sent every snapshot. The client resets its
smoke pool counter at the start of each `S` line and repopulates it from `K`
lines.

---

##### `G` — Grenade in flight

One line per grenade currently airborne:

```
G|x|y
```

Same repopulation pattern as `K`.

---

##### `T` — Tracer (this tick)

One line per hitscan or melee tracer emitted this tick:

```
T|x1|y1|x2|y2|r|g|b
```

| Field | Notes |
|-------|-------|
| `x1/y1` | Origin (shooter position) |
| `x2/y2` | Terminal point (hit or max range) |
| `r/g/b` | Tracer colour [0.0, 1.0]; defined per weapon in `weapon.go` |

Tracers are ephemeral — they are emitted once and the client animates them
locally. The client does not need to clear them from a pool.

---

##### `D` — Kill event

One line per kill that occurred since the last snapshot:

```
D|victim|killer|weaponID
```

| Field | Notes |
|-------|-------|
| `victim` | Player ID of the dead player |
| `killer` | Player ID of the attacker; `0` if environmental |
| `weaponID` | Weapon key string (e.g. `rifle`, `knife`) — not the display name |

The client uses this to populate the killfeed. If the UDP packet carrying `D`
is lost, the killfeed entry is silently missed; gameplay is unaffected.

---

##### `H` — Hit confirmation

One line per hit that occurred since the last snapshot:

```
H|attacker|isKill
```

Only the client whose `myId` matches `attacker` renders a hitmarker. `isKill`
is `1` if this hit was the killing blow.

---

##### `C` — Cover HP

One line per *active* (not yet destroyed) cover, every snapshot:

```
C|id|hp
```

Sending the full active set every snapshot serves as self-healing: if the
client missed a previous `C`, the next snapshot corrects it. Absent covers
(not listed) are detected by the client's `seen`-tick check and marked as
broken.

---

##### `B` — Cover break (server → client)

One line per cover destroyed this tick:

```
B|id
```

Triggers immediate debris particle burst and removes the cover from rendering.
If this line is lost on UDP, the `C` autocorrection mechanism detects the cover
is absent in the next snapshot and calls `_breakCover` silently.

---

##### `q` — Pong (response to `Q`)

```
q|timestamp
```

Echo of the client's timestamp. The client computes:
```
rtt_sample_ms = (now − sent_timestamp) × 1000
rtt           = rtt × 0.7 + rtt_sample_ms × 0.3
```

---

## Bandwidth

```
Input  (client → server): ~30 B/packet × 60 Hz = 1.8 KB/s per client
Snapshot (server → all):  ~400 B/snap × 30 Hz  = 12 KB/s (same datagram to all clients)

Per-client total: ≈ 14 KB/s upstream + 1.8 KB/s downstream = ~0.13 Mbps
```

At 27% of the 1472-byte MTU per snapshot, fragmentation is not a concern for
up to 4v4. At 8v8 (~800 B/snap), fragmentation risk increases; interest
management would be required.

---

## Security

### Implemented

| Threat | Mitigation |
|--------|-----------|
| Fake position | Server never reads position from client; it computes position server-side and clamps movement input to [−1, 1] |
| Fake damage | Damage is computed server-side from authoritative raycast results; client `D` packets are ignored |
| Speed hack | Movement input clamped; `MoveAndSlide` enforces arena bounds on server |
| Input injection from unknown address | Packets from addresses without an active session are silently dropped |
| Malformed packets | `DecodeInput` returns `ok=false` on parse failure; the packet is dropped without logging |
| Session exhaustion | Max 8 sessions (hardcoded player count); `FULL` is returned when no bot slot is available |
| Inactivity zombies | Sessions with no packet for 5 s are removed and the slot returned to bot control |

### Not yet implemented

| Threat | Status | Roadmap |
|--------|--------|---------|
| Per-IP packet flood (DoS) | ❌ No rate limiter | [PLAN.md](../PLAN.md) Phase 3 |
| Session spoofing (forged source IP) | ⚠️ Mitigated by UDP source address tracking; no cryptographic token | Phase 3 |
| `panic` in simulation crashes server | ❌ No `recover()` guard in main loop | Phase 3 |

---

## BNF Grammar

```
packet    ::= join | input | ping | bye | welcome | snapshot | full | pong

join      ::= "J"
input     ::= "I" "|" INT "|" INT "|" INT "|" FLOAT4 "|" INT
ping      ::= "Q" "|" FLOAT4
bye       ::= "B"

welcome   ::= "W" "|" INT "|" INT "|" F1 "|" F1 "|" F1 "|" F1
              ("\n" wall)*
              ("\n" box)*
full      ::= "FULL"
pong      ::= "q" "|" FLOAT4

wall      ::= "WALL" "|" F1 "|" F1 "|" F1 "|" F1
box       ::= "BOX"  "|" INT "|" F1 "|" F1 "|" F1 "|" F1 "|" INT

snapshot  ::= state "\n" flag ("\n" player)+ event*
state     ::= "S" "|" PHASE "|" PHASE "|" F1 "|" INT "|" INT "|" INT "|" STR
              "|" INT "|" BOOL "|" INT "|" F2 "|" F2
flag      ::= "F" "|" BOOL "|" F1 "|" F1 "|" F1 "|" F2 "|" INT "|" F1
player    ::= "P" "|" INT "|" INT "|" F1 "|" F1 "|" F3 "|" F1 "|" BOOL
              "|" STR "|" STR "|" INT "|" INT "|" BOOL "|" INT
event     ::= smoke | grenade | tracer | kill | hit | cover_hp | cover_break
smoke     ::= "\n" "K" "|" F1 "|" F1 "|" F1
grenade   ::= "\n" "G" "|" F1 "|" F1
tracer    ::= "\n" "T" "|" F1 "|" F1 "|" F1 "|" F1 "|" F2 "|" F2 "|" F2
kill      ::= "\n" "D" "|" INT "|" INT "|" STR
hit       ::= "\n" "H" "|" INT "|" BOOL
cover_hp  ::= "\n" "C" "|" INT "|" INT
cover_brk ::= "\n" "B" "|" INT

INT    ::= "-"? [0-9]+
F1     ::= "-"? [0-9]+ "." [0-9]
F2     ::= "-"? [0-9]+ "." [0-9]{2}
F3     ::= "-"? [0-9]+ "." [0-9]{3}
F4     ::= "-"? [0-9]+ "." [0-9]{4}
BOOL   ::= "0" | "1"
PHASE  ::= "waiting"|"intro"|"active"|"overtime"|"roundend"|"matchend"
         | "idle"|"ended"
STR    ::= [^\n|]+
```

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.1 | 2026-06-05 | Corrected port (`:9999`→`:40000`); corrected ping response (`PONG`→`q`); corrected `D` field order (victim before killer); corrected `btn` and `mx/my` encoding (decimal integers); expanded `S` (13 fields) and `P` (15 fields); added `K`, `G`, `T` message types; moved unimplemented security items to TODO |
| 1.0 | 2026-06-04 | Initial specification |
