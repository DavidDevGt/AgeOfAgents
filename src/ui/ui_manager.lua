-- src/ui/ui_manager.lua
-- Gestor de INTERFAZ, FLUJO (UX) y FEEDBACK de combate (game feel) de Gulag
-- Arena. Es la capa NO diegética (pantalla): menú, HUD perimetral, hitmarkers,
-- viñeta de daño, progreso de captura, killfeed y banners de fase. El mundo
-- diegético (arena, soldados, balas, humo) lo dibuja src/render.lua.
--
-- ACOPLE ASÍNCRONO CON LA RED: este módulo nunca consulta al servidor. Recibe
-- eventos por callbacks que instala en el NetClient (ui.attach): onKill, onHit
-- y onLocalDamage. El NetClient los invoca al parsear el flujo autoritativo
-- (D = baja, H = impacto, caída de HP local = daño). Así la UI reacciona a
-- hechos confirmados por el servidor, sin adivinar.
--
-- CERO GC EN EL HOT-PATH (love.draw): prohibido crear tablas {} o vectores de
-- color dentro de funciones de dibujo. Todos los colores viven en el pool
-- estático UI_COLORS. Las transiciones (fades, lerps, escalados) son escalares
-- numéricos avanzados por dt en ui.update(). Las ranuras del killfeed y los
-- offsets del menú son tablas de tamaño FIJO asignadas una sola vez en load().

local ui = {}

-- ============================================================================
-- ESTADOS DE LA MÁQUINA DE UI
-- ============================================================================
ui.STATE_MENU           = "STATE_MENU"
ui.STATE_MATCH_INTRO    = "STATE_MATCH_INTRO"
ui.STATE_GAMEPLAY       = "STATE_GAMEPLAY"
ui.STATE_OVERTIME_ALERT = "STATE_OVERTIME_ALERT"
ui.STATE_MATCH_END      = "STATE_MATCH_END"

ui.state     = ui.STATE_MENU
ui.prevState = nil

-- ============================================================================
-- POOL ESTÁTICO DE COLORES (asignado UNA vez; jamás se crean tablas en draw)
-- ============================================================================
local UI_COLORS = {
    red      = { 1.00, 0.20, 0.20, 1 },
    redHot   = { 1.00, 0.00, 0.00, 1 },
    blue     = { 0.30, 0.62, 1.00, 1 },
    redTeam  = { 1.00, 0.45, 0.32, 1 },
    blueTeam = { 0.30, 0.62, 1.00, 1 },
    white    = { 1.00, 1.00, 1.00, 1 },
    yellow   = { 1.00, 0.80, 0.00, 1 },   -- amarillo táctico
    amber    = { 1.00, 0.70, 0.20, 1 },
    grey     = { 0.55, 0.55, 0.60, 1 },
    dark     = { 0.03, 0.03, 0.04, 1 },   -- fondo del menú
    panel    = { 0.05, 0.05, 0.05, 0.80 },
    panelHi  = { 0.12, 0.13, 0.16, 0.92 },
    black    = { 0.00, 0.00, 0.00, 1 },
    grid     = { 1.00, 1.00, 1.00, 0.02 },-- rejilla militar sutil
}

-- Aplica un color del pool (sin asignar). `a` opcional sobreescribe el alpha.
local function SC(c, a)
    love.graphics.setColor(c[1], c[2], c[3], a or c[4])
end

-- Color de equipo (1 = Azul, 2 = Rojo). Devuelve la tabla estática.
local function teamCol(team)
    if team == 1 then return UI_COLORS.blueTeam end
    return UI_COLORS.redTeam
end

-- Onda cuadrada de parpadeo a partir del reloj del sistema.
local function blink(speed)
    return (love.timer.getTime() * (speed or 1)) % 1 < 0.5
end

-- ============================================================================
-- FUENTES (creadas por código, sin archivos externos)
-- ============================================================================
local F = {}

-- ============================================================================
-- ESTADO DE ANIMACIÓN / FEEDBACK (todo escalar o tabla fija; reusado por frame)
-- ============================================================================
-- Menú
local MENU_ITEMS = { "1. BUSCAR PARTIDA", "2. CONFIGURACIÓN", "3. SALIR" }
local MENU_ACTIONS = { "find", "settings", "quit" }
local menu = {
    selected = 1,
    offset   = { 0, 0, 0 },     -- desplazamiento lerp por opción (0..8 px)
    x = 100, y = 300, spacing = 56, w = 380, h = 44,
    showSettings = false,
}

