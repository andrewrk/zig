//! Semantic analysis of ZIR instructions.
//! Shared to every Block. Stored on the stack.
//! State used for compiling a `zir.Code` into TZIR.
//! Transforms untyped ZIR instructions into semantically-analyzed TZIR instructions.
//! Does type checking, comptime control flow, and safety-check generation.
//! This is the the heart of the Zig compiler.

mod: *Module,
/// Same as `mod.gpa`.
gpa: *Allocator,
/// Points to the arena allocator of the Decl.
arena: *Allocator,
code: zir.Code,
/// Maps ZIR to TZIR.
inst_map: []*const Inst,
/// When analyzing an inline function call, owner_decl is the Decl of the caller
/// and `src_decl` of `Scope.Block` is the `Decl` of the callee.
/// This `Decl` owns the arena memory of this `Sema`.
owner_decl: *Decl,
func: ?*Module.Fn,
/// For now, TZIR requires arg instructions to be the first N instructions in the
/// TZIR code. We store references here for the purpose of `resolveInst`.
/// This can get reworked with TZIR memory layout changes, into simply:
/// > Denormalized data to make `resolveInst` faster. This is 0 if not inside a function,
/// > otherwise it is the number of parameters of the function.
/// > param_count: u32
param_inst_list: []const *ir.Inst,
branch_quota: u32 = 1000,
/// This field is updated when a new source location becomes active, so that
/// instructions which do not have explicitly mapped source locations still have
/// access to the source location set by the previous instruction which did
/// contain a mapped source location.
src: LazySrcLoc = .{ .token_offset = 0 },

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.sema);

const Sema = @This();
const Value = @import("value.zig").Value;
const Type = @import("type.zig").Type;
const TypedValue = @import("TypedValue.zig");
const ir = @import("ir.zig");
const zir = @import("zir.zig");
const Module = @import("Module.zig");
const Inst = ir.Inst;
const Body = ir.Body;
const trace = @import("tracy.zig").trace;
const Scope = Module.Scope;
const InnerError = Module.InnerError;
const Decl = Module.Decl;
const LazySrcLoc = Module.LazySrcLoc;

// TODO when memory layout of TZIR is reworked, this can be simplified.
const const_tzir_inst_list = blk: {
    var result: [zir.const_inst_list.len]ir.Inst.Const = undefined;
    for (result) |*tzir_const, i| {
        tzir_const.* = .{
            .base = .{
                .tag = .constant,
                .ty = zir.const_inst_list[i].ty,
                .src = 0,
            },
            .val = zir.const_inst_list[i].val,
        };
    }
    break :blk result;
};

pub fn root(sema: *Sema, root_block: *Scope.Block) !void {
    const root_body = sema.code.extra[sema.code.root_start..][0..sema.code.root_len];
    return sema.body(root_block, root_body);
}

pub fn rootAsType(
    sema: *Sema,
    root_block: *Scope.Block,
    zir_result_inst: zir.Inst.Index,
    body: zir.Body,
) !Type {
    const root_body = sema.code.extra[sema.code.root_start..][0..sema.code.root_len];
    try sema.body(root_block, root_body);

    const result_inst = sema.inst_map[zir_result_inst];
    // Source location is unneeded because resolveConstValue must have already
    // been successfully called when coercing the value to a type, from the
    // result location.
    const val = try sema.resolveConstValue(root_block, .unneeded, result_inst);
    return val.toType(root_block.arena);
}

pub fn body(sema: *Sema, block: *Scope.Block, body: []const zir.Inst.Index) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const map = block.sema.inst_map;
    const tags = block.sema.code.instructions.items(.tag);

    // TODO: As an optimization, look into making these switch prongs directly jump
    // to the next one, rather than detouring through the loop condition.
    // Also, look into leaving only the "noreturn" loop break condition, and removing
    // the iteration based one. Better yet, have an extra entry in the tags array as a
    // sentinel, so that exiting the loop is just another jump table prong.
    // Related: https://github.com/ziglang/zig/issues/8220
    for (body) |zir_inst| {
        map[zir_inst] = switch (tags[zir_inst]) {
            .alloc => try sema.zirAlloc(block, zir_inst),
            .alloc_mut => try sema.zirAllocMut(block, zir_inst),
            .alloc_inferred => try sema.zirAllocInferred(block, zir_inst, Type.initTag(.inferred_alloc_const)),
            .alloc_inferred_mut => try sema.zirAllocInferred(block, zir_inst, Type.initTag(.inferred_alloc_mut)),
            .bitcast_ref => try sema.zirBitcastRef(block, zir_inst),
            .bitcast_result_ptr => try sema.zirBitcastResultPtr(block, zir_inst),
            .block => try sema.zirBlock(block, zir_inst, false),
            .block_comptime => try sema.zirBlock(block, zir_inst, true),
            .block_flat => try sema.zirBlockFlat(block, zir_inst, false),
            .block_comptime_flat => try sema.zirBlockFlat(block, zir_inst, true),
            .@"break" => try sema.zirBreak(block, zir_inst),
            .break_void_tok => try sema.zirBreakVoidTok(block, zir_inst),
            .breakpoint => try sema.zirBreakpoint(block, zir_inst),
            .call => try sema.zirCall(block, zir_inst, .auto),
            .call_async_kw => try sema.zirCall(block, zir_inst, .async_kw),
            .call_no_async => try sema.zirCall(block, zir_inst, .no_async),
            .call_compile_time => try sema.zirCall(block, zir_inst, .compile_time),
            .call_none => try sema.zirCallNone(block, zir_inst),
            .coerce_result_ptr => try sema.zirCoerceResultPtr(block, zir_inst),
            .compile_error => try sema.zirCompileError(block, zir_inst),
            .compile_log => try sema.zirCompileLog(block, zir_inst),
            .@"const" => try sema.zirConst(block, zir_inst),
            .dbg_stmt_node => try sema.zirDbgStmtNode(block, zir_inst),
            .decl_ref => try sema.zirDeclRef(block, zir_inst),
            .decl_val => try sema.zirDeclVal(block, zir_inst),
            .ensure_result_used => try sema.zirEnsureResultUsed(block, zir_inst),
            .ensure_result_non_error => try sema.zirEnsureResultNonError(block, zir_inst),
            .indexable_ptr_len => try sema.zirIndexablePtrLen(block, zir_inst),
            .ref => try sema.zirRef(block, zir_inst),
            .resolve_inferred_alloc => try sema.zirResolveInferredAlloc(block, zir_inst),
            .ret_ptr => try sema.zirRetPtr(block, zir_inst),
            .ret_type => try sema.zirRetType(block, zir_inst),
            .store_to_block_ptr => try sema.zirStoreToBlockPtr(block, zir_inst),
            .store_to_inferred_ptr => try sema.zirStoreToInferredPtr(block, zir_inst),
            .ptr_type_simple => try sema.zirPtrTypeSimple(block, zir_inst),
            .ptr_type => try sema.zirPtrType(block, zir_inst),
            .store => try sema.zirStore(block, zir_inst),
            .set_eval_branch_quota => try sema.zirSetEvalBranchQuota(block, zir_inst),
            .str => try sema.zirStr(block, zir_inst),
            .int => try sema.zirInt(block, zir_inst),
            .int_type => try sema.zirIntType(block, zir_inst),
            .loop => try sema.zirLoop(block, zir_inst),
            .param_type => try sema.zirParamType(block, zir_inst),
            .ptrtoint => try sema.zirPtrtoint(block, zir_inst),
            .field_ptr => try sema.zirFieldPtr(block, zir_inst),
            .field_val => try sema.zirFieldVal(block, zir_inst),
            .field_ptr_named => try sema.zirFieldPtrNamed(block, zir_inst),
            .field_val_named => try sema.zirFieldValNamed(block, zir_inst),
            .deref => try sema.zirDeref(block, zir_inst),
            .as => try sema.zirAs(block, zir_inst),
            .@"asm" => try sema.zirAsm(block, zir_inst, false),
            .asm_volatile => try sema.zirAsm(block, zir_inst, true),
            .unreachable_safe => try sema.zirUnreachable(block, zir_inst, true),
            .unreachable_unsafe => try sema.zirUnreachable(block, zir_inst, false),
            .ret_tok => try sema.zirRetTok(block, zir_inst),
            .ret_node => try sema.zirRetNode(block, zir_inst),
            .fn_type => try sema.zirFnType(block, zir_inst),
            .fn_type_cc => try sema.zirFnTypeCc(block, zir_inst),
            .intcast => try sema.zirIntcast(block, zir_inst),
            .bitcast => try sema.zirBitcast(block, zir_inst),
            .floatcast => try sema.zirFloatcast(block, zir_inst),
            .elem_ptr => try sema.zirElemPtr(block, zir_inst),
            .elem_ptr_node => try sema.zirElemPtrNode(block, zir_inst),
            .elem_val => try sema.zirElemVal(block, zir_inst),
            .elem_val_node => try sema.zirElemValNode(block, zir_inst),
            .add => try sema.zirArithmetic(block, zir_inst),
            .addwrap => try sema.zirArithmetic(block, zir_inst),
            .sub => try sema.zirArithmetic(block, zir_inst),
            .subwrap => try sema.zirArithmetic(block, zir_inst),
            .mul => try sema.zirArithmetic(block, zir_inst),
            .mulwrap => try sema.zirArithmetic(block, zir_inst),
            .div => try sema.zirArithmetic(block, zir_inst),
            .mod_rem => try sema.zirArithmetic(block, zir_inst),
            .array_cat => try sema.zirArrayCat(block, zir_inst),
            .array_mul => try sema.zirArrayMul(block, zir_inst),
            .bit_and => try sema.zirBitwise(block, zir_inst),
            .bit_not => try sema.zirBitNot(block, zir_inst),
            .bit_or => try sema.zirBitwise(block, zir_inst),
            .xor => try sema.zirBitwise(block, zir_inst),
            .shl => try sema.zirShl(block, zir_inst),
            .shr => try sema.zirShr(block, zir_inst),
            .cmp_lt => try sema.zirCmp(block, zir_inst, .lt),
            .cmp_lte => try sema.zirCmp(block, zir_inst, .lte),
            .cmp_eq => try sema.zirCmp(block, zir_inst, .eq),
            .cmp_gte => try sema.zirCmp(block, zir_inst, .gte),
            .cmp_gt => try sema.zirCmp(block, zir_inst, .gt),
            .cmp_neq => try sema.zirCmp(block, zir_inst, .neq),
            .condbr => try sema.zirCondbr(block, zir_inst),
            .is_null => try sema.zirIsNull(block, zir_inst, false),
            .is_non_null => try sema.zirIsNull(block, zir_inst, true),
            .is_null_ptr => try sema.zirIsNullPtr(block, zir_inst, false),
            .is_non_null_ptr => try sema.zirIsNullPtr(block, zir_inst, true),
            .is_err => try sema.zirIsErr(block, zir_inst),
            .is_err_ptr => try sema.zirIsErrPtr(block, zir_inst),
            .bool_not => try sema.zirBoolNot(block, zir_inst),
            .typeof => try sema.zirTypeof(block, zir_inst),
            .typeof_peer => try sema.zirTypeofPeer(block, zir_inst),
            .optional_type => try sema.zirOptionalType(block, zir_inst),
            .optional_type_from_ptr_elem => try sema.zirOptionalTypeFromPtrElem(block, zir_inst),
            .optional_payload_safe => try sema.zirOptionalPayload(block, zir_inst, true),
            .optional_payload_unsafe => try sema.zirOptionalPayload(block, zir_inst, false),
            .optional_payload_safe_ptr => try sema.zirOptionalPayloadPtr(block, zir_inst, true),
            .optional_payload_unsafe_ptr => try sema.zirOptionalPayloadPtr(block, zir_inst, false),
            .err_union_payload_safe => try sema.zirErrUnionPayload(block, zir_inst, true),
            .err_union_payload_unsafe => try sema.zirErrUnionPayload(block, zir_inst, false),
            .err_union_payload_safe_ptr => try sema.zirErrUnionPayloadPtr(block, zir_inst, true),
            .err_union_payload_unsafe_ptr => try sema.zirErrUnionPayloadPtr(block, zir_inst, false),
            .err_union_code => try sema.zirErrUnionCode(block, zir_inst),
            .err_union_code_ptr => try sema.zirErrUnionCodePtr(block, zir_inst),
            .ensure_err_payload_void => try sema.zirEnsureErrPayloadVoid(block, zir_inst),
            .array_type => try sema.zirArrayType(block, zir_inst),
            .array_type_sentinel => try sema.zirArrayTypeSentinel(block, zir_inst),
            .enum_literal => try sema.zirEnumLiteral(block, zir_inst),
            .merge_error_sets => try sema.zirMergeErrorSets(block, zir_inst),
            .error_union_type => try sema.zirErrorUnionType(block, zir_inst),
            .anyframe_type => try sema.zirAnyframeType(block, zir_inst),
            .error_set => try sema.zirErrorSet(block, zir_inst),
            .error_value => try sema.zirErrorValue(block, zir_inst),
            .slice_start => try sema.zirSliceStart(block, zir_inst),
            .slice_end => try sema.zirSliceEnd(block, zir_inst),
            .slice_sentinel => try sema.zirSliceSentinel(block, zir_inst),
            .import => try sema.zirImport(block, zir_inst),
            .bool_and => try sema.zirBoolOp(block, zir_inst, false),
            .bool_or => try sema.zirBoolOp(block, zir_inst, true),
            .void_value => try sema.mod.constVoid(block.arena, .unneeded),
            .switchbr => try sema.zirSwitchBr(block, zir_inst, false),
            .switchbr_ref => try sema.zirSwitchBr(block, zir_inst, true),
            .switch_range => try sema.zirSwitchRange(block, zir_inst),
        };
        if (map[zir_inst].ty.isNoReturn()) {
            break;
        }
    }
}

fn resolveInst(sema: *Sema, block: *Scope.Block, zir_ref: zir.Inst.Ref) *const ir.Inst {
    var i = zir_ref;

    // First section of indexes correspond to a set number of constant values.
    if (i < const_tzir_inst_list.len) {
        return &const_tzir_inst_list[i];
    }
    i -= const_tzir_inst_list.len;

    // Next section of indexes correspond to function parameters, if any.
    if (block.inlining) |inlining| {
        if (i < inlining.casted_args.len) {
            return inlining.casted_args[i];
        }
        i -= inlining.casted_args.len;
    } else {
        if (i < sema.param_inst_list.len) {
            return sema.param_inst_list[i];
        }
        i -= sema.param_inst_list.len;
    }

    // Finally, the last section of indexes refers to the map of ZIR=>TZIR.
    return sema.inst_map[i];
}

fn resolveConstString(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    zir_ref: zir.Inst.Ref,
) ![]u8 {
    const tzir_inst = sema.resolveInst(block, zir_ref);
    const wanted_type = Type.initTag(.const_slice_u8);
    const coerced_inst = try sema.coerce(block, wanted_type, tzir_inst);
    const val = try sema.resolveConstValue(block, src, coerced_inst);
    return val.toAllocatedBytes(block.arena);
}

fn resolveType(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, zir_ref: zir.Inst.Ref) !Type {
    const tzir_inst = sema.resolveInt(block, zir_ref);
    const wanted_type = Type.initTag(.@"type");
    const coerced_inst = try sema.coerce(block, wanted_type, tzir_inst);
    const val = try sema.resolveConstValue(block, src, coerced_inst);
    return val.toType(sema.arena);
}

fn resolveConstValue(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, base: *ir.Inst) !Value {
    return (try sema.resolveDefinedValue(block, src, base)) orelse
        return sema.mod.fail(&block.base, src, "unable to resolve comptime value", .{});
}

fn resolveDefinedValue(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, base: *ir.Inst) !?Value {
    if (base.value()) |val| {
        if (val.isUndef()) {
            return sema.mod.fail(&block.base, src, "use of undefined value here causes undefined behavior", .{});
        }
        return val;
    }
    return null;
}

/// Appropriate to call when the coercion has already been done by result
/// location semantics. Asserts the value fits in the provided `Int` type.
/// Only supports `Int` types 64 bits or less.
fn resolveAlreadyCoercedInt(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    zir_ref: zir.Inst.Ref,
    comptime Int: type,
) !Int {
    comptime assert(@typeInfo(Int).Int.bits <= 64);
    const tzir_inst = sema.resolveInst(block, zir_ref);
    const val = try sema.resolveConstValue(block, src, tzir_inst);
    switch (@typeInfo(Int).Int.signedness) {
        .signed => return @intCast(Int, val.toSignedInt()),
        .unsigned => return @intCast(Int, val.toUnsignedInt()),
    }
}

fn resolveInt(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    zir_ref: zir.Inst.Ref,
    dest_type: Type,
) !u64 {
    const tzir_inst = sema.resolveInst(block, zir_ref);
    const coerced = try sema.coerce(scope, dest_type, tzir_inst);
    const val = try sema.resolveConstValue(block, src, coerced);

    return val.toUnsignedInt();
}

fn resolveInstConst(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    zir_ref: zir.Inst.Ref,
) InnerError!TypedValue {
    const tzir_inst = sema.resolveInst(block, zir_ref);
    const val = try sema.resolveConstValue(block, src, tzir_inst);
    return TypedValue{
        .ty = tzir_inst.ty,
        .val = val,
    };
}

fn zirConst(sema: *Sema, block: *Scope.Block, const_inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    // Move the TypedValue from old memory to new memory. This allows freeing the ZIR instructions
    // after analysis.
    const typed_value_copy = try const_inst.positionals.typed_value.copy(block.arena);
    return sema.mod.constInst(scope, const_inst.base.src, typed_value_copy);
}

