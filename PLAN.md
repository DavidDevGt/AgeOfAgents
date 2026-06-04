# PLAN DE PRODUCCIÓN — Gulag Arena

**Fecha de creación**: 2026-06-04  
**Estado actual**: MVP funcional (core de red, gameplay, UI)  
**Objetivo**: Transición a producto distribuible y operacional

---

## 📊 ESTADO ACTUAL

### ✅ Lo que ya funciona

| Componente | Estado | Validación |
|------------|--------|-----------|
| Backend Go (autoridad) | ✅ Completo | 7+ tests, verificado con clientes reales |
| Cliente LÖVE (presentación) | ✅ Completo | Sprites procedurales, HUD sin GC, 60+ FPS |
| Protocolo UDP (red) | ✅ Completo | BOX/C/B para coberturas, H para impactos, D para bajas |
| Arena (diseño) | ✅ Completo | Simétrica, 3 carriles, 12 parapetos destruibles |
| Sistemas de juego | ✅ Completo | Colisión, raycast, interpolación, feedback visual |
| Integración E2E | ✅ Verificada | Server + cliente conectan y comunican datos reales |

### ❌ Lo que falta para producción

| Área | Prioridad | Blocker |
|------|-----------|---------|
| Build automatizado | Alta | No se puede distribuir sin esto |
| Configuración externa | Alta | No se puede escalar a múltiples entornos |
| Logging + métricas | Media | No se puede debuggear en producción |
| Validación de protocolo | Alta | DoS risk sin validación |
| Persistencia de cliente | Media | Pobre UX sin recordar settings |
| Docker + Kubernetes | Media | No se puede desplegar en la nube |
| Matchmaking/Lobby | Media | No se puede escalar a múltiples servidores |
| CI/CD | Alta | Releases manuales = error humano |
| Documentación operativa | Media | Ops no puede mantener sin runbooks |

---

## 🎯 ROADMAP (10 Fases)

### Fase 0 — Preparación
**Objetivo**: Estructura de repositorio y documentación base  
**Duración**: 1 día  
**Tareas**:
- [ ] Crear `LICENSE` (MIT)
- [ ] Crear `NOTICE` con créditos de terceros (Love2D, Go modules)
- [ ] Crear `.gitignore` completo (Go, Lua, LÖVE artifacts)
- [ ] Crear directorio `scripts/` para build/deploy
- [ ] Crear `CONTRIBUTING.md` (guía de desarrollo)
- [ ] Crear `CHANGELOG.md` vacío (para registrar versiones)

**Archivo(s)**: `LICENSE`, `NOTICE`, `.gitignore`, `CONTRIBUTING.md`, `CHANGELOG.md`

---

### Fase 1 — Empaquetado y Build
**Objetivo**: Generar artefactos distribuibles (binario Go + `.love`)  
**Duración**: 3 días  
**Tareas**:
- [ ] **Backend**:
  - [ ] Script `scripts/build-backend.sh` (Go build, cross-compile para Linux/macOS/Windows)
  - [ ] Versionar binario con `git describe --tags` (ej. `v0.1.0-5-gabcd123`)
  - [ ] Salida a `dist/server-linux`, `dist/server-windows.exe`, `dist/server-darwin`
- [ ] **Cliente**:
  - [ ] Script `scripts/build-client.sh` que:
    - [ ] Valida sintaxis Lua (`luacheck` o similar)
    - [ ] Empaqueta `src/`, `main.lua`, `conf.lua` en `dist/gulag_arena.love`
    - [ ] Opcionalmente crea `.exe` (usando `love.exe` + `cat gulag_arena.love > gulag_arena.exe`)
- [ ] **Makefile/justfile** que invoque ambos scripts y genere checksums (SHA256)
- [ ] Probar build en Windows, Linux (Docker) y macOS (si disponible)
- [ ] Documentar en `DEPLOY.md` cómo compilar localmente

**Archivo(s)**: `scripts/build-backend.sh`, `scripts/build-client.sh`, `Makefile` (o `justfile`), `DEPLOY.md` (sección "Build local")

