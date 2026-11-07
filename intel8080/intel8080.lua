local bit = require("bit")

local Intel8080 = {}

function Intel8080:new(memsize, io)
        local o = {}
        self.__index = self
        setmetatable(o, self)

        local a = 0x00 -- Accumulator (8-bit)
        local flags = 0x02 -- S Z 0 AC 0 P 1 CY
        local b = 0x00 -- B, C, D, E, H, L: general purpose registers (8-bit)
        local c = 0x00
        local d = 0x00
        local e = 0x00
        local h = 0x00
        local l = 0x00

        local sp = 0x0000 -- Stack pointer (16-bit)
        local pc = 0x0000 -- Program counter (16-bit)

        local inte = false -- Interrupt enable flip-flop
        local vector = nil -- Pending interrupt opcode (nil = none)
        local halted = false -- Set by HLT, cleared when an interrupt is serviced

        o.a = a
        o.flags = flags
        o.b = b
        o.c = c
        o.d = d
        o.e = e
        o.h = h
        o.l = l

        o.sp = sp
        o.pc = pc

        o.inte = inte
        o.vector = vector

        o.halted = halted

        o.io = io -- Host object with read(port) and write(port, value)

        o.memsize = memsize -- Bytes of installed memory
        o.mem = {}

        for i = 0, o.memsize - 1, 1 do
                o.mem[i] = 0x00
        end

        return o
end

-- Flag bits (bit 1 is always 1, bits 3 and 5 always 0)
local FLAG_SIGN = 0x80
local FLAG_ZERO = 0x40
local FLAG_AUX = 0x10
local FLAG_PARITY = 0x04
local FLAG_CARRY = 0x01

-- Truncate a value to 8 bits
local function byte(value)
        return bit.band(value, 0xFF)
end

-- Truncate a value to 16 bits
local function word(value)
        return bit.band(value, 0xFFFF)
end

local function u16(high, low)
        return bit.bor(bit.lshift(byte(high), 8), byte(low))
end

-- Read the 8-bit immediate that follows the opcode
local function imm8(self)
        local value = self:read_mem(self.pc)

        self.pc = word(self.pc + 1)

        return value
end

-- Read the 16-bit immediate that follows the opcode (low byte first)
local function imm16(self)
        local low = imm8(self)
        local high = imm8(self)

        return u16(high, low)
end

-- HL as a 16-bit value (the address pointed to by M)
local function hl(self)
        return u16(self.h, self.l)
end

-- Read an 8-bit operand by its 3-bit register code (0=B 1=C 2=D 3=E 4=H 5=L 6=M 7=A)
-- M is the memory byte at HL. Codes 0x8-0xF repeat 0x0-0x7
local getters = {
        [0x0] = function(self) return self.b end,
        [0x1] = function(self) return self.c end,
        [0x2] = function(self) return self.d end,
        [0x3] = function(self) return self.e end,
        [0x4] = function(self) return self.h end,
        [0x5] = function(self) return self.l end,
        [0x6] = function(self) return self:read_mem(hl(self)) end,
        [0x7] = function(self) return self.a end,

        [0x8] = function(self) return self.b end,
        [0x9] = function(self) return self.c end,
        [0xA] = function(self) return self.d end,
        [0xB] = function(self) return self.e end,
        [0xC] = function(self) return self.h end,
        [0xD] = function(self) return self.l end,
        [0xE] = function(self) return self:read_mem(hl(self)) end,
        [0xF] = function(self) return self.a end
}

-- Write an 8-bit operand by its register code (same codes as above)
local setters = {
        [0x0] = function(self, value) self.b = byte(value) end,
        [0x1] = function(self, value) self.c = byte(value) end,
        [0x2] = function(self, value) self.d = byte(value) end,
        [0x3] = function(self, value) self.e = byte(value) end,
        [0x4] = function(self, value) self.h = byte(value) end,
        [0x5] = function(self, value) self.l = byte(value) end,
        [0x6] = function(self, value) self:write_mem(hl(self), value) end,
        [0x7] = function(self, value) self.a = byte(value) end
}

-- Read a 16-bit register pair by its code (0=BC 1=DE 2=HL 3=SP)
local pair_getters = {
        [0x0] = function(self) return u16(self.b, self.c) end,
        [0x1] = function(self) return u16(self.d, self.e) end,
        [0x2] = function(self) return hl(self) end,
        [0x3] = function(self) return word(self.sp) end
}

-- Write a 16-bit register pair by its code (same codes as above)
local pair_setters = {
        [0x0] = function(self, value) self.b = byte(bit.rshift(value, 8)); self.c = byte(value) end,
        [0x1] = function(self, value) self.d = byte(bit.rshift(value, 8)); self.e = byte(value) end,
        [0x2] = function(self, value) self.h = byte(bit.rshift(value, 8)); self.l = byte(value) end,
        [0x3] = function(self, value) self.sp = word(value) end
}

-- Evaluate a condition by its code (0=NZ 1=Z 2=NC 3=C 4=PO 5=PE 6=P 7=M)
local conditions = {
        [0x0] = function(self) return not self:read_flag(FLAG_ZERO) end,
        [0x1] = function(self) return self:read_flag(FLAG_ZERO) end,
        [0x2] = function(self) return not self:read_flag(FLAG_CARRY) end,
        [0x3] = function(self) return self:read_flag(FLAG_CARRY) end,
        [0x4] = function(self) return not self:read_flag(FLAG_PARITY) end,
        [0x5] = function(self) return self:read_flag(FLAG_PARITY) end,
        [0x6] = function(self) return not self:read_flag(FLAG_SIGN) end,
        [0x7] = function(self) return self:read_flag(FLAG_SIGN) end
}

-- Addresses beyond the installed memory read as 0x00 and ignore writes
function Intel8080:read_mem(addr)
        return self.mem[bit.band(addr, 0xFFFF)] or 0x00
end

function Intel8080:write_mem(addr, value)
        addr = bit.band(addr, 0xFFFF)

        if addr < self.memsize then
                self.mem[addr] = byte(value)
        end
end

function Intel8080:read_flag(mask)
        return bit.band(self.flags, mask) ~= 0x00
end

function Intel8080:set_flag(mask)
        self.flags = bit.bor(self.flags, mask)
end

function Intel8080:clear_flag(mask)
        self.flags = bit.band(self.flags, bit.bnot(mask))
end

function Intel8080:write_flag(mask, cond)
        if cond then
                self:set_flag(mask)
        else
                self:clear_flag(mask)
        end
end

local PARITY = {}

for i = 0x00, 0xFF, 1 do
        local count = 0

        for b = 1, 8, 1 do
                count = count + bit.band(bit.rshift(i, b - 1), 0x01)
        end

        PARITY[i] = count % 2 == 0
end

-- Returns true if the number of 1 bits is even (parity flag)
local function parity(value)
        return PARITY[value]
end

local function negative(value)
        return bit.band(value, 0x80) ~= 0x00
end

