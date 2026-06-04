-- src/entities/bullet.lua
-- Gestor de TRAZADORAS (tracers): el efecto visual de las balas hitscan.
-- Las balas hitscan son instantáneas (no viajan), así que solo necesitamos
-- una línea que se desvanece. Es un EFECTO de cliente, pero el servidor decide
-- cuándo nace (al disparar, evento "T") para mantener consistencia.
--
-- Estética: cada trazadora se dibuja en DOS pasadas — un glow aditivo ancho y
-- un núcleo fino casi blanco — para que parezca un destello de energía y no una
-- raya plana. El SNIPER se distingue por su color autoritativo (azul dominante,
-- ver weapon.go) y se rinde como un haz ROJO grueso y persistente; el resto
-- (rifle/pistola) como hilos amarillo-blancos que se apagan en ~0.1 s.
--
-- Anti-GC: pool de tamaño fijo. spawn() reutiliza ranuras; jamás se asignan
-- tablas tras la inicialización. El color se guarda como escalares r,g,b.

local Class = require("src.core.class")

local LIFE_THIN  = 0.10    -- rifle / pistola / cuchillo
local LIFE_THICK = 0.16    -- sniper (el haz aguanta un pelín más)
local MAX_TRACERS = 64

local Tracers = Class("Tracers")

function Tracers:init()
    self.pool = {}
    for i = 1, MAX_TRACERS do
        self.pool[i] = { x1 = 0, y1 = 0, x2 = 0, y2 = 0,
                         life = 0, maxlife = LIFE_THIN,
                         r = 1, g = 1, b = 1, sniper = false }
    end
    self.next = 1
end

-- Detecta el sniper por su firma de color autoritativa: es el único arma cuyo
-- canal azul domina (0.6, 0.9, 1.0). Rifle/pistola tienen el rojo dominante.
local function isSniperColor(r, g, b)
    return b > r and b >= 0.95
end

-- Registra una trazadora desde el evento "T" del servidor.
function Tracers:spawn(x1, y1, x2, y2, r, g, b)
    local t = self.pool[self.next]
    self.next = self.next % MAX_TRACERS + 1
    t.x1, t.y1, t.x2, t.y2 = x1, y1, x2, y2

    if isSniperColor(r, g, b) then
        t.sniper  = true
        t.maxlife = LIFE_THICK
        -- El brief pide un haz rojo para el rifle de precisión.
        t.r, t.g, t.b = 1.0, 0.25, 0.18
    else
        t.sniper  = false
        t.maxlife = LIFE_THIN
        t.r, t.g, t.b = r or 1, g or 1, b or 1
    end
    t.life = t.maxlife
end

function Tracers:update(dt)
    local pool = self.pool
    for i = 1, #pool do
        local t = pool[i]
        if t.life > 0 then
            t.life = t.life - dt
            if t.life < 0 then t.life = 0 end
        end
    end
end

function Tracers:draw()
    local g = love.graphics
    local pool = self.pool

    -- 1) Pasada de GLOW aditivo: anchos translúcidos que se suman en color.
    g.setBlendMode("add")
    for i = 1, #pool do
        local t = pool[i]
        if t.life > 0 then
            local f = t.life / t.maxlife              -- 1 -> 0
            local w = t.sniper and 7 or 3
            g.setColor(t.r, t.g, t.b, 0.35 * f)
            g.setLineWidth(w)
            g.line(t.x1, t.y1, t.x2, t.y2)
        end
    end

    -- 2) Pasada de NÚCLEO: hilo brillante casi blanco sobre el glow.
    g.setBlendMode("alpha")
    for i = 1, #pool do
        local t = pool[i]
        if t.life > 0 then
            local f = t.life / t.maxlife
            local w = t.sniper and 3 or 1.5
            -- Mezcla hacia blanco para el "calor" del trazo.
            g.setColor(0.5 + t.r * 0.5, 0.5 + t.g * 0.5, 0.5 + t.b * 0.5, f)
            g.setLineWidth(w)
            g.line(t.x1, t.y1, t.x2, t.y2)
        end
    end
    g.setLineWidth(1)
end

function Tracers:clear()
    for i = 1, #self.pool do self.pool[i].life = 0 end
end

-- Número de trazadoras visibles ahora mismo (para el overlay de debug).
function Tracers:aliveCount()
    local n = 0
    for i = 1, #self.pool do
        if self.pool[i].life > 0 then n = n + 1 end
    end
    return n
end

return Tracers