-- Hitmarker (impacto confirmado por el servidor)
local hitmarker = { active = false, timer = 0, is_kill = false }
local HITMARK_LIFE = 0.10

-- Viñeta de daño recibido
local damage_flash_alpha = 0
local damageVignetteImg  = nil   -- textura roja de bordes, horneada en load()

-- Salud: barra blanca instantánea + remanente rojo que baja por lerp
local hpRemnant = 100

-- Captura de bandera en overtime (barra in-situ bajo el jugador)
local capture = { display = 0, breaking = 0 }

-- Banner de overtime que se despliega hacia abajo
local overtimeExpand = 0

-- Killfeed: lista FIJA de 4 ranuras (asignadas una vez)
local KF_SLOTS = 4
local KF_LIFE  = 4.0
local killfeed = {}

local WEAPON_LABEL = {
    sniper = "Sniper", pistol = "Pistola", rifle = "Rifle",
    knife = "Cuchillo", smoke = "Humo",
}

-- Referencia de controles del sub-panel de Configuración (tabla FIJA: jamás se
-- recrea dentro de una función de dibujo).
local SETTINGS_LINES = {
    "Mover .................. W A S D",
    "Apuntar ................ Ratón",
    "Disparar ............... Click Izquierdo",
    "Apuntar (ADS) .......... Click Derecho",
    "Recargar ............... R",
    "Cambiar arma ........... Q",
    "Depuración (overlay) ... F1",
    "Salir / Desconectar .... Esc",
}

-- ============================================================================
-- HORNEADO DE LA VIÑETA DE DAÑO (rojo en bordes, centro transparente)
-- ============================================================================
local function buildDamageVignette(w, h)
    local data = love.image.newImageData(w, h)
    local cx, cy = (w - 1) * 0.5, (h - 1) * 0.5
    local maxd = math.sqrt(cx * cx + cy * cy)
    data:mapPixel(function(x, y)
        local dx, dy = (x - cx) / maxd, (y - cy) / maxd
        local d = math.sqrt(dx * dx + dy * dy)
        local t = (d - 0.45) / (1.05 - 0.45)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local a = t * t * (3 - 2 * t)            -- smoothstep
        return 0.7, 0.0, 0.0, a
    end)
    local img = love.graphics.newImage(data)
    img:setFilter("linear", "linear")
    return img
end

-- ============================================================================
-- CARGA / ENGANCHE
-- ============================================================================
function ui.load(fonts)
    F.small = love.graphics.newFont(14)
    F.kf    = love.graphics.newFont(16)
    F.mid   = love.graphics.newFont(22)
    F.menu  = love.graphics.newFont(26)
    F.big   = love.graphics.newFont(40)
    F.huge  = love.graphics.newFont(64)
    F.title = love.graphics.newFont(56)

    for i = 1, KF_SLOTS do
        killfeed[i] = {
            active = false, lifetime = 0,
            attacker = "", victim = "", weapon = "",
            team_attacker = 0, team_victim = 0, suicide = false,
        }
    end

    damageVignetteImg = buildDamageVignette(320, 180)
end

-- Instala los callbacks de feedback en el NetClient. Se llama una vez al crear
-- la conexión; las clausuras se crean aquí (no por frame).
function ui.attach(nc)
    if not nc then return end
    nc.onKill = function(victimId, killerId, weaponId)
        ui.pushKill(victimId, killerId, weaponId, nc.view.players)
    end
    nc.onHit = function(isKill)
        hitmarker.active = true
        hitmarker.timer  = HITMARK_LIFE
        hitmarker.is_kill = isKill
    end
    nc.onLocalDamage = function()
        damage_flash_alpha = 0.6
    end
end

-- Reinicia el feedback efímero (al desconectar / volver al menú).
function ui.reset()
    hitmarker.active = false; hitmarker.timer = 0
    damage_flash_alpha = 0
    capture.display = 0; capture.breaking = 0
    overtimeExpand = 0
    hpRemnant = 100
    for i = 1, KF_SLOTS do killfeed[i].active = false; killfeed[i].lifetime = 0 end
end