fn zirBitcastRef(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    return sema.mod.fail(&block.base, inst.base.src, "TODO implement zir_sema.zirBitcastRef", .{});
}

fn zirBitcastResultPtr(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    return sema.mod.fail(&block.base, inst.base.src, "TODO implement zir_sema.zirBitcastResultPtr", .{});
}

fn zirCoerceResultPtr(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    return sema.mod.fail(&block.base, inst.base.src, "TODO implement zirCoerceResultPtr", .{});
}

fn zirRetPtr(sema: *Module, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    try sema.requireFunctionBlock(block, inst.base.src);
    const fn_ty = block.func.?.owner_decl.typed_value.most_recent.typed_value.ty;
    const ret_type = fn_ty.fnReturnType();
    const ptr_type = try sema.mod.simplePtrType(block.arena, ret_type, true, .One);
    return block.addNoOp(inst.base.src, ptr_type, .alloc);
}

fn zirRef(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const operand = sema.resolveInst(block, inst_data.operand);
    return sema.analyzeRef(block, inst_data.src(), operand);
}

fn zirRetType(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    try sema.requireFunctionBlock(block, inst.base.src);
    const fn_ty = b.func.?.owner_decl.typed_value.most_recent.typed_value.ty;
    const ret_type = fn_ty.fnReturnType();
    return sema.mod.constType(block.arena, inst.base.src, ret_type);
}

fn zirEnsureResultUsed(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const operand = sema.resolveInst(block, inst_data.operand);
    const src = inst_data.src();
    switch (operand.ty.zigTypeTag()) {
        .Void, .NoReturn => return sema.mod.constVoid(block.arena, .unneeded),
        else => return sema.mod.fail(&block.base, src, "expression value is ignored", .{}),
    }
}

fn zirEnsureResultNonError(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const operand = sema.resolveInst(block, inst_data.operand);
    const src = inst_data.src();
    switch (operand.ty.zigTypeTag()) {
        .ErrorSet, .ErrorUnion => return sema.mod.fail(&block.base, src, "error is discarded", .{}),
        else => return sema.mod.constVoid(block.arena, .unneeded),
    }
}

fn zirIndexablePtrLen(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const array_ptr = sema.resolveInst(block, inst_data.operand);

    const elem_ty = array_ptr.ty.elemType();
    if (!elem_ty.isIndexable()) {
        const cond_src: LazySrcLoc = .{ .node_offset_for_cond = inst_data.src_node };
        const msg = msg: {
            const msg = try sema.mod.errMsg(
                &block.base,
                cond_src,
                "type '{}' does not support indexing",
                .{elem_ty},
            );
            errdefer msg.destroy(mod.gpa);
            try sema.mod.errNote(
                &block.base,
                cond_src,
                msg,
                "for loop operand must be an array, slice, tuple, or vector",
                .{},
            );
            break :msg msg;
        };
        return mod.failWithOwnedErrorMsg(scope, msg);
    }
    const result_ptr = try sema.namedFieldPtr(block, inst.base.src, array_ptr, "len", inst.base.src);
    return sema.analyzeDeref(block, inst.base.src, result_ptr, result_ptr.src);
}

fn zirAlloc(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const ty_src: LazySrcLoc = .{ .node_offset_var_decl_ty = inst_data.src_node };
    const var_decl_src = inst_data.src();
    const var_type = try sema.resolveType(block, ty_src, inst_data.operand);
    const ptr_type = try sema.mod.simplePtrType(block.arena, var_type, true, .One);
    try sema.requireRuntimeBlock(block, var_decl_src);
    return block.addNoOp(var_decl_src, ptr_type, .alloc);
}

fn zirAllocMut(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const var_decl_src = inst_data.src();
    const ty_src: LazySrcLoc = .{ .node_offset_var_decl_ty = inst_data.src_node };
    const var_type = try sema.resolveType(block, ty_src, inst_data.operand);
    try sema.validateVarType(block, ty_src, var_type);
    const ptr_type = try sema.mod.simplePtrType(block.arena, var_type, true, .One);
    try sema.requireRuntimeBlock(block, var_decl_src);
    return block.addNoOp(var_decl_src, ptr_type, .alloc);
}

fn zirAllocInferred(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
    inferred_alloc_ty: Type,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    const val_payload = try block.arena.create(Value.Payload.InferredAlloc);
    val_payload.* = .{
        .data = .{},
    };
    // `Module.constInst` does not add the instruction to the block because it is
    // not needed in the case of constant values. However here, we plan to "downgrade"
    // to a normal instruction when we hit `resolve_inferred_alloc`. So we append
    // to the block even though it is currently a `.constant`.
    const result = try sema.mod.constInst(scope, inst.base.src, .{
        .ty = inferred_alloc_ty,
        .val = Value.initPayload(&val_payload.base),
    });
    try sema.requireFunctionBlock(block, inst.base.src);
    try block.instructions.append(sema.gpa, result);
    return result;
}

fn zirResolveInferredAlloc(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const ty_src: LazySrcLoc = .{ .node_offset_var_decl_ty = inst_data.src_node };
    const ptr = sema.resolveInst(block, inst_data.operand);
    const ptr_val = ptr.castTag(.constant).?.val;
    const inferred_alloc = ptr_val.castTag(.inferred_alloc).?;
    const peer_inst_list = inferred_alloc.data.stored_inst_list.items;
    const final_elem_ty = try sema.resolvePeerTypes(block, peer_inst_list);
    const var_is_mut = switch (ptr.ty.tag()) {
        .inferred_alloc_const => false,
        .inferred_alloc_mut => true,
        else => unreachable,
    };
    if (var_is_mut) {
        try sema.validateVarType(block, ty_src, final_elem_ty);
    }
    const final_ptr_ty = try sema.mod.simplePtrType(block.arena, final_elem_ty, true, .One);

    // Change it to a normal alloc.
    ptr.ty = final_ptr_ty;
    ptr.tag = .alloc;

    return sema.mod.constVoid(block.arena, .unneeded);
}

fn zirStoreToBlockPtr(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const ptr = sema.resolveInst(bin_inst.lhs);
    const value = sema.resolveInst(bin_inst.rhs);
    const ptr_ty = try sema.mod.simplePtrType(block.arena, value.ty, true, .One);
    // TODO detect when this store should be done at compile-time. For example,
    // if expressions should force it when the condition is compile-time known.
    try sema.requireRuntimeBlock(block, src);
    const bitcasted_ptr = try block.addUnOp(inst.base.src, ptr_ty, .bitcast, ptr);
    return mod.storePtr(scope, inst.base.src, bitcasted_ptr, value);
}

fn zirStoreToInferredPtr(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const ptr = sema.resolveInst(bin_inst.lhs);
    const value = sema.resolveInst(bin_inst.rhs);
    const inferred_alloc = ptr.castTag(.constant).?.val.castTag(.inferred_alloc).?;
    // Add the stored instruction to the set we will use to resolve peer types
    // for the inferred allocation.
    try inferred_alloc.data.stored_inst_list.append(block.arena, value);
    // Create a runtime bitcast instruction with exactly the type the pointer wants.
    const ptr_ty = try sema.mod.simplePtrType(block.arena, value.ty, true, .One);
    try sema.requireRuntimeBlock(block, src);
    const bitcasted_ptr = try block.addUnOp(inst.base.src, ptr_ty, .bitcast, ptr);
    return mod.storePtr(scope, inst.base.src, bitcasted_ptr, value);
}

fn zirSetEvalBranchQuota(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    try sema.requireFunctionBlock(block, src);
    const quota = try sema.resolveAlreadyCoercedInt(block, src, inst_data.operand, u32);
    if (sema.branch_quota < quota)
        sema.branch_quota = quota;
    return sema.mod.constVoid(block.arena, .unneeded);
}

fn zirStore(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const ptr = sema.resolveInst(bin_inst.lhs);
    const value = sema.resolveInst(bin_inst.rhs);
    return mod.storePtr(scope, inst.base.src, ptr, value);
}

fn zirParamType(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].param_type;
    const fn_inst = sema.resolveInst(inst_data.callee);
    const param_index = inst_data.param_index;

    const fn_ty: Type = switch (fn_inst.ty.zigTypeTag()) {
        .Fn => fn_inst.ty,
        .BoundFn => {
            return sema.mod.fail(&block.base, fn_inst.src, "TODO implement zirParamType for method call syntax", .{});
        },
        else => {
            return sema.mod.fail(&block.base, fn_inst.src, "expected function, found '{}'", .{fn_inst.ty});
        },
    };

    const param_count = fn_ty.fnParamLen();
    if (param_index >= param_count) {
        if (fn_ty.fnIsVarArgs()) {
            return sema.mod.constType(block.arena, inst.base.src, Type.initTag(.var_args_param));
        }
        return sema.mod.fail(&block.base, inst.base.src, "arg index {d} out of bounds; '{}' has {d} argument(s)", .{
            param_index,
            fn_ty,
            param_count,
        });
    }

    // TODO support generic functions
    const param_type = fn_ty.fnParamType(param_index);
    return sema.mod.constType(block.arena, inst.base.src, param_type);
}

fn zirStr(sema: *Sema, block: *Scope.Block, str_inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    // The bytes references memory inside the ZIR module, which is fine. Multiple
    // anonymous Decls may have strings which point to within the same ZIR module.
    const bytes = sema.code.instructions.items(.data)[inst].str.get(sema.code);

    var new_decl_arena = std.heap.ArenaAllocator.init(sema.gpa);
    errdefer new_decl_arena.deinit();

    const decl_ty = try Type.Tag.array_u8_sentinel_0.create(&new_decl_arena.allocator, bytes.len);
    const decl_val = try Value.Tag.bytes.create(&new_decl_arena.allocator, bytes);

    const new_decl = try sema.mod.createAnonymousDecl(&block.base, &new_decl_arena, .{
        .ty = decl_ty,
        .val = decl_val,
    });
    return sema.analyzeDeclRef(block, .unneeded, new_decl);
}

fn zirInt(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    return mod.constIntBig(scope, inst.base.src, Type.initTag(.comptime_int), inst.positionals.int);
}

fn zirCompileError(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const msg = try sema.resolveConstString(block, operand_src, inst_data.operand);
    return sema.mod.fail(&block.base, src, "{s}", .{msg});
}

fn zirCompileLog(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    var managed = mod.compile_log_text.toManaged(mod.gpa);
    defer mod.compile_log_text = managed.moveToUnmanaged();
    const writer = managed.writer();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const extra = sema.code.extraData(zir.Inst.MultiOp, inst_data.payload_index);
    for (sema.code.extra[extra.end..][0..extra.data.operands_len]) |arg_ref, i| {
        if (i != 0) try writer.print(", ", .{});

        const arg = sema.resolveInst(block, arg_ref);
        if (arg.value()) |val| {
            try writer.print("@as({}, {})", .{ arg.ty, val });
        } else {
            try writer.print("@as({}, [runtime value])", .{arg.ty});
        }
    }
    try writer.print("\n", .{});

    const gop = try mod.compile_log_decls.getOrPut(mod.gpa, scope.ownerDecl().?);
    if (!gop.found_existing) {
        gop.entry.value = .{
            .file_scope = block.getFileScope(),
            .lazy = inst_data.src(),
        };
    }
    return sema.mod.constVoid(block.arena, .unneeded);
}

fn zirLoop(sema: *Sema, parent_block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    // Reserve space for a Loop instruction so that generated Break instructions can
    // point to it, even if it doesn't end up getting used because the code ends up being
    // comptime evaluated.
    const loop_inst = try parent_block.arena.create(Inst.Loop);
    loop_inst.* = .{
        .base = .{
            .tag = Inst.Loop.base_tag,
            .ty = Type.initTag(.noreturn),
            .src = inst.base.src,
        },
        .body = undefined,
    };

    var child_block: Scope.Block = .{
        .parent = parent_block,
        .inst_table = parent_block.inst_table,
        .func = parent_block.func,
        .owner_decl = parent_block.owner_decl,
        .src_decl = parent_block.src_decl,
        .instructions = .{},
        .arena = parent_block.arena,
        .inlining = parent_block.inlining,
        .is_comptime = parent_block.is_comptime,
        .branch_quota = parent_block.branch_quota,
    };
    defer child_block.instructions.deinit(mod.gpa);

    try sema.body(&child_block, inst.positionals.body);

    // Loop repetition is implied so the last instruction may or may not be a noreturn instruction.

    try parent_block.instructions.append(mod.gpa, &loop_inst.base);
    loop_inst.body = .{ .instructions = try parent_block.arena.dupe(*Inst, child_block.instructions.items) };
    return &loop_inst.base;
}

fn zirBlockFlat(sema: *Sema, parent_block: *Scope.Block, inst: zir.Inst.Index, is_comptime: bool) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    var child_block = parent_block.makeSubBlock();
    defer child_block.instructions.deinit(mod.gpa);
    child_block.is_comptime = child_block.is_comptime or is_comptime;

    try sema.body(&child_block, inst.positionals.body);

    // Move the analyzed instructions into the parent block arena.
    const copied_instructions = try parent_block.arena.dupe(*Inst, child_block.instructions.items);
    try parent_block.instructions.appendSlice(mod.gpa, copied_instructions);

    // The result of a flat block is the last instruction.
    const zir_inst_list = inst.positionals.body.instructions;
    const last_zir_inst = zir_inst_list[zir_inst_list.len - 1];
    return sema.inst_map[last_zir_inst];
}

fn zirBlock(
    sema: *Sema,
    parent_block: *Scope.Block,
    inst: zir.Inst.Index,
    is_comptime: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    // Reserve space for a Block instruction so that generated Break instructions can
    // point to it, even if it doesn't end up getting used because the code ends up being
    // comptime evaluated.
    const block_inst = try parent_block.arena.create(Inst.Block);
    block_inst.* = .{
        .base = .{
            .tag = Inst.Block.base_tag,
            .ty = undefined, // Set after analysis.
            .src = inst.base.src,
        },
        .body = undefined,
    };

    var child_block: Scope.Block = .{
        .parent = parent_block,
        .inst_table = parent_block.inst_table,
        .func = parent_block.func,
        .owner_decl = parent_block.owner_decl,
        .src_decl = parent_block.src_decl,
        .instructions = .{},
        .arena = parent_block.arena,
        // TODO @as here is working around a stage1 miscompilation bug :(
        .label = @as(?Scope.Block.Label, Scope.Block.Label{
            .zir_block = inst,
            .merges = .{
                .results = .{},
                .br_list = .{},
                .block_inst = block_inst,
            },
        }),
        .inlining = parent_block.inlining,
        .is_comptime = is_comptime or parent_block.is_comptime,
        .branch_quota = parent_block.branch_quota,
    };
    const merges = &child_block.label.?.merges;

    defer child_block.instructions.deinit(mod.gpa);
    defer merges.results.deinit(mod.gpa);
    defer merges.br_list.deinit(mod.gpa);

    try sema.body(&child_block, inst.positionals.body);

    return analyzeBlockBody(mod, scope, &child_block, merges);
}

fn analyzeBlockBody(
    sema: *Sema,
    parent_block: *Scope.Block,
    child_block: *Scope.Block,
    merges: *Scope.Block.Merges,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    // Blocks must terminate with noreturn instruction.
    assert(child_block.instructions.items.len != 0);
    assert(child_block.instructions.items[child_block.instructions.items.len - 1].ty.isNoReturn());

    if (merges.results.items.len == 0) {
        // No need for a block instruction. We can put the new instructions
        // directly into the parent block.
        const copied_instructions = try parent_block.arena.dupe(*Inst, child_block.instructions.items);
        try parent_block.instructions.appendSlice(mod.gpa, copied_instructions);
        return copied_instructions[copied_instructions.len - 1];
    }
    if (merges.results.items.len == 1) {
        const last_inst_index = child_block.instructions.items.len - 1;
        const last_inst = child_block.instructions.items[last_inst_index];
        if (last_inst.breakBlock()) |br_block| {
            if (br_block == merges.block_inst) {
                // No need for a block instruction. We can put the new instructions directly
                // into the parent block. Here we omit the break instruction.
                const copied_instructions = try parent_block.arena.dupe(*Inst, child_block.instructions.items[0..last_inst_index]);
                try parent_block.instructions.appendSlice(mod.gpa, copied_instructions);
                return merges.results.items[0];
            }
        }
    }
    // It is impossible to have the number of results be > 1 in a comptime scope.
    assert(!child_block.is_comptime); // Should already got a compile error in the condbr condition.

    // Need to set the type and emit the Block instruction. This allows machine code generation
    // to emit a jump instruction to after the block when it encounters the break.
    try parent_block.instructions.append(mod.gpa, &merges.block_inst.base);
    const resolved_ty = try sema.resolvePeerTypes(parent_block, merges.results.items);
    merges.block_inst.base.ty = resolved_ty;
    merges.block_inst.body = .{
        .instructions = try parent_block.arena.dupe(*Inst, child_block.instructions.items),
    };
    // Now that the block has its type resolved, we need to go back into all the break
    // instructions, and insert type coercion on the operands.
    for (merges.br_list.items) |br| {
        if (br.operand.ty.eql(resolved_ty)) {
            // No type coercion needed.
            continue;
        }
        var coerce_block = parent_block.makeSubBlock();
        defer coerce_block.instructions.deinit(mod.gpa);
        const coerced_operand = try sema.coerce(&coerce_block.base, resolved_ty, br.operand);
        // If no instructions were produced, such as in the case of a coercion of a
        // constant value to a new type, we can simply point the br operand to it.
        if (coerce_block.instructions.items.len == 0) {
            br.operand = coerced_operand;
            continue;
        }
        assert(coerce_block.instructions.items[coerce_block.instructions.items.len - 1] == coerced_operand);
        // Here we depend on the br instruction having been over-allocated (if necessary)
        // inide analyzeBreak so that it can be converted into a br_block_flat instruction.
        const br_src = br.base.src;
        const br_ty = br.base.ty;
        const br_block_flat = @ptrCast(*Inst.BrBlockFlat, br);
        br_block_flat.* = .{
            .base = .{
                .src = br_src,
                .ty = br_ty,
                .tag = .br_block_flat,
            },
            .block = merges.block_inst,
            .body = .{
                .instructions = try parent_block.arena.dupe(*Inst, coerce_block.instructions.items),
            },
        };
    }
    return &merges.block_inst.base;
}