-- Shared by ADD/ADC/ADI/ACI: A = A + value + cy, updates all flags
local function Add(self, value, cy)
        local acc = self.a
        local carry = cy and 0x01 or 0x00

        local result = value + acc + carry
        local low = bit.band(acc, 0x0F) + bit.band(value, 0x0F) + carry

        self.a = byte(result)

        self:write_flag(FLAG_CARRY, result > 0xFF)
        self:write_flag(FLAG_SIGN, negative(self.a))
        self:write_flag(FLAG_ZERO, self.a == 0)
        self:write_flag(FLAG_PARITY, parity(self.a))
        self:write_flag(FLAG_AUX, low > 0x0F)
end

-- Add immediate to A with carry
function Intel8080:aci()
        Add(self, imm8(self), self:read_flag(FLAG_CARRY))
end

-- Add register/memory to A with carry
function Intel8080:adc(reg)
        Add(self, getters[reg](self), self:read_flag(FLAG_CARRY))
end

-- Add register/memory to A
function Intel8080:add(reg)
        Add(self, getters[reg](self), false)
end

-- Add immediate to A
function Intel8080:adi()
        Add(self, imm8(self), false)
end

-- Shared by ANA/ANI: A = A AND value, clears CY (AC = bit 3 of A OR value)
local function And(self, value)
        local result = bit.band(self.a, value)

        self:write_flag(FLAG_ZERO, result == 0)
        self:write_flag(FLAG_SIGN, negative(result))
        self:write_flag(FLAG_PARITY, parity(result))
        self:write_flag(FLAG_AUX, bit.band(bit.bor(self.a, value), 0x08) ~= 0x00)
        self:clear_flag(FLAG_CARRY)
        self.a = result
end

-- AND register/memory with A
function Intel8080:ana(reg)
        And(self, getters[reg](self))
end

-- AND immediate with A
function Intel8080:ani()
        And(self, imm8(self))
end

-- Push PC (the return address) on the stack and jump to addr if cond
local function CallIf(self, addr, cond)
        if cond then
                local ret = self.pc

                self:write_mem(self.sp - 1, bit.rshift(ret, 8))
                self:write_mem(self.sp - 2, ret)

                self.sp = bit.band(self.sp - 2, 0xFFFF)
                self.pc = addr
        end
end

-- Call subroutine at the immediate address
function Intel8080:call()
        CallIf(self, imm16(self), true)
end

-- Call subroutine if the condition is true
function Intel8080:ccc(cc)
        CallIf(self, imm16(self), conditions[cc](self))
end

-- Complement A
function Intel8080:cma()
        self.a = byte(bit.bnot(self.a))
end

-- Complement the carry flag
function Intel8080:cmc()
        self:write_flag(FLAG_CARRY, not self:read_flag(FLAG_CARRY))
end

-- Shared by CMP/CPI: A - value, only the flags change (Z = equal, CY = A < value)
local function Compare(self, value)
        local mvalue = byte(bit.bnot(value))
        local result = byte(self.a + mvalue + 1)
        local low = bit.band(self.a, 0x0F) + bit.band(mvalue, 0x0F) + 0x01

        self:write_flag(FLAG_ZERO, value == self.a)
        self:write_flag(FLAG_SIGN, negative(result))
        self:write_flag(FLAG_PARITY, parity(result))
        self:write_flag(FLAG_CARRY, self.a < value)
        self:write_flag(FLAG_AUX, low > 0x0F)
end

-- Compare register/memory with A
function Intel8080:cmp(reg)
        Compare(self, getters[reg](self))
end

-- Compare immediate with A
function Intel8080:cpi()
        Compare(self, imm8(self))
end

-- Decimal adjust A: corrects the result of a BCD addition into two BCD digits
function Intel8080:daa()
        local low = bit.band(self.a, 0x0F)
        local cy = self:read_flag(FLAG_CARRY)
        local ac = false

        if low > 0x09 or self:read_flag(FLAG_AUX) then
                ac = (low + 0x06) > 0x0F
                cy = cy or (self.a + 0x06) > 0xFF
                self.a = byte(self.a + 0x06)
        end

        local high = bit.band(bit.rshift(self.a, 4), 0x0F)

        if high > 0x09 or cy then
                cy = cy or (self.a + 0x60) > 0xFF
                self.a = byte(self.a + 0x60)
        end

        self:write_flag(FLAG_AUX, ac)
        self:write_flag(FLAG_ZERO, self.a == 0)
        self:write_flag(FLAG_SIGN, negative(self.a))
        self:write_flag(FLAG_PARITY, parity(self.a))
        self:write_flag(FLAG_CARRY, cy)
end

-- Add register pair to HL, only CY is affected
function Intel8080:dad(rp)
        local value = pair_getters[rp](self)
        local result = value + hl(self)

        self:write_flag(FLAG_CARRY, result > 0xFFFF)
        self.h = byte(bit.rshift(result, 8))
        self.l = byte(result)
end

-- Decrement register/memory (CY is not affected)
function Intel8080:dcr(reg)
        local value = getters[reg](self)
        local mvalue = byte(bit.bnot(0x01))
        local result = byte(value + mvalue + 1)
        local low = bit.band(value, 0x0F) + bit.band(mvalue, 0x0F) + 0x01

        setters[reg](self, result)

        self:write_flag(FLAG_SIGN, negative(result))
        self:write_flag(FLAG_ZERO, result == 0)
        self:write_flag(FLAG_PARITY, parity(result))
        self:write_flag(FLAG_AUX, low > 0x0F)
end

-- Decrement register pair (no flags)
function Intel8080:dcx(rp)
        local value = pair_getters[rp](self)
        local result = word(value + word(bit.bnot(0x0001)) + 0x0001)

        pair_setters[rp](self, result)
end

-- Disable interrupts
function Intel8080:di()
        self.inte = false
end

-- Enable interrupts
function Intel8080:ei()
        self.inte = true
end

-- Halt until an interrupt is serviced
function Intel8080:hlt()
        self.halted = true
end

-- Read the port into A
function Intel8080:_in()
        local port = imm8(self)

        self.a = byte(self.io:read(port))
end

-- Increment register/memory (CY is not affected)
function Intel8080:inr(reg)
        local value = getters[reg](self)
        local result = byte(value + 0x01)
        local low = bit.band(value, 0x0F) + 0x01

        setters[reg](self, result)

        self:write_flag(FLAG_ZERO, result == 0)
        self:write_flag(FLAG_SIGN, negative(result))
        self:write_flag(FLAG_PARITY, parity(result))
        self:write_flag(FLAG_AUX, low > 0x0F)
end

-- Increment register pair (no flags)
function Intel8080:inx(rp)
        local value = pair_getters[rp](self)
        local result = word(value + 0x01)

        pair_setters[rp](self, result)
end

local function JumpIf(self, addr, cond)
        if cond then
                self.pc = addr
        end
end

-- Jump if the condition is true
function Intel8080:jcc(cc)
        JumpIf(self, imm16(self), conditions[cc](self))
