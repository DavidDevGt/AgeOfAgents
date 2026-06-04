-- src/render/assets.lua
-- Fábrica de texturas PROCEDURALES. No carga ningún PNG: todo se genera por
-- matemáticas (love.math.noise + gradientes radiales) y se hornea UNA sola vez
-- en Images inmutables. Después el renderer solo hace love.graphics.draw() con
-- transformaciones, así que el coste por frame es cero (sin asignaciones, sin
-- recálculo de píxeles).
--
-- Filosofía anti-GC: este módulo asigna memoria a propósito, pero SOLO en
-- Assets.load(), llamado una vez desde love.load(). El hot-path de dibujo
-- nunca toca este archivo salvo para leer .img ya construidos.

-- atan2: LuaJIT (LÖVE) lo trae; Lua 5.3+ usa math.atan(y, x). Cubrimos ambos.
local atan2 = math.atan2 or math.atan

local Assets = { loaded = false }

-- smoothstep clásico: transición suave 0->1 en [e0,e1].
local function smoothstep(e0, e1, x)
    local t = (x - e0) / (e1 - e0)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return t * t * (3 - 2 * t)
end

-- ----------------------------------------------------------------------------
-- Suelo de hormigón/tierra, TILEABLE (sin costuras). Tileabilidad exacta:
-- muestreamos el ruido sobre un toro 4D (cos/sin de los ángulos u,v), técnica
-- estándar para que los bordes encajen al repetir la textura.
-- ----------------------------------------------------------------------------
local function buildFloor(size)
    local data = love.image.newImageData(size, size)
    local TAU = math.pi * 2
    local f1, f2 = 1.6, 4.7   -- frecuencias de las dos octavas

    data:mapPixel(function(x, y)
        local u, v = (x / size) * TAU, (y / size) * TAU
        -- Octava base (manchas grandes) + octava fina (grano), ambas tileables.
        local n1 = love.math.noise(math.cos(u) * f1 + 3.1, math.sin(u) * f1 + 3.1,
                                    math.cos(v) * f1 + 3.1, math.sin(v) * f1 + 3.1)
        local n2 = love.math.noise(math.cos(u) * f2 + 9.7, math.sin(u) * f2 + 9.7,
                                    math.cos(v) * f2 + 9.7, math.sin(v) * f2 + 9.7)
        local n = n1 * 0.7 + n2 * 0.3
        -- Hormigón frío y sucio: base oscura modulada por el ruido.
        local base = 0.085 + n * 0.07
        local r = base * 0.95
        local g = base * 1.0
        local b = base * 1.12
        -- Vetas sutiles más oscuras (grietas) donde el ruido fino cae.
        if n2 < 0.30 then
            local k = smoothstep(0.30, 0.10, n2) * 0.5
            r, g, b = r * (1 - k), g * (1 - k), b * (1 - k)
        end
        return r, g, b, 1
    end)

    local img = love.graphics.newImage(data)
    img:setWrap("repeat", "repeat")
    img:setFilter("linear", "linear")
    return img
end

-- ----------------------------------------------------------------------------
-- Puff de humo: disco blanco con caída radial suave y borde "deshilachado" por
-- ruido, para que al superponer varios crezca una nube orgánica en vez de
-- círculos perfectos. RGB blanco puro: el renderer lo tiñe con setColor().
-- ----------------------------------------------------------------------------
local function buildSmokePuff(size)
    local data = love.image.newImageData(size, size)
    local c = (size - 1) * 0.5
    local inv = 1 / c

    data:mapPixel(function(x, y)
        local dx, dy = (x - c) * inv, (y - c) * inv
        local d = math.sqrt(dx * dx + dy * dy)
        -- Núcleo denso, caída suave hacia el borde.
        local a = smoothstep(1.0, 0.15, d)
        -- Fractura del borde con ruido para un perfil algodonoso.
        local ang = atan2(dy, dx)
        local frill = love.math.noise(math.cos(ang) * 2.2 + 5,
                                      math.sin(ang) * 2.2 + 5, d * 3.0)
        a = a * (0.55 + frill * 0.65)
        if a > 1 then a = 1 elseif a < 0 then a = 0 end
        return 1, 1, 1, a
    end)

    local img = love.graphics.newImage(data)
    img:setFilter("linear", "linear")
    return img
end

-- ----------------------------------------------------------------------------
-- Viñeta de tensión: bordes oscuros, centro transparente. Se hornea pequeña y
-- se estira a pantalla completa (es un gradiente suave, el escalado no se nota).
-- Da el "look COD" sin coste por frame.
-- ----------------------------------------------------------------------------
local function buildVignette(w, h)
    local data = love.image.newImageData(w, h)
    local cx, cy = (w - 1) * 0.5, (h - 1) * 0.5
    local maxd = math.sqrt(cx * cx + cy * cy)

    data:mapPixel(function(x, y)
        local dx, dy = (x - cx) / maxd, (y - cy) / maxd
        local d = math.sqrt(dx * dx + dy * dy)
        local a = smoothstep(0.55, 1.05, d) * 0.6
        return 0, 0, 0, a
    end)

    local img = love.graphics.newImage(data)
    img:setFilter("linear", "linear")
    return img
end

-- Llamar UNA vez desde love.load(). Idempotente.
function Assets.load()
    if Assets.loaded then return end
    Assets.floor    = buildFloor(256)
    Assets.smoke    = buildSmokePuff(96)
    Assets.vignette = buildVignette(320, 180)
    Assets.loaded   = true
end

return Assets