-- ============================================================================
-- KILLFEED: alta de una baja (resuelve nombres/equipos desde la vista)
-- ============================================================================
function ui.pushKill(victimId, killerId, weaponId, players)
    -- Busca ranura libre; si no hay, recicla la de menor lifetime.
    local slot, lo = killfeed[1], killfeed[1].lifetime
    for i = 1, KF_SLOTS do
        local s = killfeed[i]
        if not s.active then slot = s; break end
        if s.lifetime < lo then slot, lo = s, s.lifetime end
    end

    local vp = players[victimId]
    local kp = players[killerId]
    local vTeam = vp and vp.team or 0
    local kTeam = kp and kp.team or 0

    slot.victim        = (vTeam == 2 and "ROJO #" or "AZUL #") .. victimId
    slot.weapon        = WEAPON_LABEL[weaponId] or weaponId or "?"
    slot.team_victim   = vTeam
    slot.team_attacker = kTeam
    if killerId == 0 or not kp then
        slot.suicide  = true
        slot.attacker = ""
    else
        slot.suicide  = false
        slot.attacker = (kTeam == 2 and "ROJO #" or "AZUL #") .. killerId
    end
    slot.active   = true
    slot.lifetime = KF_LIFE
end

-- ============================================================================
-- UPDATE: deriva el estado y avanza TODAS las animaciones por dt.
-- ============================================================================
local function deriveState(nc, app)
    if not app or app.state ~= "PLAY" or not nc then
        return ui.STATE_MENU
    end
    local m = nc.view.match
    if m.gamePhase == "intro" then return ui.STATE_MATCH_INTRO end
    if m.gamePhase == "matchend" then return ui.STATE_MATCH_END end
    if m.phase == "overtime" then return ui.STATE_OVERTIME_ALERT end
    return ui.STATE_GAMEPLAY
end

function ui.update(dt, nc, app)
    ui.prevState = ui.state
    ui.state = deriveState(nc, app)

    -- ---- Menú: hover por ratón + lerp de offsets ----
    if ui.state == ui.STATE_MENU and not (app and app.state == "CONNECTING") then
        local mx, my = love.mouse.getPosition()
        for i = 1, #MENU_ITEMS do
            local iy = menu.y + (i - 1) * menu.spacing
            if mx >= menu.x and mx <= menu.x + menu.w and my >= iy and my <= iy + menu.h then
                menu.selected = i
            end
        end
        for i = 1, #MENU_ITEMS do
            local target = (i == menu.selected) and 8 or 0
            menu.offset[i] = menu.offset[i] + (target - menu.offset[i]) * math.min(1, dt * 14)
        end
    end

    -- ---- Hitmarker ----
    if hitmarker.active then
        hitmarker.timer = hitmarker.timer - dt
        if hitmarker.timer <= 0 then hitmarker.active = false; hitmarker.timer = 0 end
    end

    -- ---- Viñeta de daño: decae linealmente a 0 en ~0.4 s ----
    if damage_flash_alpha > 0 then
        damage_flash_alpha = damage_flash_alpha - dt * (0.6 / 0.4)
        if damage_flash_alpha < 0 then damage_flash_alpha = 0 end
    end

    -- ---- Salud: remanente rojo que baja suave hacia el HP real ----
    local me = nc and nc.view.players[nc.myId]
    if me then
        local hp = me.hp or 0
        if hp > hpRemnant then hpRemnant = hp end          -- respawn/cura: sube ya
        if hpRemnant > hp then
            hpRemnant = hpRemnant - dt * 70                 -- 70 HP/s de drenaje
            if hpRemnant < hp then hpRemnant = hp end
        end
    else
        hpRemnant = 100
    end

    -- ---- Captura: lerp del progreso mostrado + ruptura ----
    local target = 0
    if me and me.alive and nc then
        local m = nc.view.match
        local f = m.flag
        if f.active and m.captureTeam == me.team then
            local dx, dy = me.pos.x - f.x, me.pos.y - f.y
            if dx * dx + dy * dy <= f.r * f.r then
                target = m.captureFrac or 0
            end
        end
    end
    if target > 0 then
        capture.display = capture.display + (target - capture.display) * math.min(1, dt * 8)
        capture.breaking = 0
    else
        if capture.display > 0.02 then
            capture.breaking = 1                            -- se interrumpió
            capture.display = capture.display - dt * 2.5
            if capture.display < 0 then capture.display = 0 end
        else
            capture.display = 0; capture.breaking = 0
        end
    end

    -- ---- Banner de overtime: se despliega/recoge ----
    local otTarget = (ui.state == ui.STATE_OVERTIME_ALERT) and 1 or 0
    overtimeExpand = overtimeExpand + (otTarget - overtimeExpand) * math.min(1, dt * 6)

    -- ---- Killfeed: decae lifetime ----
    for i = 1, KF_SLOTS do
        local s = killfeed[i]
        if s.active then
            s.lifetime = s.lifetime - dt
            if s.lifetime <= 0 then s.active = false; s.lifetime = 0 end
        end
    end

    -- Volver al menú limpia el feedback.
    if ui.state == ui.STATE_MENU and ui.prevState ~= ui.STATE_MENU then
        ui.reset()
    end
