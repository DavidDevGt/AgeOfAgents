-- src/render.lua
-- Renderizador estético de Gulag Arena (vista cenital / top-down). Dibuja la
-- "vista" de solo lectura que mantiene el NetClient; no toca red ni lógica.
--
-- Objetivos:
--   * Sprites PROCEDURALES (sin PNG): soldados con casco direccional + arma
--     según el loadout, granadas metálicas que giran, humo orgánico, base
--     militar con mástil e izado de bandera, HUD estilo COD y killfeed.
--   * 60+ FPS sin basura: CERO asignaciones de tablas en el hot-path. Reusamos
--     transformaciones (push/translate/rotate), colores escalares y texturas
--     pre-horneadas (src/render/assets.lua). Las únicas asignaciones por frame
--     son strings de HUD (números dinámicos), inevitables y baratas.
--   * Coherencia AUTORITATIVA: cada sprite se ancla en rpos (posición
--     interpolada del servidor) y usa el radio real de colisión (14 px).

local Assets = require("src.render.assets")

local PLAYER_RADIUS = 14      -- == game.PlayerRadius (backend autoritativo)
local MAX_HP        = 100     -- == game.MaxHP

local Render = {}

-- ---- Estado de animación del módulo (asignado UNA vez, nunca por frame) ----
local anim = {
    flagRaise = 0,            -- 0..1, izado gradual de la bandera en overtime
    floorQuad = nil,          -- quad cacheado del suelo tileado
    floorKey  = -1,           -- clave (w,h) para recrear el quad solo si cambia
}

-- Mapa nombre-de-arma (autoritativo, ver weapon.go) -> categoría de sprite.
local WKIND = {
    ["Rifle de Precisión"] = "sniper",
    ["Rifle de Asalto"]    = "rifle",
    ["Pistola"]            = "pistol",
    ["Cuchillo"]           = "knife",
    ["Granada de Humo"]    = "smoke",
}

-- Devuelve (r,g,b) base del equipo. team 1 = Azul, 2 = Rojo.
local function teamRGB(team)
    if team == 1 then return 0.30, 0.62, 1.0 end
    return 1.0, 0.45, 0.32
end

-- ============================================================================
-- ARENA: suelo de hormigón tileado + muros con volumen.
-- ============================================================================
local function drawArena(view)
    local g = love.graphics
    local b = view.bounds
    if b.w <= 0 then return end

    -- Suelo tileado (textura con wrap "repeat" + quad del tamaño de la arena).
    if Assets.loaded then
        if anim.floorKey ~= b.w * 100000 + b.h then
            anim.floorQuad = love.graphics.newQuad(0, 0, b.w, b.h, Assets.floor:getDimensions())
            anim.floorKey  = b.w * 100000 + b.h
        end
        g.setColor(1, 1, 1)
        g.draw(Assets.floor, anim.floorQuad, b.x, b.y)
    else
        g.setColor(0.10, 0.11, 0.13)
        g.rectangle("fill", b.x, b.y, b.w, b.h)
    end

    -- Borde de la arena.
    g.setColor(0.45, 0.40, 0.28)
    g.setLineWidth(4)
    g.rectangle("line", b.x, b.y, b.w, b.h)

    -- Muros con sombra proyectada + cara superior iluminada (sensación 2.5D).
    for i = 1, #view.walls do
        local w = view.walls[i]
        g.setColor(0, 0, 0, 0.35)
        g.rectangle("fill", w.x + 4, w.y + 5, w.w, w.h)           -- sombra
        g.setColor(0.26, 0.27, 0.31)
        g.rectangle("fill", w.x, w.y, w.w, w.h)                   -- cuerpo
        g.setColor(0.40, 0.42, 0.48)
        g.rectangle("fill", w.x, w.y, w.w, 4)                     -- borde sup. claro
        g.setColor(0.16, 0.17, 0.20)
        g.setLineWidth(2)
        g.rectangle("line", w.x, w.y, w.w, w.h)
    end
    g.setLineWidth(1)
end

