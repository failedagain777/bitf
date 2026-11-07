local bit = require("bit")
local Intel8080 = require("intel8080")

local SpaceInvadersIO = {}

SpaceInvadersIO.SCREEN_WIDTH = 224 -- Display size in pixels (the video RAM is rotated 90 degrees)
SpaceInvadersIO.SCREEN_HEIGHT = 256

SpaceInvadersIO.CPU_FREQUENCY = 2e6 -- 2 MHz
SpaceInvadersIO.FPS = 60
SpaceInvadersIO.FRAMETIME = 1 / SpaceInvadersIO.FPS
SpaceInvadersIO.CYCLES_PER_FRAME = SpaceInvadersIO.CPU_FREQUENCY / SpaceInvadersIO.FPS
SpaceInvadersIO.HALF_CYCLES_PER_FRAME = SpaceInvadersIO.CYCLES_PER_FRAME / 2 -- One interrupt per half frame

local VRAM_START_ADDR = 0x2400 -- Video RAM goes from 0x2400 to 0x3FFF, 1 bit per pixel

-- Input ports (read with IN)
local INP0 = 0x00
local INP1 = 0x01
local INP2 = 0x02
local SHFT_IN = 0x03 -- Result of the hardware shift register

-- Output ports (written with OUT)
local SHFTAMNT = 0x02 -- Shift amount (bits 0-2)
local SOUND1 = 0x03 -- Sound bits (OUT3_*)
local SHFT_DATA = 0x04 -- Data pushed into the shift register
local SOUND2 = 0x05 -- Sound bits (OUT5_*)
local WATCHDOG = 0x06 -- Watchdog reset (not emulated)

local function BIT(b)
        return bit.lshift(0x01, b)
end

-- Bits of each input port
local INP0_ALWAYS_ONE = BIT(1) + BIT(2) + BIT(3)
local INP0_FIRE = BIT(4)
local INP0_LEFT = BIT(5)
local INP0_RIGHT = BIT(6)

local INP1_CREDIT = BIT(0)
local INP1_P2_START = BIT(1)
local INP1_P1_START = BIT(2)
local INP1_ALWAYS_ONE = BIT(3)
local INP1_P1_SHOT = BIT(4)
local INP1_P1_LEFT = BIT(5)
local INP1_P1_RIGHT = BIT(6)

local INP2_TILT = BIT(2)
local INP2_P2_SHOT = BIT(4)
local INP2_P2_LEFT = BIT(5)
local INP2_P2_RIGHT = BIT(6)
local INP2_DIP_HIDE_COIN_INFO = BIT(7)

-- Signal name -> { input port, bit mask }, used by set_signal
local SIGNALS = {
        coin = { INP1, INP1_CREDIT },
        p1_start = { INP1, INP1_P1_START },
        p1_shot = { INP1, INP1_P1_SHOT },
        p1_left = { INP1, INP1_P1_LEFT },
        p1_right = { INP1, INP1_P1_RIGHT },
        p2_start = { INP1, INP1_P2_START },
        p2_shot = { INP2, INP2_P2_SHOT },
        p2_left = { INP2, INP2_P2_LEFT },
        p2_right = { INP2, INP2_P2_RIGHT },
        tilt = { INP2, INP2_TILT },

        dip_ships_bit0 = { INP2, BIT(0) }, -- Ships: 00 = 3, 01 = 4, 10 = 5, 11 = 6 (bit1 bit0)
        dip_ships_bit1 = { INP2, BIT(1) },
        dip_bonus      = { INP2, BIT(3) }, -- Extra ship at 1500 (0) or 1000 (1)
        dip_coin_info  = { INP2, INP2_DIP_HIDE_COIN_INFO }, -- Coin info: shown (0) or hidden (1)
}

-- Bits of each sound port (1 = sound on)
local OUT3_UFO = BIT(0) -- UFO
local OUT3_SHOT = BIT(1) -- Shot
local OUT3_FLASH = BIT(2) -- Player explosion
local OUT3_INVADER_DIE = BIT(3) -- Invader explosion

local OUT5_FLEET_MOVEMENT_1 = BIT(0) -- Fleet steps (1-4)
local OUT5_FLEET_MOVEMENT_2 = BIT(1)
local OUT5_FLEET_MOVEMENT_3 = BIT(2)
local OUT5_FLEET_MOVEMENT_4 = BIT(3)

local OUT5_UFO_HIT = BIT(4) -- UFO explosion

-- Bit mask -> sound name
local SOUNDS1 = {
        [OUT3_FLASH] = "explosion",
        [OUT3_INVADER_DIE] = "invaderkilled",
        [OUT3_SHOT] = "shoot",
        [OUT3_UFO] = "ufo_lowpitch"
}

local SOUNDS2 = {
        [OUT5_FLEET_MOVEMENT_1] = "fastinvader1",
        [OUT5_FLEET_MOVEMENT_2] = "fastinvader2",
        [OUT5_FLEET_MOVEMENT_3] = "fastinvader3",
        [OUT5_FLEET_MOVEMENT_4] = "fastinvader4",
        [OUT5_UFO_HIT] = "ufo_highpitch"
}

