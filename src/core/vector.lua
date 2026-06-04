-- src/core/vector.lua
-- Matemática vectorial 2D orientada a CERO asignaciones en el hot-path.
--
-- Filosofía anti-GC: NO devolvemos tablas nuevas en update(). Las funciones
-- mutan un vector destino que el llamante posee y reutiliza, o devuelven
-- escalares. Hay un pequeño pool de vectores "scratch" para cálculos temporales.
--
-- Un vector es simplemente { x = number, y = number }. Sin metatablas para
-- evitar overhead y mantener los datos serializables (red).

-- math.atan2 existe en LuaJIT (LÖVE por defecto) pero fue eliminado en Lua 5.3+.
-- En Lua 5.4, math.atan acepta dos argumentos (y, x). Cubrimos ambos runtimes.
local atan2 = math.atan2 or math.atan
local sqrt, cos, sin = math.sqrt, math.cos, math.sin

local Vec = {}

-- Crea un vector. Usar SOLO en load/setup, nunca por frame.
function Vec.new(x, y)
    return { x = x or 0, y = y or 0 }
end

-- Copia src dentro de dst (in-place). Devuelve dst.
function Vec.copy(dst, src)
    dst.x, dst.y = src.x, src.y
    return dst
end

function Vec.set(dst, x, y)
    dst.x, dst.y = x, y
    return dst
end

-- dst = a + b * s   (b escalado por s, útil para integrar velocidad)
function Vec.addScaled(dst, a, b, s)
    dst.x = a.x + b.x * s
    dst.y = a.y + b.y * s
    return dst
end

function Vec.add(dst, a, b)
    dst.x, dst.y = a.x + b.x, a.y + b.y
    return dst
end

function Vec.sub(dst, a, b)
    dst.x, dst.y = a.x - b.x, a.y - b.y
    return dst
end

function Vec.scale(dst, a, s)
    dst.x, dst.y = a.x * s, a.y * s
    return dst
end

function Vec.dot(a, b)
    return a.x * b.x + a.y * b.y
end

function Vec.lenSq(a)
    return a.x * a.x + a.y * a.y
end

function Vec.len(a)
    return sqrt(a.x * a.x + a.y * a.y)
end

-- Distancia al cuadrado entre dos puntos (evita sqrt para comparaciones).
function Vec.distSq(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy
end

function Vec.dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

-- Normaliza dst in-place. Devuelve la longitud original (0 si era nulo).
function Vec.normalize(dst)
    local l = sqrt(dst.x * dst.x + dst.y * dst.y)
    if l > 1e-9 then
        local inv = 1 / l
        dst.x, dst.y = dst.x * inv, dst.y * inv
    else
        dst.x, dst.y = 0, 0
    end
    return l
end

-- Construye un vector unitario a partir de un ángulo (radianes), in-place.
function Vec.fromAngle(dst, angle)
    dst.x, dst.y = cos(angle), sin(angle)
    return dst
end

-- Ángulo del vector (a->b) en radianes.
function Vec.angleTo(a, b)
    return atan2(b.y - a.y, b.x - a.x)
end

-- Interpolación lineal in-place: dst = a + (b - a) * t. Base de la
-- interpolación visual del cliente entre snapshots del servidor.
function Vec.lerp(dst, a, b, t)
    dst.x = a.x + (b.x - a.x) * t
    dst.y = a.y + (b.y - a.y) * t
    return dst
end

----------------------------------------------------------------------
-- Pool de scratch: vectores temporales reutilizables para cálculos
-- intermedios dentro de un mismo frame. Adquiere, usa, NO guardes
-- referencias entre frames.
----------------------------------------------------------------------
local POOL_SIZE = 16
local pool, poolIdx = {}, 0
for i = 1, POOL_SIZE do pool[i] = { x = 0, y = 0 } end

-- Devuelve un vector temporal del pool. Cíclico: con 16 sobran para un frame.
function Vec.scratch()
    poolIdx = poolIdx % POOL_SIZE + 1
    return pool[poolIdx]
end

return Vec