fn zirBreakpoint(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    try sema.requireRuntimeBlock(block, src);
    return block.addNoOp(inst.base.src, Type.initTag(.void), .breakpoint);
}

fn zirBreak(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const operand = sema.resolveInst(block, bin_inst.rhs);
    const zir_block = bin_inst.lhs;
    return analyzeBreak(mod, block, sema.src, zir_block, operand);
}

fn zirBreakVoidTok(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const zir_block = inst_data.operand;
    const void_inst = try sema.mod.constVoid(block.arena, .unneeded);
    return analyzeBreak(mod, block, inst_data.src(), zir_block, void_inst);
}

fn analyzeBreak(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    zir_block: zir.Inst.Index,
    operand: *Inst,
) InnerError!*Inst {
    var opt_block = scope.cast(Scope.Block);
    while (opt_block) |block| {
        if (block.label) |*label| {
            if (label.zir_block == zir_block) {
                try sema.requireFunctionBlock(block, src);
                // Here we add a br instruction, but we over-allocate a little bit
                // (if necessary) to make it possible to convert the instruction into
                // a br_block_flat instruction later.
                const br = @ptrCast(*Inst.Br, try b.arena.alignedAlloc(
                    u8,
                    Inst.convertable_br_align,
                    Inst.convertable_br_size,
                ));
                br.* = .{
                    .base = .{
                        .tag = .br,
                        .ty = Type.initTag(.noreturn),
                        .src = src,
                    },
                    .operand = operand,
                    .block = label.merges.block_inst,
                };
                try b.instructions.append(mod.gpa, &br.base);
                try label.merges.results.append(mod.gpa, operand);
                try label.merges.br_list.append(mod.gpa, br);
                return &br.base;
            }
        }
        opt_block = block.parent;
    } else unreachable;
}

fn zirDbgStmtNode(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    if (b.is_comptime) {
        return sema.mod.constVoid(block.arena, .unneeded);
    }

    const src_node = sema.code.instructions.items(.data)[inst].node;
    const src: LazySrcLoc = .{ .node_offset = src_node };
    return block.addNoOp(src, Type.initTag(.void), .dbg_stmt);
}

fn zirDeclRef(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const decl = sema.code.instructions.items(.data)[inst].decl;
    return sema.analyzeDeclRef(block, .unneeded, decl);
}

fn zirDeclVal(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const decl = sema.code.instructions.items(.data)[inst].decl;
    return sema.analyzeDeclVal(block, .unneeded, decl);
}

fn zirCallNone(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const func_src: LazySrcLoc = .{ .node_offset_call_func = inst_data.src_node };

    return sema.analyzeCall(block, inst_data.operand, func_src, inst_data.src(), .auto, &.{});
}

fn zirCall(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
    modifier: std.builtin.CallOptions.Modifier,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const func_src: LazySrcLoc = .{ .node_offset_call_func = inst_data.src_node };
    const call_src = inst_data.src();
    const extra = sema.code.extraData(zir.Inst.Call, inst_data.payload_index);
    const args = sema.code.extra[extra.end..][0..extra.data.args_len];

    return sema.analyzeCall(block, extra.data.callee, func_src, call_src, modifier, args);
}

fn analyzeCall(
    sema: *Sema,
    block: *Scope.Block,
    zir_func: zir.Inst.Ref,
    func_src: LazySrcLoc,
    call_src: LazySrcLoc,
    modifier: std.builtin.CallOptions.Modifier,
    zir_args: []const Ref,
) InnerError!*ir.Inst {
    const func = sema.resolveInst(zir_func);

    if (func.ty.zigTypeTag() != .Fn)
        return sema.mod.fail(&block.base, func_src, "type '{}' not a function", .{func.ty});

    const cc = func.ty.fnCallingConvention();
    if (cc == .Naked) {
        // TODO add error note: declared here
        return sema.mod.fail(
            &block.base,
            func_src,
            "unable to call function with naked calling convention",
            .{},
        );
    }
    const fn_params_len = func.ty.fnParamLen();
    if (func.ty.fnIsVarArgs()) {
        assert(cc == .C);
        if (zir_args.len < fn_params_len) {
            // TODO add error note: declared here
            return sema.mod.fail(
                &block.base,
                func_src,
                "expected at least {d} argument(s), found {d}",
                .{ fn_params_len, zir_args.len },
            );
        }
    } else if (fn_params_len != zir_args.len) {
        // TODO add error note: declared here
        return sema.mod.fail(
            &block.base,
            func_src,
            "expected {d} argument(s), found {d}",
            .{ fn_params_len, zir_args.len },
        );
    }

    if (modifier == .compile_time) {
        return sema.mod.fail(&block.base, call_src, "TODO implement comptime function calls", .{});
    }
    if (modifier != .auto) {
        return sema.mod.fail(&block.base, call_src, "TODO implement call with modifier {}", .{inst.positionals.modifier});
    }

    // TODO handle function calls of generic functions
    const casted_args = try block.arena.alloc(*Inst, zir_args.len);
    for (zir_args) |zir_arg, i| {
        // the args are already casted to the result of a param type instruction.
        casted_args[i] = sema.resolveInst(block, zir_arg);
    }

    const ret_type = func.ty.fnReturnType();

    try sema.requireFunctionBlock(block, call_src);
    const is_comptime_call = b.is_comptime or modifier == .compile_time;
    const is_inline_call = is_comptime_call or modifier == .always_inline or
        func.ty.fnCallingConvention() == .Inline;
    if (is_inline_call) {
        const func_val = try sema.resolveConstValue(block, func_src, func);
        const module_fn = switch (func_val.tag()) {
            .function => func_val.castTag(.function).?.data,
            .extern_fn => return sema.mod.fail(&block.base, call_src, "{s} call of extern function", .{
                @as([]const u8, if (is_comptime_call) "comptime" else "inline"),
            }),
            else => unreachable,
        };

        // Analyze the ZIR. The same ZIR gets analyzed into a runtime function
        // or an inlined call depending on what union tag the `label` field is
        // set to in the `Scope.Block`.
        // This block instruction will be used to capture the return value from the
        // inlined function.
        const block_inst = try block.arena.create(Inst.Block);
        block_inst.* = .{
            .base = .{
                .tag = Inst.Block.base_tag,
                .ty = ret_type,
                .src = call_src,
            },
            .body = undefined,
        };
        // If this is the top of the inline/comptime call stack, we use this data.
        // Otherwise we pass on the shared data from the parent scope.
        var shared_inlining: Scope.Block.Inlining.Shared = .{
            .branch_count = 0,
            .caller = b.func,
        };
        // This one is shared among sub-blocks within the same callee, but not
        // shared among the entire inline/comptime call stack.
        var inlining: Scope.Block.Inlining = .{
            .shared = if (b.inlining) |inlining| inlining.shared else &shared_inlining,
            .param_index = 0,
            .casted_args = casted_args,
            .merges = .{
                .results = .{},
                .br_list = .{},
                .block_inst = block_inst,
            },
        };
        var inst_table = Scope.Block.InstTable.init(mod.gpa);
        defer inst_table.deinit();

        var child_block: Scope.Block = .{
            .parent = null,
            .inst_table = &inst_table,
            .func = module_fn,
            .owner_decl = scope.ownerDecl().?,
            .src_decl = module_fn.owner_decl,
            .instructions = .{},
            .arena = block.arena,
            .label = null,
            .inlining = &inlining,
            .is_comptime = is_comptime_call,
            .branch_quota = b.branch_quota,
        };

        const merges = &child_block.inlining.?.merges;

        defer child_block.instructions.deinit(mod.gpa);
        defer merges.results.deinit(mod.gpa);
        defer merges.br_list.deinit(mod.gpa);

        try mod.emitBackwardBranch(&child_block, call_src);

        // This will have return instructions analyzed as break instructions to
        // the block_inst above.
        try sema.body(&child_block, module_fn.zir);

        return analyzeBlockBody(mod, scope, &child_block, merges);
    }

    return block.addCall(call_src, ret_type, func, casted_args);
}

fn zirIntType(sema: *Sema, block: *Scope.Block, inttype: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    return sema.mod.fail(&block.base, inttype.base.src, "TODO implement inttype", .{});
}

fn zirOptionalType(sema: *Sema, block: *Scope.Block, optional: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const child_type = try sema.resolveType(block, inst_data.operand);
    const opt_type = try mod.optionalType(block.arena, child_type);

    return sema.mod.constType(block.arena, inst_data.src(), opt_type);
}

fn zirOptionalTypeFromPtrElem(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const ptr = sema.resolveInst(block, inst_data.operand);
    const elem_ty = ptr.ty.elemType();
    const opt_ty = try mod.optionalType(block.arena, elem_ty);

    return sema.mod.constType(block.arena, inst_data.src(), opt_ty);
}

fn zirArrayType(sema: *Sema, block: *Scope.Block, array: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    // TODO these should be lazily evaluated
    const len = try resolveInstConst(mod, scope, array.positionals.lhs);
    const elem_type = try sema.resolveType(block, array.positionals.rhs);

    return sema.mod.constType(block.arena, array.base.src, try mod.arrayType(scope, len.val.toUnsignedInt(), null, elem_type));
}

fn zirArrayTypeSentinel(sema: *Sema, block: *Scope.Block, array: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    // TODO these should be lazily evaluated
    const len = try resolveInstConst(mod, scope, array.positionals.len);
    const sentinel = try resolveInstConst(mod, scope, array.positionals.sentinel);
    const elem_type = try sema.resolveType(block, array.positionals.elem_type);

    return sema.mod.constType(block.arena, array.base.src, try mod.arrayType(scope, len.val.toUnsignedInt(), sentinel.val, elem_type));
}

fn zirErrorUnionType(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const error_union = try sema.resolveType(block, bin_inst.lhs);
    const payload = try sema.resolveType(block, bin_inst.rhs);

    if (error_union.zigTypeTag() != .ErrorSet) {
        return sema.mod.fail(&block.base, inst.base.src, "expected error set type, found {}", .{error_union.elemType()});
    }

    return sema.mod.constType(block.arena, inst.base.src, try mod.errorUnionType(scope, error_union, payload));
}

fn zirAnyframeType(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_anyframe_type = inst_data.src_node };
    const return_type = try sema.resolveType(block, operand_src, inst_data.operand);
    const anyframe_type = try sema.mod.anyframeType(block.arena, return_type);

    return sema.mod.constType(block.arena, src, anyframe_type);
}

fn zirErrorSet(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    // The owner Decl arena will store the hashmap.
    var new_decl_arena = std.heap.ArenaAllocator.init(mod.gpa);
    errdefer new_decl_arena.deinit();

    const payload = try new_decl_arena.allocator.create(Value.Payload.ErrorSet);
    payload.* = .{
        .base = .{ .tag = .error_set },
        .data = .{
            .fields = .{},
            .decl = undefined, // populated below
        },
    };
    try payload.data.fields.ensureCapacity(&new_decl_arena.allocator, @intCast(u32, inst.positionals.fields.len));

    for (inst.positionals.fields) |field_name| {
        const entry = try mod.getErrorValue(field_name);
        if (payload.data.fields.fetchPutAssumeCapacity(entry.key, {})) |_| {
            return sema.mod.fail(&block.base, inst.base.src, "duplicate error: '{s}'", .{field_name});
        }
    }
    // TODO create name in format "error:line:column"
    const new_decl = try mod.createAnonymousDecl(scope, &new_decl_arena, .{
        .ty = Type.initTag(.type),
        .val = Value.initPayload(&payload.base),
    });
    payload.data.decl = new_decl;
    return mod.analyzeDeclVal(scope, inst.base.src, new_decl);
}

fn zirErrorValue(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    // Create an anonymous error set type with only this error value, and return the value.
    const entry = try mod.getErrorValue(inst.positionals.name);
    const result_type = try Type.Tag.error_set_single.create(block.arena, entry.key);
    return sema.mod.constInst(scope, inst.base.src, .{
        .ty = result_type,
        .val = try Value.Tag.@"error".create(block.arena, .{
            .name = entry.key,
        }),
    });
}

fn zirMergeErrorSets(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const lhs_ty = try sema.resolveType(block, bin_inst.lhs);
    const rhs_ty = try sema.resolveType(block, bin_inst.rhs);
    if (rhs_ty.zigTypeTag() != .ErrorSet)
        return sema.mod.fail(&block.base, inst.positionals.rhs.src, "expected error set type, found {}", .{rhs_ty});
    if (lhs_ty.zigTypeTag() != .ErrorSet)
        return sema.mod.fail(&block.base, inst.positionals.lhs.src, "expected error set type, found {}", .{lhs_ty});

    // anything merged with anyerror is anyerror
    if (lhs_ty.tag() == .anyerror or rhs_ty.tag() == .anyerror)
        return sema.mod.constInst(scope, inst.base.src, .{
            .ty = Type.initTag(.type),
            .val = Value.initTag(.anyerror_type),
        });
    // The declarations arena will store the hashmap.
    var new_decl_arena = std.heap.ArenaAllocator.init(mod.gpa);
    errdefer new_decl_arena.deinit();

    const payload = try new_decl_arena.allocator.create(Value.Payload.ErrorSet);
    payload.* = .{
        .base = .{ .tag = .error_set },
        .data = .{
            .fields = .{},
            .decl = undefined, // populated below
        },
    };
    try payload.data.fields.ensureCapacity(&new_decl_arena.allocator, @intCast(u32, switch (rhs_ty.tag()) {
        .error_set_single => 1,
        .error_set => rhs_ty.castTag(.error_set).?.data.typed_value.most_recent.typed_value.val.castTag(.error_set).?.data.fields.size,
        else => unreachable,
    } + switch (lhs_ty.tag()) {
        .error_set_single => 1,
        .error_set => lhs_ty.castTag(.error_set).?.data.typed_value.most_recent.typed_value.val.castTag(.error_set).?.data.fields.size,
        else => unreachable,
    }));

    switch (lhs_ty.tag()) {
        .error_set_single => {
            const name = lhs_ty.castTag(.error_set_single).?.data;
            payload.data.fields.putAssumeCapacity(name, {});
        },
        .error_set => {
            var multiple = lhs_ty.castTag(.error_set).?.data.typed_value.most_recent.typed_value.val.castTag(.error_set).?.data.fields;
            var it = multiple.iterator();
            while (it.next()) |entry| {
                payload.data.fields.putAssumeCapacity(entry.key, entry.value);
            }
        },
        else => unreachable,
    }

    switch (rhs_ty.tag()) {
        .error_set_single => {
            const name = rhs_ty.castTag(.error_set_single).?.data;
            payload.data.fields.putAssumeCapacity(name, {});
        },
        .error_set => {
            var multiple = rhs_ty.castTag(.error_set).?.data.typed_value.most_recent.typed_value.val.castTag(.error_set).?.data.fields;
            var it = multiple.iterator();
            while (it.next()) |entry| {
                payload.data.fields.putAssumeCapacity(entry.key, entry.value);
            }
        },
        else => unreachable,
    }
    // TODO create name in format "error:line:column"
    const new_decl = try mod.createAnonymousDecl(scope, &new_decl_arena, .{
        .ty = Type.initTag(.type),
        .val = Value.initPayload(&payload.base),
    });
    payload.data.decl = new_decl;

    return mod.analyzeDeclVal(scope, inst.base.src, new_decl);
}

fn zirEnumLiteral(sema: *Sema, block: *Scope.Block, zir_inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const duped_name = try block.arena.dupe(u8, inst.positionals.name);
    return sema.mod.constInst(scope, inst.base.src, .{
        .ty = Type.initTag(.enum_literal),
        .val = try Value.Tag.enum_literal.create(block.arena, duped_name),
    });
}

/// Pointer in, pointer out.
fn zirOptionalPayloadPtr(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
    safety_check: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const optional_ptr = sema.resolveInst(block, inst_data.operand);
    assert(optional_ptr.ty.zigTypeTag() == .Pointer);
    const src = inst_data.src();

    const opt_type = optional_ptr.ty.elemType();
    if (opt_type.zigTypeTag() != .Optional) {
        return sema.mod.fail(&block.base, src, "expected optional type, found {}", .{opt_type});
    }

    const child_type = try opt_type.optionalChildAlloc(block.arena);
    const child_pointer = try sema.mod.simplePtrType(block.arena, child_type, !optional_ptr.ty.isConstPtr(), .One);

    if (optional_ptr.value()) |pointer_val| {
        const val = try pointer_val.pointerDeref(block.arena);
        if (val.isNull()) {
            return sema.mod.fail(&block.base, src, "unable to unwrap null", .{});
        }
        // The same Value represents the pointer to the optional and the payload.
        return sema.mod.constInst(scope, src, .{
            .ty = child_pointer,
            .val = pointer_val,
        });
    }

    try sema.requireRuntimeBlock(block, src);
    if (safety_check and block.wantSafety()) {
        const is_non_null = try block.addUnOp(src, Type.initTag(.bool), .is_non_null_ptr, optional_ptr);
        try mod.addSafetyCheck(b, is_non_null, .unwrap_null);
    }
    return block.addUnOp(src, child_pointer, .optional_payload_ptr, optional_ptr);
}

