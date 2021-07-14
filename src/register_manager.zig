const std = @import("std");
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Air = @import("Air.zig");
const Type = @import("type.zig").Type;
const Module = @import("Module.zig");
const LazySrcLoc = Module.LazySrcLoc;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const log = std.log.scoped(.register_manager);

pub fn RegisterManager(
    comptime Function: type,
    comptime Register: type,
    comptime callee_preserved_regs: []const Register,
) type {
    return struct {
        /// The key must be canonical register.
        registers: [callee_preserved_regs.len]?Air.Inst.Index = [_]?Air.Inst.Index{null} ** callee_preserved_regs.len,
        free_registers: FreeRegInt = math.maxInt(FreeRegInt),
        /// Tracks all registers allocated in the course of this function
        allocated_registers: FreeRegInt = 0,

        const Self = @This();

        /// An integer whose bits represent all the registers and whether they are free.
        const FreeRegInt = std.meta.Int(.unsigned, callee_preserved_regs.len);
        const ShiftInt = math.Log2Int(FreeRegInt);

        fn getFunction(self: *Self) *Function {
            return @fieldParentPtr(Function, "register_manager", self);
        }

        fn markRegUsed(self: *Self, reg: Register) void {
            if (FreeRegInt == u0) return;
            const index = reg.allocIndex() orelse return;
            const shift = @intCast(ShiftInt, index);
            const mask = @as(FreeRegInt, 1) << shift;
            self.free_registers &= ~mask;
            self.allocated_registers |= mask;
        }

        fn markRegFree(self: *Self, reg: Register) void {
            if (FreeRegInt == u0) return;
            const index = reg.allocIndex() orelse return;
            const shift = @intCast(ShiftInt, index);
            self.free_registers |= @as(FreeRegInt, 1) << shift;
        }

        /// Returns true when this register is not tracked
        pub fn isRegFree(self: Self, reg: Register) bool {
            if (FreeRegInt == u0) return true;
            const index = reg.allocIndex() orelse return true;
            const shift = @intCast(ShiftInt, index);
            return self.free_registers & @as(FreeRegInt, 1) << shift != 0;
        }

        /// Returns whether this register was allocated in the course
        /// of this function.
        /// Returns false when this register is not tracked
        pub fn isRegAllocated(self: Self, reg: Register) bool {
            if (FreeRegInt == u0) return false;
            const index = reg.allocIndex() orelse return false;
            const shift = @intCast(ShiftInt, index);
            return self.allocated_registers & @as(FreeRegInt, 1) << shift != 0;
        }

        /// Allocates a specified number of registers, optionally
        /// tracking them. Returns `null` if not enough registers are
        /// free.
        pub fn tryAllocRegs(
            self: *Self,
            comptime count: comptime_int,
            insts: [count]?Air.Inst.Index,
            exceptions: []const Register,
        ) ?[count]Register {
            comptime if (callee_preserved_regs.len == 0) return null;
            comptime assert(count > 0 and count <= callee_preserved_regs.len);
            assert(count + exceptions.len <= callee_preserved_regs.len);

            const free_registers = @popCount(FreeRegInt, self.free_registers);
            if (free_registers < count) return null;

            var regs: [count]Register = undefined;
            var i: usize = 0;
            for (callee_preserved_regs) |reg| {
                if (i >= count) break;
                if (mem.indexOfScalar(Register, exceptions, reg) != null) continue;
                if (self.isRegFree(reg)) {
                    regs[i] = reg;
                    i += 1;
                }
            }

            if (i == count) {
                for (regs) |reg, j| {
                    if (insts[j]) |inst| {
                        // Track the register
                        const index = reg.allocIndex().?; // allocIndex() on a callee-preserved reg should never return null
                        self.registers[index] = inst;
                        self.markRegUsed(reg);
                    }
                }

                return regs;
            } else return null;
        }

        /// Allocates a register and optionally tracks it with a
        /// corresponding instruction. Returns `null` if all registers
        /// are allocated.
        pub fn tryAllocReg(self: *Self, inst: ?Air.Inst.Index, exceptions: []const Register) ?Register {
            return if (tryAllocRegs(self, 1, .{inst}, exceptions)) |regs| regs[0] else null;
        }

        /// Allocates a specified number of registers, optionally
        /// tracking them. Asserts that count + exceptions.len is not
        /// larger than the total number of registers available.
        pub fn allocRegs(
            self: *Self,
            comptime count: comptime_int,
            insts: [count]?Air.Inst.Index,
            exceptions: []const Register,
        ) ![count]Register {
            comptime assert(count > 0 and count <= callee_preserved_regs.len);
            assert(count + exceptions.len <= callee_preserved_regs.len);

            return self.tryAllocRegs(count, insts, exceptions) orelse blk: {
                // We'll take over the first count registers. Spill
                // the instructions that were previously there to a
                // stack allocations.
                var regs: [count]Register = undefined;
                var i: usize = 0;
                for (callee_preserved_regs) |reg| {
                    if (i >= count) break;
                    if (mem.indexOfScalar(Register, exceptions, reg) != null) continue;
                    regs[i] = reg;

                    const index = reg.allocIndex().?; // allocIndex() on a callee-preserved reg should never return null
                    if (insts[i]) |inst| {
                        // Track the register
                        if (self.isRegFree(reg)) {
                            self.markRegUsed(reg);
                        } else {
                            const spilled_inst = self.registers[index].?;
                            try self.getFunction().spillInstruction(reg, spilled_inst);
                        }
                        self.registers[index] = inst;
                    } else {
                        // Don't track the register
                        if (!self.isRegFree(reg)) {
                            const spilled_inst = self.registers[index].?;
                            try self.getFunction().spillInstruction(reg, spilled_inst);
                            self.freeReg(reg);
                        }
                    }

                    i += 1;
                }

                break :blk regs;
            };
        }

        /// Allocates a register and optionally tracks it with a
        /// corresponding instruction.
        pub fn allocReg(self: *Self, inst: ?Air.Inst.Index, exceptions: []const Register) !Register {
            return (try self.allocRegs(1, .{inst}, exceptions))[0];
        }

        /// Spills the register if it is currently allocated. If a
        /// corresponding instruction is passed, will also track this
        /// register.
        pub fn getReg(self: *Self, reg: Register, inst: ?Air.Inst.Index) !void {
            const index = reg.allocIndex() orelse return;

            if (inst) |tracked_inst|
                if (!self.isRegFree(reg)) {
                    // Move the instruction that was previously there to a
                    // stack allocation.
                    const spilled_inst = self.registers[index].?;
                    self.registers[index] = tracked_inst;
                    try self.getFunction().spillInstruction(reg, spilled_inst);
                } else {
                    self.getRegAssumeFree(reg, tracked_inst);
                }
            else {
                if (!self.isRegFree(reg)) {
                    // Move the instruction that was previously there to a
                    // stack allocation.
                    const spilled_inst = self.registers[index].?;
                    try self.getFunction().spillInstruction(reg, spilled_inst);
                    self.freeReg(reg);
                }
            }
        }

        /// Allocates the specified register with the specified
        /// instruction. Asserts that the register is free and no
        /// spilling is necessary.
        pub fn getRegAssumeFree(self: *Self, reg: Register, inst: Air.Inst.Index) void {
            const index = reg.allocIndex() orelse return;

            assert(self.registers[index] == null);
            self.registers[index] = inst;
            self.markRegUsed(reg);
        }

        /// Marks the specified register as free
        pub fn freeReg(self: *Self, reg: Register) void {
            const index = reg.allocIndex() orelse return;

            self.registers[index] = null;
            self.markRegFree(reg);
        }
    };
}

