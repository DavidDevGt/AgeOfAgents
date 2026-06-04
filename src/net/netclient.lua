-- src/net/netclient.lua
-- Cliente de red: traduce el protocolo del servidor Go en una "vista" local
-- (solo lectura) que el renderer dibuja, e interpola entre snapshots para
-- suavizar el movimiento. También captura el input del jugador local y lo
-- envía como comando compacto.
--
-- NO contiene lógica de juego: el servidor Go es la autoridad. Aquí solo hay
-- presentación + transporte. Mantiene además telemetría (RTT, snap/s, kB/s)
-- para el overlay de depuración.

local Connection = require("src.net.connection")
local Tracers    = require("src.entities.bullet")
local Debris     = require("src.entities.debris")

local atan2 = math.atan2 or math.atan

-- Máscara de botones (debe coincidir con netcode/protocol.go).
local BTN_FIRE, BTN_FIREP, BTN_ADS, BTN_RELOAD, BTN_SWAP = 1, 2, 4, 8, 16

-- Al reaparecer/teletransportarse la posición autoritativa salta mucho:
-- por encima de este umbral NO interpolamos (snap), evitando el "deslizamiento".
local SNAP_DIST2 = 140 * 140

local PING_INTERVAL = 0.5

local NetClient = {}
NetClient.__index = NetClient

local function split(line)
    local t, n = {}, 0
    for field in (line .. "|"):gmatch("(.-)|") do
        n = n + 1
        t[n] = field
    end
    return t
end

function NetClient.new(host, port)
    local self = setmetatable({}, NetClient)
    self.conn      = Connection.new(host, port)
    self.connected = false
    self.myId      = 0
    self.mode      = 1
    self.seq       = 0
    self.prev      = { fire = false, reload = false, swap = false }
    self.tracers   = Tracers()
    self.debris    = Debris()

    -- Estado para la sincronización de coberturas destruibles:
    --   snapTick  = sello de snapshot (para detectar coberturas ausentes/rotas)
    --   lastRound = última ronda vista (al cambiar, restaura las coberturas)
    self.snapTick  = 0
    self.lastRound = -1

    -- Callbacks de feedback (los instala la capa de UI con ui.attach). El
    -- NetClient los invoca al parsear el flujo autoritativo, manteniéndose
    -- desacoplado de la UI. Por defecto nil = sin oyente.
    self.onKill        = nil   -- (victimId, killerId, weaponId)
    self.onHit         = nil   -- (isKill)  -- impacto del jugador local
    self.onLocalDamage = nil   -- (amount)  -- el jugador local recibió daño

    -- Handshake/keepalive.
    self.joinTimer = 0          -- reenvía "J" hasta conectar
    self.pingTimer = 0

    -- Telemetría.
    self.rtt       = 0          -- ms (suavizado)
    self.stats     = { snaps = 0, inputs = 0, bytesIn = 0,
                       snapsPerSec = 0, inputsPerSec = 0, kbInPerSec = 0,
                       lastBytes = 0, _t = 0 }

    self.view = {
        bounds   = { x = 0, y = 0, w = 0, h = 0 },
        walls    = {},
        covers   = {}, coversMaxId = 0, -- coberturas destruibles, indexadas por id
        players  = {},
        smokes   = {}, smokesN = 0,     -- pool reutilizado (sin GC por snapshot)
        grenades = {}, grenadesN = 0,
        match = {
            gamePhase = "waiting", phase = "idle",
            roundTime = 0, scores = { 0, 0 }, roundNumber = 0,
            loadout = "-", roundWinner = -1, matchOver = false, matchWinner = 0,
            introTimer = 0, endTimer = 0,
            flag = { x = 0, y = 0, r = 0, active = false },
            captureFrac = 0, captureTeam = 0, overtimeLeft = 0,
        },
    }
    return self
end

function NetClient:join()
    if self.conn then self.conn:send("J") end
end

function NetClient:disconnect()
    if self.conn then
        self.conn:send("B")
        self.conn:close()
        self.conn = nil
    end
    self.connected = false
end