end

-- ============================================================================
-- ENTRADA (solo relevante en el menú)
-- ============================================================================
-- Devuelve una acción ("find"/"settings"/"quit"/"back") o nil.
function ui.keypressed(key, app)
    if ui.state ~= ui.STATE_MENU then return nil end
    if app and app.state == "CONNECTING" then return nil end

    if menu.showSettings then
        if key == "escape" or key == "backspace" then menu.showSettings = false; return "back" end
        return nil
    end

    if key == "up" or key == "w" then
        menu.selected = (menu.selected - 2) % #MENU_ITEMS + 1
    elseif key == "down" or key == "s" then
        menu.selected = menu.selected % #MENU_ITEMS + 1
    elseif key == "return" or key == "kpenter" or key == "space" then
        return ui.activate(app)
    elseif key == "1" then menu.selected = 1; return ui.activate(app)
    elseif key == "2" then menu.selected = 2; return ui.activate(app)
    elseif key == "3" then menu.selected = 3; return ui.activate(app)
    end
    return nil
end

function ui.mousepressed(x, y, button, app)
    if ui.state ~= ui.STATE_MENU or button ~= 1 then return nil end
    if app and app.state == "CONNECTING" then return nil end
    if menu.showSettings then menu.showSettings = false; return "back" end
    for i = 1, #MENU_ITEMS do
        local iy = menu.y + (i - 1) * menu.spacing
        if x >= menu.x and x <= menu.x + menu.w and y >= iy and y <= iy + menu.h then
            menu.selected = i
            return ui.activate(app)
        end
    end
    return nil
end

function ui.activate(app)
    local action = MENU_ACTIONS[menu.selected]
    if action == "settings" then menu.showSettings = true; return "settings" end
    return action       -- "find" / "quit"
end

-- ============================================================================
-- DIBUJO DE COMPONENTES
-- ============================================================================

-- Panel rectangular con esquinas biseladas (polígono de 8 vértices).
local function beveledPanel(x, y, w, h, bevel, color, alpha)
    SC(color, alpha)
    love.graphics.polygon("fill",
        x + bevel, y,
        x + w - bevel, y,
        x + w, y + bevel,
        x + w, y + h - bevel,
        x + w - bevel, y + h,
        x + bevel, y + h,
        x, y + h - bevel,
        x, y + bevel)
end