-- ============================================================================
-- COBERTURAS DESTRUIBLES: parapetos de madera. El feedback de daño dibuja
-- grietas crecientes y baja el alpha según la vida restante (autoritativa).
-- ============================================================================
local function drawCovers(view)
    local g = love.graphics
    for id = 1, view.coversMaxId do
        local c = view.covers[id]
        if c and c.active then
            local x, y, w, h = c.x, c.y, c.w, c.h
            local frac = c.hp / c.maxhp            -- 1 intacta .. 0 a punto de romper
            if frac < 0 then frac = 0 end
            local a = 0.78 + 0.22 * frac           -- el daño la "desgasta" (alpha)

            -- Sombra proyectada.
            g.setColor(0, 0, 0, 0.30)
            g.rectangle("fill", x + 3, y + 4, w, h)
            -- Cuerpo de madera (marrón táctico) + tablones.
            g.setColor(0.46 * a, 0.30 * a, 0.16 * a, 1)
            g.rectangle("fill", x, y, w, h)
            g.setColor(0.56, 0.39, 0.21, a)
            g.rectangle("fill", x, y + h * 0.5 - 1, w, 2)        -- veta horizontal
            g.rectangle("fill", x + w * 0.5 - 1, y, 2, h)        -- veta vertical
            -- Refuerzos metálicos en las esquinas.
            g.setColor(0.32, 0.33, 0.36, a)
            g.rectangle("fill", x, y, 5, 5);          g.rectangle("fill", x + w - 5, y, 5, 5)
            g.rectangle("fill", x, y + h - 5, 5, 5);  g.rectangle("fill", x + w - 5, y + h - 5, 5, 5)
            -- Contorno.
            g.setColor(0.22, 0.14, 0.07, a)
            g.setLineWidth(2)
            g.rectangle("line", x, y, w, h)

            -- Grietas: aparecen progresivamente según el daño (deterministas).
            local cracks = math.floor((1 - frac) * 4 + 0.001)   -- 0..3
            if cracks > 0 then
                g.setColor(0.10, 0.06, 0.03, a)
                g.setLineWidth(1.5)
                local cx, cy = c.cx, c.cy
                for k = 1, cracks do
                    -- Ángulo estable por (id,k): sin asignaciones ni aleatoriedad.
                    local ang = (id * 1.7 + k * 2.3)
                    local ex = cx + math.cos(ang) * w * 0.5
                    local ey = cy + math.sin(ang) * h * 0.5
                    local mx = cx + math.cos(ang + 0.5) * w * 0.22
                    local my = cy + math.sin(ang + 0.5) * h * 0.22
                    g.line(cx, cy, mx, my)                       -- grieta quebrada
                    g.line(mx, my, ex, ey)
                end
            end
        end
    end
    g.setLineWidth(1)
end