/// Value in, value out.
fn zirOptionalPayload(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
    safety_check: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const src = inst_data.src();
    const operand = sema.resolveInst(block, inst_data.operand);
    const opt_type = operand.ty;
    if (opt_type.zigTypeTag() != .Optional) {
        return sema.mod.fail(&block.base, src, "expected optional type, found {}", .{opt_type});
    }

    const child_type = try opt_type.optionalChildAlloc(block.arena);

    if (operand.value()) |val| {
        if (val.isNull()) {
            return sema.mod.fail(&block.base, src, "unable to unwrap null", .{});
        }
        return sema.mod.constInst(scope, src, .{
            .ty = child_type,
            .val = val,
        });
    }

    try sema.requireRuntimeBlock(block, src);
    if (safety_check and block.wantSafety()) {
        const is_non_null = try block.addUnOp(src, Type.initTag(.bool), .is_non_null, operand);
        try mod.addSafetyCheck(b, is_non_null, .unwrap_null);
    }
    return block.addUnOp(src, child_type, .optional_payload, operand);
}

/// Value in, value out
fn zirErrUnionPayload(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
    safety_check: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const src = inst_data.src();
    const operand = sema.resolveInst(block, inst_data.operand);
    if (operand.ty.zigTypeTag() != .ErrorUnion)
        return sema.mod.fail(&block.base, operand.src, "expected error union type, found '{}'", .{operand.ty});

    if (operand.value()) |val| {
        if (val.getError()) |name| {
            return sema.mod.fail(&block.base, src, "caught unexpected error '{s}'", .{name});
        }
        const data = val.castTag(.error_union).?.data;
        return sema.mod.constInst(scope, src, .{
            .ty = operand.ty.castTag(.error_union).?.data.payload,
            .val = data,
        });
    }
    try sema.requireRuntimeBlock(block, src);
    if (safety_check and block.wantSafety()) {
        const is_non_err = try block.addUnOp(src, Type.initTag(.bool), .is_err, operand);
        try mod.addSafetyCheck(b, is_non_err, .unwrap_errunion);
    }
    return block.addUnOp(src, operand.ty.castTag(.error_union).?.data.payload, .unwrap_errunion_payload, operand);
}

