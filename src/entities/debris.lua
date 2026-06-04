-- src/entities/debris.lua
-- Micro-sistema de PARTÍCULAS de escombros: cuadrados de madera diminutos que
-- salen despedidos al romperse una cobertura (evento "B" del servidor). Le dan
-- peso visual al impacto. Física simple: velocidad inicial radial + "gravedad"
-- y fricción, desvanecimiento en ~0.5 s.
--
-- Anti-GC: pool de tamaño fijo (ring buffer). burst()/spawn() reutilizan
-- ranuras muertas; jamás se asignan tablas tras la inicialización. draw() no
-- asigna nada (transformaciones push/translate/rotate, sin tablas de color).

local Class = require("src.core.class")

local LIFE      = 0.5
local MAX_PARTS = 64
local GRAVITY   = 420     -- px/s^2 (peso visual, pantalla = +y hacia abajo)
local FRICTION  = 2.2

local Debris = Class("Debris")

function Debris:init()
    self.pool = {}
    for i = 1, MAX_PARTS do
        self.pool[i] = { x = 0, y = 0, vx = 0, vy = 0,
                         life = 0, size = 3, rot = 0, vr = 0 }
    end
    self.next = 1
end

local function spawnOne(self, x, y)
    local p = self.pool[self.next]
    self.next = self.next % MAX_PARTS + 1
    local ang = love.math.random() * 2 * math.pi
    local spd = 80 + love.math.random() * 160
    p.x, p.y = x, y
    p.vx = math.cos(ang) * spd
    p.vy = math.sin(ang) * spd - 60          -- impulso inicial hacia arriba
    p.life = LIFE
    p.size = 2 + love.math.random() * 3
    p.rot  = love.math.random() * 2 * math.pi
    p.vr   = (love.math.random() * 2 - 1) * 12
end

-- Lanza una ráfaga de escombros desde (x,y) — el centro de la cobertura rota.
function Debris:burst(x, y)
    for _ = 1, 10 do spawnOne(self, x, y) end
end

function Debris:update(dt)
    local pool = self.pool
    for i = 1, #pool do
        local p = pool[i]
        if p.life > 0 then
            local f = 1 - FRICTION * dt
            if f < 0 then f = 0 end
            p.vx = p.vx * f
            p.vy = (p.vy + GRAVITY * dt) * f
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            p.rot = p.rot + p.vr * dt
            p.life = p.life - dt
            if p.life < 0 then p.life = 0 end
        end
    end
end

function Debris:draw()
    local g = love.graphics
    local pool = self.pool
    for i = 1, #pool do
        local p = pool[i]
        if p.life > 0 then
            local a = p.life / LIFE
            g.push()
            g.translate(p.x, p.y)
            g.rotate(p.rot)
            -- Astilla de madera (marrón) con un borde más oscuro.
            g.setColor(0.45, 0.30, 0.16, a)
            g.rectangle("fill", -p.size, -p.size, p.size * 2, p.size * 2)
            g.setColor(0.25, 0.16, 0.08, a)
            g.rectangle("line", -p.size, -p.size, p.size * 2, p.size * 2)
            g.pop()
        end
    end
    g.setColor(1, 1, 1, 1)
end

function Debris:clear()
    for i = 1, #self.pool do self.pool[i].life = 0 end
end

return Debris