const MockRegister1 = enum(u2) {
    r0,
    r1,
    r2,
    r3,

    pub fn allocIndex(self: MockRegister1) ?u2 {
        inline for (callee_preserved_regs) |cpreg, i| {
            if (self == cpreg) return i;
        }
        return null;
    }

    const callee_preserved_regs = [_]MockRegister1{ .r2, .r3 };
};

const MockRegister2 = enum(u2) {
    r0,
    r1,
    r2,
    r3,

    pub fn allocIndex(self: MockRegister2) ?u2 {
        inline for (callee_preserved_regs) |cpreg, i| {
            if (self == cpreg) return i;
        }
        return null;
    }

    const callee_preserved_regs = [_]MockRegister2{ .r0, .r1, .r2, .r3 };
};

fn MockFunction(comptime Register: type) type {
    return struct {
        allocator: *Allocator,
        register_manager: RegisterManager(Self, Register, &Register.callee_preserved_regs) = .{},
        spilled: std.ArrayListUnmanaged(Register) = .{},

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.spilled.deinit(self.allocator);
        }

        pub fn spillInstruction(self: *Self, reg: Register, inst: Air.Inst.Index) !void {
            _ = inst;
            try self.spilled.append(self.allocator, reg);
        }
    };
}

const MockFunction1 = MockFunction(MockRegister1);
const MockFunction2 = MockFunction(MockRegister2);

test "default state" {
    const allocator = std.testing.allocator;

    var function = MockFunction1{
        .allocator = allocator,
    };
    defer function.deinit();

    try expect(!function.register_manager.isRegAllocated(.r2));
    try expect(!function.register_manager.isRegAllocated(.r3));
    try expect(function.register_manager.isRegFree(.r2));
    try expect(function.register_manager.isRegFree(.r3));
}