function SpaceInvadersIO:new(sound_handler)
        local o = {}
        self.__index = self
        setmetatable(o, self)

        o.cpu = Intel8080:new(0x10000, o) -- 64KB address space, this object handles the I/O ports

        -- Values returned by IN (1 = pressed/on)
        o.in_ports = {
                [INP0] = INP0_ALWAYS_ONE + INP0_FIRE + INP0_LEFT + INP0_RIGHT,
                [INP1] = INP1_ALWAYS_ONE,
                [INP2] = 0x00,
                [SHFT_IN] = 0x00
        }

        -- Last values written by OUT
        o.out_ports = {
                [SHFTAMNT] = 0x00,
                [SOUND1] = 0x00,
                [SHFT_DATA] = 0x00,
                [SOUND2] = 0x00,
                [WATCHDOG] = 0x00
        }

        o.sound_handler = sound_handler or function() end -- sound_handler(name, state)

        o.shift_reg = 0x0000 -- 16-bit shift register (new data enters on the high byte)

        return o
end

-- Call sound_handler for each sound bit that changed (rising = start, falling = end)
-- Bits with no change are ignored, so the current state (playing or not) is kept
function SpaceInvadersIO:update_sound(port, value)
        local sounds
        local previous

        if port == SOUND1 then
                previous = self.out_ports[SOUND1]
                self.out_ports[SOUND1] = value
                sounds = SOUNDS1
        else
                previous = self.out_ports[SOUND2]
                self.out_ports[SOUND2] = value
                sounds = SOUNDS2
        end

        local rising = bit.band(bit.bnot(previous), value)
        local falling = bit.band(previous, bit.bnot(value))

        for mask, name in pairs(sounds) do
                if bit.band(rising, mask) ~= 0x00 then
                        self.sound_handler(name, true)
                elseif bit.band(falling, mask) ~= 0x00 then
                        self.sound_handler(name, false)
                end
        end
end

-- Called by the CPU on IN
function SpaceInvadersIO:read(port)
        return self.in_ports[port]
end

-- Called by the CPU on OUT
function SpaceInvadersIO:write(port, value)
        value = bit.band(value, 0xFF)

        if port == SHFTAMNT then
                -- Only the lower 3 bits are used; changing the amount changes the result right away
                self.out_ports[SHFTAMNT] = bit.band(value, 0x07)
                self.in_ports[SHFT_IN] = bit.band(bit.rshift(self.shift_reg, 8 - self.out_ports[SHFTAMNT]), 0xFF)
        elseif port == SHFT_DATA then
                -- The old high byte moves to the low byte, the new value becomes the high byte
                self.shift_reg = bit.bor(bit.lshift(value, 8), bit.rshift(self.shift_reg, 8))
                self.in_ports[SHFT_IN] = bit.band(bit.rshift(self.shift_reg, 8 - self.out_ports[SHFTAMNT]), 0xFF)
        elseif port == SOUND1 or port == SOUND2 then
                self:update_sound(port, value)
        else
                self.out_ports[port] = value
        end
end

-- Copy the ROM into memory, starting at offset
function SpaceInvadersIO:load(rom, size, offset)
        for i = 0, size - 1, 1 do
                self.cpu:write_mem(offset + i, string.byte(rom, i + 1))
        end
end

function SpaceInvadersIO:set_input(port, mask)
        self.in_ports[port] = bit.band(bit.bor(self.in_ports[port], mask), 0xFF)
end

function SpaceInvadersIO:clear_input(port, mask)
        self.in_ports[port] = bit.band(bit.band(self.in_ports[port], bit.bnot(mask)), 0xFF)
end

function SpaceInvadersIO:write_input(port, mask, cond)
        if cond then
                self:set_input(port, mask)
        else
                self:clear_input(port, mask)
        end
end

-- Turn a named input signal on or off
function SpaceInvadersIO:set_signal(name, state)
        local entry = SIGNALS[name]

        self:write_input(entry[1], entry[2], state == 0x01 or state == true)
end

-- Returns true if the pixel (x, y) is on
-- The video RAM is stored in columns (32 bytes per x), from the bottom of the screen to the top
function SpaceInvadersIO:get_pixel(x, y)
        local col_size = SpaceInvadersIO.SCREEN_HEIGHT / 8
        local col_offset = col_size * x
        local byte_index = math.floor((SpaceInvadersIO.SCREEN_HEIGHT - 1 - y) / 8)
        local addr = VRAM_START_ADDR + col_offset + byte_index

        local vram_byte = self.cpu:read_mem(addr)
        local pixel = bit.band(bit.rshift(vram_byte, 7 - (y % 8)), 0x01)

        return pixel == 0x01
end

-- Run the CPU for at least n cycles
local function ncycles(self, n)
        local count = 0

        while count < n do
                count = count + self.cpu:step()
        end
end

-- Run one frame: two half frames, each one ends with an interrupt
function SpaceInvadersIO:run_frame()
        ncycles(self, SpaceInvadersIO.HALF_CYCLES_PER_FRAME)

        self.cpu:interrupt(0xCF) -- RST 1 (middle of the screen)

        ncycles(self, SpaceInvadersIO.HALF_CYCLES_PER_FRAME)

        self.cpu:interrupt(0xD7) -- RST 2 (end of the screen, vblank)
end

return SpaceInvadersIO

