# Runbook — Gulag Arena

Operational procedures for diagnosing and resolving common issues in
production or local LAN deployments.

---

## Table of Contents

1. [Server Won't Start](#server-wont-start)
2. [Client Can't Connect](#client-cant-connect)
3. [High Latency / Lag Spikes](#high-latency--lag-spikes)
4. [Players Rubberbanding](#players-rubberbanding)
5. [Server Crashed](#server-crashed)
6. [Clients Desync After Cover Destruction](#clients-desync-after-cover-destruction)
7. [Bots Not Moving](#bots-not-moving)
8. [Match Stuck in "waiting" Phase](#match-stuck-in-waiting-phase)
9. [Key Metrics Reference](#key-metrics-reference)

---

## Server Won't Start

**Symptom:** `no se pudo iniciar el servidor: ...` on startup, or immediate exit.

**Diagnosis steps:**

1. Check if the port is already in use:
   ```bash
   # Linux / macOS
   ss -ulnp | grep 40000
   # or
   lsof -iUDP:40000
   ```
   If occupied: kill the conflicting process, or start the server on a
   different port with `-addr :40001`.

2. Check bind permission. Ports < 1024 require root on Linux. Use a port
   ≥ 1024 (default `:40000` is fine).

3. Verify the binary was compiled for the correct platform:
   ```bash
   file ./dist/server-linux-amd64
   # Expected: ELF 64-bit LSB executable, x86-64
   ```

---

## Client Can't Connect

**Symptom:** Client stays on "Conectando…" indefinitely, or logs no
`Jugador N se unió` on the server.

**Diagnosis steps:**

1. Confirm the server is running and listening:
   ```bash
   ss -ulnp | grep 40000
   ```

2. Test UDP reachability from the client host:
   ```bash
   # Requires netcat with UDP support
   echo "J" | nc -u <server-ip> 40000
   ```
   A `W|…` response confirms the server is reachable.

3. Verify `HOST` and `PORT` in `main.lua` match the server address.

4. Check firewall rules on the server:
   ```bash
   sudo ufw status verbose | grep 40000
   ```

5. If the server is behind NAT or a cloud provider: ensure UDP 40000 is
   port-forwarded or in the security group's inbound rules.

6. The client retries `J` every 250 ms until it receives `W`. If `W` arrives
   but the client still shows "Conectando…", the welcome packet may be
   malformed (check server logs with `-debug`).

---

## High Latency / Lag Spikes

**Symptom:** F1 overlay shows RTT > 150 ms, or visible teleporting of
remote players.

**Diagnosis:**

1. Open the **F1 debug overlay** on the client. Check:
   - `RTT`: the smoothed round-trip time. Values > 150 ms indicate a
     network path problem.
   - `snap/s`: should be ~30. Values < 25 indicate server overload or
     packet loss.
   - `pkt B`: snapshot size. Should be 350–500 bytes.

2. Check server CPU from the `-debug` log:
   ```
   [stats] 60 tick/s · 30 snap/s · in 1.8 kB/s · out 14.7 kB/s · 60 pkt/s · 2 sesiones
   ```
   If `tick/s` < 55, the main loop is falling behind. Cause: OS scheduling
   jitter or CPU contention. Mitigation: reduce other workloads on the server.

3. Verify network bandwidth. At 2 clients × 14.7 kB/s ≈ 30 kB/s outbound.
   A server uplink < 1 Mbps is not the bottleneck.

4. If RTT is stable but snap/s is low: check for UDP packet loss with:
   ```bash
   ping -c 100 <server-ip>   # Should show < 1% loss
   ```

---

## Players Rubberbanding

**Symptom:** A specific player's position snaps back repeatedly.

**Root cause:** The client is receiving snapshots but the server's authoritative
position differs from what the client predicted. This is expected behaviour —
the client interpolates, not predicts. Rubberbanding occurs when:

- Input packets are arriving late or being dropped (check `in kB/s` in server
  `-debug` stats; should be ~1.8 kB/s per connected human).
- The client's `love.update()` loop is not running at the expected 60 FPS
  (check `FPS` in F1 overlay).

**Mitigation:**

- Rubberbanding > 140 px triggers a position snap in the client (intentional,
  see `SNAP_DIST2` in `netclient.lua`). This covers respawns cleanly.
- For persistent rubberbanding of non-local players: the other player may have
  high packet loss. No workaround without client-side prediction.

---

## Server Crashed

**Symptom:** Server process exited unexpectedly.

**Current state:** The server has no `recover()` guard around the simulation
loop. A panic in `world.Step()` or `broadcast()` will terminate the process.
This is a known gap tracked in [PLAN.md](PLAN.md) Phase 3.

**Immediate recovery:**

```bash
# Restart the server
./dist/server-linux-amd64 -debug 2>&1 | tee server.log &

# Or with systemd
sudo systemctl restart gulag-arena
sudo journalctl -u gulag-arena -n 50
```

**Root-cause investigation:**

```bash
# Inspect the last lines before the crash
tail -50 server.log

# Look for Go panic stack trace
grep -A 30 "goroutine" server.log
```

Common causes and fixes:

| Symptom in log | Root cause | Fix |
|---------------|-----------|-----|
| `index out of range` | Player ID outside `[0, len(Players))` | Validate IDs in `ApplyInput` — already done; check for regression |
| `nil pointer dereference` in weapon code | Player with no active weapon slot | Ensure `ActiveWeapon()` nil-check paths are covered |
| `send on closed channel` | `readLoop` writing to `incoming` after `conn.Close()` | Graceful shutdown not yet implemented; restart is the fix |

---

## Clients Desync After Cover Destruction

**Symptom:** One client sees a cover as standing while another sees it
destroyed.

**Expected behaviour:** The server sends:
- `B|id` on the tick a cover breaks (event-driven, may be lost on UDP).
- `C|id|hp` for all *active* covers in every snapshot (self-healing).

If a client missed the `B` event AND the following `C` messages don't list
the cover (because it's destroyed), the client's snapshot-tick autocorrection
will mark it broken within one snapshot period (33 ms).

If desync persists beyond 100 ms, it indicates a bug in the cover autocorrection
logic in `netclient.lua` (`_breakCover`). Check:

```lua
-- netclient.lua ~line 350
if c and c.active and not c.broken and c.seen ~= self.snapTick then
    self:_breakCover(id)
end
```

Ensure `coversMaxId` is set correctly when the welcome message is received.

---

## Bots Not Moving

**Symptom:** Bot players stand still; the game runs but AI is inactive.

**Diagnosis:**

1. Verify the game phase. Bots only think during `active` and `overtime`:
   ```go
   // world.go
   case "active", "overtime":
       w.stepBots(dt)
   ```
   Check the F1 overlay `fase` field. If it shows `waiting` or `intro`, bots
   are intentionally idle.

2. Confirm at least one human has joined (phase stays `waiting` until `Start()`
   is called on the first join).

3. Check that `IsBot` is `true` for the non-human player slots. After a human
   disconnects, `freeSlot()` in `server.go` sets `IsBot = true`.

---

## Match Stuck in "waiting" Phase

**Symptom:** F1 overlay shows `fase: waiting` indefinitely after a client
connects.

**Root cause:** `world.Start()` is called on the first `J` that gets assigned a
slot. If all slots are occupied by human sessions (no bot to displace), `Start()`
is never called.

**Diagnosis:**

```bash
# Enable debug logging and watch for:
# "Jugador N se unió" — client joined
# "── Ronda 1 ──" — first round started
./server -debug
```

If `Jugador N se unió` appears but no round starts: the `assignSlot()` function
returned 0 (no bot slot available), the join was rejected with `FULL`, and
`Start()` was never called. This means all bot slots have active human sessions.
Wait for a session timeout (5 s of inactivity) or restart the server.

---

## Key Metrics Reference

These appear in the server `-debug` log every 5 seconds:

```
[stats] 60 tick/s · 30 snap/s · in 1.8 kB/s · out 14.7 kB/s · 60 pkt/s · 2 sesiones
```

| Metric | Healthy range | Action if outside range |
|--------|--------------|------------------------|
| `tick/s` | 58–62 | < 55: check CPU load on server host |
| `snap/s` | 28–32 | < 25: check CPU; > 35 is not possible (hardcoded 30 Hz) |
| `in kB/s` | 1.8 × N clients | Much higher: possible packet flood; add rate limiting (Phase 3) |
| `out kB/s` | ~14–15 per broadcast | Much lower: broadcast may be failing silently |
| `sesiones` | ≥ 1 | 0: all clients disconnected or timed out |

And on the client F1 overlay:

| Metric | Healthy range | Action if outside range |
|--------|--------------|------------------------|
| `FPS` | 55–60 | < 45: reduce window resolution or disable vsync |
| `RTT` | 20–150 ms | > 200 ms: network path issue |
| `snap/s` | 28–32 | < 20: packet loss or server overloaded |
| `interp err` | < 5 px | > 20 px: sustained rubberbanding, see above |