**Dependencias**: Fase 0

---

### Fase 2 — Configuración Externa y Logs
**Objetivo**: Hacer servidor y cliente configurables sin recompilar  
**Duración**: 2 días  
**Backend**:
- [ ] Leer variables de entorno:
  - [ ] `SERVER_ADDR` (default `:40000`)
  - [ ] `SERVER_MODE` (default `1`; 1=1v1, 2=2v2)
  - [ ] `LOG_LEVEL` (default `info`; values: `debug`, `info`, `warn`, `error`)
  - [ ] `LOG_FILE` (default `stdout`; si no vacío, escribir a archivo)
  - [ ] `RATE_LIMIT_PER_IP` (default `1000`; paquetes/segundo)
- [ ] Reemplazar `log.Printf` por logger estructurado (`logrus` o `zap`)
- [ ] Logs a stdout y a archivo (`server.log`) con timestamps y niveles
- [ ] Documentar en `DEPLOY.md` las variables disponibles y valores recomendados

**Cliente**:
- [ ] Crear `config.lua` en `love.filesystem` que guarde:
  - [ ] `windowMode` (windowed / fullscreen)
  - [ ] `width`, `height` (resolución)
  - [ ] `vsync` (0 o 1)
  - [ ] `volume` (0.0 to 1.0)
  - [ ] `serverHost`, `serverPort` (opcionalmente recuerdos del último servidor)
- [ ] Leer desde `love.filesystem` al iniciar; si no existe, usar defaults
- [ ] Exponer en la pantalla de Configuración (UI existente) los controles para cambiar estos valores
- [ ] Guardar cambios en `config.lua` cuando el usuario confirme

**Archivo(s)**: Backend modificado (cmd/server/main.go), `config.lua` (generado en `love.filesystem`), `DEPLOY.md` (sección "Configuración")

**Dependencias**: Fase 0, Fase 1

---

### Fase 3 — Robustez y Seguridad
**Objetivo**: Prevenir crashes y abusos; mejorar experiencia en redes inestables  
**Duración**: 3 días  
**Backend**:
- [ ] **Validación estricta de protocolo** (`protocol.go` / `server.go`):
  - [ ] Rangos de coordenadas (dentro de `bounds`)
  - [ ] IDs de jugador (1 ≤ id ≤ maxPlayers)
  - [ ] Máscara de botones (0 ≤ btn < 32)
  - [ ] Tamaño de paquete máximo (rechazar > 2048 bytes)
  - [ ] Longitud de campos de string (ej. nombre ≤ 32 caracteres)
- [ ] **Rate limiting por IP** (`golang.org/x/time/rate`):
  - [ ] Máximo `RATE_LIMIT_PER_IP` paquetes/segundo por dirección
  - [ ] Pasado ese límite, dropear paquetes silenciosamente (log WARN)
  - [ ] Hacer configurable vía variable de entorno
- [ ] **Timeouts de red**:
  - [ ] Timeout de lectura UDP (500ms)
  - [ ] Desconectar jugador si inactivo > 5 segundos (actual)
- [ ] **Panic recovery**: Envolver `Step` y `broadcast` en `defer` que loguee panic sin crashear el servidor

**Cliente**:
- [ ] **Reconexión automática**:
  - [ ] Al perder conexión, entrar a estado `CONNECTING` y reintentar cada 1s
  - [ ] Back-off exponencial (1s, 2s, 4s, 8s, máx 30s)
  - [ ] Mostrar en UI: "Reintentando… (intento 3)" con icono de carga
  - [ ] Cancelable con ESC
- [ ] **Timeout de conexión inicial**: Si no se conecta en 10s, mostrar error "No responde el servidor"
- [ ] **Validación de snapshots**: Si un snapshot llega malformado, loguear error y no procesarlo (no crashear)