end

-- Jump to the immediate address
function Intel8080:jmp()
        JumpIf(self, imm16(self), true)
end

-- Load A from the immediate address
function Intel8080:lda()
        self.a = self:read_mem(imm16(self))
end

-- Load A from the address in BC or DE
function Intel8080:ldax(rp)
        local addr = pair_getters[rp](self)

        self.a = self:read_mem(addr)
end

-- Load L from the immediate address and H from the next one
function Intel8080:lhld()
        local addr = imm16(self)

        self.l = self:read_mem(addr)
        self.h = self:read_mem(addr + 0x01)
end

-- Load register pair with the 16-bit immediate
function Intel8080:lxi(rp)
        local data = imm16(self)

        pair_setters[rp](self, data)
end

-- Move register/memory to register/memory
function Intel8080:mov(dst, src)
        setters[dst](self, getters[src](self))
end

-- Move immediate to register/memory
function Intel8080:mvi(dst)
        setters[dst](self, imm8(self))
end

-- No operation
function Intel8080:nop()
end

-- Shared by ORA/ORI: A = A OR value, clears CY and AC
local function Or(self, value)
        local result = bit.bor(self.a, value)
        self:write_flag(FLAG_ZERO, result == 0x00)
        self:write_flag(FLAG_SIGN, negative(result))
        self:write_flag(FLAG_PARITY, parity(result))
        self:clear_flag(FLAG_CARRY)
        self:clear_flag(FLAG_AUX)
        self.a = result
end

-- OR register/memory with A
function Intel8080:ora(reg)
        Or(self, getters[reg](self))
end

-- OR immediate with A
function Intel8080:ori()
        Or(self, imm8(self))
end

-- Write A to the port
function Intel8080:_out()
        local port = imm8(self)

        self.io:write(port, self.a)
end

-- Jump to the address in HL
function Intel8080:pchl()
        self.pc = hl(self)
end

-- PUSH/POP use the register pair codes, but code 3 is PSW (A and flags) instead of SP
local stack_getter = {
        [0x0] = pair_getters[0x0],
        [0x1] = pair_getters[0x1],
        [0x2] = pair_getters[0x2],
        [0x3] = function(self) return u16(self.a, self.flags) end
}

-- POP PSW forces the fixed flag bits back (bit 1 = 1, bits 3 and 5 = 0)
local stack_setter = {
        [0x0] = pair_setters[0x0],
        [0x1] = pair_setters[0x1],
        [0x2] = pair_setters[0x2],
        [0x3] = function(self, value)
                self.a = byte(bit.rshift(value, 8))
                self.flags = bit.bor(bit.band(value, 0xD7), 0x02)
        end
}

-- Pop two bytes off the stack into a register pair
function Intel8080:pop(rp)
        local low = self:read_mem(self.sp)
        local high = self:read_mem(self.sp + 1)

        self.sp = word(self.sp + 2)

        stack_setter[rp](self, u16(high, low))
end

-- Push a register pair on the stack (high byte first)
function Intel8080:push(rp)
        local value = stack_getter[rp](self)
        local high = byte(bit.rshift(value, 8))
        local low = byte(value)

        self:write_mem(self.sp - 1, high)
        self:write_mem(self.sp - 2, low)

        self.sp = word(self.sp - 2)
end

-- Rotate A left through carry
function Intel8080:ral()
        local cy = self:read_flag(FLAG_CARRY) and 0x01 or 0x00
        local msb = bit.band(bit.rshift(self.a, 7), 0x01)

        self:write_flag(FLAG_CARRY, msb == 0x01)
        self.a = byte(bit.bor(bit.lshift(self.a, 1), cy))
end

-- Rotate A right through carry
function Intel8080:rar()
        local cy = self:read_flag(FLAG_CARRY) and 0x01 or 0x00
        local lsb = bit.band(self.a, 0x01)

        self:write_flag(FLAG_CARRY, lsb == 0x01)
        self.a = bit.bor(bit.rshift(self.a, 1), bit.lshift(cy, 7))
end

-- Pop the return address from the stack into PC if cond
local function ReturnIf(self, cond)
        if cond then
                local low = self:read_mem(self.sp)
                local high = self:read_mem(self.sp + 1)

                self.sp = word(self.sp + 2)
                self.pc = u16(high, low)
        end
end

-- Return if the condition is true
function Intel8080:rcc(cc)
        ReturnIf(self, conditions[cc](self))
end

-- Return from subroutine
function Intel8080:ret()
        ReturnIf(self, true)
end

-- Rotate A left (bit 7 goes to bit 0 and CY)
function Intel8080:rlc()
        local msb = bit.rshift(self.a, 7)

        self:write_flag(FLAG_CARRY, msb == 0x01)

        self.a = byte(bit.bor(bit.lshift(self.a, 1), msb))
end

-- Rotate A right (bit 0 goes to bit 7 and CY)
function Intel8080:rrc()
        local lsb = bit.band(self.a, 0x01)

        self:write_flag(FLAG_CARRY, lsb == 0x01)

        self.a = bit.bor(bit.rshift(self.a, 1), bit.lshift(lsb, 7))
end

-- Call the fixed address
function Intel8080:rst(addr)
        CallIf(self, addr, true)
end

-- Shared by SUB/SUI/SBB/SBI: A = A - value - borrow, done as A + NOT value + NOT borrow
-- CY is the borrow, so it is inverted after the addition
local function Sub(self, value, with_borrow)
        local borrow = (with_borrow and self:read_flag(FLAG_CARRY)) and 0x01 or 0x00
        local carry = 0x01 - borrow
        Add(self, byte(bit.bnot(value)), carry == 0x01)
        self:write_flag(FLAG_CARRY, not self:read_flag(FLAG_CARRY))
end

-- Subtract register/memory from A with borrow
function Intel8080:sbb(reg)
        Sub(self, getters[reg](self), true)
end

-- Subtract immediate from A with borrow
function Intel8080:sbi()
        Sub(self, imm8(self), true)
end

-- Store L at the immediate address and H at the next one
function Intel8080:shld()
        local addr = imm16(self)

        self:write_mem(addr, self.l)
        self:write_mem(addr + 1, self.h)
end

-- Load SP from HL
function Intel8080:sphl()
        local value = u16(self.h, self.l)
        self.sp = value
end

-- Store A at the immediate address
function Intel8080:sta()
        self:write_mem(imm16(self), self.a)
end

-- Store A at the address in BC or DE
function Intel8080:stax(rp)
        self:write_mem(pair_getters[rp](self), self.a)
end

-- Set the carry flag
function Intel8080:stc()
        self:set_flag(FLAG_CARRY)
end

-- Subtract register/memory from A
function Intel8080:sub(reg)
        Sub(self, getters[reg](self), false)
end

-- Subtract immediate from A
function Intel8080:sui()
        Sub(self, imm8(self), false)
end

