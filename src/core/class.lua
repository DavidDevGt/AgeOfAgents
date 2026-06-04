-- src/core/class.lua
-- Sistema de clases mínimo basado en metatablas (OOP clásico).
-- Elegido sobre un ECS completo por claridad para un prototipo de este alcance,
-- manteniendo la posibilidad de migrar a ECS más adelante sin reescribir la lógica.
--
-- Uso:
--   local Class  = require("src.core.class")
--   local Player = Class("Player")
--   function Player:init(x, y) self.x, self.y = x, y end
--   local Bot = Class("Bot", Player)            -- herencia
--   function Bot:init(x, y) Bot.super.init(self, x, y) end
--   local p = Player(10, 20)                     -- llamar a la clase la instancia

local function Class(name, parent)
    local cls = {}
    cls.__index = cls
    cls.__name  = name
    cls.super   = parent

    if parent then
        -- Hereda métodos del padre buscando en su tabla cuando no existen aquí.
        setmetatable(cls, { __index = parent })
    end

    -- Llamar a la tabla-clase como función construye una instancia.
    setmetatable(cls, {
        __index = parent,
        __call  = function(self, ...)
            local obj = setmetatable({}, self)
            if obj.init then obj:init(...) end
            return obj
        end,
    })

    return cls
end

return Class
