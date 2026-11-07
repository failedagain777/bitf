local SpaceInvadersIO = require("spaceinvaders")

local COLOR = { 85 / 255, 15 / 255, 247 / 255 }
local BACKGROUND = { 4 / 255, 6 / 255, 20 / 255 }

local SCALE = 3

-- Key (scancode) -> input signal
local KEYPAD_MAP = {
        ['1'] = "p1_start",
        ['w'] = "p1_shot",
        ['a'] = "p1_left",
        ['2'] = "p2_start",
        ['d'] = "p1_right",
        ['up'] = "p2_shot",
        ['left'] = "p2_left",
        ['right'] = "p2_right",
        ['c'] = "coin",
        ['t'] = "tilt"
}

-- Sound name -> Source (filled in love.load)
local SOUNDS_SOURCE = {}

-- Sounds that loop while the bit is on
local REPEATS = { ["ufo_lowpitch"] = true }

-- state = true restarts the sound; false stops it only if it loops
local function sound_handler(name, state)
        local source = SOUNDS_SOURCE[name]

        if not source then return end

        if state then
                source:stop()
                source:play()
        elseif REPEATS[name] then
                source:stop()
        end
end

local emulator
local time_acc = 0

function love.load(args)
        love.window.setTitle("Space Invaders")
        love.window.setMode(SpaceInvadersIO.SCREEN_WIDTH * SCALE, SpaceInvadersIO.SCREEN_HEIGHT * SCALE)
        love.graphics.setBackgroundColor( BACKGROUND[1], BACKGROUND[2], BACKGROUND[3] )

        -- The ROM is usually four files put in consecutive addresses, so pass the path of their concatenation
        local path = assert(args[1], "No ROM path was given")
        local rom_content = assert(love.filesystem.read(path))

        emulator = SpaceInvadersIO:new(sound_handler)

        assert(emulator)

        emulator:load(rom_content, string.len(rom_content), 0x0000)

        --[[
                bit1    bit0   ships
                0       0      3
                0       1      4
                1       0      5
                1       1      6
        ]]--
        emulator:set_signal("dip_ships_bit0", false)
        emulator:set_signal("dip_ships_bit1", true)

        -- Extra ship at 1500 (false) or 1000 (true)
        emulator:set_signal("dip_bonus", true)

        -- Hide (true) or show (false) the coin info
        emulator:set_signal("dip_coin_info", true)

        -- Sounds available at https://www.classicgaming.cc/classics/space-invaders/sounds
        SOUNDS_SOURCE = {
                ["explosion"] = love.audio.newSource("sounds/explosion.wav", "static"),
                ["fastinvader1"] = love.audio.newSource("sounds/fastinvader1.wav", "static"),
                ["fastinvader2"] = love.audio.newSource("sounds/fastinvader2.wav", "static"),
                ["fastinvader3"] = love.audio.newSource("sounds/fastinvader3.wav", "static"),
                ["fastinvader4"] = love.audio.newSource("sounds/fastinvader4.wav", "static"),
                ["invaderkilled"] = love.audio.newSource("sounds/invaderkilled.wav", "static"),
                ["shoot"] = love.audio.newSource("sounds/shoot.wav", "static"),
                ["ufo_highpitch"] = love.audio.newSource("sounds/ufo_highpitch.wav", "static"),
                ["ufo_lowpitch"] = love.audio.newSource("sounds/ufo_lowpitch.wav", "static")
        }

        SOUNDS_SOURCE["ufo_lowpitch"]:setLooping(true)
end

function love.update(dt)
        -- Must be 60Hz: run one emulated frame (2 interrupts) per FRAMETIME

        time_acc = time_acc + dt

        while time_acc >= SpaceInvadersIO.FRAMETIME do
                emulator:run_frame()

                time_acc = time_acc - SpaceInvadersIO.FRAMETIME
        end
end

function love.draw()
        love.graphics.setColor( COLOR[1], COLOR[2], COLOR[3] )

        for y = 0, SpaceInvadersIO.SCREEN_HEIGHT - 1 do
                for x = 0, SpaceInvadersIO.SCREEN_WIDTH - 1 do
                        if emulator:get_pixel(x, y) then
                                love.graphics.rectangle("fill", x * SCALE, y * SCALE, SCALE, SCALE)
                        end
                end
        end
end

function love.keypressed(key, scancode, isrepeat)
        local keypad = KEYPAD_MAP[scancode]

        if keypad then
                emulator:set_signal(keypad, true)
        end

        if key == 'escape' then
                love.event.quit()
        end
end

function love.keyreleased(key, scancode)
        local keypad = KEYPAD_MAP[scancode]

        if keypad then
                emulator:set_signal(keypad, false)
        end
end