/// Pointer in, pointer out.
fn zirErrUnionPayloadPtr(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
    safety_check: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const src = inst_data.src();
    const operand = sema.resolveInst(block, inst_data.operand);
    assert(operand.ty.zigTypeTag() == .Pointer);

    if (operand.ty.elemType().zigTypeTag() != .ErrorUnion)
        return sema.mod.fail(&block.base, src, "expected error union type, found {}", .{operand.ty.elemType()});

    const operand_pointer_ty = try sema.mod.simplePtrType(block.arena, operand.ty.elemType().castTag(.error_union).?.data.payload, !operand.ty.isConstPtr(), .One);

    if (operand.value()) |pointer_val| {
        const val = try pointer_val.pointerDeref(block.arena);
        if (val.getError()) |name| {
            return sema.mod.fail(&block.base, src, "caught unexpected error '{s}'", .{name});
        }
        const data = val.castTag(.error_union).?.data;
        // The same Value represents the pointer to the error union and the payload.
        return sema.mod.constInst(scope, src, .{
            .ty = operand_pointer_ty,
            .val = try Value.Tag.ref_val.create(
                block.arena,
                data,
            ),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    if (safety_check and block.wantSafety()) {
        const is_non_err = try block.addUnOp(src, Type.initTag(.bool), .is_err, operand);
        try mod.addSafetyCheck(b, is_non_err, .unwrap_errunion);
    }
    return block.addUnOp(src, operand_pointer_ty, .unwrap_errunion_payload_ptr, operand);
}

/// Value in, value out
fn zirErrUnionCode(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const src = inst_data.src();
    const operand = sema.resolveInst(block, inst_data.operand);
    if (operand.ty.zigTypeTag() != .ErrorUnion)
        return sema.mod.fail(&block.base, src, "expected error union type, found '{}'", .{operand.ty});

    if (operand.value()) |val| {
        assert(val.getError() != null);
        const data = val.castTag(.error_union).?.data;
        return sema.mod.constInst(scope, src, .{
            .ty = operand.ty.castTag(.error_union).?.data.error_set,
            .val = data,
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, operand.ty.castTag(.error_union).?.data.payload, .unwrap_errunion_err, operand);
}

/// Pointer in, value out
fn zirErrUnionCodePtr(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const src = inst_data.src();
    const operand = sema.resolveInst(block, inst_data.operand);
    assert(operand.ty.zigTypeTag() == .Pointer);

    if (operand.ty.elemType().zigTypeTag() != .ErrorUnion)
        return sema.mod.fail(&block.base, src, "expected error union type, found {}", .{operand.ty.elemType()});

    if (operand.value()) |pointer_val| {
        const val = try pointer_val.pointerDeref(block.arena);
        assert(val.getError() != null);
        const data = val.castTag(.error_union).?.data;
        return sema.mod.constInst(scope, src, .{
            .ty = operand.ty.elemType().castTag(.error_union).?.data.error_set,
            .val = data,
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, operand.ty.castTag(.error_union).?.data.payload, .unwrap_errunion_err_ptr, operand);
}

fn zirEnsureErrPayloadVoid(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const src = inst_data.src();
    const operand = sema.resolveInst(block, inst_data.operand);
    if (operand.ty.zigTypeTag() != .ErrorUnion)
        return sema.mod.fail(&block.base, src, "expected error union type, found '{}'", .{operand.ty});
    if (operand.ty.castTag(.error_union).?.data.payload.zigTypeTag() != .Void) {
        return sema.mod.fail(&block.base, src, "expression value is ignored", .{});
    }
    return sema.mod.constVoid(block.arena, .unneeded);
}

fn zirFnType(sema: *Sema, block: *Scope.Block, fntype: zir.Inst.Index, var_args: bool) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    return fnTypeCommon(
        mod,
        scope,
        &fntype.base,
        fntype.positionals.param_types,
        fntype.positionals.return_type,
        .Unspecified,
        var_args,
    );
}

fn zirFnTypeCc(sema: *Sema, block: *Scope.Block, fntype: zir.Inst.Index, var_args: bool) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const cc_tv = try resolveInstConst(mod, scope, fntype.positionals.cc);
    // TODO once we're capable of importing and analyzing decls from
    // std.builtin, this needs to change
    const cc_str = cc_tv.val.castTag(.enum_literal).?.data;
    const cc = std.meta.stringToEnum(std.builtin.CallingConvention, cc_str) orelse
        return sema.mod.fail(&block.base, fntype.positionals.cc.src, "Unknown calling convention {s}", .{cc_str});
    return fnTypeCommon(
        mod,
        scope,
        &fntype.base,
        fntype.positionals.param_types,
        fntype.positionals.return_type,
        cc,
        var_args,
    );
}

fn fnTypeCommon(
    sema: *Sema,
    block: *Scope.Block,
    zir_inst: zir.Inst.Index,
    zir_param_types: []zir.Inst.Index,
    zir_return_type: zir.Inst.Index,
    cc: std.builtin.CallingConvention,
    var_args: bool,
) InnerError!*Inst {
    const return_type = try sema.resolveType(block, zir_return_type);

    // Hot path for some common function types.
    if (zir_param_types.len == 0 and !var_args) {
        if (return_type.zigTypeTag() == .NoReturn and cc == .Unspecified) {
            return sema.mod.constType(block.arena, zir_inst.src, Type.initTag(.fn_noreturn_no_args));
        }

        if (return_type.zigTypeTag() == .Void and cc == .Unspecified) {
            return sema.mod.constType(block.arena, zir_inst.src, Type.initTag(.fn_void_no_args));
        }

        if (return_type.zigTypeTag() == .NoReturn and cc == .Naked) {
            return sema.mod.constType(block.arena, zir_inst.src, Type.initTag(.fn_naked_noreturn_no_args));
        }

        if (return_type.zigTypeTag() == .Void and cc == .C) {
            return sema.mod.constType(block.arena, zir_inst.src, Type.initTag(.fn_ccc_void_no_args));
        }
    }

    const param_types = try block.arena.alloc(Type, zir_param_types.len);
    for (zir_param_types) |param_type, i| {
        const resolved = try sema.resolveType(block, param_type);
        // TODO skip for comptime params
        if (!resolved.isValidVarType(false)) {
            return sema.mod.fail(&block.base, param_type.src, "parameter of type '{}' must be declared comptime", .{resolved});
        }
        param_types[i] = resolved;
    }

    const fn_ty = try Type.Tag.function.create(block.arena, .{
        .param_types = param_types,
        .return_type = return_type,
        .cc = cc,
        .is_var_args = var_args,
    });
    return sema.mod.constType(block.arena, zir_inst.src, fn_ty);
}

fn zirAs(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const dest_type = try sema.resolveType(block, bin_inst.lhs);
    const tzir_inst = sema.resolveInst(block, bin_inst.rhs);
    return sema.coerce(scope, dest_type, tzir_inst);
}

fn zirPtrtoint(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const ptr = sema.resolveInst(block, inst_data.operand);
    if (ptr.ty.zigTypeTag() != .Pointer) {
        const ptr_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
        return sema.mod.fail(&block.base, ptr_src, "expected pointer, found '{}'", .{ptr.ty});
    }
    // TODO handle known-pointer-address
    const src = inst_data.src();
    try sema.requireRuntimeBlock(block, src);
    const ty = Type.initTag(.usize);
    return block.addUnOp(src, ty, .ptrtoint, ptr);
}

fn zirFieldVal(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const field_name_src: LazySrcLoc = .{ .node_offset_field_name = inst_data.src_node };
    const extra = sema.code.extraData(zir.Inst.Field, inst_data.payload_index).data;
    const field_name = sema.code.string_bytes[extra.field_name_start..][0..extra.field_name_len];
    const object = sema.resolveInst(block, extra.lhs);
    const object_ptr = try sema.analyzeRef(block, src, object);
    const result_ptr = try sema.namedFieldPtr(block, src, object_ptr, field_name, field_name_src);
    return sema.analyzeDeref(block, src, result_ptr, result_ptr.src);
}

fn zirFieldPtr(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const field_name_src: LazySrcLoc = .{ .node_offset_field_name = inst_data.src_node };
    const extra = sema.code.extraData(zir.Inst.Field, inst_data.payload_index).data;
    const field_name = sema.code.string_bytes[extra.field_name_start..][0..extra.field_name_len];
    const object_ptr = sema.resolveInst(block, extra.lhs);
    return sema.namedFieldPtr(block, src, object_ptr, field_name, field_name_src);
}

fn zirFieldValNamed(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const field_name_src: LazySrcLoc = .{ .node_offset_builtin_call_arg1 = inst_data.src_node };
    const extra = sema.code.extraData(zir.Inst.FieldNamed, inst_data.payload_index).data;
    const object = sema.resolveInst(block, extra.lhs);
    const field_name = try sema.resolveConstString(block, field_name_src, extra.field_name);
    const object_ptr = try sema.analyzeRef(block, src, object);
    const result_ptr = try sema.namedFieldPtr(block, src, object_ptr, field_name, field_name_src);
    return sema.analyzeDeref(block, src, result_ptr, src);
}

fn zirFieldPtrNamed(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const field_name_src: LazySrcLoc = .{ .node_offset_builtin_call_arg1 = inst_data.src_node };
    const extra = sema.code.extraData(zir.Inst.FieldNamed, inst_data.payload_index).data;
    const object_ptr = sema.resolveInst(block, extra.lhs);
    const field_name = try sema.resolveConstString(block, field_name_src, extra.field_name);
    return sema.namedFieldPtr(block, src, object_ptr, field_name, field_name_src);
}

fn zirIntcast(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const dest_type = try sema.resolveType(block, bin_inst.lhs);
    const operand = sema.resolveInst(bin_inst.rhs);

    const dest_is_comptime_int = switch (dest_type.zigTypeTag()) {
        .ComptimeInt => true,
        .Int => false,
        else => return mod.fail(
            scope,
            inst.positionals.lhs.src,
            "expected integer type, found '{}'",
            .{
                dest_type,
            },
        ),
    };

    switch (operand.ty.zigTypeTag()) {
        .ComptimeInt, .Int => {},
        else => return mod.fail(
            scope,
            inst.positionals.rhs.src,
            "expected integer type, found '{}'",
            .{operand.ty},
        ),
    }

    if (operand.value() != null) {
        return sema.coerce(scope, dest_type, operand);
    } else if (dest_is_comptime_int) {
        return sema.mod.fail(&block.base, inst.base.src, "unable to cast runtime value to 'comptime_int'", .{});
    }

    return sema.mod.fail(&block.base, inst.base.src, "TODO implement analyze widen or shorten int", .{});
}

fn zirBitcast(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const dest_type = try sema.resolveType(block, bin_inst.lhs);
    const operand = sema.resolveInst(bin_inst.rhs);
    return mod.bitcast(scope, dest_type, operand);
}

fn zirFloatcast(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const dest_type = try sema.resolveType(block, bin_inst.lhs);
    const operand = sema.resolveInst(bin_inst.rhs);

    const dest_is_comptime_float = switch (dest_type.zigTypeTag()) {
        .ComptimeFloat => true,
        .Float => false,
        else => return mod.fail(
            scope,
            inst.positionals.lhs.src,
            "expected float type, found '{}'",
            .{
                dest_type,
            },
        ),
    };

    switch (operand.ty.zigTypeTag()) {
        .ComptimeFloat, .Float, .ComptimeInt => {},
        else => return mod.fail(
            scope,
            inst.positionals.rhs.src,
            "expected float type, found '{}'",
            .{operand.ty},
        ),
    }

    if (operand.value() != null) {
        return sema.coerce(scope, dest_type, operand);
    } else if (dest_is_comptime_float) {
        return sema.mod.fail(&block.base, inst.base.src, "unable to cast runtime value to 'comptime_float'", .{});
    }

    return sema.mod.fail(&block.base, inst.base.src, "TODO implement analyze widen or shorten float", .{});
}

fn zirElemVal(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const array = sema.resolveInst(block, bin_inst.lhs);
    const array_ptr = try sema.analyzeRef(block, sema.src, array);
    const elem_index = sema.resolveInst(block, bin_inst.rhs);
    const result_ptr = try sema.elemPtr(block, sema.src, array_ptr, elem_index, sema.src);
    return sema.analyzeDeref(block, sema.src, result_ptr, sema.src);
}

fn zirElemValNode(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const elem_index_src: LazySrcLoc = .{ .node_offset_array_access_index = inst_data.src_node };
    const extra = sema.code.extraData(zir.Inst.Bin, inst_data.payload_index).data;
    const array = sema.resolveInst(block, extra.lhs);
    const array_ptr = try sema.analyzeRef(block, src, array);
    const elem_index = sema.resolveInst(block, extra.rhs);
    const result_ptr = try sema.elemPtr(block, src, array_ptr, elem_index, elem_index_src);
    return sema.analyzeDeref(block, src, result_ptr, src);
}

fn zirElemPtr(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const array_ptr = sema.resolveInst(block, bin_inst.lhs);
    const elem_index = sema.resolveInst(block, bin_inst.rhs);
    return sema.elemPtr(block, sema.src, array_ptr, elem_index, sema.src);
}

fn zirElemPtrNode(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const elem_index_src: LazySrcLoc = .{ .node_offset_array_access_index = inst_data.src_node };
    const extra = sema.code.extraData(zir.Inst.Bin, inst_data.payload_index).data;
    const array_ptr = sema.resolveInst(block, extra.lhs);
    const elem_index = sema.resolveInst(block, extra.rhs);
    return sema.elemPtr(block, src, array_ptr, elem_index, elem_index_src);
}

fn zirSliceStart(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const extra = sema.code.extraData(zir.Inst.SliceStart, inst_data.payload_index).data;
    const array_ptr = sema.resolveInst(extra.lhs);
    const start = sema.resolveInst(extra.start);

    return sema.analyzeSlice(block, src, array_ptr, start, null, null, .unneeded);
}

fn zirSliceEnd(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const extra = sema.code.extraData(zir.Inst.SliceEnd, inst_data.payload_index).data;
    const array_ptr = sema.resolveInst(extra.lhs);
    const start = sema.resolveInst(extra.start);
    const end = sema.resolveInst(extra.end);

    return sema.analyzeSlice(block, src, array_ptr, start, end, null, .unneeded);
}

fn zirSliceSentinel(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const sentinel_src: LazySrcLoc = .{ .node_offset_slice_sentinel = inst_data.src_node };
    const extra = sema.code.extraData(zir.Inst.SliceSentinel, inst_data.payload_index).data;
    const array_ptr = sema.resolveInst(extra.lhs);
    const start = sema.resolveInst(extra.start);
    const end = sema.resolveInst(extra.end);
    const sentinel = sema.resolveInst(extra.sentinel);

    return sema.analyzeSlice(block, inst.base.src, array_ptr, start, end, sentinel, sentinel_src);
}

fn zirSwitchRange(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const start = sema.resolveInst(bin_inst.lhs);
    const end = sema.resolveInst(bin_inst.rhs);

    switch (start.ty.zigTypeTag()) {
        .Int, .ComptimeInt => {},
        else => return sema.mod.constVoid(block.arena, .unneeded),
    }
    switch (end.ty.zigTypeTag()) {
        .Int, .ComptimeInt => {},
        else => return sema.mod.constVoid(block.arena, .unneeded),
    }
    // .switch_range must be inside a comptime scope
    const start_val = start.value().?;
    const end_val = end.value().?;
    if (start_val.compare(.gte, end_val)) {
        return sema.mod.fail(&block.base, inst.base.src, "range start value must be smaller than the end value", .{});
    }
    return sema.mod.constVoid(block.arena, .unneeded);
}

fn zirSwitchBr(
    sema: *Sema,
    parent_block: *Scope.Block,
    inst: zir.Inst.Index,
    ref: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    if (true) @panic("TODO rework with zir-memory-layout in mind");

    const target_ptr = sema.resolveInst(block, inst.positionals.target);
    const target = if (ref)
        try sema.analyzeDeref(block, inst.base.src, target_ptr, inst.positionals.target.src)
    else
        target_ptr;
    try validateSwitch(mod, scope, target, inst);

    if (try mod.resolveDefinedValue(scope, target)) |target_val| {
        for (inst.positionals.cases) |case| {
            const resolved = sema.resolveInst(block, case.item);
            const casted = try sema.coerce(scope, target.ty, resolved);
            const item = try sema.resolveConstValue(parent_block, case_src, casted);

            if (target_val.eql(item)) {
                try sema.body(scope.cast(Scope.Block).?, case.body);
                return mod.constNoReturn(scope, inst.base.src);
            }
        }
        try sema.body(scope.cast(Scope.Block).?, inst.positionals.else_body);
        return mod.constNoReturn(scope, inst.base.src);
    }

    if (inst.positionals.cases.len == 0) {
        // no cases just analyze else_branch
        try sema.body(scope.cast(Scope.Block).?, inst.positionals.else_body);
        return mod.constNoReturn(scope, inst.base.src);
    }

    try sema.requireRuntimeBlock(parent_block, inst.base.src);
    const cases = try parent_block.arena.alloc(Inst.SwitchBr.Case, inst.positionals.cases.len);

    var case_block: Scope.Block = .{
        .parent = parent_block,
        .inst_table = parent_block.inst_table,
        .func = parent_block.func,
        .owner_decl = parent_block.owner_decl,
        .src_decl = parent_block.src_decl,
        .instructions = .{},
        .arena = parent_block.arena,
        .inlining = parent_block.inlining,
        .is_comptime = parent_block.is_comptime,
        .branch_quota = parent_block.branch_quota,
    };
    defer case_block.instructions.deinit(mod.gpa);

    for (inst.positionals.cases) |case, i| {
        // Reset without freeing.
        case_block.instructions.items.len = 0;

        const resolved = sema.resolveInst(block, case.item);
        const casted = try sema.coerce(scope, target.ty, resolved);
        const item = try sema.resolveConstValue(parent_block, case_src, casted);

        try sema.body(&case_block, case.body);

        cases[i] = .{
            .item = item,
            .body = .{ .instructions = try parent_block.arena.dupe(*Inst, case_block.instructions.items) },
        };
    }

    case_block.instructions.items.len = 0;
    try sema.body(&case_block, inst.positionals.else_body);

    const else_body: ir.Body = .{
        .instructions = try parent_block.arena.dupe(*Inst, case_block.instructions.items),
    };

    return mod.addSwitchBr(parent_block, inst.base.src, target, cases, else_body);
}

fn validateSwitch(sema: *Sema, block: *Scope.Block, target: *Inst, inst: zir.Inst.Index) InnerError!void {
    // validate usage of '_' prongs
    if (inst.positionals.special_prong == .underscore and target.ty.zigTypeTag() != .Enum) {
        return sema.mod.fail(&block.base, inst.base.src, "'_' prong only allowed when switching on non-exhaustive enums", .{});
        // TODO notes "'_' prong here" inst.positionals.cases[last].src
    }

    // check that target type supports ranges
    if (inst.positionals.range) |range_inst| {
        switch (target.ty.zigTypeTag()) {
            .Int, .ComptimeInt => {},
            else => {
                return sema.mod.fail(&block.base, target.src, "ranges not allowed when switching on type {}", .{target.ty});
                // TODO notes "range used here" range_inst.src
            },
        }
    }

    // validate for duplicate items/missing else prong
    switch (target.ty.zigTypeTag()) {
        .Enum => return sema.mod.fail(&block.base, inst.base.src, "TODO validateSwitch .Enum", .{}),
        .ErrorSet => return sema.mod.fail(&block.base, inst.base.src, "TODO validateSwitch .ErrorSet", .{}),
        .Union => return sema.mod.fail(&block.base, inst.base.src, "TODO validateSwitch .Union", .{}),
        .Int, .ComptimeInt => {
            var range_set = @import("RangeSet.zig").init(mod.gpa);
            defer range_set.deinit();

            for (inst.positionals.items) |item| {
                const maybe_src = if (item.castTag(.switch_range)) |range| blk: {
                    const start_resolved = sema.resolveInst(block, range.positionals.lhs);
                    const start_casted = try sema.coerce(scope, target.ty, start_resolved);
                    const end_resolved = sema.resolveInst(block, range.positionals.rhs);
                    const end_casted = try sema.coerce(scope, target.ty, end_resolved);

                    break :blk try range_set.add(
                        try sema.resolveConstValue(block, range_start_src, start_casted),
                        try sema.resolveConstValue(block, range_end_src, end_casted),
                        item.src,
                    );
                } else blk: {
                    const resolved = sema.resolveInst(block, item);
                    const casted = try sema.coerce(scope, target.ty, resolved);
                    const value = try sema.resolveConstValue(block, item_src, casted);
                    break :blk try range_set.add(value, value, item.src);
                };

                if (maybe_src) |previous_src| {
                    return sema.mod.fail(&block.base, item.src, "duplicate switch value", .{});
                    // TODO notes "previous value is here" previous_src
                }
            }

            if (target.ty.zigTypeTag() == .Int) {
                var arena = std.heap.ArenaAllocator.init(mod.gpa);
                defer arena.deinit();

                const start = try target.ty.minInt(&arena, mod.getTarget());
                const end = try target.ty.maxInt(&arena, mod.getTarget());
                if (try range_set.spans(start, end)) {
                    if (inst.positionals.special_prong == .@"else") {
                        return sema.mod.fail(&block.base, inst.base.src, "unreachable else prong, all cases already handled", .{});
                    }
                    return;
                }
            }

            if (inst.positionals.special_prong != .@"else") {
                return sema.mod.fail(&block.base, inst.base.src, "switch must handle all possibilities", .{});
            }
        },
        .Bool => {
            var true_count: u8 = 0;
            var false_count: u8 = 0;
            for (inst.positionals.items) |item| {
                const resolved = sema.resolveInst(block, item);
                const casted = try sema.coerce(scope, Type.initTag(.bool), resolved);
                if ((try sema.resolveConstValue(block, item_src, casted)).toBool()) {
                    true_count += 1;
                } else {
                    false_count += 1;
                }

                if (true_count + false_count > 2) {
                    return sema.mod.fail(&block.base, item.src, "duplicate switch value", .{});
                }
            }
            if ((true_count + false_count < 2) and inst.positionals.special_prong != .@"else") {
                return sema.mod.fail(&block.base, inst.base.src, "switch must handle all possibilities", .{});
            }
            if ((true_count + false_count == 2) and inst.positionals.special_prong == .@"else") {
                return sema.mod.fail(&block.base, inst.base.src, "unreachable else prong, all cases already handled", .{});
            }
        },
        .EnumLiteral, .Void, .Fn, .Pointer, .Type => {
            if (inst.positionals.special_prong != .@"else") {
                return sema.mod.fail(&block.base, inst.base.src, "else prong required when switching on type '{}'", .{target.ty});
            }

            var seen_values = std.HashMap(Value, usize, Value.hash, Value.eql, std.hash_map.DefaultMaxLoadPercentage).init(mod.gpa);
            defer seen_values.deinit();

            for (inst.positionals.items) |item| {
                const resolved = sema.resolveInst(block, item);
                const casted = try sema.coerce(scope, target.ty, resolved);
                const val = try sema.resolveConstValue(block, item_src, casted);

                if (try seen_values.fetchPut(val, item.src)) |prev| {
                    return sema.mod.fail(&block.base, item.src, "duplicate switch value", .{});
                    // TODO notes "previous value here" prev.value
                }
            }
        },

        .ErrorUnion,
        .NoReturn,
        .Array,
        .Struct,
        .Undefined,
        .Null,
        .Optional,
        .BoundFn,
        .Opaque,
        .Vector,
        .Frame,
        .AnyFrame,
        .ComptimeFloat,
        .Float,
        => {
            return sema.mod.fail(&block.base, target.src, "invalid switch target type '{}'", .{target.ty});
        },
    }
}

fn zirImport(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const operand = try sema.resolveConstString(block, operand_src, inst_data.operand);

    const file_scope = sema.analyzeImport(block, src, operand) catch |err| switch (err) {
        error.ImportOutsidePkgPath => {
            return sema.mod.fail(&block.base, src, "import of file outside package path: '{s}'", .{operand});
        },
        error.FileNotFound => {
            return sema.mod.fail(&block.base, src, "unable to find '{s}'", .{operand});
        },
        else => {
            // TODO: make sure this gets retried and not cached
            return sema.mod.fail(&block.base, src, "unable to open '{s}': {s}", .{ operand, @errorName(err) });
        },
    };
    return sema.mod.constType(block.arena, src, file_scope.root_container.ty);
}

fn zirShl(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    return sema.mod.fail(&block.base, inst.base.src, "TODO implement zirShl", .{});
}

fn zirShr(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    return sema.mod.fail(&block.base, inst.base.src, "TODO implement zirShr", .{});
}

fn zirBitwise(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const lhs = sema.resolveInst(bin_inst.lhs);
    const rhs = sema.resolveInst(bin_inst.rhs);

    const instructions = &[_]*Inst{ lhs, rhs };
    const resolved_type = try sema.resolvePeerTypes(block, instructions);
    const casted_lhs = try sema.coerce(scope, resolved_type, lhs);
    const casted_rhs = try sema.coerce(scope, resolved_type, rhs);

    const scalar_type = if (resolved_type.zigTypeTag() == .Vector)
        resolved_type.elemType()
    else
        resolved_type;

    const scalar_tag = scalar_type.zigTypeTag();

    if (lhs.ty.zigTypeTag() == .Vector and rhs.ty.zigTypeTag() == .Vector) {
        if (lhs.ty.arrayLen() != rhs.ty.arrayLen()) {
            return sema.mod.fail(&block.base, inst.base.src, "vector length mismatch: {d} and {d}", .{
                lhs.ty.arrayLen(),
                rhs.ty.arrayLen(),
            });
        }
        return sema.mod.fail(&block.base, inst.base.src, "TODO implement support for vectors in zirBitwise", .{});
    } else if (lhs.ty.zigTypeTag() == .Vector or rhs.ty.zigTypeTag() == .Vector) {
        return sema.mod.fail(&block.base, inst.base.src, "mixed scalar and vector operands to binary expression: '{}' and '{}'", .{
            lhs.ty,
            rhs.ty,
        });
    }

    const is_int = scalar_tag == .Int or scalar_tag == .ComptimeInt;

    if (!is_int) {
        return sema.mod.fail(&block.base, inst.base.src, "invalid operands to binary bitwise expression: '{s}' and '{s}'", .{ @tagName(lhs.ty.zigTypeTag()), @tagName(rhs.ty.zigTypeTag()) });
    }

    if (casted_lhs.value()) |lhs_val| {
        if (casted_rhs.value()) |rhs_val| {
            if (lhs_val.isUndef() or rhs_val.isUndef()) {
                return sema.mod.constInst(scope, inst.base.src, .{
                    .ty = resolved_type,
                    .val = Value.initTag(.undef),
                });
            }
            return sema.mod.fail(&block.base, inst.base.src, "TODO implement comptime bitwise operations", .{});
        }
    }

    try sema.requireRuntimeBlock(block, inst.base.src);
    const ir_tag = switch (inst.base.tag) {
        .bit_and => Inst.Tag.bit_and,
        .bit_or => Inst.Tag.bit_or,
        .xor => Inst.Tag.xor,
        else => unreachable,
    };

    return mod.addBinOp(b, inst.base.src, scalar_type, ir_tag, casted_lhs, casted_rhs);
}

fn zirBitNot(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    return sema.mod.fail(&block.base, inst.base.src, "TODO implement zirBitNot", .{});
}

fn zirArrayCat(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    return sema.mod.fail(&block.base, inst.base.src, "TODO implement zirArrayCat", .{});
}

fn zirArrayMul(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();
    return sema.mod.fail(&block.base, inst.base.src, "TODO implement zirArrayMul", .{});
}

fn zirArithmetic(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const lhs = sema.resolveInst(bin_inst.lhs);
    const rhs = sema.resolveInst(bin_inst.rhs);

    const instructions = &[_]*Inst{ lhs, rhs };
    const resolved_type = try sema.resolvePeerTypes(block, instructions);
    const casted_lhs = try sema.coerce(scope, resolved_type, lhs);
    const casted_rhs = try sema.coerce(scope, resolved_type, rhs);

    const scalar_type = if (resolved_type.zigTypeTag() == .Vector)
        resolved_type.elemType()
    else
        resolved_type;

    const scalar_tag = scalar_type.zigTypeTag();

    if (lhs.ty.zigTypeTag() == .Vector and rhs.ty.zigTypeTag() == .Vector) {
        if (lhs.ty.arrayLen() != rhs.ty.arrayLen()) {
            return sema.mod.fail(&block.base, inst.base.src, "vector length mismatch: {d} and {d}", .{
                lhs.ty.arrayLen(),
                rhs.ty.arrayLen(),
            });
        }
        return sema.mod.fail(&block.base, inst.base.src, "TODO implement support for vectors in zirBinOp", .{});
    } else if (lhs.ty.zigTypeTag() == .Vector or rhs.ty.zigTypeTag() == .Vector) {
        return sema.mod.fail(&block.base, inst.base.src, "mixed scalar and vector operands to binary expression: '{}' and '{}'", .{
            lhs.ty,
            rhs.ty,
        });
    }

    const is_int = scalar_tag == .Int or scalar_tag == .ComptimeInt;
    const is_float = scalar_tag == .Float or scalar_tag == .ComptimeFloat;

    if (!is_int and !(is_float and floatOpAllowed(inst.base.tag))) {
        return sema.mod.fail(&block.base, inst.base.src, "invalid operands to binary expression: '{s}' and '{s}'", .{ @tagName(lhs.ty.zigTypeTag()), @tagName(rhs.ty.zigTypeTag()) });
    }

    if (casted_lhs.value()) |lhs_val| {
        if (casted_rhs.value()) |rhs_val| {
            if (lhs_val.isUndef() or rhs_val.isUndef()) {
                return sema.mod.constInst(scope, inst.base.src, .{
                    .ty = resolved_type,
                    .val = Value.initTag(.undef),
                });
            }
            return analyzeInstComptimeOp(mod, scope, scalar_type, inst, lhs_val, rhs_val);
        }
    }

    try sema.requireRuntimeBlock(block, inst.base.src);
    const ir_tag: Inst.Tag = switch (inst.base.tag) {
        .add => .add,
        .addwrap => .addwrap,
        .sub => .sub,
        .subwrap => .subwrap,
        .mul => .mul,
        .mulwrap => .mulwrap,
        else => return sema.mod.fail(&block.base, inst.base.src, "TODO implement arithmetic for operand '{s}''", .{@tagName(inst.base.tag)}),
    };

    return mod.addBinOp(b, inst.base.src, scalar_type, ir_tag, casted_lhs, casted_rhs);
}

/// Analyzes operands that are known at comptime
fn analyzeInstComptimeOp(sema: *Sema, block: *Scope.Block, res_type: Type, inst: zir.Inst.Index, lhs_val: Value, rhs_val: Value) InnerError!*Inst {
    // incase rhs is 0, simply return lhs without doing any calculations
    // TODO Once division is implemented we should throw an error when dividing by 0.
    if (rhs_val.compareWithZero(.eq)) {
        return sema.mod.constInst(scope, inst.base.src, .{
            .ty = res_type,
            .val = lhs_val,
        });
    }
    const is_int = res_type.isInt() or res_type.zigTypeTag() == .ComptimeInt;

    const value = switch (inst.base.tag) {
        .add => blk: {
            const val = if (is_int)
                try Module.intAdd(block.arena, lhs_val, rhs_val)
            else
                try mod.floatAdd(scope, res_type, inst.base.src, lhs_val, rhs_val);
            break :blk val;
        },
        .sub => blk: {
            const val = if (is_int)
                try Module.intSub(block.arena, lhs_val, rhs_val)
            else
                try mod.floatSub(scope, res_type, inst.base.src, lhs_val, rhs_val);
            break :blk val;
        },
        else => return sema.mod.fail(&block.base, inst.base.src, "TODO Implement arithmetic operand '{s}'", .{@tagName(inst.base.tag)}),
    };

    log.debug("{s}({}, {}) result: {}", .{ @tagName(inst.base.tag), lhs_val, rhs_val, value });

    return sema.mod.constInst(scope, inst.base.src, .{
        .ty = res_type,
        .val = value,
    });
}

fn zirDeref(sema: *Sema, block: *Scope.Block, deref: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const ptr_src: LazySrcLoc = .{ .node_offset_deref_ptr = inst_data.src_node };
    const ptr = sema.resolveInst(block, inst_data.operand);
    return sema.analyzeDeref(block, src, ptr, ptr_src);
}

fn zirAsm(
    sema: *Sema,
    block: *Scope.Block,
    assembly: zir.Inst.Index,
    is_volatile: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const asm_source_src: LazySrcLoc = .{ .node_offset_asm_source = inst_data.src_node };
    const ret_ty_src: LazySrcLoc = .{ .node_offset_asm_ret_ty = inst_data.src_node };
    const extra = sema.code.extraData(zir.Inst.Asm, inst_data.payload_index);
    const return_type = try sema.resolveType(block, ret_ty_src, extra.data.return_type);
    const asm_source = try sema.resolveConstString(block, asm_source_src, extra.data.asm_source);

    var extra_i = extra.end;
    const output = if (extra.data.output != 0) blk: {
        const name = sema.code.nullTerminatedString(sema.code.extra[extra_i]);
        extra_i += 1;
        break :blk .{
            .name = name,
            .inst = try sema.resolveInst(block, extra.data.output),
        };
    } else null;

    const args = try block.arena.alloc(*Inst, extra.data.args.len);
    const inputs = try block.arena.alloc([]const u8, extra.data.args_len);
    const clobbers = try block.arena.alloc([]const u8, extra.data.clobbers_len);

    for (args) |*arg| {
        const uncasted = sema.resolveInst(block, sema.code.extra[extra_i]);
        extra_i += 1;
        arg.* = try sema.coerce(block, Type.initTag(.usize), uncasted);
    }
    for (inputs) |*name| {
        name.* = sema.code.nullTerminatedString(sema.code.extra[extra_i]);
        extra_i += 1;
    }
    for (clobbers) |*name| {
        name.* = sema.code.nullTerminatedString(sema.code.extra[extra_i]);
        extra_i += 1;
    }

    try sema.requireRuntimeBlock(block, src);
    const inst = try block.arena.create(Inst.Assembly);
    inst.* = .{
        .base = .{
            .tag = .assembly,
            .ty = return_type,
            .src = src,
        },
        .asm_source = asm_source,
        .is_volatile = is_volatile,
        .output = if (output) |o| o.inst else null,
        .output_name = if (output) |o| o.name else null,
        .inputs = inputs,
        .clobbers = clobbers,
        .args = args,
    };
    try block.instructions.append(mod.gpa, &inst.base);
    return &inst.base;
}

fn zirCmp(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
    op: std.math.CompareOperator,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const lhs = sema.resolveInst(bin_inst.lhs);
    const rhs = sema.resolveInst(bin_inst.rhs);

    const is_equality_cmp = switch (op) {
        .eq, .neq => true,
        else => false,
    };
    const lhs_ty_tag = lhs.ty.zigTypeTag();
    const rhs_ty_tag = rhs.ty.zigTypeTag();
    if (is_equality_cmp and lhs_ty_tag == .Null and rhs_ty_tag == .Null) {
        // null == null, null != null
        return mod.constBool(block.arena, inst.base.src, op == .eq);
    } else if (is_equality_cmp and
        ((lhs_ty_tag == .Null and rhs_ty_tag == .Optional) or
        rhs_ty_tag == .Null and lhs_ty_tag == .Optional))
    {
        // comparing null with optionals
        const opt_operand = if (lhs_ty_tag == .Optional) lhs else rhs;
        return sema.analyzeIsNull(block, inst.base.src, opt_operand, op == .neq);
    } else if (is_equality_cmp and
        ((lhs_ty_tag == .Null and rhs.ty.isCPtr()) or (rhs_ty_tag == .Null and lhs.ty.isCPtr())))
    {
        return sema.mod.fail(&block.base, inst.base.src, "TODO implement C pointer cmp", .{});
    } else if (lhs_ty_tag == .Null or rhs_ty_tag == .Null) {
        const non_null_type = if (lhs_ty_tag == .Null) rhs.ty else lhs.ty;
        return sema.mod.fail(&block.base, inst.base.src, "comparison of '{}' with null", .{non_null_type});
    } else if (is_equality_cmp and
        ((lhs_ty_tag == .EnumLiteral and rhs_ty_tag == .Union) or
        (rhs_ty_tag == .EnumLiteral and lhs_ty_tag == .Union)))
    {
        return sema.mod.fail(&block.base, inst.base.src, "TODO implement equality comparison between a union's tag value and an enum literal", .{});
    } else if (lhs_ty_tag == .ErrorSet and rhs_ty_tag == .ErrorSet) {
        if (!is_equality_cmp) {
            return sema.mod.fail(&block.base, inst.base.src, "{s} operator not allowed for errors", .{@tagName(op)});
        }
        if (rhs.value()) |rval| {
            if (lhs.value()) |lval| {
                // TODO optimisation oppurtunity: evaluate if std.mem.eql is faster with the names, or calling to Module.getErrorValue to get the values and then compare them is faster
                return mod.constBool(block.arena, inst.base.src, std.mem.eql(u8, lval.castTag(.@"error").?.data.name, rval.castTag(.@"error").?.data.name) == (op == .eq));
            }
        }
        try sema.requireRuntimeBlock(block, inst.base.src);
        return mod.addBinOp(b, inst.base.src, Type.initTag(.bool), if (op == .eq) .cmp_eq else .cmp_neq, lhs, rhs);
    } else if (lhs.ty.isNumeric() and rhs.ty.isNumeric()) {
        // This operation allows any combination of integer and float types, regardless of the
        // signed-ness, comptime-ness, and bit-width. So peer type resolution is incorrect for
        // numeric types.
        return mod.cmpNumeric(scope, inst.base.src, lhs, rhs, op);
    } else if (lhs_ty_tag == .Type and rhs_ty_tag == .Type) {
        if (!is_equality_cmp) {
            return sema.mod.fail(&block.base, inst.base.src, "{s} operator not allowed for types", .{@tagName(op)});
        }
        return mod.constBool(block.arena, inst.base.src, lhs.value().?.eql(rhs.value().?) == (op == .eq));
    }
    return sema.mod.fail(&block.base, inst.base.src, "TODO implement more cmp analysis", .{});
}

fn zirTypeof(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const operand = sema.resolveInst(block, inst_data.operand);
    return sema.mod.constType(block.arena, inst_data.src(), operand.ty);
}

fn zirTypeofPeer(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const extra = sema.code.extraData(zir.Inst.MultiOp, inst_data.payload_index);

    const inst_list = try mod.gpa.alloc(*ir.Inst, extra.data.operands_len);
    defer mod.gpa.free(inst_list);

    const src_list = try mod.gpa.alloc(LazySrcLoc, extra.data.operands_len);
    defer mod.gpa.free(src_list);

    for (sema.code.extra[extra.end..][0..extra.data.operands_len]) |arg_ref, i| {
        inst_list[i] = sema.resolveInst(block, arg_ref);
        src_list[i] = .{ .node_offset_builtin_call_argn = inst_data.src_node };
    }

    const result_type = try sema.resolvePeerTypes(block, inst_list, src_list);
    return sema.mod.constType(block.arena, src, result_type);
}

fn zirBoolNot(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const src = inst_data.src();
    const uncasted_operand = sema.resolveInst(block, inst_data.operand);

    const bool_type = Type.initTag(.bool);
    const operand = try sema.coerce(scope, bool_type, uncasted_operand);
    if (try mod.resolveDefinedValue(scope, operand)) |val| {
        return mod.constBool(block.arena, src, !val.toBool());
    }
    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, bool_type, .not, operand);
}

fn zirBoolOp(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
    comptime is_bool_or: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bool_type = Type.initTag(.bool);
    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const uncasted_lhs = sema.resolveInst(bin_inst.lhs);
    const lhs = try sema.coerce(scope, bool_type, uncasted_lhs);
    const uncasted_rhs = sema.resolveInst(bin_inst.rhs);
    const rhs = try sema.coerce(scope, bool_type, uncasted_rhs);

    if (lhs.value()) |lhs_val| {
        if (rhs.value()) |rhs_val| {
            if (is_bool_or) {
                return mod.constBool(block.arena, inst.base.src, lhs_val.toBool() or rhs_val.toBool());
            } else {
                return mod.constBool(block.arena, inst.base.src, lhs_val.toBool() and rhs_val.toBool());
            }
        }
    }
    try sema.requireRuntimeBlock(block, inst.base.src);
    const tag: ir.Inst.Tag = if (is_bool_or) .bool_or else .bool_and;
    return mod.addBinOp(b, inst.base.src, bool_type, tag, lhs, rhs);
}

fn zirIsNull(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
    invert_logic: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const src = inst_data.src();
    const operand = sema.resolveInst(block, inst_data.operand);
    return sema.analyzeIsNull(block, src, operand, invert_logic);
}

fn zirIsNullPtr(
    sema: *Sema,
    block: *Scope.Block,
    inst: zir.Inst.Index,
    invert_logic: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const src = inst_data.src();
    const ptr = sema.resolveInst(block, inst_data.operand);
    const loaded = try sema.analyzeDeref(block, src, ptr, src);
    return sema.analyzeIsNull(block, src, loaded, invert_logic);
}

fn zirIsErr(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const operand = sema.resolveInst(block, inst_data.operand);
    return mod.analyzeIsErr(scope, inst_data.src(), operand);
}

fn zirIsErrPtr(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const src = inst_data.src();
    const ptr = sema.resolveInst(block, inst_data.operand);
    const loaded = try sema.analyzeDeref(block, src, ptr, src);
    return mod.analyzeIsErr(scope, src, loaded);
}

fn zirCondbr(sema: *Sema, parent_block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const uncasted_cond = sema.resolveInst(block, inst.positionals.condition);
    const cond = try sema.coerce(scope, Type.initTag(.bool), uncasted_cond);

    if (try mod.resolveDefinedValue(scope, cond)) |cond_val| {
        const body = if (cond_val.toBool()) &inst.positionals.then_body else &inst.positionals.else_body;
        try sema.body(parent_block, body.*);
        return mod.constNoReturn(scope, inst.base.src);
    }

    var true_block: Scope.Block = .{
        .parent = parent_block,
        .inst_table = parent_block.inst_table,
        .func = parent_block.func,
        .owner_decl = parent_block.owner_decl,
        .src_decl = parent_block.src_decl,
        .instructions = .{},
        .arena = parent_block.arena,
        .inlining = parent_block.inlining,
        .is_comptime = parent_block.is_comptime,
        .branch_quota = parent_block.branch_quota,
    };
    defer true_block.instructions.deinit(mod.gpa);
    try sema.body(&true_block, inst.positionals.then_body);

    var false_block: Scope.Block = .{
        .parent = parent_block,
        .inst_table = parent_block.inst_table,
        .func = parent_block.func,
        .owner_decl = parent_block.owner_decl,
        .src_decl = parent_block.src_decl,
        .instructions = .{},
        .arena = parent_block.arena,
        .inlining = parent_block.inlining,
        .is_comptime = parent_block.is_comptime,
        .branch_quota = parent_block.branch_quota,
    };
    defer false_block.instructions.deinit(mod.gpa);
    try sema.body(&false_block, inst.positionals.else_body);

    const then_body: ir.Body = .{ .instructions = try block.arena.dupe(*Inst, true_block.instructions.items) };
    const else_body: ir.Body = .{ .instructions = try block.arena.dupe(*Inst, false_block.instructions.items) };
    return mod.addCondBr(parent_block, inst.base.src, cond, then_body, else_body);
}

fn zirUnreachable(
    sema: *Sema,
    block: *Scope.Block,
    zir_index: zir.Inst.Index,
    safety_check: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    try sema.requireRuntimeBlock(block, zir_index.base.src);
    // TODO Add compile error for @optimizeFor occurring too late in a scope.
    if (safety_check and block.wantSafety()) {
        return mod.safetyPanic(b, zir_index.base.src, .unreach);
    } else {
        return block.addNoOp(zir_index.base.src, Type.initTag(.noreturn), .unreach);
    }
}

fn zirRetTok(sema: *Sema, block: *Scope.Block, zir_inst: zir.Inst.Index) InnerError!*Inst {
    @compileError("TODO");
}

fn zirRetNode(sema: *Sema, block: *Scope.Block, zir_inst: zir.Inst.Index) InnerError!*Inst {
    @compileError("TODO");
}

fn floatOpAllowed(tag: zir.Inst.Tag) bool {
    // extend this swich as additional operators are implemented
    return switch (tag) {
        .add, .sub => true,
        else => false,
    };
}

fn zirPtrTypeSimple(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].ptr_type_simple;
    const elem_type = try sema.resolveType(block, .unneeded, inst_data.elem_type);
    const ty = try sema.mod.ptrType(
        block.arena,
        elem_type,
        null,
        0,
        0,
        0,
        inst_data.is_mutable,
        inst_data.is_allowzero,
        inst_data.is_volatile,
        inst_data.size,
    );
    return sema.mod.constType(block.arena, .unneeded, ty);
}

fn zirPtrType(sema: *Sema, block: *Scope.Block, inst: zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].ptr_type;
    const extra = sema.code.extraData(zir.Inst.PtrType, inst_data.payload_index);

    var extra_i = extra.end;

    const sentinel = if (inst_data.flags.has_sentinel) blk: {
        const ref = sema.code.extra[extra_i];
        extra_i += 1;
        break :blk (try sema.resolveInstConst(block, .unneeded, ref)).val;
    } else null;

    const abi_align = if (inst_data.flags.has_align) blk: {
        const ref = sema.code.extra[extra_i];
        extra_i += 1;
        break :blk try sema.resolveAlreadyCoercedInt(block, .unneeded, ref, u32);
    } else 0;

    const bit_start = if (inst_data.flags.has_bit_start) blk: {
        const ref = sema.code.extra[extra_i];
        extra_i += 1;
        break :blk try sema.resolveAlreadyCoercedInt(block, .unneeded, ref, u16);
    } else 0;

    const bit_end = if (inst_data.flags.has_bit_end) blk: {
        const ref = sema.code.extra[extra_i];
        extra_i += 1;
        break :blk try sema.resolveAlreadyCoercedInt(block, .unneeded, ref, u16);
    } else 0;

    if (bit_end != 0 and bit_offset >= bit_end * 8)
        return sema.mod.fail(&block.base, inst.base.src, "bit offset starts after end of host integer", .{});

    const elem_type = try sema.resolveType(block, extra.data.elem_type);

    const ty = try mod.ptrType(
        scope,
        elem_type,
        sentinel,
        abi_align,
        bit_start,
        bit_end,
        inst_data.flags.is_mutable,
        inst_data.flags.is_allowzero,
        inst_data.flags.is_volatile,
        inst_data.size,
    );
    return sema.mod.constType(block.arena, .unneeded, ty);
}

fn requireFunctionBlock(sema: *Sema, block: *Scope.Block, src: LazySrcLoc) !void {
    if (sema.func == null) {
        return sema.mod.fail(&block.base, src, "instruction illegal outside function body", .{});
    }
}

fn requireRuntimeBlock(sema: *Sema, block: *Scope.Block, src: LazySrcLoc) !void {
    try sema.requireFunctionBlock(scope, src);
    if (block.is_comptime) {
        return sema.mod.fail(&block.base, src, "unable to resolve comptime value", .{});
    }
}

fn validateVarType(sema: *Module, block: *Scope.Block, src: LazySrcLoc, ty: Type) !void {
    if (!ty.isValidVarType(false)) {
        return mod.fail(&block.base, src, "variable of type '{}' must be const or comptime", .{ty});
    }
}

pub const PanicId = enum {
    unreach,
    unwrap_null,
    unwrap_errunion,
};

fn addSafetyCheck(sema: *Sema, parent_block: *Scope.Block, ok: *Inst, panic_id: PanicId) !void {
    const block_inst = try parent_block.arena.create(Inst.Block);
    block_inst.* = .{
        .base = .{
            .tag = Inst.Block.base_tag,
            .ty = Type.initTag(.void),
            .src = ok.src,
        },
        .body = .{
            .instructions = try parent_block.arena.alloc(*Inst, 1), // Only need space for the condbr.
        },
    };

    const ok_body: ir.Body = .{
        .instructions = try parent_block.arena.alloc(*Inst, 1), // Only need space for the br_void.
    };
    const br_void = try parent_block.arena.create(Inst.BrVoid);
    br_void.* = .{
        .base = .{
            .tag = .br_void,
            .ty = Type.initTag(.noreturn),
            .src = ok.src,
        },
        .block = block_inst,
    };
    ok_body.instructions[0] = &br_void.base;

    var fail_block: Scope.Block = .{
        .parent = parent_block,
        .inst_map = parent_block.inst_map,
        .func = parent_block.func,
        .owner_decl = parent_block.owner_decl,
        .src_decl = parent_block.src_decl,
        .instructions = .{},
        .arena = parent_block.arena,
        .inlining = parent_block.inlining,
        .is_comptime = parent_block.is_comptime,
        .branch_quota = parent_block.branch_quota,
    };

    defer fail_block.instructions.deinit(mod.gpa);

    _ = try mod.safetyPanic(&fail_block, ok.src, panic_id);

    const fail_body: ir.Body = .{ .instructions = try parent_block.arena.dupe(*Inst, fail_block.instructions.items) };

    const condbr = try parent_block.arena.create(Inst.CondBr);
    condbr.* = .{
        .base = .{
            .tag = .condbr,
            .ty = Type.initTag(.noreturn),
            .src = ok.src,
        },
        .condition = ok,
        .then_body = ok_body,
        .else_body = fail_body,
    };
    block_inst.body.instructions[0] = &condbr.base;

    try parent_block.instructions.append(mod.gpa, &block_inst.base);
}

fn safetyPanic(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, panic_id: PanicId) !*Inst {
    // TODO Once we have a panic function to call, call it here instead of breakpoint.
    _ = try mod.addNoOp(block, src, Type.initTag(.void), .breakpoint);
    return mod.addNoOp(block, src, Type.initTag(.noreturn), .unreach);
}

fn emitBackwardBranch(sema: *Sema, block: *Scope.Block, src: LazySrcLoc) !void {
    const shared = block.inlining.?.shared;
    shared.branch_count += 1;
    if (shared.branch_count > sema.branch_quota) {
        // TODO show the "called from here" stack
        return sema.mod.fail(&block.base, src, "evaluation exceeded {d} backwards branches", .{sema.branch_quota});
    }
}

fn namedFieldPtr(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    object_ptr: *Inst,
    field_name: []const u8,
    field_name_src: LazySrcLoc,
) InnerError!*Inst {
    const elem_ty = switch (object_ptr.ty.zigTypeTag()) {
        .Pointer => object_ptr.ty.elemType(),
        else => return sema.mod.fail(&block.base, object_ptr.src, "expected pointer, found '{}'", .{object_ptr.ty}),
    };
    switch (elem_ty.zigTypeTag()) {
        .Array => {
            if (mem.eql(u8, field_name, "len")) {
                return mod.constInst(scope, src, .{
                    .ty = Type.initTag(.single_const_pointer_to_comptime_int),
                    .val = try Value.Tag.ref_val.create(
                        scope.arena(),
                        try Value.Tag.int_u64.create(scope.arena(), elem_ty.arrayLen()),
                    ),
                });
            } else {
                return mod.fail(
                    scope,
                    field_name_src,
                    "no member named '{s}' in '{}'",
                    .{ field_name, elem_ty },
                );
            }
        },
        .Pointer => {
            const ptr_child = elem_ty.elemType();
            switch (ptr_child.zigTypeTag()) {
                .Array => {
                    if (mem.eql(u8, field_name, "len")) {
                        return mod.constInst(scope, src, .{
                            .ty = Type.initTag(.single_const_pointer_to_comptime_int),
                            .val = try Value.Tag.ref_val.create(
                                scope.arena(),
                                try Value.Tag.int_u64.create(scope.arena(), ptr_child.arrayLen()),
                            ),
                        });
                    } else {
                        return mod.fail(
                            scope,
                            field_name_src,
                            "no member named '{s}' in '{}'",
                            .{ field_name, elem_ty },
                        );
                    }
                },
                else => {},
            }
        },
        .Type => {
            _ = try sema.resolveConstValue(scope, object_ptr.src, object_ptr);
            const result = try sema.analyzeDeref(block, src, object_ptr, object_ptr.src);
            const val = result.value().?;
            const child_type = try val.toType(scope.arena());
            switch (child_type.zigTypeTag()) {
                .ErrorSet => {
                    var name: []const u8 = undefined;
                    // TODO resolve inferred error sets
                    if (val.castTag(.error_set)) |payload|
                        name = (payload.data.fields.getEntry(field_name) orelse return sema.mod.fail(&block.base, src, "no error named '{s}' in '{}'", .{ field_name, child_type })).key
                    else
                        name = (try mod.getErrorValue(field_name)).key;

                    const result_type = if (child_type.tag() == .anyerror)
                        try Type.Tag.error_set_single.create(scope.arena(), name)
                    else
                        child_type;

                    return mod.constInst(scope, src, .{
                        .ty = try mod.simplePtrType(scope.arena(), result_type, false, .One),
                        .val = try Value.Tag.ref_val.create(
                            scope.arena(),
                            try Value.Tag.@"error".create(scope.arena(), .{
                                .name = name,
                            }),
                        ),
                    });
                },
                .Struct => {
                    const container_scope = child_type.getContainerScope();
                    if (mod.lookupDeclName(&container_scope.base, field_name)) |decl| {
                        // TODO if !decl.is_pub and inDifferentFiles() "{} is private"
                        return sema.analyzeDeclRef(block, src, decl);
                    }

                    if (container_scope.file_scope == mod.root_scope) {
                        return sema.mod.fail(&block.base, src, "root source file has no member called '{s}'", .{field_name});
                    } else {
                        return sema.mod.fail(&block.base, src, "container '{}' has no member called '{s}'", .{ child_type, field_name });
                    }
                },
                else => return sema.mod.fail(&block.base, src, "type '{}' does not support field access", .{child_type}),
            }
        },
        else => {},
    }
    return sema.mod.fail(&block.base, src, "type '{}' does not support field access", .{elem_ty});
}

fn elemPtr(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    array_ptr: *Inst,
    elem_index: *Inst,
    elem_index_src: LazySrcLoc,
) InnerError!*Inst {
    const elem_ty = switch (array_ptr.ty.zigTypeTag()) {
        .Pointer => array_ptr.ty.elemType(),
        else => return sema.mod.fail(&block.base, array_ptr.src, "expected pointer, found '{}'", .{array_ptr.ty}),
    };
    if (!elem_ty.isIndexable()) {
        return sema.mod.fail(&block.base, src, "array access of non-array type '{}'", .{elem_ty});
    }

    if (elem_ty.isSinglePointer() and elem_ty.elemType().zigTypeTag() == .Array) {
        // we have to deref the ptr operand to get the actual array pointer
        const array_ptr_deref = try sema.analyzeDeref(block, src, array_ptr, array_ptr.src);
        if (array_ptr_deref.value()) |array_ptr_val| {
            if (elem_index.value()) |index_val| {
                // Both array pointer and index are compile-time known.
                const index_u64 = index_val.toUnsignedInt();
                // @intCast here because it would have been impossible to construct a value that
                // required a larger index.
                const elem_ptr = try array_ptr_val.elemPtr(scope.arena(), @intCast(usize, index_u64));
                const pointee_type = elem_ty.elemType().elemType();

                return mod.constInst(scope, src, .{
                    .ty = try Type.Tag.single_const_pointer.create(scope.arena(), pointee_type),
                    .val = elem_ptr,
                });
            }
        }
    }

    return sema.mod.fail(&block.base, src, "TODO implement more analyze elemptr", .{});
}

fn coerce(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) InnerError!*Inst {
    if (dest_type.tag() == .var_args_param) {
        return sema.coerceVarArgParam(scope, inst);
    }
    // If the types are the same, we can return the operand.
    if (dest_type.eql(inst.ty))
        return inst;

    const in_memory_result = coerceInMemoryAllowed(dest_type, inst.ty);
    if (in_memory_result == .ok) {
        return sema.bitcast(scope, dest_type, inst);
    }

    // undefined to anything
    if (inst.value()) |val| {
        if (val.isUndef() or inst.ty.zigTypeTag() == .Undefined) {
            return mod.constInst(scope.arena(), inst.src, .{ .ty = dest_type, .val = val });
        }
    }
    assert(inst.ty.zigTypeTag() != .Undefined);

    // null to ?T
    if (dest_type.zigTypeTag() == .Optional and inst.ty.zigTypeTag() == .Null) {
        return mod.constInst(scope.arena(), inst.src, .{ .ty = dest_type, .val = Value.initTag(.null_value) });
    }

    // T to ?T
    if (dest_type.zigTypeTag() == .Optional) {
        var buf: Type.Payload.ElemType = undefined;
        const child_type = dest_type.optionalChild(&buf);
        if (child_type.eql(inst.ty)) {
            return mod.wrapOptional(scope, dest_type, inst);
        } else if (try sema.coerceNum(scope, child_type, inst)) |some| {
            return mod.wrapOptional(scope, dest_type, some);
        }
    }

    // T to E!T or E to E!T
    if (dest_type.tag() == .error_union) {
        return try mod.wrapErrorUnion(scope, dest_type, inst);
    }

    // Coercions where the source is a single pointer to an array.
    src_array_ptr: {
        if (!inst.ty.isSinglePointer()) break :src_array_ptr;
        const array_type = inst.ty.elemType();
        if (array_type.zigTypeTag() != .Array) break :src_array_ptr;
        const array_elem_type = array_type.elemType();
        if (inst.ty.isConstPtr() and !dest_type.isConstPtr()) break :src_array_ptr;
        if (inst.ty.isVolatilePtr() and !dest_type.isVolatilePtr()) break :src_array_ptr;

        const dst_elem_type = dest_type.elemType();
        switch (coerceInMemoryAllowed(dst_elem_type, array_elem_type)) {
            .ok => {},
            .no_match => break :src_array_ptr,
        }

        switch (dest_type.ptrSize()) {
            .Slice => {
                // *[N]T to []T
                return sema.coerceArrayPtrToSlice(scope, dest_type, inst);
            },
            .C => {
                // *[N]T to [*c]T
                return sema.coerceArrayPtrToMany(scope, dest_type, inst);
            },
            .Many => {
                // *[N]T to [*]T
                // *[N:s]T to [*:s]T
                const src_sentinel = array_type.sentinel();
                const dst_sentinel = dest_type.sentinel();
                if (src_sentinel == null and dst_sentinel == null)
                    return sema.coerceArrayPtrToMany(scope, dest_type, inst);

                if (src_sentinel) |src_s| {
                    if (dst_sentinel) |dst_s| {
                        if (src_s.eql(dst_s)) {
                            return sema.coerceArrayPtrToMany(scope, dest_type, inst);
                        }
                    }
                }
            },
            .One => {},
        }
    }

    // comptime known number to other number
    if (try sema.coerceNum(scope, dest_type, inst)) |some|
        return some;

    // integer widening
    if (inst.ty.zigTypeTag() == .Int and dest_type.zigTypeTag() == .Int) {
        assert(inst.value() == null); // handled above

        const src_info = inst.ty.intInfo(mod.getTarget());
        const dst_info = dest_type.intInfo(mod.getTarget());
        if ((src_info.signedness == dst_info.signedness and dst_info.bits >= src_info.bits) or
            // small enough unsigned ints can get casted to large enough signed ints
            (src_info.signedness == .signed and dst_info.signedness == .unsigned and dst_info.bits > src_info.bits))
        {
            try sema.requireRuntimeBlock(block, inst.src);
            return mod.addUnOp(b, inst.src, dest_type, .intcast, inst);
        }
    }

    // float widening
    if (inst.ty.zigTypeTag() == .Float and dest_type.zigTypeTag() == .Float) {
        assert(inst.value() == null); // handled above

        const src_bits = inst.ty.floatBits(mod.getTarget());
        const dst_bits = dest_type.floatBits(mod.getTarget());
        if (dst_bits >= src_bits) {
            try sema.requireRuntimeBlock(block, inst.src);
            return mod.addUnOp(b, inst.src, dest_type, .floatcast, inst);
        }
    }

    return sema.mod.fail(&block.base, inst.src, "expected {}, found {}", .{ dest_type, inst.ty });
}

const InMemoryCoercionResult = enum {
    ok,
    no_match,
};

fn coerceInMemoryAllowed(dest_type: Type, src_type: Type) InMemoryCoercionResult {
    if (dest_type.eql(src_type))
        return .ok;

    // TODO: implement more of this function

    return .no_match;
}

fn coerceNum(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) InnerError!?*Inst {
    const val = inst.value() orelse return null;
    const src_zig_tag = inst.ty.zigTypeTag();
    const dst_zig_tag = dest_type.zigTypeTag();

    if (dst_zig_tag == .ComptimeInt or dst_zig_tag == .Int) {
        if (src_zig_tag == .Float or src_zig_tag == .ComptimeFloat) {
            if (val.floatHasFraction()) {
                return sema.mod.fail(&block.base, inst.src, "fractional component prevents float value {} from being casted to type '{}'", .{ val, inst.ty });
            }
            return sema.mod.fail(&block.base, inst.src, "TODO float to int", .{});
        } else if (src_zig_tag == .Int or src_zig_tag == .ComptimeInt) {
            if (!val.intFitsInType(dest_type, mod.getTarget())) {
                return sema.mod.fail(&block.base, inst.src, "type {} cannot represent integer value {}", .{ inst.ty, val });
            }
            return mod.constInst(scope, inst.src, .{ .ty = dest_type, .val = val });
        }
    } else if (dst_zig_tag == .ComptimeFloat or dst_zig_tag == .Float) {
        if (src_zig_tag == .Float or src_zig_tag == .ComptimeFloat) {
            const res = val.floatCast(scope.arena(), dest_type, mod.getTarget()) catch |err| switch (err) {
                error.Overflow => return mod.fail(
                    scope,
                    inst.src,
                    "cast of value {} to type '{}' loses information",
                    .{ val, dest_type },
                ),
                error.OutOfMemory => return error.OutOfMemory,
            };
            return mod.constInst(scope, inst.src, .{ .ty = dest_type, .val = res });
        } else if (src_zig_tag == .Int or src_zig_tag == .ComptimeInt) {
            return sema.mod.fail(&block.base, inst.src, "TODO int to float", .{});
        }
    }
    return null;
}

fn coerceVarArgParam(sema: *Sema, block: *Scope.Block, inst: *Inst) !*Inst {
    switch (inst.ty.zigTypeTag()) {
        .ComptimeInt, .ComptimeFloat => return sema.mod.fail(&block.base, inst.src, "integer and float literals in var args function must be casted", .{}),
        else => {},
    }
    // TODO implement more of this function.
    return inst;
}

fn storePtr(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, ptr: *Inst, uncasted_value: *Inst) !*Inst {
    if (ptr.ty.isConstPtr())
        return sema.mod.fail(&block.base, src, "cannot assign to constant", .{});

    const elem_ty = ptr.ty.elemType();
    const value = try sema.coerce(scope, elem_ty, uncasted_value);
    if (elem_ty.onePossibleValue() != null)
        return sema.mod.constVoid(block.arena, .unneeded);

    // TODO handle comptime pointer writes
    // TODO handle if the element type requires comptime

    try sema.requireRuntimeBlock(block, src);
    return mod.addBinOp(b, src, Type.initTag(.void), .store, ptr, value);
}

fn bitcast(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        // Keep the comptime Value representation; take the new type.
        return mod.constInst(scope, inst.src, .{ .ty = dest_type, .val = val });
    }
    // TODO validate the type size and other compile errors
    try sema.requireRuntimeBlock(block, inst.src);
    return mod.addUnOp(b, inst.src, dest_type, .bitcast, inst);
}

fn coerceArrayPtrToSlice(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        // The comptime Value representation is compatible with both types.
        return mod.constInst(scope, inst.src, .{ .ty = dest_type, .val = val });
    }
    return sema.mod.fail(&block.base, inst.src, "TODO implement coerceArrayPtrToSlice runtime instruction", .{});
}