**Tests**:
- [ ] Añadir test para rate-limit (spawn sesiones falsas, enviar 2000 paquetes, verificar drop)
- [ ] Añadir test para validación (enviar coordenadas fuera de bounds, verificar rechazo)

**Archivo(s)**: Backend modificado (protocol.go, server.go, world.go), client modificado (netclient.lua, main.lua), tests añadidos (world_test.go)

**Dependencias**: Fase 1, Fase 2

---

### Fase 4 — Persistencia de Ajustes Cliente
**Objetivo**: Recordar preferencias entre sesiones  
**Duración**: 2 días  
**Tareas**:
- [ ] Implementar lectura/escritura de `config.lua` en `love.filesystem`:
  ```lua
  -- En ui_manager.lua o main.lua:
  local function loadConfig()
    local data = love.filesystem.read("config.lua")
    if data then
      local fn = load(data)
      return fn() or {}
    end
    return {}
  end

  local function saveConfig(cfg)
    local str = serializeTable(cfg) -- convertir tabla a Lua code
    love.filesystem.write("config.lua", str)
  end
  ```
- [ ] Vincular valores guardados a `love.window.setMode`:
  - [ ] Al cargar: aplicar `width`, `height`, `windowMode`, `vsync`
  - [ ] Al cambiar en UI: guardar inmediatamente
- [ ] Para volumen (futura expansión con audio): aplicar `love.audio.setVolume(cfg.volume)`
- [ ] Mostrar en UI de Configuración: resolución (dropdown o input), modo ventana (toggle), vsync (toggle)
- [ ] Validar que resoluciones cargadas sean válidas (no > límites de pantalla)

**Tests**: Prueba manual (cambiar settings, cerrar, reabre, verifica que se recuerden)

**Archivo(s)**: ui_manager.lua o main.lua modificado, config.lua (generado en love.filesystem)

**Dependencias**: Fase 2

---

### Fase 5 — Docker y Despliegue
**Objetivo**: Permitir despliegue en contenedores y orquestadores  
**Duración**: 3 días  
**Tareas**:
- [ ] **Dockerfile**:
  ```dockerfile
  # Builder stage
  FROM golang:1.22-alpine AS builder
  WORKDIR /build
  COPY backend .
  RUN go build -o server ./cmd/server

  # Runtime stage
  FROM alpine:latest
  COPY --from=builder /build/server /usr/local/bin/server
  EXPOSE 40000/udp
  CMD ["server"]
  ```
  - [ ] Usar imagen `distroless` o `alpine` (pequeña, segura)
  - [ ] Exponer puerto UDP 40000
  - [ ] Pasar variables de entorno (SERVER_ADDR, LOG_LEVEL, etc.)
  
- [ ] **docker-compose.yml** para pruebas locales:
  ```yaml
  version: '3.9'
  services:
    server:
      build: ./backend
      ports:
        - "40000:40000/udp"
      environment:
        LOG_LEVEL: debug
        SERVER_ADDR: ":40000"
    client1:
      image: love:0.10.2  # imagen custom con love instalado
      environment:
        SERVER_HOST: server
        SERVER_PORT: 40000
  ```
  - [ ] Verificar que servidor y clientes se comunican dentro de la red Docker

- [ ] **Helm Chart** (`helm/gulag-arena/`):
  - [ ] `Chart.yaml`, `values.yaml`, `templates/deployment.yaml`
  - [ ] Configurar réplicas, limites de recursos (CPU/memoria)
  - [ ] Service UDP (LoadBalancer o ClusterIP)
  - [ ] ConfigMap para variables de entorno
  - [ ] PodDisruptionBudget (minAvailable=1 si hay 2+ réplicas)
  
- [ ] Probar en `kind` o `k3s` (localmente o en VM)
- [ ] Documentar en `DEPLOY.md` (sección "Docker" y "Kubernetes")

**Archivo(s)**: `Dockerfile`, `docker-compose.yml`, `helm/gulag-arena/`, `DEPLOY.md` (secciones "Docker", "Kubernetes")

**Dependencias**: Fase 1, Fase 2

