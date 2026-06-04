# Gulag Arena: 1v1 / 2v2 Showdown

Shooter táctico top-down con **backend autoritativo en Go** y **cliente en LÖVE (Lua)**.
La simulación (física, daño, rondas, overtime, bots) vive 100% en el servidor Go;
el cliente solo envía input y renderiza snapshots interpolados.

```
┌─────────────────┐   UDP (texto)   ┌──────────────────────────┐
│  Cliente LÖVE   │  ── I|... ──►   │   Servidor Go            │
│  (Lua)          │                 │   (autoridad)            │
│  · input        │   ◄── S|... ──  │   · simulación 60 Hz     │
│  · render/HUD   │   snapshots     │   · daño/colisión/rondas │
│  · interpolación│     30 Hz       │   · IA de bots           │
└─────────────────┘                 └──────────────────────────┘
```

## Requisitos
- [Go](https://go.dev) 1.24+
- [LÖVE](https://love2d.org) 11.5

## Cómo jugar

**1) Arranca el backend** (terminal 1):
```sh
cd backend
go run ./cmd/server            # 1v1 en :40000
# o:  go run ./cmd/server -mode 2 -addr :40000   # 2v2
```

**2) Arranca el cliente** (terminal 2):
```sh
love .
```
Pulsa **Enter** para conectar. Eres el jugador **Azul**; los huecos libres los
controlan bots en el servidor. Para jugar contra un servidor remoto, edita
`HOST`/`PORT` en [main.lua](main.lua).

### Controles
| Acción | Tecla |
|---|---|
| Mover | `WASD` |
| Apuntar | Ratón (360°) |
| Disparar | Click izq. |
| Apuntar (ADS) | Click der. |
| Recargar | `R` |
| Cambiar arma | `Q` |

## Mecánicas
- **Loadout simétrico** aleatorio por ronda (mismo equipo para todos).
- **Vida estricta** 100 HP, sin regeneración.
- **Timer 40 s → Overtime**: aparece la bandera central; 3 s dentro sin disputa = victoria.
- Armas **hitscan** (rifles/pistola), **melee** (cuchillo) y **proyectil** (humo que bloquea balas).

## Estructura

```
backend/                         # ── Autoridad (Go) ──
  cmd/server/main.go             # entrypoint + flags
  internal/game/                 # simulación pura (sin red)
    vec, collision, raycast, weapon, grenade, player, world (+ tests)
  internal/netcode/              # transporte
    protocol.go                  # codificación de mensajes UDP
    server.go                    # servidor UDP + sesiones + bucle de tick

main.lua                         # ── Cliente (LÖVE) ──
conf.lua
src/
  core/        class, vector
  entities/    bullet (trazadoras)
  net/         connection (UDP), netclient (protocolo + vista + input)
  render.lua   dibujado (arena, jugadores, bandera, HUD, banners)
```

## Pruebas
```sh
cd backend && go test ./...      # simulación: loadout, daño, overtime, captura, partida con bots
```