fn coerceArrayPtrToMany(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        // The comptime Value representation is compatible with both types.
        return mod.constInst(scope, inst.src, .{ .ty = dest_type, .val = val });
    }
    return sema.mod.fail(&block.base, inst.src, "TODO implement coerceArrayPtrToMany runtime instruction", .{});
}

fn analyzeDeclVal(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, decl: *Decl) InnerError!*Inst {
    const decl_ref = try sema.analyzeDeclRef(block, src, decl);
    return sema.analyzeDeref(block, src, decl_ref, src);
}

fn analyzeDeclRef(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, decl: *Decl) InnerError!*Inst {
    const scope_decl = scope.ownerDecl().?;
    try mod.declareDeclDependency(scope_decl, decl);
    mod.ensureDeclAnalyzed(decl) catch |err| {
        if (scope.cast(Scope.Block)) |block| {
            if (block.func) |func| {
                func.state = .dependency_failure;
            } else {
                block.owner_decl.analysis = .dependency_failure;
            }
        } else {
            scope_decl.analysis = .dependency_failure;
        }
        return err;
    };

    const decl_tv = try decl.typedValue();
    if (decl_tv.val.tag() == .variable) {
        return mod.analyzeVarRef(scope, src, decl_tv);
    }
    return mod.constInst(scope.arena(), src, .{
        .ty = try mod.simplePtrType(scope.arena(), decl_tv.ty, false, .One),
        .val = try Value.Tag.decl_ref.create(scope.arena(), decl),
    });
}