-- ============================================================================
-- BANDERA / BASE MILITAR (overtime). Base + zona de captura + mástil con izado.
-- ============================================================================
local function drawFlag(view)
    local g = love.graphics
    local m = view.match
    local f = m.flag

    -- Izado gradual: rampa hacia 1 mientras la bandera está activa, reset si no.
    local dt = love.timer.getDelta()
    if f.active then
        anim.flagRaise = math.min(1, anim.flagRaise + dt * 0.45)   -- ~2.2 s
    else
        anim.flagRaise = 0
        return
    end

    local t   = love.timer.getTime()
    local frac, team = m.captureFrac, m.captureTeam
    local r, gg, bl = 0.95, 0.82, 0.25
    if team == 1 then r, gg, bl = 0.30, 0.62, 1.0
    elseif team == 2 then r, gg, bl = 1.0, 0.45, 0.32 end

    -- Zona de captura: disco translúcido pulsante + anillo.
    local pulse = 0.5 + 0.5 * math.sin(t * 2.2)
    g.setColor(r, gg, bl, 0.10 + 0.10 * pulse + 0.12 * frac)
    g.circle("fill", f.x, f.y, f.r)
    g.setColor(r, gg, bl, 0.85)
    g.setLineWidth(3)
    g.circle("line", f.x, f.y, f.r)

    -- Arco de progreso de captura.
    if team ~= 0 and frac > 0 then
        g.setColor(r, gg, bl, 1)
        g.setLineWidth(5)
        g.arc("line", "open", f.x, f.y, f.r + 9, -math.pi / 2, -math.pi / 2 + frac * 2 * math.pi)
    end
    g.setLineWidth(1)

    -- Base militar: plataforma + sacos terreros (anillo de elipses) + cajas.
    g.setColor(0.18, 0.16, 0.12)
    g.circle("fill", f.x, f.y, 30)
    g.setColor(0.32, 0.29, 0.20)
    for k = 0, 7 do
        local a = k * (math.pi / 4)
        g.ellipse("fill", f.x + math.cos(a) * 28, f.y + math.sin(a) * 28, 9, 7)
    end
    g.setColor(0.30, 0.26, 0.16)
    g.rectangle("fill", f.x - 16, f.y - 4, 12, 12, 2)             -- cajón de munición
    g.setColor(0.42, 0.36, 0.22)
    g.rectangle("line", f.x - 16, f.y - 4, 12, 12, 2)

    -- Mástil: poste vertical desde la base hacia arriba (pantalla: -y).
    local poleH = 64
    local topY  = f.y - poleH
    g.setColor(0.55, 0.55, 0.58)
    g.setLineWidth(3)
    g.line(f.x, f.y, f.x, topY)
    g.setColor(0.85, 0.85, 0.4)
    g.circle("fill", f.x, topY, 3)                               -- pomo del mástil

    -- Bandera: sube con flagRaise; ondea con sin(t); parpadea si capturan.
    local flagY = topY + (poleH - 22) * (1 - anim.flagRaise)
    local blink = 1
    if team ~= 0 and frac > 0 and frac < 1 then
        blink = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(t * 12))     -- parpadeo
    end
    local fr, fg, fb = 0.85, 0.75, 0.25
    if team == 1 then fr, fg, fb = 0.30, 0.62, 1.0
    elseif team == 2 then fr, fg, fb = 1.0, 0.45, 0.32 end
    local wv = math.sin(t * 4) * 3                               -- ondeo
    g.setColor(fr, fg, fb, blink)
    g.polygon("fill",
        f.x,      flagY,
        f.x + 30, flagY + 4 + wv,
        f.x + 30, flagY + 16 + wv,
        f.x,      flagY + 18)
    g.setColor(0, 0, 0, 0.25 * blink)
    g.polygon("line",
        f.x,      flagY,
        f.x + 30, flagY + 4 + wv,
        f.x + 30, flagY + 16 + wv,
        f.x,      flagY + 18)
    g.setLineWidth(1)
end

-- ============================================================================
-- GRANADAS: cilindros metálicos que rotan en vuelo (sombreado por primitivas).
-- ============================================================================
local function drawGrenades(view)
    local g = love.graphics
    local t = love.timer.getTime()
    for i = 1, view.grenadesN do
        local gr = view.grenades[i]
        local x, y = gr.x, gr.y

        -- Sombra al vuelo.
        g.setColor(0, 0, 0, 0.30)
        g.ellipse("fill", x + 3, y + 4, 6, 4)

        g.push()
        g.translate(x, y)
        g.rotate(t * 7 + i * 1.7)               -- giro continuo (no hay rot del servidor)

        -- Cuerpo metálico: anillos oscuro->claro para volumen esférico.
        g.setColor(0.18, 0.19, 0.20); g.circle("fill", 0, 0, 6)
        g.setColor(0.34, 0.36, 0.38); g.circle("fill", -0.6, -0.6, 4.6)
        g.setColor(0.55, 0.58, 0.60); g.circle("fill", -1.4, -1.4, 2.6)
        g.setColor(0.85, 0.88, 0.90); g.circle("fill", -2.0, -2.0, 1.0)   -- brillo especular

        -- Tapa y espoleta (giran con el cuerpo, delatan la rotación).
        g.setColor(0.45, 0.47, 0.49)
        g.rectangle("fill", -1.5, -8, 3, 3)
        g.setColor(0.30, 0.31, 0.33)
        g.setLineWidth(1.5)
        g.line(1.5, -6.5, 6, -9)                -- palanca/cuchara
        g.pop()
    end
    g.setLineWidth(1)
end