function NetClient:update(dt)
    -- 1) Drenar datagramas entrantes.
    if self.conn then
        local data = self.conn:receive()
        local guard = 0
        while data and guard < 32 do
            self.stats.bytesIn = self.stats.bytesIn + #data
            self.stats.lastBytes = #data
            self:_parse(data)
            guard = guard + 1
            data = self.conn:receive()
        end
    end

    -- 2) Handshake robusto: si aún no conectamos, reenviar "J" periódicamente
    -- (UDP puede perder el primer J o su bienvenida).
    if self.conn and not self.connected then
        self.joinTimer = self.joinTimer - dt
        if self.joinTimer <= 0 then
            self.conn:send("J")
            self.joinTimer = 0.25
        end
    end

    -- 3) Enviar input + ping de RTT.
    if self.connected and self.conn then
        self:_sendInput()
        self.pingTimer = self.pingTimer - dt
        if self.pingTimer <= 0 then
            self.conn:send(string.format("Q|%.4f", love.timer.getTime()))
            self.pingTimer = PING_INTERVAL
        end
    end

    -- 4) Interpolación visual + decaimiento de efectos efímeros.
    self:_interpolate(dt)
    self.tracers:update(dt)
    self.debris:update(dt)

    -- 5) Telemetría por segundo.
    local st = self.stats
    st._t = st._t + dt
    if st._t >= 1 then
        st.snapsPerSec  = st.snaps / st._t
        st.inputsPerSec = st.inputs / st._t
        st.kbInPerSec   = st.bytesIn / st._t / 1024
        st.snaps, st.inputs, st.bytesIn, st._t = 0, 0, 0, 0
    end
end