-- ---- A. MENÚ PRINCIPAL ----
local function drawMenu(app)
    local g = love.graphics
    local W, H = g.getWidth(), g.getHeight()

    -- Fondo gris ultra oscuro + rejilla militar sutil.
    SC(UI_COLORS.dark); g.rectangle("fill", 0, 0, W, H)
    SC(UI_COLORS.grid); g.setLineWidth(1)
    for x = 0, W, 48 do g.line(x, 0, x, H) end
    for y = 0, H, 48 do g.line(0, y, W, y) end

    -- Título.
    g.setFont(F.title); SC(UI_COLORS.yellow)
    g.print("GULAG ARENA", menu.x, 150)
    g.setFont(F.mid); SC(UI_COLORS.grey)
    g.print("1v1 / 2v2 SHOWDOWN", menu.x, 220)

    -- Estado intermedio "Conectando..." con spinner geométrico.
    if app and app.state == "CONNECTING" then
        g.setFont(F.menu); SC(UI_COLORS.white)
        g.print("CONECTANDO", menu.x, menu.y)
        local t = love.timer.getTime()
        local cx, cy = menu.x + 220, menu.y + 16
        -- Tres puntos pulsantes (math.sin) + arco giratorio.
        for i = 0, 2 do
            local a = 0.4 + 0.6 * (0.5 + 0.5 * math.sin(t * 5 - i * 0.7))
            SC(UI_COLORS.yellow, a)
            g.circle("fill", cx + i * 16, cy, 4)
        end
        SC(UI_COLORS.yellow)
        g.setLineWidth(3)
        g.arc("line", "open", menu.x + 320, cy, 14, t * 5, t * 5 + 4.2)
        g.setLineWidth(1)
        if app.error then
            g.setFont(F.small); SC(UI_COLORS.red)
            g.printf(app.error, menu.x, menu.y + 80, W - menu.x - 60, "left")
        end
        return
    end

    -- Opciones del menú con hover (offset lerp + color táctil).
    g.setFont(F.menu)
    for i = 1, #MENU_ITEMS do
        local iy = menu.y + (i - 1) * menu.spacing
        local sel = (i == menu.selected)
        if sel then
            SC(UI_COLORS.yellow, 0.12)
            g.rectangle("fill", menu.x - 8, iy - 4, menu.w, menu.h, 4)
            SC(UI_COLORS.yellow)
            g.rectangle("fill", menu.x - 8, iy - 4, 4, menu.h)   -- acento izquierdo
            SC(UI_COLORS.yellow)
        else
            SC(UI_COLORS.white)
        end
        g.print(MENU_ITEMS[i], menu.x + 6 + menu.offset[i], iy)
    end

    -- Sub-panel de Configuración (referencia real de controles).
    if menu.showSettings then
        local px, py, pw, ph = W / 2 - 230, H / 2 - 140, 460, 280
        beveledPanel(px, py, pw, ph, 14, UI_COLORS.panelHi)
        SC(UI_COLORS.yellow); g.setLineWidth(2)
        g.polygon("line",
            px + 14, py, px + pw - 14, py, px + pw, py + 14,
            px + pw, py + ph - 14, px + pw - 14, py + ph,
            px + 14, py + ph, px, py + ph - 14, px, py + 14)
        g.setLineWidth(1)
        g.setFont(F.mid); SC(UI_COLORS.yellow)
        g.print("CONFIGURACIÓN — CONTROLES", px + 24, py + 18)
        g.setFont(F.small); SC(UI_COLORS.white)
        for i = 1, #SETTINGS_LINES do
            g.print(SETTINGS_LINES[i], px + 24, py + 56 + (i - 1) * 24)
        end
        SC(UI_COLORS.grey)
        g.print("[Esc] o click para volver", px + 24, py + ph - 30)
    end

    -- Pie.
    g.setFont(F.small); SC(UI_COLORS.grey)
    g.printf("Version 1.0.0",
             0, H - 36, W - 40, "right")
end

-- ---- B. MARCADOR CENTRAL SUPERIOR (+ banner de overtime desplegable) ----
local function drawScoreboard(nc)
    local g = love.graphics
    local m = nc.view.match
    local W = g.getWidth()
    local overtime = (m.phase == "overtime")

    local pw, ph = 300, 50
    local px, py = W / 2 - pw / 2, 10
    beveledPanel(px, py, pw, ph, 12, UI_COLORS.panel)

    g.setFont(F.mid)
    SC(UI_COLORS.blueTeam); g.printf("AZUL " .. m.scores[1], px + 12, py + 13, 90, "left")
    SC(UI_COLORS.redTeam);  g.printf(m.scores[2] .. " ROJO", px + pw - 102, py + 13, 90, "right")

    -- Separadores verticales.
    SC(UI_COLORS.grey, 0.5); g.setLineWidth(1)
    g.line(px + 108, py + 8, px + 108, py + ph - 8)
    g.line(px + pw - 108, py + 8, px + pw - 108, py + ph - 8)

    -- Temporizador central (MM:SS) o reloj de overtime.
    if overtime then
        SC(UI_COLORS.red, blink(2) and 1 or 0.55)
        g.printf(string.format("OT %02d", math.ceil(m.overtimeLeft or 0)),
                 px + 108, py + 13, pw - 216, "center")
    else
        local t = m.roundTime or 0
        local mm, ss = math.floor(t / 60), math.floor(t % 60)
        if t < 10 then
            SC(UI_COLORS.red, blink(4) and 1 or 0.35)   -- parpadeo onda cuadrada
        else
            SC(UI_COLORS.white)
        end
        g.printf(string.format("%02d:%02d", mm, ss), px + 108, py + 13, pw - 216, "center")
    end

    -- Banner desplegable de PUNTO DE CAPTURA (se expande hacia abajo).
    if overtimeExpand > 0.01 then
        local bh = 30 * overtimeExpand
        beveledPanel(px + 10, py + ph, pw - 20, bh, 8, UI_COLORS.panel, 0.85 * overtimeExpand)
        if overtimeExpand > 0.6 then
            g.setFont(F.small)
            SC(UI_COLORS.yellow, blink(2.5) and 1 or 0.6)
            g.printf("/!\\  PUNTO DE CAPTURA ACTIVO", px + 10, py + ph + 6, pw - 20, "center")
        end
    end

    g.setFont(F.small); SC(UI_COLORS.grey)
    g.printf("RONDA " .. (m.roundNumber or 0), px, py + ph + 34, pw, "center")