-- ============================================================================
-- HUMO: nube orgánica con puffs superpuestos a baja alpha que respiran.
-- Se dibuja DESPUÉS de los jugadores: una nube táctica debe ocultar la escena.
-- ============================================================================
local function drawSmokes(view)
    local g = love.graphics
    if not Assets.loaded then return end
    local img = Assets.smoke
    local iw  = img:getWidth()
    local ox  = iw * 0.5
    local t   = love.timer.getTime()

    for i = 1, view.smokesN do
        local s = view.smokes[i]
        -- Puff central denso.
        local sc = (s.r * 1.05) / ox
        g.setColor(0.74, 0.75, 0.78, 0.30)
        g.draw(img, s.x, s.y, 0, sc, sc, ox, ox)

        -- Corona de puffs girando en espiral (ángulo áureo), radio pulsante.
        for j = 1, 6 do
            local a    = j * 2.39996 + t * 0.18
            local puls = 0.85 + 0.15 * math.sin(t * 1.3 + i * 2.1 + j)
            local dist = s.r * 0.5 * puls
            local px   = s.x + math.cos(a) * dist
            local py   = s.y + math.sin(a) * dist
            local psc  = (s.r * 0.6 * puls) / ox
            g.setColor(0.78, 0.79, 0.82, 0.18)
            g.draw(img, px, py, 0, psc, psc, ox, ox)
        end
    end
end

-- ============================================================================
-- JUGADOR: soldado cenital con casco direccional + arma del loadout activo.
-- ============================================================================

-- Dibuja el arma en el marco LOCAL del jugador (adelante = +x, manos en ~+R/2).
local function drawWeapon(g, kind)
    local R = PLAYER_RADIUS
    if kind == "sniper" then
        g.setColor(0.12, 0.12, 0.13)                       -- cañón largo
        g.rectangle("fill", R * 0.2, -1.6, R * 2.4, 3.2)
        g.setColor(0.30, 0.30, 0.33)                       -- mira/scope
        g.rectangle("fill", R * 0.8, -3.4, 7, 2.4)
        g.setColor(0.20, 0.16, 0.10)                       -- culata
        g.rectangle("fill", R * 0.0, -2.4, 6, 4.8)
    elseif kind == "rifle" then
        g.setColor(0.14, 0.14, 0.15)
        g.rectangle("fill", R * 0.25, -1.6, R * 1.7, 3.2)
        g.setColor(0.10, 0.10, 0.11)                       -- cargador
        g.rectangle("fill", R * 0.7, 1.4, 3.2, 6)
        g.setColor(0.22, 0.18, 0.12)                       -- culata
        g.rectangle("fill", R * 0.05, -2.2, 5, 4.4)
    elseif kind == "pistol" then
        g.setColor(0.16, 0.16, 0.17)                       -- silueta corta
        g.rectangle("fill", R * 0.35, -1.4, R * 0.9, 2.8)
        g.setColor(0.10, 0.10, 0.11)                       -- empuñadura
        g.rectangle("fill", R * 0.35, 0.6, 2.6, 4)
    elseif kind == "knife" then
        g.setColor(0.78, 0.80, 0.85)                       -- hoja triangular
        g.polygon("fill", R * 0.5, -2, R * 1.3, 0, R * 0.5, 2)
        g.setColor(0.20, 0.16, 0.12)                       -- mango
        g.rectangle("fill", R * 0.3, -1.4, 4, 2.8)
    elseif kind == "smoke" then
        g.setColor(0.28, 0.45, 0.30)                       -- bote en mano
        g.rectangle("fill", R * 0.45, -2.4, 5, 5, 2)
        g.setColor(0.5, 0.6, 0.5)
        g.rectangle("line", R * 0.45, -2.4, 5, 5, 2)
    end
end

