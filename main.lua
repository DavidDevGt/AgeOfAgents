-- main.lua
-- Cliente LÖVE de Gulag Arena. La autoridad vive en el backend Go; aquí solo
-- conectamos, enviamos input y renderizamos la vista interpolada.
--
-- Estados del cliente (NO confundir con las fases de partida, que las dicta el
-- servidor en nc.view.match.gamePhase):
--   MENU -> CONNECTING -> PLAY    (Esc desconecta y vuelve a MENU)

local NetClient = require("src.net.netclient")
local Render    = require("src.render")

-- Dirección del backend. Cámbiala para jugar contra un servidor remoto.
local HOST, PORT = "127.0.0.1", 40000

local app = {
    state    = "MENU",
    nc       = nil,
    timer    = 0,        -- timeout de conexión
    error    = nil,
    debug    = false,    -- overlay de depuración (F1)
}

local fonts = {}

local function connect()
    app.error = nil
    local ok, ncOrErr = pcall(NetClient.new, HOST, PORT)
    if not ok then
        app.error = "Socket: " .. tostring(ncOrErr)
        return
    end
    app.nc = ncOrErr
    app.nc:join()
    app.state = "CONNECTING"
    app.timer = 3.0
end

local function disconnect()
    if app.nc then app.nc:disconnect() end
    app.nc = nil
    app.state = "MENU"
end

function love.load()
    love.graphics.setBackgroundColor(0.05, 0.05, 0.06)
    fonts.small = love.graphics.newFont(14)
    fonts.kf    = love.graphics.newFont(15)   -- killfeed
    fonts.mid   = love.graphics.newFont(22)
    fonts.ammo  = love.graphics.newFont(40)   -- contador de munición (COD)
    fonts.big   = love.graphics.newFont(48)
    love.graphics.setFont(fonts.small)

    -- Hornea las texturas procedurales una sola vez (sin assets externos).
    Render.load()
end

function love.update(dt)
    if dt > 0.1 then dt = 0.1 end

    if app.state == "CONNECTING" then
        app.nc:update(dt)
        if app.nc.connected then
            app.state = "PLAY"
        else
            app.timer = app.timer - dt
            if app.timer <= 0 then
                disconnect()
                app.error = "Sin respuesta del servidor. ¿Está corriendo el backend Go?"
            end
        end

    elseif app.state == "PLAY" then
        app.nc:update(dt)
    end
end

function love.draw()
    local g = love.graphics
    local W, H = g.getWidth(), g.getHeight()

    if app.state == "PLAY" then
        Render.draw(app.nc, fonts)
        if app.debug then Render.drawDebug(app.nc, fonts) end
        return
    end

    -- MENU / CONNECTING
    g.setFont(fonts.big); g.setColor(1, 0.85, 0.3)
    g.printf("GULAG ARENA", 0, H/2 - 150, W, "center")
    g.setFont(fonts.mid); g.setColor(0.9, 0.9, 0.9)
    g.printf("1v1 / 2v2 Showdown", 0, H/2 - 92, W, "center")

    g.setFont(fonts.small); g.setColor(0.7, 0.75, 0.8)
    g.printf("Backend Go (autoritativo)  ·  " .. HOST .. ":" .. PORT, 0, H/2 - 50, W, "center")

    if app.state == "CONNECTING" then
        g.setColor(0.9, 0.9, 0.5)
        g.printf("Conectando...", 0, H/2, W, "center")
    else
        g.setColor(0.85, 0.85, 0.85)
        g.printf("[Enter]  Conectar al servidor\n[Esc]  Salir", 0, H/2, W, "center")
    end

    if app.error then
        g.setColor(1, 0.4, 0.4)
        g.printf(app.error, 0, H/2 + 70, W, "center")
    end

    g.setColor(0.5, 0.5, 0.5)
    g.printf("Arranca el backend con:  cd backend  &&  go run ./cmd/server",
             0, H - 40, W, "center")
end

function love.keypressed(key)
    if key == "f1" then
        app.debug = not app.debug
        return
    end

    if key == "escape" then
        if app.state == "MENU" then
            love.event.quit()
        else
            disconnect()
        end
        return
    end

    if app.state == "MENU" then
        if key == "return" or key == "kpenter" then
            connect()
        end
    end
end

function love.quit()
    if app.nc then app.nc:disconnect() end
end