-- ===================== Parseo del protocolo =====================
function NetClient:_parse(packet)
    local sawSnap = false
    for line in packet:gmatch("[^\n]+") do
        local f = split(line)
        local tag = f[1]

        if tag == "S" then
            self.stats.snaps = self.stats.snaps + 1
            sawSnap = true
            self.snapTick = self.snapTick + 1
            local m = self.view.match
            m.gamePhase   = f[2]
            m.phase       = f[3]
            m.roundTime   = tonumber(f[4]) or 0
            m.scores[1]   = tonumber(f[5]) or 0
            m.scores[2]   = tonumber(f[6]) or 0
            m.roundNumber = tonumber(f[7]) or 0
            m.loadout     = f[8]
            m.roundWinner = tonumber(f[9]) or -1
            m.matchOver   = f[10] == "1"
            m.matchWinner = tonumber(f[11]) or 0
            m.introTimer  = tonumber(f[12]) or 0
            m.endTimer    = tonumber(f[13]) or 0
            -- Nuevo snapshot: reiniciar CONTADORES (no las tablas) de efímeros.
            self.view.smokesN   = 0
            self.view.grenadesN = 0
            -- Cambio de ronda: el servidor restauró las coberturas; el cliente
            -- las reactiva a vida completa para evitar desincronización visual.
            if m.roundNumber ~= self.lastRound then
                self.lastRound = m.roundNumber
                local cov = self.view.covers
                for id = 1, self.view.coversMaxId do
                    local c = cov[id]
                    if c then c.active = true; c.broken = false; c.hp = c.maxhp end
                end
            end

        elseif tag == "F" then
            local m = self.view.match
            local fl = m.flag
            fl.active = f[2] == "1"
            fl.x = tonumber(f[3]) or 0
            fl.y = tonumber(f[4]) or 0
            fl.r = tonumber(f[5]) or 0
            m.captureFrac  = tonumber(f[6]) or 0
            m.captureTeam  = tonumber(f[7]) or 0
            m.overtimeLeft = tonumber(f[8]) or 0

        elseif tag == "P" then
            local id = tonumber(f[2])
            local x, y = tonumber(f[4]) or 0, tonumber(f[5]) or 0
            local p = self.view.players[id]
            if not p then
                -- hurt: temporizador de flash rojo al recibir daño (s).
                -- deathAnim: rampa 0->1 para fundir el cadáver al morir.
                p = { pos = { x = x, y = y }, rpos = { x = x, y = y },
                      hurt = 0, deathAnim = 0 }
                self.view.players[id] = p
            else
                -- Snap si la posición autoritativa dio un salto grande (respawn).
                local dx, dy = x - p.rpos.x, y - p.rpos.y
                if dx * dx + dy * dy > SNAP_DIST2 then
                    p.rpos.x, p.rpos.y = x, y
                end
            end

            -- Detectar daño/muerte comparando con el snapshot anterior. El
            -- servidor no envía un evento "recibí daño": lo deducimos del HP.
            local prevHp    = p.hp
            local prevAlive = p.alive
            local newHp     = tonumber(f[7]) or 0
            local newAlive  = f[8] == "1"
            if prevHp and newHp < prevHp and newAlive then
                p.hurt = 0.18
                -- Daño al jugador LOCAL -> viñeta de daño en la UI.
                if id == self.myId and self.onLocalDamage then
                    self.onLocalDamage(prevHp - newHp)
                end
            end
            if prevAlive and not newAlive then
                p.deathAnim = 0          -- arranca el fundido del cadáver
            elseif not prevAlive and newAlive then
                p.deathAnim = 0          -- respawn: limpia el estado de muerte
            end

            p.id        = id
            p.team      = tonumber(f[3]) or 1
            p.pos.x, p.pos.y = x, y
            p.aim       = tonumber(f[6]) or 0
            p.hp        = newHp
            p.alive     = newAlive
            p.state     = f[9]
            p.slot      = f[10]
            p.wname     = f[11]
            p.ammo        = tonumber(f[12]) or 0
            p.mag         = tonumber(f[13]) or 0
            p.reloading   = f[14] == "1"
            p.reserveAmmo = tonumber(f[15]) or 0

        elseif tag == "K" then
            local n = self.view.smokesN + 1
            local arr = self.view.smokes
            local s = arr[n]; if not s then s = {}; arr[n] = s end
            s.x, s.y, s.r = tonumber(f[2]) or 0, tonumber(f[3]) or 0, tonumber(f[4]) or 0
            self.view.smokesN = n

        elseif tag == "G" then
            local n = self.view.grenadesN + 1
            local arr = self.view.grenades
            local gr = arr[n]; if not gr then gr = {}; arr[n] = gr end
            gr.x, gr.y = tonumber(f[2]) or 0, tonumber(f[3]) or 0
            self.view.grenadesN = n

        elseif tag == "T" then
            self.tracers:spawn(
                tonumber(f[2]) or 0, tonumber(f[3]) or 0,
                tonumber(f[4]) or 0, tonumber(f[5]) or 0,
                tonumber(f[6]) or 1, tonumber(f[7]) or 1, tonumber(f[8]) or 1)

        elseif tag == "q" then
            -- Pong: medir RTT (ms) con suavizado exponencial.
            local sent = tonumber(f[2])
            if sent then
                local sample = (love.timer.getTime() - sent) * 1000
                self.rtt = (self.rtt > 0) and (self.rtt * 0.7 + sample * 0.3) or sample
            end

        elseif tag == "W" then
            self.myId = tonumber(f[2]) or 0
            self.mode = tonumber(f[3]) or 1
            local b = self.view.bounds
            b.x, b.y = tonumber(f[4]) or 0, tonumber(f[5]) or 0
            b.w, b.h = tonumber(f[6]) or 0, tonumber(f[7]) or 0
            self.view.walls = {}
            self.view.covers = {}              -- mapa nuevo: limpia coberturas
            self.view.coversMaxId = 0
            self.connected = true

        elseif tag == "BOX" then
            -- Geometría estática de una cobertura destruible: id|x|y|w|h|maxhp.
            local id = tonumber(f[2]) or 0
            local x = tonumber(f[3]) or 0
            local y = tonumber(f[4]) or 0
            local w = tonumber(f[5]) or 0
            local h = tonumber(f[6]) or 0
            local maxhp = tonumber(f[7]) or 1
            self.view.covers[id] = {
                x = x, y = y, w = w, h = h,
                cx = x + w * 0.5, cy = y + h * 0.5,
                maxhp = maxhp, hp = maxhp,
                active = true, broken = false, seen = 0,
            }
            if id > self.view.coversMaxId then self.view.coversMaxId = id end

        elseif tag == "WALL" then
            local w = self.view.walls
            w[#w + 1] = {
                x = tonumber(f[2]) or 0, y = tonumber(f[3]) or 0,
                w = tonumber(f[4]) or 0, h = tonumber(f[5]) or 0,
            }

        elseif tag == "D" then
            -- Baja: "D|victim|killer|weaponID". Notifica al killfeed de la UI.
            if self.onKill then
                self.onKill(tonumber(f[2]) or 0, tonumber(f[3]) or 0, f[4])
            end

        elseif tag == "H" then
            -- Impacto confirmado: "H|attacker|kill". Solo nos importa el del
            -- jugador local (hitmarker autoritativo).
            local attacker = tonumber(f[2]) or 0
            if attacker == self.myId and self.onHit then
                self.onHit(f[3] == "1")
            end

        elseif tag == "C" then
            -- Estado de una cobertura activa: "C|id|hp". Marca vista (seen) para
            -- la detección de rupturas, y actualiza la vida (grietas en cliente).
            local id = tonumber(f[2]) or 0
            local c = self.view.covers[id]
            if c then
                c.hp = tonumber(f[3]) or c.hp
                c.active = true
                c.seen = self.snapTick
            end

        elseif tag == "B" then
            -- Ruptura inmediata: "B|id". Escombros + sacar de la vista.
            self:_breakCover(tonumber(f[2]) or 0)
        end
    end

    -- Autocorrección: tras un snapshot, cualquier cobertura activa NO listada
    -- (su "seen" quedó atrás) debe estar rota aunque se perdiera el evento "B".
    if sawSnap then
        local cov = self.view.covers
        for id = 1, self.view.coversMaxId do
            local c = cov[id]
            if c and c.active and not c.broken and c.seen ~= self.snapTick then
                self:_breakCover(id)
            end
        end
    end