-- Exchange DE and HL
function Intel8080:xchg()
        local h = self.h
        local l = self.l

        self.h = self.d
        self.l = self.e
        self.d = h
        self.e = l
end

-- Shared by XRA/XRI: A = A XOR value, clears CY and AC
local function Xor(self, value)
        self.a = byte(bit.bxor(value, self.a))

        self:clear_flag(FLAG_AUX)
        self:clear_flag(FLAG_CARRY)
        self:write_flag(FLAG_ZERO, self.a == 0x00)
        self:write_flag(FLAG_SIGN, negative(self.a))
        self:write_flag(FLAG_PARITY, parity(self.a))
end

-- XOR register/memory with A
function Intel8080:xra(reg)
        Xor(self, getters[reg](self))
end

-- XOR immediate with A
function Intel8080:xri()
        Xor(self, imm8(self))
end

-- Exchange HL with the top of the stack
function Intel8080:xthl()
        local h = self.h
        local l = self.l
        local low = self:read_mem(self.sp)
        local high = self:read_mem(self.sp + 1)

        self.h = high
        self.l = low

        self:write_mem(self.sp, l)
        self:write_mem(self.sp + 1, h)
end

-- Opcode -> { instruction, arguments }
-- The arguments are register, pair or condition codes (see above), or the RST address
-- Undocumented opcodes behave like NOP, JMP, RET and CALL
local opcodes = {
        [0x00] = { Intel8080.nop }, -- NOP
        [0x01] = { Intel8080.lxi, 0x0 }, -- LXI B
        [0x02] = { Intel8080.stax, 0x0 }, -- STAX B
        [0x03] = { Intel8080.inx, 0x0 }, -- INX B
        [0x04] = { Intel8080.inr, 0x0 }, -- INR B
        [0x05] = { Intel8080.dcr, 0x0 }, -- DCR B
        [0x06] = { Intel8080.mvi, 0x0 }, -- MVI B
        [0x07] = { Intel8080.rlc }, -- RLC
        [0x08] = { Intel8080.nop }, -- NOP (undocumented)
        [0x09] = { Intel8080.dad, 0x0 }, -- DAD B
        [0x0A] = { Intel8080.ldax, 0x0 }, -- LDAX B
        [0x0B] = { Intel8080.dcx, 0x0 }, -- DCX B
        [0x0C] = { Intel8080.inr, 0x1 }, -- INR C
        [0x0D] = { Intel8080.dcr, 0x1 }, -- DCR C
        [0x0E] = { Intel8080.mvi, 0x1 }, -- MVI C
        [0x0F] = { Intel8080.rrc }, -- RRC

        [0x10] = { Intel8080.nop }, -- NOP (undocumented)
        [0x11] = { Intel8080.lxi, 0x1 }, -- LXI D
        [0x12] = { Intel8080.stax, 0x1 }, -- STAX D
        [0x13] = { Intel8080.inx, 0x1 }, -- INX D
        [0x14] = { Intel8080.inr, 0x2 }, -- INR D
        [0x15] = { Intel8080.dcr, 0x2 }, -- DCR D
        [0x16] = { Intel8080.mvi, 0x2 }, -- MVI D
        [0x17] = { Intel8080.ral }, -- RAL
        [0x18] = { Intel8080.nop }, -- NOP (undocumented)
        [0x19] = { Intel8080.dad, 0x1 }, -- DAD D
        [0x1A] = { Intel8080.ldax, 0x1 }, -- LDAX D
        [0x1B] = { Intel8080.dcx, 0x1 }, -- DCX D
        [0x1C] = { Intel8080.inr, 0x3 }, -- INR E
        [0x1D] = { Intel8080.dcr, 0x3 }, -- DCR E
        [0x1E] = { Intel8080.mvi, 0x3 }, -- MVI E
        [0x1F] = { Intel8080.rar }, -- RAR

        [0x20] = { Intel8080.nop }, -- NOP (undocumented)
        [0x21] = { Intel8080.lxi, 0x2 }, -- LXI H
        [0x22] = { Intel8080.shld }, -- SHLD
        [0x23] = { Intel8080.inx, 0x2 }, -- INX H
        [0x24] = { Intel8080.inr, 0x4 }, -- INR H
        [0x25] = { Intel8080.dcr, 0x4 }, -- DCR H
        [0x26] = { Intel8080.mvi, 0x4 }, -- MVI H
        [0x27] = { Intel8080.daa }, -- DAA
        [0x28] = { Intel8080.nop }, -- NOP (undocumented)
        [0x29] = { Intel8080.dad, 0x2 }, -- DAD H
        [0x2A] = { Intel8080.lhld }, -- LHLD
        [0x2B] = { Intel8080.dcx, 0x2 }, -- DCX H
        [0x2C] = { Intel8080.inr, 0x5 }, -- INR L
        [0x2D] = { Intel8080.dcr, 0x5 }, -- DCR L
        [0x2E] = { Intel8080.mvi, 0x5 }, -- MVI L
        [0x2F] = { Intel8080.cma }, -- CMA

        [0x30] = { Intel8080.nop }, -- NOP (undocumented)
        [0x31] = { Intel8080.lxi, 0x3 }, -- LXI SP
        [0x32] = { Intel8080.sta }, -- STA
        [0x33] = { Intel8080.inx, 0x3 }, -- INX SP
        [0x34] = { Intel8080.inr, 0x6 }, -- INR M
        [0x35] = { Intel8080.dcr, 0x6 }, -- DCR M
        [0x36] = { Intel8080.mvi, 0x6 }, -- MVI M
        [0x37] = { Intel8080.stc }, -- STC
        [0x38] = { Intel8080.nop }, -- NOP (undocumented)
        [0x39] = { Intel8080.dad, 0x3 }, -- DAD SP
        [0x3A] = { Intel8080.lda }, -- LDA
        [0x3B] = { Intel8080.dcx, 0x3 }, -- DCX SP
        [0x3C] = { Intel8080.inr, 0x7 }, -- INR A
        [0x3D] = { Intel8080.dcr, 0x7 }, -- DCR A
        [0x3E] = { Intel8080.mvi, 0x7 }, -- MVI A
        [0x3F] = { Intel8080.cmc }, -- CMC

        [0x40] = { Intel8080.mov, 0x0, 0x0 }, -- MOV B,B
        [0x41] = { Intel8080.mov, 0x0, 0x1 }, -- MOV B,C
        [0x42] = { Intel8080.mov, 0x0, 0x2 }, -- MOV B,D
        [0x43] = { Intel8080.mov, 0x0, 0x3 }, -- MOV B,E
        [0x44] = { Intel8080.mov, 0x0, 0x4 }, -- MOV B,H
        [0x45] = { Intel8080.mov, 0x0, 0x5 }, -- MOV B,L
        [0x46] = { Intel8080.mov, 0x0, 0x6 }, -- MOV B,M
        [0x47] = { Intel8080.mov, 0x0, 0x7 }, -- MOV B,A
        [0x48] = { Intel8080.mov, 0x1, 0x0 }, -- MOV C,B
        [0x49] = { Intel8080.mov, 0x1, 0x1 }, -- MOV C,C
        [0x4A] = { Intel8080.mov, 0x1, 0x2 }, -- MOV C,D
        [0x4B] = { Intel8080.mov, 0x1, 0x3 }, -- MOV C,E
        [0x4C] = { Intel8080.mov, 0x1, 0x4 }, -- MOV C,H
        [0x4D] = { Intel8080.mov, 0x1, 0x5 }, -- MOV C,L
        [0x4E] = { Intel8080.mov, 0x1, 0x6 }, -- MOV C,M
        [0x4F] = { Intel8080.mov, 0x1, 0x7 }, -- MOV C,A

        [0x50] = { Intel8080.mov, 0x2, 0x0 }, -- MOV D,B
        [0x51] = { Intel8080.mov, 0x2, 0x1 }, -- MOV D,C
        [0x52] = { Intel8080.mov, 0x2, 0x2 }, -- MOV D,D
        [0x53] = { Intel8080.mov, 0x2, 0x3 }, -- MOV D,E
        [0x54] = { Intel8080.mov, 0x2, 0x4 }, -- MOV D,H
        [0x55] = { Intel8080.mov, 0x2, 0x5 }, -- MOV D,L
        [0x56] = { Intel8080.mov, 0x2, 0x6 }, -- MOV D,M
        [0x57] = { Intel8080.mov, 0x2, 0x7 }, -- MOV D,A
        [0x58] = { Intel8080.mov, 0x3, 0x0 }, -- MOV E,B
        [0x59] = { Intel8080.mov, 0x3, 0x1 }, -- MOV E,C
        [0x5A] = { Intel8080.mov, 0x3, 0x2 }, -- MOV E,D
        [0x5B] = { Intel8080.mov, 0x3, 0x3 }, -- MOV E,E
        [0x5C] = { Intel8080.mov, 0x3, 0x4 }, -- MOV E,H
        [0x5D] = { Intel8080.mov, 0x3, 0x5 }, -- MOV E,L
        [0x5E] = { Intel8080.mov, 0x3, 0x6 }, -- MOV E,M
        [0x5F] = { Intel8080.mov, 0x3, 0x7 }, -- MOV E,A

        [0x60] = { Intel8080.mov, 0x4, 0x0 }, -- MOV H,B
        [0x61] = { Intel8080.mov, 0x4, 0x1 }, -- MOV H,C
        [0x62] = { Intel8080.mov, 0x4, 0x2 }, -- MOV H,D
        [0x63] = { Intel8080.mov, 0x4, 0x3 }, -- MOV H,E
        [0x64] = { Intel8080.mov, 0x4, 0x4 }, -- MOV H,H
        [0x65] = { Intel8080.mov, 0x4, 0x5 }, -- MOV H,L
        [0x66] = { Intel8080.mov, 0x4, 0x6 }, -- MOV H,M
        [0x67] = { Intel8080.mov, 0x4, 0x7 }, -- MOV H,A
        [0x68] = { Intel8080.mov, 0x5, 0x0 }, -- MOV L,B
        [0x69] = { Intel8080.mov, 0x5, 0x1 }, -- MOV L,C
        [0x6A] = { Intel8080.mov, 0x5, 0x2 }, -- MOV L,D
        [0x6B] = { Intel8080.mov, 0x5, 0x3 }, -- MOV L,E
        [0x6C] = { Intel8080.mov, 0x5, 0x4 }, -- MOV L,H
        [0x6D] = { Intel8080.mov, 0x5, 0x5 }, -- MOV L,L
        [0x6E] = { Intel8080.mov, 0x5, 0x6 }, -- MOV L,M
        [0x6F] = { Intel8080.mov, 0x5, 0x7 }, -- MOV L,A

        [0x70] = { Intel8080.mov, 0x6, 0x0 }, -- MOV M,B
        [0x71] = { Intel8080.mov, 0x6, 0x1 }, -- MOV M,C
        [0x72] = { Intel8080.mov, 0x6, 0x2 }, -- MOV M,D
        [0x73] = { Intel8080.mov, 0x6, 0x3 }, -- MOV M,E
        [0x74] = { Intel8080.mov, 0x6, 0x4 }, -- MOV M,H
        [0x75] = { Intel8080.mov, 0x6, 0x5 }, -- MOV M,L
        [0x76] = { Intel8080.hlt }, -- HLT
        [0x77] = { Intel8080.mov, 0x6, 0x7 }, -- MOV M,A
        [0x78] = { Intel8080.mov, 0x7, 0x0 }, -- MOV A,B
        [0x79] = { Intel8080.mov, 0x7, 0x1 }, -- MOV A,C
        [0x7A] = { Intel8080.mov, 0x7, 0x2 }, -- MOV A,D
        [0x7B] = { Intel8080.mov, 0x7, 0x3 }, -- MOV A,E
        [0x7C] = { Intel8080.mov, 0x7, 0x4 }, -- MOV A,H
        [0x7D] = { Intel8080.mov, 0x7, 0x5 }, -- MOV A,L
        [0x7E] = { Intel8080.mov, 0x7, 0x6 }, -- MOV A,M
        [0x7F] = { Intel8080.mov, 0x7, 0x7 }, -- MOV A,A

        [0x80] = { Intel8080.add, 0x0 }, -- ADD B
        [0x81] = { Intel8080.add, 0x1 }, -- ADD C
        [0x82] = { Intel8080.add, 0x2 }, -- ADD D
        [0x83] = { Intel8080.add, 0x3 }, -- ADD E
        [0x84] = { Intel8080.add, 0x4 }, -- ADD H
        [0x85] = { Intel8080.add, 0x5 }, -- ADD L
        [0x86] = { Intel8080.add, 0x6 }, -- ADD M
        [0x87] = { Intel8080.add, 0x7 }, -- ADD A
        [0x88] = { Intel8080.adc, 0x0 }, -- ADC B
        [0x89] = { Intel8080.adc, 0x1 }, -- ADC C
        [0x8A] = { Intel8080.adc, 0x2 }, -- ADC D
        [0x8B] = { Intel8080.adc, 0x3 }, -- ADC E
        [0x8C] = { Intel8080.adc, 0x4 }, -- ADC H
        [0x8D] = { Intel8080.adc, 0x5 }, -- ADC L
        [0x8E] = { Intel8080.adc, 0x6 }, -- ADC M
        [0x8F] = { Intel8080.adc, 0x7 }, -- ADC A

        [0x90] = { Intel8080.sub, 0x0 }, -- SUB B
        [0x91] = { Intel8080.sub, 0x1 }, -- SUB C
        [0x92] = { Intel8080.sub, 0x2 }, -- SUB D
        [0x93] = { Intel8080.sub, 0x3 }, -- SUB E
        [0x94] = { Intel8080.sub, 0x4 }, -- SUB H
        [0x95] = { Intel8080.sub, 0x5 }, -- SUB L
        [0x96] = { Intel8080.sub, 0x6 }, -- SUB M
        [0x97] = { Intel8080.sub, 0x7 }, -- SUB A
        [0x98] = { Intel8080.sbb, 0x0 }, -- SBB B
        [0x99] = { Intel8080.sbb, 0x1 }, -- SBB C
        [0x9A] = { Intel8080.sbb, 0x2 }, -- SBB D
        [0x9B] = { Intel8080.sbb, 0x3 }, -- SBB E
        [0x9C] = { Intel8080.sbb, 0x4 }, -- SBB H
        [0x9D] = { Intel8080.sbb, 0x5 }, -- SBB L
        [0x9E] = { Intel8080.sbb, 0x6 }, -- SBB M
        [0x9F] = { Intel8080.sbb, 0x7 }, -- SBB A

        [0xA0] = { Intel8080.ana, 0x0 }, -- ANA B
        [0xA1] = { Intel8080.ana, 0x1 }, -- ANA C
        [0xA2] = { Intel8080.ana, 0x2 }, -- ANA D
        [0xA3] = { Intel8080.ana, 0x3 }, -- ANA E
        [0xA4] = { Intel8080.ana, 0x4 }, -- ANA H
        [0xA5] = { Intel8080.ana, 0x5 }, -- ANA L
        [0xA6] = { Intel8080.ana, 0x6 }, -- ANA M
        [0xA7] = { Intel8080.ana, 0x7 }, -- ANA A
        [0xA8] = { Intel8080.xra, 0x0 }, -- XRA B
        [0xA9] = { Intel8080.xra, 0x1 }, -- XRA C
        [0xAA] = { Intel8080.xra, 0x2 }, -- XRA D
        [0xAB] = { Intel8080.xra, 0x3 }, -- XRA E
        [0xAC] = { Intel8080.xra, 0x4 }, -- XRA H
        [0xAD] = { Intel8080.xra, 0x5 }, -- XRA L
        [0xAE] = { Intel8080.xra, 0x6 }, -- XRA M
        [0xAF] = { Intel8080.xra, 0x7 }, -- XRA A

        [0xB0] = { Intel8080.ora, 0x0 }, -- ORA B
        [0xB1] = { Intel8080.ora, 0x1 }, -- ORA C
        [0xB2] = { Intel8080.ora, 0x2 }, -- ORA D
        [0xB3] = { Intel8080.ora, 0x3 }, -- ORA E
        [0xB4] = { Intel8080.ora, 0x4 }, -- ORA H
        [0xB5] = { Intel8080.ora, 0x5 }, -- ORA L
        [0xB6] = { Intel8080.ora, 0x6 }, -- ORA M
        [0xB7] = { Intel8080.ora, 0x7 }, -- ORA A
        [0xB8] = { Intel8080.cmp, 0x0 }, -- CMP B
        [0xB9] = { Intel8080.cmp, 0x1 }, -- CMP C
        [0xBA] = { Intel8080.cmp, 0x2 }, -- CMP D
        [0xBB] = { Intel8080.cmp, 0x3 }, -- CMP E
        [0xBC] = { Intel8080.cmp, 0x4 }, -- CMP H
        [0xBD] = { Intel8080.cmp, 0x5 }, -- CMP L
        [0xBE] = { Intel8080.cmp, 0x6 }, -- CMP M
        [0xBF] = { Intel8080.cmp, 0x7 }, -- CMP A

        [0xC0] = { Intel8080.rcc, 0x0 }, -- RNZ
        [0xC1] = { Intel8080.pop, 0x0 }, -- POP B
        [0xC2] = { Intel8080.jcc, 0x0 }, -- JNZ
        [0xC3] = { Intel8080.jmp }, -- JMP
        [0xC4] = { Intel8080.ccc, 0x0 }, -- CNZ
        [0xC5] = { Intel8080.push, 0x0 }, -- PUSH B
        [0xC6] = { Intel8080.adi }, -- ADI
        [0xC7] = { Intel8080.rst, 0x0 }, -- RST 0
        [0xC8] = { Intel8080.rcc, 0x1 }, -- RZ
        [0xC9] = { Intel8080.ret }, -- RET
        [0xCA] = { Intel8080.jcc, 0x1 }, -- JZ
        [0xCB] = { Intel8080.jmp }, -- JMP (undocumented)
        [0xCC] = { Intel8080.ccc, 0x1 }, -- CZ
        [0xCD] = { Intel8080.call }, -- CALL
        [0xCE] = { Intel8080.aci }, -- ACI
        [0xCF] = { Intel8080.rst, 0x8 }, -- RST 1

        [0xD0] = { Intel8080.rcc, 0x2 }, -- RNC
        [0xD1] = { Intel8080.pop, 0x1 }, -- POP D
        [0xD2] = { Intel8080.jcc, 0x2 }, -- JNC
        [0xD3] = { Intel8080._out }, -- OUT
        [0xD4] = { Intel8080.ccc, 0x2 }, -- CNC
        [0xD5] = { Intel8080.push, 0x1 }, -- PUSH D
        [0xD6] = { Intel8080.sui }, -- SUI
        [0xD7] = { Intel8080.rst, 0x10 }, -- RST 2
        [0xD8] = { Intel8080.rcc, 0x3 }, -- RC
        [0xD9] = { Intel8080.ret }, -- RET (undocumented)
        [0xDA] = { Intel8080.jcc, 0x3 }, -- JC
        [0xDB] = { Intel8080._in }, -- IN
        [0xDC] = { Intel8080.ccc, 0x3 }, -- CC
        [0xDD] = { Intel8080.call }, -- CALL (undocumented)
        [0xDE] = { Intel8080.sbi }, -- SBI
        [0xDF] = { Intel8080.rst, 0x18 }, -- RST 3

        [0xE0] = { Intel8080.rcc, 0x4 }, -- RPO
        [0xE1] = { Intel8080.pop, 0x2 }, -- POP H
        [0xE2] = { Intel8080.jcc, 0x4 }, -- JPO
        [0xE3] = { Intel8080.xthl }, -- XTHL
        [0xE4] = { Intel8080.ccc, 0x4 }, -- CPO
        [0xE5] = { Intel8080.push, 0x2 }, -- PUSH H
        [0xE6] = { Intel8080.ani }, -- ANI
        [0xE7] = { Intel8080.rst, 0x20 }, -- RST 4
        [0xE8] = { Intel8080.rcc, 0x5 }, -- RPE
        [0xE9] = { Intel8080.pchl }, -- PCHL
        [0xEA] = { Intel8080.jcc, 0x5 }, -- JPE
        [0xEB] = { Intel8080.xchg }, -- XCHG
        [0xEC] = { Intel8080.ccc, 0x5 }, -- CPE
        [0xED] = { Intel8080.call }, -- CALL (undocumented)
        [0xEE] = { Intel8080.xri }, -- XRI
        [0xEF] = { Intel8080.rst, 0x28 }, -- RST 5

        [0xF0] = { Intel8080.rcc, 0x6 }, -- RP
        [0xF1] = { Intel8080.pop, 0x3 }, -- POP PSW
        [0xF2] = { Intel8080.jcc, 0x6 }, -- JP
        [0xF3] = { Intel8080.di }, -- DI
        [0xF4] = { Intel8080.ccc, 0x6 }, -- CP
        [0xF5] = { Intel8080.push, 0x3 }, -- PUSH PSW
        [0xF6] = { Intel8080.ori }, -- ORI
        [0xF7] = { Intel8080.rst, 0x30 }, -- RST 6
        [0xF8] = { Intel8080.rcc, 0x7 }, -- RM
        [0xF9] = { Intel8080.sphl }, -- SPHL
        [0xFA] = { Intel8080.jcc, 0x7 }, -- JM
        [0xFB] = { Intel8080.ei }, -- EI
        [0xFC] = { Intel8080.ccc, 0x7 }, -- CM
        [0xFD] = { Intel8080.call }, -- CALL (undocumented)
        [0xFE] = { Intel8080.cpi }, -- CPI
        [0xFF] = { Intel8080.rst, 0x38 } -- RST 7
}