end

-- ---- B. PANEL OPERADOR (abajo-izq): loadout + salud con remanente ----
local function drawOperatorPanel(nc)
    local g = love.graphics
    local me = nc.view.players[nc.myId]
    if not me then return end
    local W, H = g.getWidth(), g.getHeight()
    local m = nc.view.match

    local px, py = 24, H - 80
    beveledPanel(px, py, 320, 64, 10, UI_COLORS.panel)

    g.setFont(F.small); SC(UI_COLORS.yellow)
    g.print("LOADOUT: " .. string.upper(m.loadout or "-"), px + 14, py + 8)

    -- Barra de salud: contenedor negro, remanente rojo (lerp), barra blanca.
    local bx, by, bw, bh = px + 14, py + 32, 292, 18
    local hp = me.hp or 0
    SC(UI_COLORS.black); g.rectangle("fill", bx, by, bw, bh)
    -- Remanente del daño perdido.
    SC(UI_COLORS.red, 0.85)
    g.rectangle("fill", bx, by, bw * (hpRemnant / 100), bh)
    -- Barra real: blanca, o roja parpadeante si crítica (<30).
    if hp < 30 and blink(6) then SC(UI_COLORS.redHot) else SC(UI_COLORS.white) end
    g.rectangle("fill", bx, by, bw * (hp / 100), bh)
    SC(UI_COLORS.black, 0.7); g.setLineWidth(1)
    g.rectangle("line", bx, by, bw, bh)
    g.setFont(F.small); SC(UI_COLORS.black)
    g.print(math.floor(hp), bx + 6, by + 1)
end

-- ---- B. MÓDULO DE ARMAMENTO (abajo-der): munición + alerta de recarga ----
local function drawWeaponModule(nc)
    local g = love.graphics
    local me = nc.view.players[nc.myId]
    if not me then return end
    local W, H = g.getWidth(), g.getHeight()

    local pw, ph = 230, 72
    local px, py = W - pw - 24, H - ph - 16
    beveledPanel(px, py, pw, ph, 10, UI_COLORS.panel)

    g.setFont(F.small); SC(UI_COLORS.grey)
    g.printf(me.wname or "-", px, py + 8, pw - 16, "right")

    if me.reloading then
        g.setFont(F.mid); SC(UI_COLORS.amber, blink(4) and 1 or 0.5)
        g.printf("RECARGANDO", px, py + 34, pw - 16, "right")
        return
    end

    -- Número GIGANTE para el cargador; pequeño para la reserva real.
    -- Formato:  [ cargador ] / [ reserva ].  El cuchillo (mag<0) es infinito.
    local mag = me.mag or 0
    if mag < 0 then
        g.setFont(F.huge); SC(UI_COLORS.blue)
        g.printf("∞", px, py + 4, pw - 60, "right")
    else
        local ammo    = me.ammo or 0
        local reserve = me.reserveAmmo or 0
        local low = (mag > 0) and (ammo / mag < 0.25)
        -- Cargador (gigante): rojo si está bajo.
        g.setFont(F.huge)
        if low then SC(UI_COLORS.red) else SC(UI_COLORS.white) end
        g.printf(ammo, px, py + 2, pw - 76, "right")
        -- Separador + reserva (pequeña). Reserva 0 -> rojo apagado parpadeante.
        g.setFont(F.mid); SC(UI_COLORS.grey)
        g.print("/", px + pw - 68, py + 32)
        if reserve <= 0 then
            SC(UI_COLORS.red, blink(3) and 0.85 or 0.40)
        else
            SC(UI_COLORS.grey)
        end
        g.printf(reserve, px + pw - 58, py + 32, 50, "right")
    end
end