---

### Fase 6 — Matchmaking / Lobby (Opcional)
**Objetivo**: Facilitar búsqueda de partidas sin compartir IPs manualmente  
**Duración**: 5 días  
**Tareas**:
- [ ] **Backend "Lobby"** (`cmd/lobby/main.go`):
  - [ ] Servicio HTTP simple (puerto 8080) que mantiene lista de rooms
  - [ ] Endpoints:
    - [ ] `POST /rooms/create` → crea room, devuelve `{roomID, addr}` 
    - [ ] `GET /rooms` → lista rooms activos (playerCount, maxPlayers)
    - [ ] `POST /rooms/{id}/join` → marca join, devuelve `{addr}`
  - [ ] Rooms expiran después de 5 min sin actividad
  - [ ] Cada room guarda direcciones de los servidores de juego (con heartbeat)

- [ ] **Cliente** (modificar `main.lua`):
  - [ ] Pantalla de Lobby (en UI existente):
    - [ ] Botón "Crear partida" → POST /rooms/create → muestra QR o código de room ID
    - [ ] Botón "Unirse" → input de ID → GET /rooms/{id} → GET /rooms/{id}/join → obtiene `addr`
    - [ ] Modo offline (input directo de HOST:PORT para pruebas)
  - [ ] Al obtener `addr`, conectar a ese servidor y entrar a PLAY
  - [ ] Opcionalmente: pasar `HOST:PORT` vía argumentos CLI a `love .` para automatizar

- [ ] **Documentación en `DEPLOY.md`**: cómo correr el lobby, escalar a múltiples servidores

**Archivo(s)**: `cmd/lobby/main.go`, UI modificado (main.lua), `DEPLOY.md` (sección "Matchmaking")

**Dependencias**: Fase 1, Fase 5 (opcional pero recomendado si hay múltiples servidores)

---

### Fase 7 — Métricas y Observabilidad
**Objetivo**: Exportar datos para monitoreo en producción  
**Duración**: 2 días  
**Tareas**:
- [ ] **Endpoint `/metrics`** en el servidor (formato Prometheus):
  - [ ] `gulag_server_ticks_total` (counter)
  - [ ] `gulag_server_snapshots_per_second` (gauge)
  - [ ] `gulag_server_bandwidth_in_bytes` (counter)
  - [ ] `gulag_server_bandwidth_out_bytes` (counter)
  - [ ] `gulag_server_active_sessions` (gauge)
  - [ ] `gulag_server_avg_rtt_ms` (gauge, promedio de todos los clientes)
  - [ ] `gulag_server_process_uptime_seconds` (gauge)

- [ ] Usar librería `prometheus/client_golang` para exponer métricas

- [ ] Documentación en `DEPLOY.md`:
  - [ ] Cómo configurar Prometheus (ejemplo `prometheus.yml`)
  - [ ] Cómo visualizar en Grafana (dashboard JSON incluido)
  - [ ] Alertas básicas (ej. "si avg_rtt > 200ms por 2 min")

**Archivo(s)**: Backend modificado (server.go), `docs/prometheus.yml`, `docs/grafana-dashboard.json`, `DEPLOY.md` (sección "Observabilidad")

**Dependencias**: Fase 2, Fase 5

---

### Fase 8 — CI/CD (GitHub Actions)
**Objetivo**: Automatizar builds, tests y releases  
**Duración**: 3 días  
**Tareas**:
- [ ] **Workflow `.github/workflows/build.yml`**:
  - [ ] Trigger: push a main, PR
  - [ ] Job "build":
    - [ ] `go build ./cmd/server` (Linux, Windows, macOS)
    - [ ] `scripts/build-client.sh` (genera .love)
    - [ ] Subir artifacts a GitHub (release drafts)

- [ ] **Workflow `.github/workflows/test.yml`**:
  - [ ] Trigger: push a main, PR
  - [ ] `go test ./...`
  - [ ] `golangci-lint run` (linting)
  - [ ] (Opcional) `luacheck src/` (linting Lua)

