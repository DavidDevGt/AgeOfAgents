-- main.lua
-- Cliente LÖVE de Gulag Arena. La autoridad vive en el backend Go; aquí solo
-- conectamos, enviamos input y renderizamos.
--
-- Tres capas de presentación:
--   * src/render.lua          -> MUNDO diegético (arena, soldados, balas, humo)
--   * src/ui/ui_manager.lua   -> UI/UX/feedback no diegético (menú, HUD, etc.)
--   * src/net/netclient.lua   -> transporte + vista interpolada (autoritativa)
--
-- Estados de la APP (conexión):  MENU -> CONNECTING -> PLAY
-- La máquina de estados de UI (5 estados de pantalla) la deriva ui_manager a
-- partir de la fase de partida que dicta el servidor.

local NetClient = require("src.net.netclient")
local Render    = require("src.render")
local ui        = require("src.ui.ui_manager")

-- Dirección del backend. Cámbiala para jugar contra un servidor remoto.
local HOST, PORT = "127.0.0.1", 40000

local app = {
    state = "MENU",
    nc    = nil,
    timer = 0,        -- timeout de conexión
    error = nil,
    debug = false,    -- overlay de depuración (F1)
}

local fonts = {}      -- usados por Render (mundo + overlay de debug)

local function connect()
    app.error = nil
    local ok, ncOrErr = pcall(NetClient.new, HOST, PORT)
    if not ok then
        app.error = "Socket: " .. tostring(ncOrErr)
        return
    end
    app.nc = ncOrErr
    ui.attach(app.nc)         -- instala callbacks de feedback (hit/kill/daño)
    app.nc:join()
    app.state = "CONNECTING"
    app.timer = 3.0
end

local function disconnect()
    if app.nc then app.nc:disconnect() end
    app.nc = nil
    app.state = "MENU"
    ui.reset()
end

function love.load()
    love.graphics.setBackgroundColor(0.05, 0.05, 0.06)
    fonts.small = love.graphics.newFont(14)
    fonts.mid   = love.graphics.newFont(22)
    fonts.big   = love.graphics.newFont(48)
    love.graphics.setFont(fonts.small)

    Render.load()             -- texturas procedurales del mundo (1 vez)
    ui.load(fonts)            -- fuentes + viñeta de daño de la UI (1 vez)
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

    -- La UI se actualiza siempre (animaciones de menú, fades, lerps, killfeed).
    ui.update(dt, app.nc, app)
end

function love.draw()
    if app.state == "PLAY" then
        Render.draw(app.nc, fonts)     -- mundo
        ui.draw(app.nc, app)           -- HUD + feedback + banners
        if app.debug then Render.drawDebug(app.nc, fonts) end
        return
    end

    -- MENU / CONNECTING: la UI dibuja el menú (y el overlay de conexión).
    ui.draw(app.nc, app)
end

function love.keypressed(key)
    if key == "f1" then
        app.debug = not app.debug
        return
    end

    if app.state == "MENU" then
        local action = ui.keypressed(key, app)
        if action == "find" then
            connect()
        elseif action == "quit" then
            love.event.quit()
        elseif action == nil and key == "escape" then
            love.event.quit()
        end
    else
        -- CONNECTING / PLAY: Esc cancela / desconecta.
        if key == "escape" then disconnect() end
    end
end

function love.mousepressed(x, y, button)
    if app.state ~= "MENU" then return end   -- en juego el click es disparo (netclient)
    local action = ui.mousepressed(x, y, button, app)
    if action == "find" then
        connect()
    elseif action == "quit" then
        love.event.quit()
    end
end

function love.quit()
    if app.nc then app.nc:disconnect() end
end