test "tryAllocReg: no spilling" {
    const allocator = std.testing.allocator;

    var function = MockFunction1{
        .allocator = allocator,
    };
    defer function.deinit();

    var mock_instruction = ir.Inst{
        .tag = .breakpoint,
        .ty = Type.initTag(.void),
        .src = .unneeded,
    };

    try expectEqual(@as(?MockRegister1, .r2), function.register_manager.tryAllocReg(&mock_instruction, &.{}));
    try expectEqual(@as(?MockRegister1, .r3), function.register_manager.tryAllocReg(&mock_instruction, &.{}));
    try expectEqual(@as(?MockRegister1, null), function.register_manager.tryAllocReg(&mock_instruction, &.{}));

    try expect(function.register_manager.isRegAllocated(.r2));
    try expect(function.register_manager.isRegAllocated(.r3));
    try expect(!function.register_manager.isRegFree(.r2));
    try expect(!function.register_manager.isRegFree(.r3));

    function.register_manager.freeReg(.r2);
    function.register_manager.freeReg(.r3);

    try expect(function.register_manager.isRegAllocated(.r2));
    try expect(function.register_manager.isRegAllocated(.r3));
    try expect(function.register_manager.isRegFree(.r2));
    try expect(function.register_manager.isRegFree(.r3));
}

test "allocReg: spilling" {
    const allocator = std.testing.allocator;

    var function = MockFunction1{
        .allocator = allocator,
    };
    defer function.deinit();

    var mock_instruction = ir.Inst{
        .tag = .breakpoint,
        .ty = Type.initTag(.void),
        .src = .unneeded,
    };

    try expectEqual(@as(?MockRegister1, .r2), try function.register_manager.allocReg(&mock_instruction, &.{}));
    try expectEqual(@as(?MockRegister1, .r3), try function.register_manager.allocReg(&mock_instruction, &.{}));

    // Spill a register
    try expectEqual(@as(?MockRegister1, .r2), try function.register_manager.allocReg(&mock_instruction, &.{}));
    try expectEqualSlices(MockRegister1, &[_]MockRegister1{.r2}, function.spilled.items);

    // No spilling necessary
    function.register_manager.freeReg(.r3);
    try expectEqual(@as(?MockRegister1, .r3), try function.register_manager.allocReg(&mock_instruction, &.{}));
    try expectEqualSlices(MockRegister1, &[_]MockRegister1{.r2}, function.spilled.items);

    // Exceptions
    function.register_manager.freeReg(.r2);
    function.register_manager.freeReg(.r3);
    try expectEqual(@as(?MockRegister1, .r3), try function.register_manager.allocReg(&mock_instruction, &.{.r2}));
}

test "tryAllocRegs" {
    const allocator = std.testing.allocator;

    var function = MockFunction2{
        .allocator = allocator,
    };
    defer function.deinit();

    try expectEqual([_]MockRegister2{ .r0, .r1, .r2 }, function.register_manager.tryAllocRegs(3, .{ null, null, null }, &.{}).?);

    // Exceptions
    function.register_manager.freeReg(.r0);
    function.register_manager.freeReg(.r1);
    function.register_manager.freeReg(.r2);
    try expectEqual([_]MockRegister2{ .r0, .r2, .r3 }, function.register_manager.tryAllocRegs(3, .{ null, null, null }, &.{.r1}).?);
}

test "allocRegs" {
    const allocator = std.testing.allocator;

    var function = MockFunction2{
        .allocator = allocator,
    };
    defer function.deinit();

    var mock_instruction = ir.Inst{
        .tag = .breakpoint,
        .ty = Type.initTag(.void),
        .src = .unneeded,
    };

    try expectEqual([_]MockRegister2{ .r0, .r1, .r2 }, try function.register_manager.allocRegs(3, .{
        &mock_instruction,
        &mock_instruction,
        &mock_instruction,
    }, &.{}));

    // Exceptions
    try expectEqual([_]MockRegister2{ .r0, .r2, .r3 }, try function.register_manager.allocRegs(3, .{ null, null, null }, &.{.r1}));
    try expectEqualSlices(MockRegister2, &[_]MockRegister2{ .r0, .r2 }, function.spilled.items);
}

test "getReg" {
    const allocator = std.testing.allocator;

    var function = MockFunction1{
        .allocator = allocator,
    };
    defer function.deinit();

    var mock_instruction = ir.Inst{
        .tag = .breakpoint,
        .ty = Type.initTag(.void),
        .src = .unneeded,
    };

    try function.register_manager.getReg(.r3, &mock_instruction);

    try expect(!function.register_manager.isRegAllocated(.r2));
    try expect(function.register_manager.isRegAllocated(.r3));
    try expect(function.register_manager.isRegFree(.r2));
    try expect(!function.register_manager.isRegFree(.r3));

    // Spill r3
    try function.register_manager.getReg(.r3, &mock_instruction);

    try expect(!function.register_manager.isRegAllocated(.r2));
    try expect(function.register_manager.isRegAllocated(.r3));
    try expect(function.register_manager.isRegFree(.r2));
    try expect(!function.register_manager.isRegFree(.r3));
    try expectEqualSlices(MockRegister1, &[_]MockRegister1{.r3}, function.spilled.items);
}
