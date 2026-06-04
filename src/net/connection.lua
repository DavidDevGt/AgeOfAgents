-- src/net/connection.lua
-- Envoltura UDP no bloqueante sobre LuaSocket (incluido en LÖVE).
-- "Connected UDP": fijamos el peer con setpeername, así send/receive van
-- siempre hacia/desde el servidor sin repetir la dirección.

local socket = require("socket")

local Connection = {}
Connection.__index = Connection

function Connection.new(host, port)
    local self = setmetatable({}, Connection)
    self.udp = assert(socket.udp())
    self.udp:settimeout(0)                 -- no bloquear nunca el hilo de render
    assert(self.udp:setpeername(host, port))
    self.host, self.port = host, port
    return self
end

-- Envía un datagrama (string). Silencioso ante errores transitorios de UDP.
function Connection:send(msg)
    self.udp:send(msg)
end

-- Devuelve el siguiente datagrama recibido, o nil si no hay ninguno.
function Connection:receive()
    local data, err = self.udp:receive()
    if data then return data end
    -- 'timeout' es lo normal en modo no bloqueante; cualquier otro error se ignora.
    return nil
end

function Connection:close()
    if self.udp then self.udp:close() end
end

return Connection