- [ ] **Workflow `.github/workflows/release.yml`**:
  - [ ] Trigger: push de tag (ej. `v0.1.0`)
  - [ ] Compile binarios
  - [ ] Genera checksums (SHA256)
  - [ ] Crea GitHub Release con artefactos

- [ ] Añadir badges al `README.md`:
  - [ ] Build status
  - [ ] Latest release
  - [ ] License

**Archivo(s)**: `.github/workflows/*.yml`, `README.md` (badges)

**Dependencias**: Fase 1, Fase 3

---

### Fase 9 — Documentación Operativa
**Objetivo**: Facilitar adopción y mantenimiento  
**Duración**: 2 días  
**Tareas**:
- [ ] **`DEPLOY.md`** (consolidar desde fases anteriores):
  - [ ] Build local (Fase 1)
  - [ ] Variables de entorno (Fase 2)
  - [ ] Docker y Kubernetes (Fase 5)
  - [ ] Matchmaking (Fase 6, opcional)
  - [ ] Métricas (Fase 7)
  - [ ] Ejemplo: `SERVER_ADDR=:40001 go run ./cmd/server`

- [ ] **`RUNBOOK.md`** (guía de troubleshooting):
  - [ ] "El servidor tarda en responder" → revisar RTT en `/metrics`, memoria, CPU
  - [ ] "Cliente no puede conectarse" → verificar firewall (puerto 40000 UDP), HOST:PORT
  - [ ] "Tasa de frames cae" → revisar FPS en overlay F1, reducir resolución gráfica
  - [ ] "Logs no se escriben" → verificar permisos, directorio de `love.filesystem`

- [ ] **`README.md`** actualizado:
  - [ ] Badges de CI/CD, versión, licencia
  - [ ] Descripción corta
  - [ ] Links a DEPLOY.md, RUNBOOK.md, CONTRIBUTING.md
  - [ ] Comandos rápidos (build, run local, Docker)
  - [ ] Créditos y licencias

**Archivo(s)**: `DEPLOY.md`, `RUNBOOK.md`, `README.md`

**Dependencias**: Todas las fases anteriores

---

### Fase 10 — Pulido y Lanzamiento
**Objetivo**: Versión 1.0 lista para producción  
**Duración**: 5 días  
**Tareas**:
- [ ] **Revisión de código**:
  - [ ] `golangci-lint` sin warnings
  - [ ] `luacheck` sin warnings
  - [ ] No hay `panic` en código de producción (solo en tests/debug)
  - [ ] No hay `TODO` sin asignar

- [ ] **Prueba de carga** (staging):
  - [ ] Correr 5-10 partidas simultáneas (50-100 concurrencias)
  - [ ] Verificar memoria, CPU, bandwidth
  - [ ] Medir latencia (RTT) promedio
  - [ ] Documentar resultados en `PERFORMANCE.md`

- [ ] **Release Candidate (RC)**:
  - [ ] Crear tag `v0.1.0-rc.1`
  - [ ] Distribuir a usuarios internos (beta testers)
  - [ ] Recopilar feedback (bugs, UX, performance)
  - [ ] Documentar issues en GitHub Issues

- [ ] **Feedback loop** (1-2 semanas):
  - [ ] Corregir bugs críticos (bugs blocker)
  - [ ] Mejorar UI según feedback
  - [ ] Publicar RC.2, RC.3 si es necesario

- [ ] **Release estable**:
  - [ ] Crear tag `v0.1.0` (o versionado semántico acordado)
  - [ ] Publicar GitHub Release con notas de cambio
  - [ ] Anunciar en redes/comunidad

**Archivo(s)**: `PERFORMANCE.md`, GitHub Release notes, CHANGELOG.md actualizado

**Dependencias**: Todas las fases anteriores

---

## 📈 MATRIZ DE DEPENDENCIAS