-- ---- B. ALERTA DE RECARGA (centro, bajo la retícula) ----
local function drawReloadAlert(nc)
    local g = love.graphics
    local me = nc.view.players[nc.myId]
    if not me or not me.alive or me.reloading then return end
    local mag = me.mag or 0
    if mag <= 0 then return end
    if (me.ammo or 0) / mag >= 0.25 then return end

    local W, H = g.getWidth(), g.getHeight()
    local cx, cy = W / 2, H / 2 + 60
    local a = blink(2.5) and 1 or 0.35
    -- Triángulo de advertencia (sin depender de emojis del sistema).
    SC(UI_COLORS.yellow, a); g.setLineWidth(2)
    g.polygon("line", cx - 92, cy + 8, cx - 78, cy - 12, cx - 64, cy + 8)
    SC(UI_COLORS.yellow, a)
    g.rectangle("fill", cx - 79, cy - 7, 2, 8)
    g.circle("fill", cx - 78, cy + 4, 1.2)
    g.setFont(F.mid); SC(UI_COLORS.yellow, a)
    g.print("¡RECARGAR! [R]", cx - 56, cy - 12)
    g.setLineWidth(1)
end

-- ---- C. HITMARKER (X en la retícula del ratón) ----
local function drawHitmarker()
    if not hitmarker.active then return end
    local g = love.graphics
    local mx, my = love.mouse.getPosition()
    local f = hitmarker.timer / HITMARK_LIFE        -- 1 -> 0
    local s = hitmarker.is_kill and 12 or 8         -- baja: 50% más grande
    local gap = 3
    if hitmarker.is_kill then SC(UI_COLORS.redHot, f) else SC(UI_COLORS.white, f) end
    g.setLineWidth(2)
    -- Cuatro líneas oblicuas formando una "X".
    g.line(mx - s, my - s, mx - gap, my - gap)
    g.line(mx + gap, my + gap, mx + s, my + s)
    g.line(mx + s, my - s, mx + gap, my - gap)
    g.line(mx - gap, my + gap, mx - s, my + s)
    g.setLineWidth(1)
end

-- ---- C. VIÑETA DE DAÑO ----
local function drawDamageVignette()
    if damage_flash_alpha <= 0 or not damageVignetteImg then return end
    local g = love.graphics
    local W, H = g.getWidth(), g.getHeight()
    local iw, ih = damageVignetteImg:getDimensions()
    g.setColor(1, 1, 1, damage_flash_alpha)
    g.draw(damageVignetteImg, 0, 0, 0, W / iw, H / ih)
end

-- ---- C. BARRA DE CAPTURA IN-SITU (bajo el jugador local) ----
local function drawCaptureProgress(nc)
    if capture.display <= 0.01 then return end
    local g = love.graphics
    local me = nc.view.players[nc.myId]
    if not me then return end
    local x, y = me.rpos.x, me.rpos.y + 26
    local bw, bh = 46, 6
    -- Ruptura: parpadeo al interrumpirse.
    local a = 1
    if capture.breaking == 1 then a = blink(8) and 1 or 0.2 end
    SC(UI_COLORS.black, 0.7 * a); g.rectangle("fill", x - bw / 2 - 1, y - 1, bw + 2, bh + 2)
    SC(UI_COLORS.dark, a); g.rectangle("fill", x - bw / 2, y, bw, bh)
    SC(UI_COLORS.yellow, a); g.rectangle("fill", x - bw / 2, y, bw * capture.display, bh)
end

-- ---- D. KILLFEED (esquina superior derecha, fade-out por lifetime) ----
local function drawKillfeed()
    local g = love.graphics
    g.setFont(F.kf)
    local fh = F.kf:getHeight()
    local W = g.getWidth()
    local baseX = W - 350
    local y = 50
    for i = 1, KF_SLOTS do
        local s = killfeed[i]
        if s.active then
            local a = 1
            if s.lifetime < 1.0 then a = s.lifetime end     -- fade en el último segundo

            local atkW = s.suicide and 0 or (F.kf:getWidth(s.attacker) + 8)
            local wlbl = "[" .. s.weapon .. "]"
            local wW   = F.kf:getWidth(wlbl) + 8
            local vicW = F.kf:getWidth(s.victim)
            local total = atkW + wW + vicW + (s.suicide and 0 or 16)
            local x = math.max(baseX, W - total - 16)

            SC(UI_COLORS.panel, UI_COLORS.panel[4] * a)
            g.rectangle("fill", x - 8, y - 3, total + 16, fh + 6, 4)

            if not s.suicide then
                SC(teamCol(s.team_attacker), a)
                g.print(s.attacker, x, y); x = x + atkW
                SC(UI_COLORS.grey, a)
                g.print(">>", x, y); x = x + 24
            end
            SC(UI_COLORS.amber, a)
            g.print(wlbl, x, y); x = x + wW
            SC(teamCol(s.team_victim), a)
            g.print(s.victim, x, y)

            y = y + fh + 12
        end
    end