local function drawPlayer(p, isLocal)
    local g = love.graphics
    local x, y = p.rpos.x, p.rpos.y
    local R = PLAYER_RADIUS
    local tr, tg, tb = teamRGB(p.team)

    -- ---- Muerto: cuerpo caído + charco, se asienta con deathAnim (0->1). ----
    if not p.alive then
        local settle = p.deathAnim or 1
        g.setColor(0.20, 0.02, 0.02, 0.35)                 -- charco de sangre
        g.ellipse("fill", x, y, R * 1.3, R * 0.9)
        g.push()
        g.translate(x, y)
        g.rotate((p.aim or 0) + 1.2)                       -- desplomado de lado
        g.setColor(tr * 0.4, tg * 0.4, tb * 0.4, 0.85)     -- cuerpo apagado
        g.ellipse("fill", 0, 0, R * 1.1, R * 0.6)
        g.setColor(0.10, 0.10, 0.11, 0.85)                 -- casco caído
        g.circle("fill", -R * 0.7, 0, R * 0.42)
        g.pop()
        -- Crucecita translúcida (lápida) que aparece al asentarse.
        g.setColor(0.7, 0.7, 0.7, 0.25 * settle)
        g.setLineWidth(2)
        g.line(x, y - R, x, y - R - 8)
        g.line(x - 4, y - R - 4, x + 4, y - R - 4)
        g.setLineWidth(1)
        return
    end

    local kind = WKIND[p.wname] or "pistol"
    local firing = (p.state == "firing")

    -- Sombra bajo el soldado.
    g.setColor(0, 0, 0, 0.35)
    g.ellipse("fill", x + 2, y + 3, R + 1, R - 1)

    g.push()
    g.translate(x, y)
    g.rotate(p.aim or 0)

    -- Cuerpo (torso ovalado) + chaleco táctico.
    g.setColor(tr, tg, tb)
    g.ellipse("fill", 0, 0, R, R * 0.84)
    g.setColor(tr * 0.45, tg * 0.45, tb * 0.45)
    g.rectangle("fill", -R * 0.5, -R * 0.5, R * 0.85, R)       -- chaleco
    g.setColor(0, 0, 0, 0.35)                                 -- contorno
    g.setLineWidth(2)
    g.ellipse("line", 0, 0, R, R * 0.84)

    -- Brazos sosteniendo el arma hacia adelante.
    g.setColor(tr * 0.7, tg * 0.7, tb * 0.7)
    g.ellipse("fill", R * 0.45, -R * 0.45, R * 0.32, R * 0.26)
    g.ellipse("fill", R * 0.45,  R * 0.45, R * 0.32, R * 0.26)

    -- Arma del loadout activo.
    drawWeapon(g, kind)

    -- Casco/cabeza adelantado: indica claramente hacia dónde mira.
    g.setColor(0.16, 0.17, 0.19)
    g.circle("fill", R * 0.35, 0, R * 0.55)
    g.setColor(0.30, 0.32, 0.36)
    g.circle("fill", R * 0.30, -R * 0.12, R * 0.40)           -- reflejo del casco
    g.setColor(tr, tg, tb)                                    -- visera del color de equipo
    g.rectangle("fill", R * 0.75, -2, 4, 4)

    -- Fogonazo aditivo al disparar (en la punta del arma).
    if firing then
        local tip = (kind == "sniper") and R * 2.6
                 or (kind == "rifle")  and R * 1.95
                 or R * 1.25
        g.setBlendMode("add")
        g.setColor(1.0, 0.85, 0.4, 0.9)
        g.circle("fill", tip, 0, 4)
        g.setColor(1.0, 0.7, 0.2, 0.5)
        g.polygon("fill", tip - 3, -3, tip + 6, 0, tip - 3, 3)
        g.setBlendMode("alpha")
    end

    -- Flash rojo al recibir daño (sobre todo el cuerpo).
    if p.hurt and p.hurt > 0 then
        local a = (p.hurt / 0.18) * 0.6
        g.setColor(1, 0.1, 0.1, a)
        g.ellipse("fill", 0, 0, R + 2, R * 0.84 + 2)
    end
    g.pop()
    g.setLineWidth(1)

    -- ---- Adornos en espacio de pantalla (NO rotados) ----

    -- Anillo del jugador local.
    if isLocal then
        g.setColor(1, 1, 0.4, 0.85)
        g.setLineWidth(2)
        g.circle("line", x, y, R + 6)
    end
    -- Aro sutil al apuntar (ADS).
    if p.state == "aiming" or firing then
        g.setColor(1, 1, 1, 0.4)
        g.setLineWidth(1.5)
        g.circle("line", x, y, R + 3)
    end

    -- Barra de vida flotante.
    local bw, bh = 34, 4
    local hx, hy = x - bw / 2, y - R - 13
    g.setColor(0, 0, 0, 0.6); g.rectangle("fill", hx - 1, hy - 1, bw + 2, bh + 2)
    g.setColor(0.12, 0.12, 0.14); g.rectangle("fill", hx, hy, bw, bh)
    local frac = (p.hp or 0) / MAX_HP
    if frac < 0 then frac = 0 end
    g.setColor(1 - frac, frac * 0.9 + 0.1, 0.12); g.rectangle("fill", hx, hy, bw * frac, bh)
    g.setLineWidth(1)