```
Fase 0 (Preparación)
  ↓
Fase 1 (Build) ← Fase 2 (Config+Logs) ← Fase 3 (Robustez)
  ↓                    ↓
Fase 5 (Docker) ← Fase 7 (Métricas) ← Fase 4 (Persistencia)
  ↓
Fase 6 (Lobby, opcional)
  ↓
Fase 8 (CI/CD)
  ↓
Fase 9 (Documentación)
  ↓
Fase 10 (Lanzamiento)
```

---

## 🕐 ESTIMACIÓN DE TIEMPO TOTAL

| Fase | Duración | Parallelizable | Esfuerzo acumulado |
|------|----------|----------------|-------------------|
| 0 | 1 d | No | 1 d |
| 1 | 3 d | No | 4 d |
| 2 | 2 d | Con 1 | 6 d |
| 3 | 3 d | Con 2 | 9 d |
| 4 | 2 d | Con 3 | 11 d |
| 5 | 3 d | Con 4 | 14 d |
| 6 | 5 d | Con 5 | 19 d (16 d si se salta) |
| 7 | 2 d | Con 5 | 21 d (18 d si se salta 6) |
| 8 | 3 d | Sí, con todo | 24 d |
| 9 | 2 d | Sí, con todo | 26 d |
| 10 | 5 d | No | 31 d |

**Secuencia óptima** (con paralelización): **~20 días de tiempo calendario** (1 desarrollador a tiempo parcial, 4-6 horas/día).  
**Secuencia agresiva** (sin Fase 6): **~18 días**.

---

## 🎯 HITOS CLAVE (Propuesta)

| Hito | Fases completadas | Timeline |
|------|-------------------|----------|
| **Mvp v0.0.1** (current) | Core gameplay | Ahora (2026-06-04) |
| **v0.1.0-alpha** | Fases 0-3 | +2 semanas |
| **v0.1.0-beta** | Fases 0-8 | +4 semanas |
| **v0.1.0-rc** | Fases 0-9 + feedback | +5 semanas |
| **v0.1.0 (stable)** | Fases 0-10 | +6 semanas |

---

## 📝 CHECKLIST DE INICIO

Para **comenzar Fase 0**, verificar:

- [ ] Todos los tests pasan (`go test ./...`)
- [ ] Sintaxis Lua es válida (`luacheck src/`)
- [ ] No hay warnings o panics en ejecución local
- [ ] El protocolo está documentado (comentarios en protocol.go)
- [ ] Hay un README.md básico explicando cómo correr localmente

Para **comenzar Fase 1**, verificar:

- [ ] Fase 0 completada
- [ ] Tienes acceso a compilador Go (≥1.22) y Love2D (≥11.5)
- [ ] Has testado builds manuales en tu plataforma (Windows/Linux/macOS)

---

## 🔗 REFERENCIAS

- [Go Modules](https://golang.org/ref/mod)
- [Love2D Documentation](https://love2d.org/wiki/Main_Page)
- [Prometheus Metrics](https://prometheus.io/docs/concepts/metric_types/)
- [Kubernetes Best Practices](https://kubernetes.io/docs/concepts/configuration/overview/)
- [GitHub Actions Workflows](https://docs.github.com/en/actions/learn-github-actions)

---

## 💬 PREGUNTAS FRECUENTES

**P: ¿Es obligatorio hacer todas las fases?**  
R: No. Para un servidor privado/LAN, las Fases 0-4 son suficientes. Para escala pública, las Fases 0-9.

**P: ¿Puedo saltarme Fase 6 (Matchmaking)?**  
R: Sí, si los jugadores pueden coordinar IPs manualmente o si solo ejecutas 1-2 servidores.

**P: ¿Cómo sé que estoy listo para pasar de fase?**  
R: Cuando todos los `[ ]` de esa fase estén completos y los tests pasen.

**P: ¿Dónde reporto bugs encontrados durante el testing?**  
R: En GitHub Issues, con etiqueta `bug` y el commit/versión donde aparece.

---

**Última actualización**: 2026-06-04  
**Responsable**: Equipo de desarrollo
