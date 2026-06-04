-- conf.lua
-- Configuración de la ventana y módulos de LÖVE 11.5.
-- Se ejecuta antes que main.lua. No instanciar nada del juego aquí.

function love.conf(t)
    t.identity         = "gulag_arena"      -- carpeta de save (appdata)
    t.version          = "11.5"             -- versión de LÖVE objetivo
    t.console          = false              -- poner true en Windows para stdout

    t.window.title     = "Gulag Arena: 1v1 / 2v2 Showdown"
    t.window.width     = 1280
    t.window.height    = 720
    t.window.resizable = false
    t.window.vsync     = 1                  -- 1 = vsync activado (estabiliza dt)
    t.window.msaa      = 0
    t.window.highdpi   = false

    -- Módulos: desactivamos lo que no usamos para arranque más limpio.
    t.modules.audio    = true
    t.modules.physics  = false              -- usamos física propia (top-down, sin box2d)
    t.modules.joystick = false
    t.modules.touch    = false
    t.modules.video    = false
end