end

-- Viñeta de tensión (estirada a pantalla). Sobre el mundo, bajo el HUD.
local function drawVignette()
    if not Assets.loaded then return end
    local g = love.graphics
    local W, H = g.getWidth(), g.getHeight()
    local iw, ih = Assets.vignette:getDimensions()
    g.setColor(1, 1, 1)
    g.draw(Assets.vignette, 0, 0, 0, W / iw, H / ih)
end

-- ----------------------------------------------------------------------------
-- API pública
-- ----------------------------------------------------------------------------

-- Generación de texturas. Llamar una vez desde love.load().
function Render.load()
    Assets.load()
end

-- Dibuja todo el estado de juego en orden de capas.
function Render.draw(nc, fonts)
    local view = nc.view
    drawArena(view)
    drawCovers(view)          -- parapetos de madera (obstáculos del mapa)
    drawFlag(view)            -- base + zona + mástil (bajo los jugadores)
    drawGrenades(view)

    local localId = nc.myId
    for id, p in pairs(view.players) do
        drawPlayer(p, id == localId)
    end

    nc.tracers:draw()
    nc.debris:draw()          -- escombros de coberturas rotas
    drawSmokes(view)          -- nube táctica: oculta la escena (sobre jugadores)

    drawVignette()            -- viñeta de AMBIENTE (negra). El HUD/feedback los
                              -- pinta src/ui/ui_manager.lua sobre esta capa.
end

-- Overlay de depuración (tecla F1). Rendimiento, red, fase y jugadores.
function Render.drawDebug(nc, fonts)
    local g = love.graphics
    local v = nc.view
    local m = v.match
    local st = nc.stats

    g.setFont(fonts.small)
    local lines = {}
    local function add(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end

    add("== DEBUG (F1) ==")
    add("FPS %d   frame %.1f ms", love.timer.getFPS(), love.timer.getAverageDelta() * 1000)
    add("RTT %.0f ms   interp err %.1f px", nc.rtt, nc:localInterpError())
    add("net: %.0f snap/s  %.0f in/s  %.1f kB/s  pkt %d B",
        st.snapsPerSec, st.inputsPerSec, st.kbInPerSec, st.lastBytes)
    add("yo=#%d  modo %dv%d  trazadoras %d", nc.myId, nc.mode, nc.mode, nc.tracers:aliveCount())
    add("fase %s / %s   ronda %d   %s", m.gamePhase, m.phase, m.roundNumber, m.loadout)
    if m.phase == "overtime" then
        add("OT restante %.1fs  captura %d%% eq.%d", m.overtimeLeft, math.floor(m.captureFrac * 100), m.captureTeam)
    else
        add("tiempo %.1fs   marcador %d-%d", m.roundTime, m.scores[1], m.scores[2])
    end
    add("intro %.1f  end %.1f   winner=%d  matchOver=%s",
        m.introTimer, m.endTimer, m.roundWinner, tostring(m.matchOver))
    add("--- jugadores ---")
    for id = 1, nc.mode * 2 do
        local p = v.players[id]
        if p then
            local me = (id == nc.myId) and "*" or " "
            add("%s#%d T%d hp%3.0f %-7s %-9s %s %d/%d (%.0f,%.0f)",
                me, id, p.team, p.hp, p.alive and p.state or "DEAD",
                p.wname or "-", p.slot or "-", p.ammo or 0, p.mag or 0, p.pos.x, p.pos.y)
        end
    end

    local pad = 6
    local lh = fonts.small:getHeight() + 1
    local boxW = 430
    local boxH = pad * 2 + #lines * lh
    g.setColor(0, 0, 0, 0.72)
    g.rectangle("fill", 8, 70, boxW, boxH)
    g.setColor(0.2, 0.8, 0.4)
    g.setLineWidth(1)
    g.rectangle("line", 8, 70, boxW, boxH)
    for i, ln in ipairs(lines) do
        g.setColor(0.85, 0.95, 0.85)
        g.print(ln, 8 + pad, 70 + pad + (i - 1) * lh)
    end
end

return Render