-- Opcode -> cycles (conditional CALL and RET always use the count of the taken branch)
local cycles = {
        [0x00] = 4, -- NOP
        [0x01] = 10, -- LXI B
        [0x02] = 7, -- STAX B
        [0x03] = 5, -- INX B
        [0x04] = 5, -- INR B
        [0x05] = 5, -- DCR B
        [0x06] = 7, -- MVI B
        [0x07] = 4, -- RLC
        [0x08] = 4, -- NOP (undocumented)
        [0x09] = 10, -- DAD B
        [0x0A] = 7, -- LDAX B
        [0x0B] = 5, -- DCX B
        [0x0C] = 5, -- INR C
        [0x0D] = 5, -- DCR C
        [0x0E] = 7, -- MVI C
        [0x0F] = 4, -- RRC

        [0x10] = 4, -- NOP (undocumented)
        [0x11] = 10, -- LXI D
        [0x12] = 7, -- STAX D
        [0x13] = 5, -- INX D
        [0x14] = 5, -- INR D
        [0x15] = 5, -- DCR D
        [0x16] = 7, -- MVI D
        [0x17] = 4, -- RAL
        [0x18] = 4, -- NOP (undocumented)
        [0x19] = 10, -- DAD D
        [0x1A] = 7, -- LDAX D
        [0x1B] = 5, -- DCX D
        [0x1C] = 5, -- INR E
        [0x1D] = 5, -- DCR E
        [0x1E] = 7, -- MVI E
        [0x1F] = 4, -- RAR

        [0x20] = 4, -- NOP (undocumented)
        [0x21] = 10, -- LXI H
        [0x22] = 16, -- SHLD
        [0x23] = 5, -- INX H
        [0x24] = 5, -- INR H
        [0x25] = 5, -- DCR H
        [0x26] = 7, -- MVI H
        [0x27] = 4, -- DAA
        [0x28] = 4, -- NOP (undocumented)
        [0x29] = 10, -- DAD H
        [0x2A] = 16, -- LHLD
        [0x2B] = 5, -- DCX H
        [0x2C] = 5, -- INR L
        [0x2D] = 5, -- DCR L
        [0x2E] = 7, -- MVI L
        [0x2F] = 4, -- CMA

        [0x30] = 4, -- NOP (undocumented)
        [0x31] = 10, -- LXI SP
        [0x32] = 13, -- STA
        [0x33] = 5, -- INX SP
        [0x34] = 10, -- INR M
        [0x35] = 10, -- DCR M
        [0x36] = 10, -- MVI M
        [0x37] = 4, -- STC
        [0x38] = 4, -- NOP (undocumented)
        [0x39] = 10, -- DAD SP
        [0x3A] = 13, -- LDA
        [0x3B] = 5, -- DCX SP
        [0x3C] = 5, -- INR A
        [0x3D] = 5, -- DCR A
        [0x3E] = 7, -- MVI A
        [0x3F] = 4, -- CMC

        [0x40] = 5, -- MOV B,B
        [0x41] = 5, -- MOV B,C
        [0x42] = 5, -- MOV B,D
        [0x43] = 5, -- MOV B,E
        [0x44] = 5, -- MOV B,H
        [0x45] = 5, -- MOV B,L
        [0x46] = 7, -- MOV B,M
        [0x47] = 5, -- MOV B,A
        [0x48] = 5, -- MOV C,B
        [0x49] = 5, -- MOV C,C
        [0x4A] = 5, -- MOV C,D
        [0x4B] = 5, -- MOV C,E
        [0x4C] = 5, -- MOV C,H
        [0x4D] = 5, -- MOV C,L
        [0x4E] = 7, -- MOV C,M
        [0x4F] = 5, -- MOV C,A

        [0x50] = 5, -- MOV D,B
        [0x51] = 5, -- MOV D,C
        [0x52] = 5, -- MOV D,D
        [0x53] = 5, -- MOV D,E
        [0x54] = 5, -- MOV D,H
        [0x55] = 5, -- MOV D,L
        [0x56] = 7, -- MOV D,M
        [0x57] = 5, -- MOV D,A
        [0x58] = 5, -- MOV E,B
        [0x59] = 5, -- MOV E,C
        [0x5A] = 5, -- MOV E,D
        [0x5B] = 5, -- MOV E,E
        [0x5C] = 5, -- MOV E,H
        [0x5D] = 5, -- MOV E,L
        [0x5E] = 7, -- MOV E,M
        [0x5F] = 5, -- MOV E,A

        [0x60] = 5, -- MOV H,B
        [0x61] = 5, -- MOV H,C
        [0x62] = 5, -- MOV H,D
        [0x63] = 5, -- MOV H,E
        [0x64] = 5, -- MOV H,H
        [0x65] = 5, -- MOV H,L
        [0x66] = 7, -- MOV H,M
        [0x67] = 5, -- MOV H,A
        [0x68] = 5, -- MOV L,B
        [0x69] = 5, -- MOV L,C
        [0x6A] = 5, -- MOV L,D
        [0x6B] = 5, -- MOV L,E
        [0x6C] = 5, -- MOV L,H
        [0x6D] = 5, -- MOV L,L
        [0x6E] = 7, -- MOV L,M
        [0x6F] = 5, -- MOV L,A

        [0x70] = 7, -- MOV M,B
        [0x71] = 7, -- MOV M,C
        [0x72] = 7, -- MOV M,D
        [0x73] = 7, -- MOV M,E
        [0x74] = 7, -- MOV M,H
        [0x75] = 7, -- MOV M,L
        [0x76] = 7, -- HLT
        [0x77] = 7, -- MOV M,A
        [0x78] = 5, -- MOV A,B
        [0x79] = 5, -- MOV A,C
        [0x7A] = 5, -- MOV A,D
        [0x7B] = 5, -- MOV A,E
        [0x7C] = 5, -- MOV A,H
        [0x7D] = 5, -- MOV A,L
        [0x7E] = 7, -- MOV A,M
        [0x7F] = 5, -- MOV A,A

        [0x80] = 4, -- ADD B
        [0x81] = 4, -- ADD C
        [0x82] = 4, -- ADD D
        [0x83] = 4, -- ADD E
        [0x84] = 4, -- ADD H
        [0x85] = 4, -- ADD L
        [0x86] = 7, -- ADD M
        [0x87] = 4, -- ADD A
        [0x88] = 4, -- ADC B
        [0x89] = 4, -- ADC C
        [0x8A] = 4, -- ADC D
        [0x8B] = 4, -- ADC E
        [0x8C] = 4, -- ADC H
        [0x8D] = 4, -- ADC L
        [0x8E] = 7, -- ADC M
        [0x8F] = 4, -- ADC A

        [0x90] = 4, -- SUB B
        [0x91] = 4, -- SUB C
        [0x92] = 4, -- SUB D
        [0x93] = 4, -- SUB E
        [0x94] = 4, -- SUB H
        [0x95] = 4, -- SUB L
        [0x96] = 7, -- SUB M
        [0x97] = 4, -- SUB A
        [0x98] = 4, -- SBB B
        [0x99] = 4, -- SBB C
        [0x9A] = 4, -- SBB D
        [0x9B] = 4, -- SBB E
        [0x9C] = 4, -- SBB H
        [0x9D] = 4, -- SBB L
        [0x9E] = 7, -- SBB M
        [0x9F] = 4, -- SBB A

        [0xA0] = 4, -- ANA B
        [0xA1] = 4, -- ANA C
        [0xA2] = 4, -- ANA D
        [0xA3] = 4, -- ANA E
        [0xA4] = 4, -- ANA H
        [0xA5] = 4, -- ANA L
        [0xA6] = 7, -- ANA M
        [0xA7] = 4, -- ANA A
        [0xA8] = 4, -- XRA B
        [0xA9] = 4, -- XRA C
        [0xAA] = 4, -- XRA D
        [0xAB] = 4, -- XRA E
        [0xAC] = 4, -- XRA H
        [0xAD] = 4, -- XRA L
        [0xAE] = 7, -- XRA M
        [0xAF] = 4, -- XRA A

        [0xB0] = 4, -- ORA B
        [0xB1] = 4, -- ORA C
        [0xB2] = 4, -- ORA D
        [0xB3] = 4, -- ORA E
        [0xB4] = 4, -- ORA H
        [0xB5] = 4, -- ORA L
        [0xB6] = 7, -- ORA M
        [0xB7] = 4, -- ORA A
        [0xB8] = 4, -- CMP B
        [0xB9] = 4, -- CMP C
        [0xBA] = 4, -- CMP D
        [0xBB] = 4, -- CMP E
        [0xBC] = 4, -- CMP H
        [0xBD] = 4, -- CMP L
        [0xBE] = 7, -- CMP M
        [0xBF] = 4, -- CMP A

        [0xC0] = 11, -- RNZ
        [0xC1] = 10, -- POP B
        [0xC2] = 10, -- JNZ
        [0xC3] = 10, -- JMP
        [0xC4] = 17, -- CNZ
        [0xC5] = 11, -- PUSH B
        [0xC6] = 7, -- ADI
        [0xC7] = 11, -- RST 0
        [0xC8] = 11, -- RZ
        [0xC9] = 10, -- RET
        [0xCA] = 10, -- JZ
        [0xCB] = 10, -- JMP (undocumented)
        [0xCC] = 17, -- CZ
        [0xCD] = 17, -- CALL
        [0xCE] = 7, -- ACI
        [0xCF] = 11, -- RST 1

        [0xD0] = 11, -- RNC
        [0xD1] = 10, -- POP D
        [0xD2] = 10, -- JNC
        [0xD3] = 10, -- OUT
        [0xD4] = 17, -- CNC
        [0xD5] = 11, -- PUSH D
        [0xD6] = 7, -- SUI
        [0xD7] = 11, -- RST 2
        [0xD8] = 11, -- RC
        [0xD9] = 10, -- RET (undocumented)
        [0xDA] = 10, -- JC
        [0xDB] = 10, -- IN
        [0xDC] = 17, -- CC
        [0xDD] = 17, -- CALL (undocumented)
        [0xDE] = 7, -- SBI
        [0xDF] = 11, -- RST 3

        [0xE0] = 11, -- RPO
        [0xE1] = 10, -- POP H
        [0xE2] = 10, -- JPO
        [0xE3] = 18, -- XTHL
        [0xE4] = 17, -- CPO
        [0xE5] = 11, -- PUSH H
        [0xE6] = 7, -- ANI
        [0xE7] = 11, -- RST 4
        [0xE8] = 11, -- RPE
        [0xE9] = 5, -- PCHL
        [0xEA] = 10, -- JPE
        [0xEB] = 4, -- XCHG
        [0xEC] = 17, -- CPE
        [0xED] = 17, -- CALL (undocumented)
        [0xEE] = 7, -- XRI
        [0xEF] = 11, -- RST 5

        [0xF0] = 11, -- RP
        [0xF1] = 10, -- POP PSW
        [0xF2] = 10, -- JP
        [0xF3] = 4, -- DI
        [0xF4] = 17, -- CP
        [0xF5] = 11, -- PUSH PSW
        [0xF6] = 7, -- ORI
        [0xF7] = 11, -- RST 6
        [0xF8] = 11, -- RM
        [0xF9] = 5, -- SPHL
        [0xFA] = 10, -- JM
        [0xFB] = 4, -- EI
        [0xFC] = 17, -- CM
        [0xFD] = 17, -- CALL (undocumented)
        [0xFE] = 7, -- CPI
        [0xFF] = 11 -- RST 7
}

-- Read the opcode at PC and advance PC
function Intel8080:fetch()
        return imm8(self)
end

-- Find the table entry for the opcode
function Intel8080:decode(opcode)
        return opcodes[opcode]
end

-- Call the instruction with its arguments
function Intel8080:execute(entry)
        local instr = entry[1]
        local arg1 = entry[2]
        local arg2 = entry[3]

        instr(self, arg1, arg2)
end

-- Latch an interrupt opcode (usually RST). It runs on the next step if interrupts are enabled,
-- otherwise it stays pending until EI
function Intel8080:interrupt(opcode)
        self.vector = opcode
end

-- Run one instruction (or service a pending interrupt) and return the cycles it took
function Intel8080:step()
        local opcode

        if self.inte and self.vector then
                opcode = self.vector

                self.inte = false
                self.vector = nil
                self.halted = false
                self:execute(self:decode(opcode))
        elseif not self.halted then
                opcode = self:fetch()

                self:execute(self:decode(opcode))
        else
                return 7 -- HLT
        end

        return cycles[opcode]
end

return Intel8080