fn analyzeVarRef(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, tv: TypedValue) InnerError!*Inst {
    const variable = tv.val.castTag(.variable).?.data;

    const ty = try mod.simplePtrType(scope.arena(), tv.ty, variable.is_mutable, .One);
    if (!variable.is_mutable and !variable.is_extern) {
        return mod.constInst(scope.arena(), src, .{
            .ty = ty,
            .val = try Value.Tag.ref_val.create(scope.arena(), variable.init),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    const inst = try b.arena.create(Inst.VarPtr);
    inst.* = .{
        .base = .{
            .tag = .varptr,
            .ty = ty,
            .src = src,
        },
        .variable = variable,
    };
    try b.instructions.append(mod.gpa, &inst.base);
    return &inst.base;
}

fn analyzeRef(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    operand: *Inst,
) InnerError!*Inst {
    const ptr_type = try mod.simplePtrType(scope.arena(), operand.ty, false, .One);

    if (operand.value()) |val| {
        return mod.constInst(scope.arena(), src, .{
            .ty = ptr_type,
            .val = try Value.Tag.ref_val.create(scope.arena(), val),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, ptr_type, .ref, operand);
}

fn analyzeDeref(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    ptr: *Inst,
    ptr_src: LazySrcLoc,
) InnerError!*Inst {
    const elem_ty = switch (ptr.ty.zigTypeTag()) {
        .Pointer => ptr.ty.elemType(),
        else => return sema.mod.fail(&block.base, ptr_src, "expected pointer, found '{}'", .{ptr.ty}),
    };
    if (ptr.value()) |val| {
        return mod.constInst(scope.arena(), src, .{
            .ty = elem_ty,
            .val = try val.pointerDeref(scope.arena()),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return mod.addUnOp(b, src, elem_ty, .load, ptr);
}

fn analyzeIsNull(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    operand: *Inst,
    invert_logic: bool,
) InnerError!*Inst {
    if (operand.value()) |opt_val| {
        const is_null = opt_val.isNull();
        const bool_value = if (invert_logic) !is_null else is_null;
        return mod.constBool(block.arena, src, bool_value);
    }
    try sema.requireRuntimeBlock(block, src);
    const inst_tag: Inst.Tag = if (invert_logic) .is_non_null else .is_null;
    return mod.addUnOp(b, src, Type.initTag(.bool), inst_tag, operand);
}

fn analyzeIsErr(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, operand: *Inst) InnerError!*Inst {
    const ot = operand.ty.zigTypeTag();
    if (ot != .ErrorSet and ot != .ErrorUnion) return mod.constBool(block.arena, src, false);
    if (ot == .ErrorSet) return mod.constBool(block.arena, src, true);
    assert(ot == .ErrorUnion);
    if (operand.value()) |err_union| {
        return mod.constBool(block.arena, src, err_union.getError() != null);
    }
    try sema.requireRuntimeBlock(block, src);
    return mod.addUnOp(b, src, Type.initTag(.bool), .is_err, operand);
}

fn analyzeSlice(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    array_ptr: *Inst,
    start: *Inst,
    end_opt: ?*Inst,
    sentinel_opt: ?*Inst,
    sentinel_src: LazySrcLoc,
) InnerError!*Inst {
    const ptr_child = switch (array_ptr.ty.zigTypeTag()) {
        .Pointer => array_ptr.ty.elemType(),
        else => return sema.mod.fail(&block.base, src, "expected pointer, found '{}'", .{array_ptr.ty}),
    };

    var array_type = ptr_child;
    const elem_type = switch (ptr_child.zigTypeTag()) {
        .Array => ptr_child.elemType(),
        .Pointer => blk: {
            if (ptr_child.isSinglePointer()) {
                if (ptr_child.elemType().zigTypeTag() == .Array) {
                    array_type = ptr_child.elemType();
                    break :blk ptr_child.elemType().elemType();
                }

                return sema.mod.fail(&block.base, src, "slice of single-item pointer", .{});
            }
            break :blk ptr_child.elemType();
        },
        else => return sema.mod.fail(&block.base, src, "slice of non-array type '{}'", .{ptr_child}),
    };

    const slice_sentinel = if (sentinel_opt) |sentinel| blk: {
        const casted = try sema.coerce(scope, elem_type, sentinel);
        break :blk try sema.resolveConstValue(block, sentinel_src, casted);
    } else null;

    var return_ptr_size: std.builtin.TypeInfo.Pointer.Size = .Slice;
    var return_elem_type = elem_type;
    if (end_opt) |end| {
        if (end.value()) |end_val| {
            if (start.value()) |start_val| {
                const start_u64 = start_val.toUnsignedInt();
                const end_u64 = end_val.toUnsignedInt();
                if (start_u64 > end_u64) {
                    return sema.mod.fail(&block.base, src, "out of bounds slice", .{});
                }

                const len = end_u64 - start_u64;
                const array_sentinel = if (array_type.zigTypeTag() == .Array and end_u64 == array_type.arrayLen())
                    array_type.sentinel()
                else
                    slice_sentinel;
                return_elem_type = try mod.arrayType(scope, len, array_sentinel, elem_type);
                return_ptr_size = .One;
            }
        }
    }
    const return_type = try mod.ptrType(
        scope,
        return_elem_type,
        if (end_opt == null) slice_sentinel else null,
        0, // TODO alignment
        0,
        0,
        !ptr_child.isConstPtr(),
        ptr_child.isAllowzeroPtr(),
        ptr_child.isVolatilePtr(),
        return_ptr_size,
    );

    return sema.mod.fail(&block.base, src, "TODO implement analysis of slice", .{});
}

fn analyzeImport(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, target_string: []const u8) !*Scope.File {
    const cur_pkg = scope.getFileScope().pkg;
    const cur_pkg_dir_path = cur_pkg.root_src_directory.path orelse ".";
    const found_pkg = cur_pkg.table.get(target_string);

    const resolved_path = if (found_pkg) |pkg|
        try std.fs.path.resolve(mod.gpa, &[_][]const u8{ pkg.root_src_directory.path orelse ".", pkg.root_src_path })
    else
        try std.fs.path.resolve(mod.gpa, &[_][]const u8{ cur_pkg_dir_path, target_string });
    errdefer mod.gpa.free(resolved_path);

    if (mod.import_table.get(resolved_path)) |some| {
        mod.gpa.free(resolved_path);
        return some;
    }

    if (found_pkg == null) {
        const resolved_root_path = try std.fs.path.resolve(mod.gpa, &[_][]const u8{cur_pkg_dir_path});
        defer mod.gpa.free(resolved_root_path);

        if (!mem.startsWith(u8, resolved_path, resolved_root_path)) {
            return error.ImportOutsidePkgPath;
        }
    }

    // TODO Scope.Container arena for ty and sub_file_path
    const file_scope = try mod.gpa.create(Scope.File);
    errdefer mod.gpa.destroy(file_scope);
    const struct_ty = try Type.Tag.empty_struct.create(mod.gpa, &file_scope.root_container);
    errdefer mod.gpa.destroy(struct_ty.castTag(.empty_struct).?);

    file_scope.* = .{
        .sub_file_path = resolved_path,
        .source = .{ .unloaded = {} },
        .tree = undefined,
        .status = .never_loaded,
        .pkg = found_pkg orelse cur_pkg,
        .root_container = .{
            .file_scope = file_scope,
            .decls = .{},
            .ty = struct_ty,
        },
    };
    mod.analyzeContainer(&file_scope.root_container) catch |err| switch (err) {
        error.AnalysisFail => {
            assert(mod.comp.totalErrorCount() != 0);
        },
        else => |e| return e,
    };
    try mod.import_table.put(mod.gpa, file_scope.sub_file_path, file_scope);
    return file_scope;
}

/// Asserts that lhs and rhs types are both numeric.
fn cmpNumeric(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    lhs: *Inst,
    rhs: *Inst,
    op: std.math.CompareOperator,
) InnerError!*Inst {
    assert(lhs.ty.isNumeric());
    assert(rhs.ty.isNumeric());

    const lhs_ty_tag = lhs.ty.zigTypeTag();
    const rhs_ty_tag = rhs.ty.zigTypeTag();

    if (lhs_ty_tag == .Vector and rhs_ty_tag == .Vector) {
        if (lhs.ty.arrayLen() != rhs.ty.arrayLen()) {
            return sema.mod.fail(&block.base, src, "vector length mismatch: {d} and {d}", .{
                lhs.ty.arrayLen(),
                rhs.ty.arrayLen(),
            });
        }
        return sema.mod.fail(&block.base, src, "TODO implement support for vectors in cmpNumeric", .{});
    } else if (lhs_ty_tag == .Vector or rhs_ty_tag == .Vector) {
        return sema.mod.fail(&block.base, src, "mixed scalar and vector operands to comparison operator: '{}' and '{}'", .{
            lhs.ty,
            rhs.ty,
        });
    }

    if (lhs.value()) |lhs_val| {
        if (rhs.value()) |rhs_val| {
            return mod.constBool(block.arena, src, Value.compare(lhs_val, op, rhs_val));
        }
    }

    // TODO handle comparisons against lazy zero values
    // Some values can be compared against zero without being runtime known or without forcing
    // a full resolution of their value, for example `@sizeOf(@Frame(function))` is known to
    // always be nonzero, and we benefit from not forcing the full evaluation and stack frame layout
    // of this function if we don't need to.

    // It must be a runtime comparison.
    try sema.requireRuntimeBlock(block, src);
    // For floats, emit a float comparison instruction.
    const lhs_is_float = switch (lhs_ty_tag) {
        .Float, .ComptimeFloat => true,
        else => false,
    };
    const rhs_is_float = switch (rhs_ty_tag) {
        .Float, .ComptimeFloat => true,
        else => false,
    };
    if (lhs_is_float and rhs_is_float) {
        // Implicit cast the smaller one to the larger one.
        const dest_type = x: {
            if (lhs_ty_tag == .ComptimeFloat) {
                break :x rhs.ty;
            } else if (rhs_ty_tag == .ComptimeFloat) {
                break :x lhs.ty;
            }
            if (lhs.ty.floatBits(mod.getTarget()) >= rhs.ty.floatBits(mod.getTarget())) {
                break :x lhs.ty;
            } else {
                break :x rhs.ty;
            }
        };
        const casted_lhs = try sema.coerce(scope, dest_type, lhs);
        const casted_rhs = try sema.coerce(scope, dest_type, rhs);
        return mod.addBinOp(b, src, dest_type, Inst.Tag.fromCmpOp(op), casted_lhs, casted_rhs);
    }
    // For mixed unsigned integer sizes, implicit cast both operands to the larger integer.
    // For mixed signed and unsigned integers, implicit cast both operands to a signed
    // integer with + 1 bit.
    // For mixed floats and integers, extract the integer part from the float, cast that to
    // a signed integer with mantissa bits + 1, and if there was any non-integral part of the float,
    // add/subtract 1.
    const lhs_is_signed = if (lhs.value()) |lhs_val|
        lhs_val.compareWithZero(.lt)
    else
        (lhs.ty.isFloat() or lhs.ty.isSignedInt());
    const rhs_is_signed = if (rhs.value()) |rhs_val|
        rhs_val.compareWithZero(.lt)
    else
        (rhs.ty.isFloat() or rhs.ty.isSignedInt());
    const dest_int_is_signed = lhs_is_signed or rhs_is_signed;

    var dest_float_type: ?Type = null;

    var lhs_bits: usize = undefined;
    if (lhs.value()) |lhs_val| {
        if (lhs_val.isUndef())
            return mod.constUndef(scope, src, Type.initTag(.bool));
        const is_unsigned = if (lhs_is_float) x: {
            var bigint_space: Value.BigIntSpace = undefined;
            var bigint = try lhs_val.toBigInt(&bigint_space).toManaged(mod.gpa);
            defer bigint.deinit();
            const zcmp = lhs_val.orderAgainstZero();
            if (lhs_val.floatHasFraction()) {
                switch (op) {
                    .eq => return mod.constBool(block.arena, src, false),
                    .neq => return mod.constBool(block.arena, src, true),
                    else => {},
                }
                if (zcmp == .lt) {
                    try bigint.addScalar(bigint.toConst(), -1);
                } else {
                    try bigint.addScalar(bigint.toConst(), 1);
                }
            }
            lhs_bits = bigint.toConst().bitCountTwosComp();
            break :x (zcmp != .lt);
        } else x: {
            lhs_bits = lhs_val.intBitCountTwosComp();
            break :x (lhs_val.orderAgainstZero() != .lt);
        };
        lhs_bits += @boolToInt(is_unsigned and dest_int_is_signed);
    } else if (lhs_is_float) {
        dest_float_type = lhs.ty;
    } else {
        const int_info = lhs.ty.intInfo(mod.getTarget());
        lhs_bits = int_info.bits + @boolToInt(int_info.signedness == .unsigned and dest_int_is_signed);
    }

    var rhs_bits: usize = undefined;
    if (rhs.value()) |rhs_val| {
        if (rhs_val.isUndef())
            return mod.constUndef(scope, src, Type.initTag(.bool));
        const is_unsigned = if (rhs_is_float) x: {
            var bigint_space: Value.BigIntSpace = undefined;
            var bigint = try rhs_val.toBigInt(&bigint_space).toManaged(mod.gpa);
            defer bigint.deinit();
            const zcmp = rhs_val.orderAgainstZero();
            if (rhs_val.floatHasFraction()) {
                switch (op) {
                    .eq => return mod.constBool(block.arena, src, false),
                    .neq => return mod.constBool(block.arena, src, true),
                    else => {},
                }
                if (zcmp == .lt) {
                    try bigint.addScalar(bigint.toConst(), -1);
                } else {
                    try bigint.addScalar(bigint.toConst(), 1);
                }
            }
            rhs_bits = bigint.toConst().bitCountTwosComp();
            break :x (zcmp != .lt);
        } else x: {
            rhs_bits = rhs_val.intBitCountTwosComp();
            break :x (rhs_val.orderAgainstZero() != .lt);
        };
        rhs_bits += @boolToInt(is_unsigned and dest_int_is_signed);
    } else if (rhs_is_float) {
        dest_float_type = rhs.ty;
    } else {
        const int_info = rhs.ty.intInfo(mod.getTarget());
        rhs_bits = int_info.bits + @boolToInt(int_info.signedness == .unsigned and dest_int_is_signed);
    }

    const dest_type = if (dest_float_type) |ft| ft else blk: {
        const max_bits = std.math.max(lhs_bits, rhs_bits);
        const casted_bits = std.math.cast(u16, max_bits) catch |err| switch (err) {
            error.Overflow => return sema.mod.fail(&block.base, src, "{d} exceeds maximum integer bit count", .{max_bits}),
        };
        break :blk try mod.makeIntType(scope, dest_int_is_signed, casted_bits);
    };
    const casted_lhs = try sema.coerce(scope, dest_type, lhs);
    const casted_rhs = try sema.coerce(scope, dest_type, rhs);

    return mod.addBinOp(b, src, Type.initTag(.bool), Inst.Tag.fromCmpOp(op), casted_lhs, casted_rhs);
}

fn wrapOptional(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        return mod.constInst(scope.arena(), inst.src, .{ .ty = dest_type, .val = val });
    }

    try sema.requireRuntimeBlock(block, inst.src);
    return mod.addUnOp(b, inst.src, dest_type, .wrap_optional, inst);
}

fn wrapErrorUnion(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) !*Inst {
    // TODO deal with inferred error sets
    const err_union = dest_type.castTag(.error_union).?;
    if (inst.value()) |val| {
        const to_wrap = if (inst.ty.zigTypeTag() != .ErrorSet) blk: {
            _ = try sema.coerce(scope, err_union.data.payload, inst);
            break :blk val;
        } else switch (err_union.data.error_set.tag()) {
            .anyerror => val,
            .error_set_single => blk: {
                const n = err_union.data.error_set.castTag(.error_set_single).?.data;
                if (!mem.eql(u8, val.castTag(.@"error").?.data.name, n))
                    return sema.mod.fail(&block.base, inst.src, "expected type '{}', found type '{}'", .{ err_union.data.error_set, inst.ty });
                break :blk val;
            },
            .error_set => blk: {
                const f = err_union.data.error_set.castTag(.error_set).?.data.typed_value.most_recent.typed_value.val.castTag(.error_set).?.data.fields;
                if (f.get(val.castTag(.@"error").?.data.name) == null)
                    return sema.mod.fail(&block.base, inst.src, "expected type '{}', found type '{}'", .{ err_union.data.error_set, inst.ty });
                break :blk val;
            },
            else => unreachable,
        };

        return mod.constInst(scope.arena(), inst.src, .{
            .ty = dest_type,
            // creating a SubValue for the error_union payload
            .val = try Value.Tag.error_union.create(
                scope.arena(),
                to_wrap,
            ),
        });
    }

    try sema.requireRuntimeBlock(block, inst.src);

    // we are coercing from E to E!T
    if (inst.ty.zigTypeTag() == .ErrorSet) {
        var coerced = try sema.coerce(scope, err_union.data.error_set, inst);
        return mod.addUnOp(b, inst.src, dest_type, .wrap_errunion_err, coerced);
    } else {
        var coerced = try sema.coerce(scope, err_union.data.payload, inst);
        return mod.addUnOp(b, inst.src, dest_type, .wrap_errunion_payload, coerced);
    }
}

fn resolvePeerTypes(sema: *Sema, block: *Scope.Block, instructions: []*Inst) !Type {
    if (instructions.len == 0)
        return Type.initTag(.noreturn);

    if (instructions.len == 1)
        return instructions[0].ty;

    var chosen = instructions[0];
    for (instructions[1..]) |candidate| {
        if (candidate.ty.eql(chosen.ty))
            continue;
        if (candidate.ty.zigTypeTag() == .NoReturn)
            continue;
        if (chosen.ty.zigTypeTag() == .NoReturn) {
            chosen = candidate;
            continue;
        }
        if (candidate.ty.zigTypeTag() == .Undefined)
            continue;
        if (chosen.ty.zigTypeTag() == .Undefined) {
            chosen = candidate;
            continue;
        }
        if (chosen.ty.isInt() and
            candidate.ty.isInt() and
            chosen.ty.isSignedInt() == candidate.ty.isSignedInt())
        {
            if (chosen.ty.intInfo(mod.getTarget()).bits < candidate.ty.intInfo(mod.getTarget()).bits) {
                chosen = candidate;
            }
            continue;
        }
        if (chosen.ty.isFloat() and candidate.ty.isFloat()) {
            if (chosen.ty.floatBits(mod.getTarget()) < candidate.ty.floatBits(mod.getTarget())) {
                chosen = candidate;
            }
            continue;
        }

        if (chosen.ty.zigTypeTag() == .ComptimeInt and candidate.ty.isInt()) {
            chosen = candidate;
            continue;
        }

        if (chosen.ty.isInt() and candidate.ty.zigTypeTag() == .ComptimeInt) {
            continue;
        }

        // TODO error notes pointing out each type
        return sema.mod.fail(&block.base, candidate.src, "incompatible types: '{}' and '{}'", .{ chosen.ty, candidate.ty });
    }

    return chosen.ty;
}
