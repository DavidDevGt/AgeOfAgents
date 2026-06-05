# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- MIT license
- `CONTRIBUTING.md` with development workflow and conventions
- `DEPLOY.md` with build, configuration, and container setup
- `RUNBOOK.md` with operational troubleshooting procedures
- `Makefile` with `build`, `test`, `lint`, `package`, and `clean` targets
- GitHub Actions CI workflow (build + test on every push and PR)
- Corrected `docs/PROTOCOL.md`: accurate port, message field counts, D-event order, btn encoding, K/G/T message types
- Corrected `docs/ARCHITECTURE.md`: port reference, unimplemented security items marked as TODO

---

## [0.1.0-alpha] — 2026-06-04

### Added
- Server-authoritative Go backend (60 Hz simulation, 30 Hz snapshots over UDP)
- LÖVE 11.5 / Lua client with procedural sprites, HUD, killfeed, and damage vignette
- 1v1 and 2v2 modes via `-mode` flag
- Symmetric arena with 4 static walls and 12 destructible covers
- Five weapons across four random loadouts per round: Rifle de Precisión, Rifle de Asalto, Pistola, Cuchillo, Granada de Humo
- Hitscan (rifle/pistol), melee (knife), and projectile (smoke grenade) weapon types
- Round timer (40 s) → Overtime flag capture (3 s uncontested) → sudden-death by HP
- Best-of-7 match format (first to 4 round wins)
- Bot AI: strafe, aim, fire, reload, overtime flag rush
- Linear interpolation with snap-on-teleport for smooth remote player rendering
- Authoritative hitmarkers (server-confirmed, not client-predicted)
- Destructible cover sync: `C` (HP updates) + `B` (break events) + snapshot autocorrection
- Client-side RTT measurement via `Q`/`q` ping-pong
- Debug overlay (F1): FPS, RTT, snap/s, player list, interpolation error
- Server telemetry: per-tick stats (logged every 5 s with `-debug`)
- 6 integration tests: loadout symmetry, damage, overtime capture, contested capture, sudden-death

[Unreleased]: https://github.com/daviddevgt/ageofagents/compare/v0.1.0-alpha...HEAD
[0.1.0-alpha]: https://github.com/daviddevgt/ageofagents/releases/tag/v0.1.0-alpha