end

-- ---- BANNERS DE FASE (intro / overtime / fin / espera / fin de ronda) ----
local function drawPhaseBanners(nc)
    local g = love.graphics
    local m = nc.view.match
    local W, H = g.getWidth(), g.getHeight()
    local gp = m.gamePhase

    if gp == "waiting" then
        SC(UI_COLORS.black, 0.45); g.rectangle("fill", 0, H / 2 - 40, W, 80)
        g.setFont(F.mid); SC(UI_COLORS.white)
        g.printf("Esperando a la partida...", 0, H / 2 - 16, W, "center")

    elseif gp == "intro" then
        SC(UI_COLORS.black, 0.5); g.rectangle("fill", 0, H / 2 - 90, W, 180)
        g.setFont(F.big); SC(UI_COLORS.white)
        g.printf("RONDA " .. m.roundNumber, 0, H / 2 - 78, W, "center")
        g.setFont(F.mid); SC(UI_COLORS.yellow)
        g.printf("LOADOUT: " .. string.upper(m.loadout or "-"), 0, H / 2 - 20, W, "center")
        g.setFont(F.small); SC(UI_COLORS.grey)
        g.printf(string.format("¡Prepárate!  %0.0f", math.ceil(m.introTimer)), 0, H / 2 + 30, W, "center")

    elseif gp == "roundend" then
        SC(UI_COLORS.black, 0.5); g.rectangle("fill", 0, H / 2 - 60, W, 120)
        g.setFont(F.big)
        if m.roundWinner == 0 then SC(UI_COLORS.grey)
        elseif m.roundWinner == 1 then SC(UI_COLORS.blueTeam)
        elseif m.roundWinner == 2 then SC(UI_COLORS.redTeam)
        else SC(UI_COLORS.grey) end
        local txt = (m.roundWinner == 0 and "EMPATE")
                 or (m.roundWinner == 1 and "GANA AZUL")
                 or (m.roundWinner == 2 and "GANA ROJO") or "FIN DE RONDA"
        g.printf(txt, 0, H / 2 - 40, W, "center")

    elseif gp == "matchend" then
        SC(UI_COLORS.black, 0.65); g.rectangle("fill", 0, H / 2 - 110, W, 220)
        g.setFont(F.big)
        if m.matchWinner == 1 then SC(UI_COLORS.blueTeam) else SC(UI_COLORS.redTeam) end
        g.printf((m.matchWinner == 1 and "AZUL" or "ROJO") .. " GANA LA PARTIDA",
                 0, H / 2 - 78, W, "center")
        g.setFont(F.mid); SC(UI_COLORS.white)
        g.printf(m.scores[1] .. "  -  " .. m.scores[2], 0, H / 2 + 2, W, "center")
        g.setFont(F.small); SC(UI_COLORS.grey)
        g.printf("Nueva partida en breve...", 0, H / 2 + 48, W, "center")
    end
end

-- ============================================================================
-- DRAW PRINCIPAL: despacha según el estado de la máquina de UI.
-- ============================================================================
function ui.draw(nc, app)
    local g = love.graphics

    if ui.state == ui.STATE_MENU then
        drawMenu(app)
        g.setColor(1, 1, 1, 1)
        return
    end

    -- En partida (GAMEPLAY / OVERTIME_ALERT / INTRO / MATCH_END):
    -- 1) feedback de combate; 2) HUD perimetral; 3) banners de fase.
    drawDamageVignette()
    drawCaptureProgress(nc)
    drawHitmarker()
    drawKillfeed()

    drawScoreboard(nc)
    drawOperatorPanel(nc)
    drawWeaponModule(nc)
    drawReloadAlert(nc)

    drawPhaseBanners(nc)

    g.setColor(1, 1, 1, 1)
    g.setLineWidth(1)
end

return ui