end

-- Marca una cobertura como rota (idempotente) y lanza escombros una sola vez.
function NetClient:_breakCover(id)
    local c = self.view.covers[id]
    if not c or c.broken then return end
    c.broken = true
    c.active = false
    c.hp = 0
    self.debris:burst(c.cx, c.cy)
end

-- ===================== Input local =====================
function NetClient:_sendInput()
    local kb = love.keyboard
    local mx = (kb.isDown("d") and 1 or 0) - (kb.isDown("a") and 1 or 0)
    local my = (kb.isDown("s") and 1 or 0) - (kb.isDown("w") and 1 or 0)

    local me = self.view.players[self.myId]
    local msx, msy = love.mouse.getPosition()
    local aim = 0
    if me then aim = atan2(msy - me.rpos.y, msx - me.rpos.x) end

    local fire   = love.mouse.isDown(1)
    local ads    = love.mouse.isDown(2)
    local reload = kb.isDown("r")
    local swap   = kb.isDown("q")

    local btn = 0
    if fire then btn = btn + BTN_FIRE end
    if fire and not self.prev.fire then btn = btn + BTN_FIREP end
    if ads then btn = btn + BTN_ADS end
    if reload and not self.prev.reload then btn = btn + BTN_RELOAD end
    if swap and not self.prev.swap then btn = btn + BTN_SWAP end
    self.prev.fire, self.prev.reload, self.prev.swap = fire, reload, swap

    self.seq = self.seq + 1
    self.stats.inputs = self.stats.inputs + 1
    self.conn:send(string.format("I|%d|%d|%d|%.4f|%d", self.seq, mx, my, aim, btn))
end

-- ===================== Interpolación =====================
function NetClient:_interpolate(dt)
    local k = 1 - math.exp(-22 * dt)
    for _, p in pairs(self.view.players) do
        p.rpos.x = p.rpos.x + (p.pos.x - p.rpos.x) * k
        p.rpos.y = p.rpos.y + (p.pos.y - p.rpos.y) * k
        -- Decaimiento del flash de daño y rampa del fundido de muerte.
        if p.hurt > 0 then
            p.hurt = p.hurt - dt
            if p.hurt < 0 then p.hurt = 0 end
        end
        if not p.alive and p.deathAnim < 1 then
            p.deathAnim = p.deathAnim + dt * 3   -- ~0.33 s de fundido
            if p.deathAnim > 1 then p.deathAnim = 1 end
        end
    end
end

-- Error de interpolación (px) del jugador local: útil en el overlay de debug.
function NetClient:localInterpError()
    local me = self.view.players[self.myId]
    if not me then return 0 end
    local dx, dy = me.pos.x - me.rpos.x, me.pos.y - me.rpos.y
    return math.sqrt(dx * dx + dy * dy)
end

return NetClient
