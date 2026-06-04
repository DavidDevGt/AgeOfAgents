-- src/entities/killfeed.lua
-- Killfeed: las notificaciones de baja de la esquina superior derecha.
-- Alimentado por el evento "D|victim|killer|weapon" del servidor (weapon es el
-- ID del arma: sniper/pistol/rifle/knife/smoke).
--
-- Render objetivo:  [Azul #1]  ☠ Sniper  →  [Rojo #2]
-- Las entradas viven 4 s y se desvanecen suavemente.
--
-- Anti-GC: pool circular de tamaño fijo. La única asignación es la del string
-- ya compuesto en push() — que ocurre SOLO cuando hay una baja (evento raro),
-- nunca en el hot-path de dibujo. draw() no asigna nada.

local Class = require("src.core.class")

local KF_LIFE  = 4.0
local KF_FADE  = 0.6     -- segundos de desvanecimiento al final
local MAX_KF   = 6

-- Nombre corto y legible del arma a partir de su ID autoritativo.
local WEAPON_LABEL = {
    sniper = "Sniper",
    pistol = "Pistola",
    rifle  = "Rifle",
    knife  = "Cuchillo",
    smoke  = "Humo",
}

local Killfeed = Class("Killfeed")

function Killfeed:init()
    self.pool = {}
    for i = 1, MAX_KF do
        -- text precompuesto + colores de cada bando (escalares, sin tablas).
        self.pool[i] = {
            life = 0, text = "",
            kr = 1, kg = 1, kb = 1,   -- color del autor (killer)
            vr = 1, vg = 1, vb = 1,   -- color de la víctima
        }
    end
    self.next = 1
end

local function teamName(team) return team == 2 and "Rojo" or "Azul" end

-- Asigna (r,g,b) del bando a tres campos de la entrada. Sin asignar tablas.
local function teamColor(e, prefix, team)
    local r, g, b
    if team == 1 then r, g, b = 0.40, 0.70, 1.0
    else              r, g, b = 1.0, 0.50, 0.35 end
    if prefix == "k" then e.kr, e.kg, e.kb = r, g, b
    else                  e.vr, e.vg, e.vb = r, g, b end
end

-- Registra una baja. `players` es view.players para resolver equipos.
function Killfeed:push(victimId, killerId, weaponId, players)
    local e = self.pool[self.next]
    self.next = self.next % MAX_KF + 1

    local vp = players[victimId]
    local kp = players[killerId]
    local vTeam = vp and vp.team or 0
    local kTeam = kp and kp.team or 0
    local wlabel = WEAPON_LABEL[weaponId] or weaponId or "?"

    teamColor(e, "v", vTeam)
    teamColor(e, "k", kTeam)

    if killerId == 0 or not kp then
        -- Muerte sin autor (entorno / desconexión).
        e.text = string.format("%s #%d  se eliminó", teamName(vTeam), victimId)
        e.kr, e.kg, e.kb = 0.7, 0.7, 0.7
    else
        e.text = string.format("%s #%d   %s   %s #%d",
            teamName(kTeam), killerId, wlabel, teamName(vTeam), victimId)
    end
    e.life = KF_LIFE
end

function Killfeed:update(dt)
    local pool = self.pool
    for i = 1, #pool do
        if pool[i].life > 0 then
            pool[i].life = pool[i].life - dt
            if pool[i].life < 0 then pool[i].life = 0 end
        end
    end
end

-- Dibuja las entradas vivas, las más recientes arriba. font es opcional.
function Killfeed:draw(font)
    local g = love.graphics
    if font then g.setFont(font) end
    local fh = g.getFont():getHeight()
    local W = g.getWidth()
    local pad, rowH = 10, fh + 10
    local y = 12

    -- Recorremos del más nuevo al más viejo para apilar arriba->abajo.
    local idx = (self.next - 2) % MAX_KF + 1
    for _ = 1, MAX_KF do
        local e = self.pool[idx]
        if e.life > 0 then
            local a = 1
            if e.life < KF_FADE then a = e.life / KF_FADE end
            local tw = g.getFont():getWidth(e.text)
            local boxW = tw + pad * 2
            local x = W - boxW - 12

            g.setColor(0, 0, 0, 0.5 * a)
            g.rectangle("fill", x, y, boxW, rowH, 4, 4)
            -- Borde acentuado con el color del autor.
            g.setColor(e.kr, e.kg, e.kb, 0.9 * a)
            g.setLineWidth(2)
            g.rectangle("line", x, y, boxW, rowH, 4, 4)

            g.setColor(0.92, 0.92, 0.95, a)
            g.print(e.text, x + pad, y + 5)
            y = y + rowH + 4
        end
        idx = (idx - 2) % MAX_KF + 1
    end
    g.setLineWidth(1)
end

function Killfeed:clear()
    for i = 1, #self.pool do self.pool[i].life = 0 end
end

return Killfeed
