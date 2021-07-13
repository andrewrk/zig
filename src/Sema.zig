//! Semantic analysis of ZIR instructions.
//! Shared to every Block. Stored on the stack.
//! State used for compiling a `Zir` into AIR.
//! Transforms untyped ZIR instructions into semantically-analyzed AIR instructions.
//! Does type checking, comptime control flow, and safety-check generation.
//! This is the the heart of the Zig compiler.

mod: *Module,
/// Alias to `mod.gpa`.
gpa: *Allocator,
/// Points to the arena allocator of the Decl.
arena: *Allocator,
code: Zir,
/// Maps ZIR to AIR.
inst_map: InstMap = .{},
/// When analyzing an inline function call, owner_decl is the Decl of the caller
/// and `src_decl` of `Scope.Block` is the `Decl` of the callee.
/// This `Decl` owns the arena memory of this `Sema`.
owner_decl: *Decl,
/// How to look up decl names.
namespace: *Scope.Namespace,
/// For an inline or comptime function call, this will be the root parent function
/// which contains the callsite. Corresponds to `owner_decl`.
owner_func: ?*Module.Fn,
/// The function this ZIR code is the body of, according to the source code.
/// This starts out the same as `owner_func` and then diverges in the case of
/// an inline or comptime function call.
func: ?*Module.Fn,
/// For now, AIR requires arg instructions to be the first N instructions in the
/// AIR code. We store references here for the purpose of `resolveInst`.
/// This can get reworked with AIR memory layout changes, into simply:
/// > Denormalized data to make `resolveInst` faster. This is 0 if not inside a function,
/// > otherwise it is the number of parameters of the function.
/// > param_count: u32
param_inst_list: []const *ir.Inst,
branch_quota: u32 = 1000,
branch_count: u32 = 0,
/// This field is updated when a new source location becomes active, so that
/// instructions which do not have explicitly mapped source locations still have
/// access to the source location set by the previous instruction which did
/// contain a mapped source location.
src: LazySrcLoc = .{ .token_offset = 0 },
next_arg_index: usize = 0,

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.sema);

const Sema = @This();
const Value = @import("value.zig").Value;
const Type = @import("type.zig").Type;
const TypedValue = @import("TypedValue.zig");
const ir = @import("air.zig");
const Zir = @import("Zir.zig");
const Module = @import("Module.zig");
const Inst = ir.Inst;
const Body = ir.Body;
const trace = @import("tracy.zig").trace;
const Scope = Module.Scope;
const InnerError = Module.InnerError;
const Decl = Module.Decl;
const LazySrcLoc = Module.LazySrcLoc;
const RangeSet = @import("RangeSet.zig");
const target_util = @import("target.zig");

pub const InstMap = std.AutoHashMapUnmanaged(Zir.Inst.Index, *ir.Inst);

pub fn deinit(sema: *Sema) void {
    sema.inst_map.deinit(sema.gpa);
    sema.* = undefined;
}

pub fn analyzeFnBody(
    sema: *Sema,
    block: *Scope.Block,
    fn_body_inst: Zir.Inst.Index,
) InnerError!void {
    const tags = sema.code.instructions.items(.tag);
    const datas = sema.code.instructions.items(.data);
    const body: []const Zir.Inst.Index = switch (tags[fn_body_inst]) {
        .func, .func_inferred => blk: {
            const inst_data = datas[fn_body_inst].pl_node;
            const extra = sema.code.extraData(Zir.Inst.Func, inst_data.payload_index);
            const param_types_len = extra.data.param_types_len;
            const body = sema.code.extra[extra.end + param_types_len ..][0..extra.data.body_len];
            break :blk body;
        },
        .extended => blk: {
            const extended = datas[fn_body_inst].extended;
            assert(extended.opcode == .func);
            const extra = sema.code.extraData(Zir.Inst.ExtendedFunc, extended.operand);
            const small = @bitCast(Zir.Inst.ExtendedFunc.Small, extended.small);
            var extra_index: usize = extra.end;
            extra_index += @boolToInt(small.has_lib_name);
            extra_index += @boolToInt(small.has_cc);
            extra_index += @boolToInt(small.has_align);
            extra_index += extra.data.param_types_len;
            const body = sema.code.extra[extra_index..][0..extra.data.body_len];
            break :blk body;
        },
        else => unreachable,
    };
    _ = try sema.analyzeBody(block, body);
}

/// Returns only the result from the body that is specified.
/// Only appropriate to call when it is determined at comptime that this body
/// has no peers.
fn resolveBody(sema: *Sema, block: *Scope.Block, body: []const Zir.Inst.Index) InnerError!*Inst {
    const break_inst = try sema.analyzeBody(block, body);
    const operand_ref = sema.code.instructions.items(.data)[break_inst].@"break".operand;
    return sema.resolveInst(operand_ref);
}

/// ZIR instructions which are always `noreturn` return this. This matches the
/// return type of `analyzeBody` so that we can tail call them.
/// Only appropriate to return when the instruction is known to be NoReturn
/// solely based on the ZIR tag.
const always_noreturn: InnerError!Zir.Inst.Index = @as(Zir.Inst.Index, undefined);

/// This function is the main loop of `Sema` and it can be used in two different ways:
/// * The traditional way where there are N breaks out of the block and peer type
///   resolution is done on the break operands. In this case, the `Zir.Inst.Index`
///   part of the return value will be `undefined`, and callsites should ignore it,
///   finding the block result value via the block scope.
/// * The "flat" way. There is only 1 break out of the block, and it is with a `break_inline`
///   instruction. In this case, the `Zir.Inst.Index` part of the return value will be
///   the break instruction. This communicates both which block the break applies to, as
///   well as the operand. No block scope needs to be created for this strategy.
pub fn analyzeBody(
    sema: *Sema,
    block: *Scope.Block,
    body: []const Zir.Inst.Index,
) InnerError!Zir.Inst.Index {
    // No tracy calls here, to avoid interfering with the tail call mechanism.

    const map = &block.sema.inst_map;
    const tags = block.sema.code.instructions.items(.tag);
    const datas = block.sema.code.instructions.items(.data);

    // We use a while(true) loop here to avoid a redundant way of breaking out of
    // the loop. The only way to break out of the loop is with a `noreturn`
    // instruction.
    // TODO: As an optimization, make sure the codegen for these switch prongs
    // directly jump to the next one, rather than detouring through the loop
    // continue expression. Related: https://github.com/ziglang/zig/issues/8220
    var i: usize = 0;
    while (true) {
        const inst = body[i];
        const air_inst = switch (tags[inst]) {
            // zig fmt: off
            .arg                          => try sema.zirArg(block, inst),
            .alloc                        => try sema.zirAlloc(block, inst),
            .alloc_inferred               => try sema.zirAllocInferred(block, inst, Type.initTag(.inferred_alloc_const)),
            .alloc_inferred_mut           => try sema.zirAllocInferred(block, inst, Type.initTag(.inferred_alloc_mut)),
            .alloc_inferred_comptime      => try sema.zirAllocInferredComptime(block, inst),
            .alloc_mut                    => try sema.zirAllocMut(block, inst),
            .alloc_comptime               => try sema.zirAllocComptime(block, inst),
            .anyframe_type                => try sema.zirAnyframeType(block, inst),
            .array_cat                    => try sema.zirArrayCat(block, inst),
            .array_mul                    => try sema.zirArrayMul(block, inst),
            .array_type                   => try sema.zirArrayType(block, inst),
            .array_type_sentinel          => try sema.zirArrayTypeSentinel(block, inst),
            .vector_type                  => try sema.zirVectorType(block, inst),
            .as                           => try sema.zirAs(block, inst),
            .as_node                      => try sema.zirAsNode(block, inst),
            .bit_and                      => try sema.zirBitwise(block, inst, .bit_and),
            .bit_not                      => try sema.zirBitNot(block, inst),
            .bit_or                       => try sema.zirBitwise(block, inst, .bit_or),
            .bitcast                      => try sema.zirBitcast(block, inst),
            .bitcast_result_ptr           => try sema.zirBitcastResultPtr(block, inst),
            .block                        => try sema.zirBlock(block, inst),
            .suspend_block                => try sema.zirSuspendBlock(block, inst),
            .bool_not                     => try sema.zirBoolNot(block, inst),
            .bool_and                     => try sema.zirBoolOp(block, inst, false),
            .bool_or                      => try sema.zirBoolOp(block, inst, true),
            .bool_br_and                  => try sema.zirBoolBr(block, inst, false),
            .bool_br_or                   => try sema.zirBoolBr(block, inst, true),
            .c_import                     => try sema.zirCImport(block, inst),
            .call                         => try sema.zirCall(block, inst, .auto, false),
            .call_chkused                 => try sema.zirCall(block, inst, .auto, true),
            .call_compile_time            => try sema.zirCall(block, inst, .compile_time, false),
            .call_nosuspend               => try sema.zirCall(block, inst, .no_async, false),
            .call_async                   => try sema.zirCall(block, inst, .async_kw, false),
            .cmp_eq                       => try sema.zirCmp(block, inst, .eq),
            .cmp_gt                       => try sema.zirCmp(block, inst, .gt),
            .cmp_gte                      => try sema.zirCmp(block, inst, .gte),
            .cmp_lt                       => try sema.zirCmp(block, inst, .lt),
            .cmp_lte                      => try sema.zirCmp(block, inst, .lte),
            .cmp_neq                      => try sema.zirCmp(block, inst, .neq),
            .coerce_result_ptr            => try sema.zirCoerceResultPtr(block, inst),
            .decl_ref                     => try sema.zirDeclRef(block, inst),
            .decl_val                     => try sema.zirDeclVal(block, inst),
            .load                         => try sema.zirLoad(block, inst),
            .elem_ptr                     => try sema.zirElemPtr(block, inst),
            .elem_ptr_node                => try sema.zirElemPtrNode(block, inst),
            .elem_val                     => try sema.zirElemVal(block, inst),
            .elem_val_node                => try sema.zirElemValNode(block, inst),
            .elem_type                    => try sema.zirElemType(block, inst),
            .enum_literal                 => try sema.zirEnumLiteral(block, inst),
            .enum_to_int                  => try sema.zirEnumToInt(block, inst),
            .int_to_enum                  => try sema.zirIntToEnum(block, inst),
            .err_union_code               => try sema.zirErrUnionCode(block, inst),
            .err_union_code_ptr           => try sema.zirErrUnionCodePtr(block, inst),
            .err_union_payload_safe       => try sema.zirErrUnionPayload(block, inst, true),
            .err_union_payload_safe_ptr   => try sema.zirErrUnionPayloadPtr(block, inst, true),
            .err_union_payload_unsafe     => try sema.zirErrUnionPayload(block, inst, false),
            .err_union_payload_unsafe_ptr => try sema.zirErrUnionPayloadPtr(block, inst, false),
            .error_union_type             => try sema.zirErrorUnionType(block, inst),
            .error_value                  => try sema.zirErrorValue(block, inst),
            .error_to_int                 => try sema.zirErrorToInt(block, inst),
            .int_to_error                 => try sema.zirIntToError(block, inst),
            .field_ptr                    => try sema.zirFieldPtr(block, inst),
            .field_ptr_named              => try sema.zirFieldPtrNamed(block, inst),
            .field_val                    => try sema.zirFieldVal(block, inst),
            .field_val_named              => try sema.zirFieldValNamed(block, inst),
            .func                         => try sema.zirFunc(block, inst, false),
            .func_inferred                => try sema.zirFunc(block, inst, true),
            .import                       => try sema.zirImport(block, inst),
            .indexable_ptr_len            => try sema.zirIndexablePtrLen(block, inst),
            .int                          => try sema.zirInt(block, inst),
            .int_big                      => try sema.zirIntBig(block, inst),
            .float                        => try sema.zirFloat(block, inst),
            .float128                     => try sema.zirFloat128(block, inst),
            .int_type                     => try sema.zirIntType(block, inst),
            .is_non_err                   => try sema.zirIsNonErr(block, inst),
            .is_non_err_ptr               => try sema.zirIsNonErrPtr(block, inst),
            .is_non_null                  => try sema.zirIsNonNull(block, inst),
            .is_non_null_ptr              => try sema.zirIsNonNullPtr(block, inst),
            .loop                         => try sema.zirLoop(block, inst),
            .merge_error_sets             => try sema.zirMergeErrorSets(block, inst),
            .negate                       => try sema.zirNegate(block, inst, .sub),
            .negate_wrap                  => try sema.zirNegate(block, inst, .subwrap),
            .optional_payload_safe        => try sema.zirOptionalPayload(block, inst, true),
            .optional_payload_safe_ptr    => try sema.zirOptionalPayloadPtr(block, inst, true),
            .optional_payload_unsafe      => try sema.zirOptionalPayload(block, inst, false),
            .optional_payload_unsafe_ptr  => try sema.zirOptionalPayloadPtr(block, inst, false),
            .optional_type                => try sema.zirOptionalType(block, inst),
            .param_type                   => try sema.zirParamType(block, inst),
            .ptr_type                     => try sema.zirPtrType(block, inst),
            .ptr_type_simple              => try sema.zirPtrTypeSimple(block, inst),
            .ref                          => try sema.zirRef(block, inst),
            .ret_err_value_code           => try sema.zirRetErrValueCode(block, inst),
            .shl                          => try sema.zirShl(block, inst),
            .shr                          => try sema.zirShr(block, inst),
            .slice_end                    => try sema.zirSliceEnd(block, inst),
            .slice_sentinel               => try sema.zirSliceSentinel(block, inst),
            .slice_start                  => try sema.zirSliceStart(block, inst),
            .str                          => try sema.zirStr(block, inst),
            .switch_block                 => try sema.zirSwitchBlock(block, inst, false, .none),
            .switch_block_multi           => try sema.zirSwitchBlockMulti(block, inst, false, .none),
            .switch_block_else            => try sema.zirSwitchBlock(block, inst, false, .@"else"),
            .switch_block_else_multi      => try sema.zirSwitchBlockMulti(block, inst, false, .@"else"),
            .switch_block_under           => try sema.zirSwitchBlock(block, inst, false, .under),
            .switch_block_under_multi     => try sema.zirSwitchBlockMulti(block, inst, false, .under),
            .switch_block_ref             => try sema.zirSwitchBlock(block, inst, true, .none),
            .switch_block_ref_multi       => try sema.zirSwitchBlockMulti(block, inst, true, .none),
            .switch_block_ref_else        => try sema.zirSwitchBlock(block, inst, true, .@"else"),
            .switch_block_ref_else_multi  => try sema.zirSwitchBlockMulti(block, inst, true, .@"else"),
            .switch_block_ref_under       => try sema.zirSwitchBlock(block, inst, true, .under),
            .switch_block_ref_under_multi => try sema.zirSwitchBlockMulti(block, inst, true, .under),
            .switch_capture               => try sema.zirSwitchCapture(block, inst, false, false),
            .switch_capture_ref           => try sema.zirSwitchCapture(block, inst, false, true),
            .switch_capture_multi         => try sema.zirSwitchCapture(block, inst, true, false),
            .switch_capture_multi_ref     => try sema.zirSwitchCapture(block, inst, true, true),
            .switch_capture_else          => try sema.zirSwitchCaptureElse(block, inst, false),
            .switch_capture_else_ref      => try sema.zirSwitchCaptureElse(block, inst, true),
            .type_info                    => try sema.zirTypeInfo(block, inst),
            .size_of                      => try sema.zirSizeOf(block, inst),
            .bit_size_of                  => try sema.zirBitSizeOf(block, inst),
            .typeof                       => try sema.zirTypeof(block, inst),
            .typeof_elem                  => try sema.zirTypeofElem(block, inst),
            .log2_int_type                => try sema.zirLog2IntType(block, inst),
            .typeof_log2_int_type         => try sema.zirTypeofLog2IntType(block, inst),
            .xor                          => try sema.zirBitwise(block, inst, .xor),
            .struct_init_empty            => try sema.zirStructInitEmpty(block, inst),
            .struct_init                  => try sema.zirStructInit(block, inst, false),
            .struct_init_ref              => try sema.zirStructInit(block, inst, true),
            .struct_init_anon             => try sema.zirStructInitAnon(block, inst, false),
            .struct_init_anon_ref         => try sema.zirStructInitAnon(block, inst, true),
            .array_init                   => try sema.zirArrayInit(block, inst, false),
            .array_init_ref               => try sema.zirArrayInit(block, inst, true),
            .array_init_anon              => try sema.zirArrayInitAnon(block, inst, false),
            .array_init_anon_ref          => try sema.zirArrayInitAnon(block, inst, true),
            .union_init_ptr               => try sema.zirUnionInitPtr(block, inst),
            .field_type                   => try sema.zirFieldType(block, inst),
            .field_type_ref               => try sema.zirFieldTypeRef(block, inst),
            .ptr_to_int                   => try sema.zirPtrToInt(block, inst),
            .align_of                     => try sema.zirAlignOf(block, inst),
            .bool_to_int                  => try sema.zirBoolToInt(block, inst),
            .embed_file                   => try sema.zirEmbedFile(block, inst),
            .error_name                   => try sema.zirErrorName(block, inst),
            .tag_name                     => try sema.zirTagName(block, inst),
            .reify                        => try sema.zirReify(block, inst),
            .type_name                    => try sema.zirTypeName(block, inst),
            .frame_type                   => try sema.zirFrameType(block, inst),
            .frame_size                   => try sema.zirFrameSize(block, inst),
            .float_to_int                 => try sema.zirFloatToInt(block, inst),
            .int_to_float                 => try sema.zirIntToFloat(block, inst),
            .int_to_ptr                   => try sema.zirIntToPtr(block, inst),
            .float_cast                   => try sema.zirFloatCast(block, inst),
            .int_cast                     => try sema.zirIntCast(block, inst),
            .err_set_cast                 => try sema.zirErrSetCast(block, inst),
            .ptr_cast                     => try sema.zirPtrCast(block, inst),
            .truncate                     => try sema.zirTruncate(block, inst),
            .align_cast                   => try sema.zirAlignCast(block, inst),
            .has_decl                     => try sema.zirHasDecl(block, inst),
            .has_field                    => try sema.zirHasField(block, inst),
            .clz                          => try sema.zirClz(block, inst),
            .ctz                          => try sema.zirCtz(block, inst),
            .pop_count                    => try sema.zirPopCount(block, inst),
            .byte_swap                    => try sema.zirByteSwap(block, inst),
            .bit_reverse                  => try sema.zirBitReverse(block, inst),
            .div_exact                    => try sema.zirDivExact(block, inst),
            .div_floor                    => try sema.zirDivFloor(block, inst),
            .div_trunc                    => try sema.zirDivTrunc(block, inst),
            .mod                          => try sema.zirMod(block, inst),
            .rem                          => try sema.zirRem(block, inst),
            .shl_exact                    => try sema.zirShlExact(block, inst),
            .shr_exact                    => try sema.zirShrExact(block, inst),
            .bit_offset_of                => try sema.zirBitOffsetOf(block, inst),
            .offset_of                    => try sema.zirOffsetOf(block, inst),
            .cmpxchg_strong               => try sema.zirCmpxchg(block, inst),
            .cmpxchg_weak                 => try sema.zirCmpxchg(block, inst),
            .splat                        => try sema.zirSplat(block, inst),
            .reduce                       => try sema.zirReduce(block, inst),
            .shuffle                      => try sema.zirShuffle(block, inst),
            .atomic_load                  => try sema.zirAtomicLoad(block, inst),
            .atomic_rmw                   => try sema.zirAtomicRmw(block, inst),
            .atomic_store                 => try sema.zirAtomicStore(block, inst),
            .mul_add                      => try sema.zirMulAdd(block, inst),
            .builtin_call                 => try sema.zirBuiltinCall(block, inst),
            .field_ptr_type               => try sema.zirFieldPtrType(block, inst),
            .field_parent_ptr             => try sema.zirFieldParentPtr(block, inst),
            .memcpy                       => try sema.zirMemcpy(block, inst),
            .memset                       => try sema.zirMemset(block, inst),
            .builtin_async_call           => try sema.zirBuiltinAsyncCall(block, inst),
            .@"resume"                    => try sema.zirResume(block, inst),
            .@"await"                     => try sema.zirAwait(block, inst, false),
            .await_nosuspend              => try sema.zirAwait(block, inst, true),
            .extended                     => try sema.zirExtended(block, inst),

            .sqrt  => try sema.zirUnaryMath(block, inst),
            .sin   => try sema.zirUnaryMath(block, inst),
            .cos   => try sema.zirUnaryMath(block, inst),
            .exp   => try sema.zirUnaryMath(block, inst),
            .exp2  => try sema.zirUnaryMath(block, inst),
            .log   => try sema.zirUnaryMath(block, inst),
            .log2  => try sema.zirUnaryMath(block, inst),
            .log10 => try sema.zirUnaryMath(block, inst),
            .fabs  => try sema.zirUnaryMath(block, inst),
            .floor => try sema.zirUnaryMath(block, inst),
            .ceil  => try sema.zirUnaryMath(block, inst),
            .trunc => try sema.zirUnaryMath(block, inst),
            .round => try sema.zirUnaryMath(block, inst),

            .opaque_decl         => try sema.zirOpaqueDecl(block, inst, .parent),
            .opaque_decl_anon    => try sema.zirOpaqueDecl(block, inst, .anon),
            .opaque_decl_func    => try sema.zirOpaqueDecl(block, inst, .func),
            .error_set_decl      => try sema.zirErrorSetDecl(block, inst, .parent),
            .error_set_decl_anon => try sema.zirErrorSetDecl(block, inst, .anon),
            .error_set_decl_func => try sema.zirErrorSetDecl(block, inst, .func),

            .add     => try sema.zirArithmetic(block, inst),
            .addwrap => try sema.zirArithmetic(block, inst),
            .div     => try sema.zirArithmetic(block, inst),
            .mod_rem => try sema.zirArithmetic(block, inst),
            .mul     => try sema.zirArithmetic(block, inst),
            .mulwrap => try sema.zirArithmetic(block, inst),
            .sub     => try sema.zirArithmetic(block, inst),
            .subwrap => try sema.zirArithmetic(block, inst),

            // Instructions that we know to *always* be noreturn based solely on their tag.
            // These functions match the return type of analyzeBody so that we can
            // tail call them here.
            .break_inline   => return inst,
            .condbr         => return sema.zirCondbr(block, inst),
            .@"break"       => return sema.zirBreak(block, inst),
            .compile_error  => return sema.zirCompileError(block, inst),
            .ret_coerce     => return sema.zirRetCoerce(block, inst, true),
            .ret_node       => return sema.zirRetNode(block, inst),
            .ret_err_value  => return sema.zirRetErrValue(block, inst),
            .@"unreachable" => return sema.zirUnreachable(block, inst),
            .repeat         => return sema.zirRepeat(block, inst),
            .panic          => return sema.zirPanic(block, inst),
            // zig fmt: on

            // Instructions that we know can *never* be noreturn based solely on
            // their tag. We avoid needlessly checking if they are noreturn and
            // continue the loop.
            // We also know that they cannot be referenced later, so we avoid
            // putting them into the map.
            .breakpoint => {
                try sema.zirBreakpoint(block, inst);
                i += 1;
                continue;
            },
            .fence => {
                try sema.zirFence(block, inst);
                i += 1;
                continue;
            },
            .dbg_stmt => {
                try sema.zirDbgStmt(block, inst);
                i += 1;
                continue;
            },
            .ensure_err_payload_void => {
                try sema.zirEnsureErrPayloadVoid(block, inst);
                i += 1;
                continue;
            },
            .ensure_result_non_error => {
                try sema.zirEnsureResultNonError(block, inst);
                i += 1;
                continue;
            },
            .ensure_result_used => {
                try sema.zirEnsureResultUsed(block, inst);
                i += 1;
                continue;
            },
            .set_eval_branch_quota => {
                try sema.zirSetEvalBranchQuota(block, inst);
                i += 1;
                continue;
            },
            .store => {
                try sema.zirStore(block, inst);
                i += 1;
                continue;
            },
            .store_node => {
                try sema.zirStoreNode(block, inst);
                i += 1;
                continue;
            },
            .store_to_block_ptr => {
                try sema.zirStoreToBlockPtr(block, inst);
                i += 1;
                continue;
            },
            .store_to_inferred_ptr => {
                try sema.zirStoreToInferredPtr(block, inst);
                i += 1;
                continue;
            },
            .resolve_inferred_alloc => {
                try sema.zirResolveInferredAlloc(block, inst);
                i += 1;
                continue;
            },
            .validate_struct_init_ptr => {
                try sema.zirValidateStructInitPtr(block, inst);
                i += 1;
                continue;
            },
            .validate_array_init_ptr => {
                try sema.zirValidateArrayInitPtr(block, inst);
                i += 1;
                continue;
            },
            .@"export" => {
                try sema.zirExport(block, inst);
                i += 1;
                continue;
            },
            .set_align_stack => {
                try sema.zirSetAlignStack(block, inst);
                i += 1;
                continue;
            },
            .set_cold => {
                try sema.zirSetCold(block, inst);
                i += 1;
                continue;
            },
            .set_float_mode => {
                try sema.zirSetFloatMode(block, inst);
                i += 1;
                continue;
            },
            .set_runtime_safety => {
                try sema.zirSetRuntimeSafety(block, inst);
                i += 1;
                continue;
            },

            // Special case instructions to handle comptime control flow.
            .repeat_inline => {
                // Send comptime control flow back to the beginning of this block.
                const src: LazySrcLoc = .{ .node_offset = datas[inst].node };
                try sema.emitBackwardBranch(block, src);
                i = 0;
                continue;
            },
            .block_inline => blk: {
                // Directly analyze the block body without introducing a new block.
                const inst_data = datas[inst].pl_node;
                const extra = sema.code.extraData(Zir.Inst.Block, inst_data.payload_index);
                const inline_body = sema.code.extra[extra.end..][0..extra.data.body_len];
                const break_inst = try sema.analyzeBody(block, inline_body);
                const break_data = datas[break_inst].@"break";
                if (inst == break_data.block_inst) {
                    break :blk try sema.resolveInst(break_data.operand);
                } else {
                    return break_inst;
                }
            },
            .condbr_inline => blk: {
                const inst_data = datas[inst].pl_node;
                const cond_src: LazySrcLoc = .{ .node_offset_if_cond = inst_data.src_node };
                const extra = sema.code.extraData(Zir.Inst.CondBr, inst_data.payload_index);
                const then_body = sema.code.extra[extra.end..][0..extra.data.then_body_len];
                const else_body = sema.code.extra[extra.end + then_body.len ..][0..extra.data.else_body_len];
                const cond = try sema.resolveInstConst(block, cond_src, extra.data.condition);
                const inline_body = if (cond.val.toBool()) then_body else else_body;
                const break_inst = try sema.analyzeBody(block, inline_body);
                const break_data = datas[break_inst].@"break";
                if (inst == break_data.block_inst) {
                    break :blk try sema.resolveInst(break_data.operand);
                } else {
                    return break_inst;
                }
            },
        };
        if (air_inst.ty.isNoReturn())
            return always_noreturn;
        try map.put(sema.gpa, inst, air_inst);
        i += 1;
    }
}

fn zirExtended(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const extended = sema.code.instructions.items(.data)[inst].extended;
    switch (extended.opcode) {
        // zig fmt: off
        .func               => return sema.zirFuncExtended(      block, extended, inst),
        .variable           => return sema.zirVarExtended(       block, extended),
        .struct_decl        => return sema.zirStructDecl(        block, extended, inst),
        .enum_decl          => return sema.zirEnumDecl(          block, extended),
        .union_decl         => return sema.zirUnionDecl(         block, extended, inst),
        .ret_ptr            => return sema.zirRetPtr(            block, extended),
        .ret_type           => return sema.zirRetType(           block, extended),
        .this               => return sema.zirThis(              block, extended),
        .ret_addr           => return sema.zirRetAddr(           block, extended),
        .builtin_src        => return sema.zirBuiltinSrc(        block, extended),
        .error_return_trace => return sema.zirErrorReturnTrace(  block, extended),
        .frame              => return sema.zirFrame(             block, extended),
        .frame_address      => return sema.zirFrameAddress(      block, extended),
        .alloc              => return sema.zirAllocExtended(     block, extended),
        .builtin_extern     => return sema.zirBuiltinExtern(     block, extended),
        .@"asm"             => return sema.zirAsm(               block, extended),
        .typeof_peer        => return sema.zirTypeofPeer(        block, extended),
        .compile_log        => return sema.zirCompileLog(        block, extended),
        .add_with_overflow  => return sema.zirOverflowArithmetic(block, extended),
        .sub_with_overflow  => return sema.zirOverflowArithmetic(block, extended),
        .mul_with_overflow  => return sema.zirOverflowArithmetic(block, extended),
        .shl_with_overflow  => return sema.zirOverflowArithmetic(block, extended),
        .c_undef            => return sema.zirCUndef(            block, extended),
        .c_include          => return sema.zirCInclude(          block, extended),
        .c_define           => return sema.zirCDefine(           block, extended),
        .wasm_memory_size   => return sema.zirWasmMemorySize(    block, extended),
        .wasm_memory_grow   => return sema.zirWasmMemoryGrow(    block, extended),
        // zig fmt: on
    }
}

/// TODO when we rework AIR memory layout, this function will no longer have a possible error.
pub fn resolveInst(sema: *Sema, zir_ref: Zir.Inst.Ref) error{OutOfMemory}!*ir.Inst {
    var i: usize = @enumToInt(zir_ref);

    // First section of indexes correspond to a set number of constant values.
    if (i < Zir.Inst.Ref.typed_value_map.len) {
        // TODO when we rework AIR memory layout, this function can be as simple as:
        // if (zir_ref < Zir.const_inst_list.len + sema.param_count)
        //     return zir_ref;
        // Until then we allocate memory for a new, mutable `ir.Inst` to match what
        // AIR expects.
        return sema.mod.constInst(sema.arena, .unneeded, Zir.Inst.Ref.typed_value_map[i]);
    }
    i -= Zir.Inst.Ref.typed_value_map.len;

    // Finally, the last section of indexes refers to the map of ZIR=>AIR.
    return sema.inst_map.get(@intCast(u32, i)).?;
}

fn resolveConstBool(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    zir_ref: Zir.Inst.Ref,
) !bool {
    const air_inst = try sema.resolveInst(zir_ref);
    const wanted_type = Type.initTag(.bool);
    const coerced_inst = try sema.coerce(block, wanted_type, air_inst, src);
    const val = try sema.resolveConstValue(block, src, coerced_inst);
    return val.toBool();
}

fn resolveConstString(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    zir_ref: Zir.Inst.Ref,
) ![]u8 {
    const air_inst = try sema.resolveInst(zir_ref);
    const wanted_type = Type.initTag(.const_slice_u8);
    const coerced_inst = try sema.coerce(block, wanted_type, air_inst, src);
    const val = try sema.resolveConstValue(block, src, coerced_inst);
    return val.toAllocatedBytes(sema.arena);
}

pub fn resolveType(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, zir_ref: Zir.Inst.Ref) !Type {
    const air_inst = try sema.resolveInst(zir_ref);
    return sema.resolveAirAsType(block, src, air_inst);
}

fn resolveAirAsType(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, air_inst: *ir.Inst) !Type {
    const wanted_type = Type.initTag(.@"type");
    const coerced_inst = try sema.coerce(block, wanted_type, air_inst, src);
    const val = try sema.resolveConstValue(block, src, coerced_inst);
    return val.toType(sema.arena);
}

fn resolveConstValue(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, base: *ir.Inst) !Value {
    return (try sema.resolveDefinedValue(block, src, base)) orelse
        return sema.failWithNeededComptime(block, src);
}

fn resolveDefinedValue(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, base: *ir.Inst) !?Value {
    if (try sema.resolvePossiblyUndefinedValue(block, src, base)) |val| {
        if (val.isUndef()) {
            return sema.failWithUseOfUndef(block, src);
        }
        return val;
    }
    return null;
}

fn resolvePossiblyUndefinedValue(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    base: *ir.Inst,
) !?Value {
    if (try sema.typeHasOnePossibleValue(block, src, base.ty)) |opv| {
        return opv;
    }
    const inst = base.castTag(.constant) orelse return null;
    return inst.val;
}

fn failWithNeededComptime(sema: *Sema, block: *Scope.Block, src: LazySrcLoc) InnerError {
    return sema.mod.fail(&block.base, src, "unable to resolve comptime value", .{});
}

fn failWithUseOfUndef(sema: *Sema, block: *Scope.Block, src: LazySrcLoc) InnerError {
    return sema.mod.fail(&block.base, src, "use of undefined value here causes undefined behavior", .{});
}

/// Appropriate to call when the coercion has already been done by result
/// location semantics. Asserts the value fits in the provided `Int` type.
/// Only supports `Int` types 64 bits or less.
fn resolveAlreadyCoercedInt(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    zir_ref: Zir.Inst.Ref,
    comptime Int: type,
) !Int {
    comptime assert(@typeInfo(Int).Int.bits <= 64);
    const air_inst = try sema.resolveInst(zir_ref);
    const val = try sema.resolveConstValue(block, src, air_inst);
    switch (@typeInfo(Int).Int.signedness) {
        .signed => return @intCast(Int, val.toSignedInt()),
        .unsigned => return @intCast(Int, val.toUnsignedInt()),
    }
}

fn resolveInt(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    zir_ref: Zir.Inst.Ref,
    dest_type: Type,
) !u64 {
    const air_inst = try sema.resolveInst(zir_ref);
    const coerced = try sema.coerce(block, dest_type, air_inst, src);
    const val = try sema.resolveConstValue(block, src, coerced);

    return val.toUnsignedInt();
}

pub fn resolveInstConst(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    zir_ref: Zir.Inst.Ref,
) InnerError!TypedValue {
    const air_inst = try sema.resolveInst(zir_ref);
    const val = try sema.resolveConstValue(block, src, air_inst);
    return TypedValue{
        .ty = air_inst.ty,
        .val = val,
    };
}

fn zirBitcastResultPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO implement zir_sema.zirBitcastResultPtr", .{});
}

fn zirCoerceResultPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    _ = inst;
    const tracy = trace(@src());
    defer tracy.end();
    return sema.mod.fail(&block.base, sema.src, "TODO implement zirCoerceResultPtr", .{});
}

pub fn analyzeStructDecl(
    sema: *Sema,
    new_decl: *Decl,
    inst: Zir.Inst.Index,
    struct_obj: *Module.Struct,
) InnerError!void {
    const extended = sema.code.instructions.items(.data)[inst].extended;
    assert(extended.opcode == .struct_decl);
    const small = @bitCast(Zir.Inst.StructDecl.Small, extended.small);

    var extra_index: usize = extended.operand;
    extra_index += @boolToInt(small.has_src_node);
    extra_index += @boolToInt(small.has_body_len);
    extra_index += @boolToInt(small.has_fields_len);
    const decls_len = if (small.has_decls_len) blk: {
        const decls_len = sema.code.extra[extra_index];
        extra_index += 1;
        break :blk decls_len;
    } else 0;

    _ = try sema.mod.scanNamespace(&struct_obj.namespace, extra_index, decls_len, new_decl);
}

fn zirStructDecl(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
    inst: Zir.Inst.Index,
) InnerError!*Inst {
    const small = @bitCast(Zir.Inst.StructDecl.Small, extended.small);
    const src: LazySrcLoc = if (small.has_src_node) blk: {
        const node_offset = @bitCast(i32, sema.code.extra[extended.operand]);
        break :blk .{ .node_offset = node_offset };
    } else sema.src;

    var new_decl_arena = std.heap.ArenaAllocator.init(sema.gpa);
    errdefer new_decl_arena.deinit();

    const struct_obj = try new_decl_arena.allocator.create(Module.Struct);
    const struct_ty = try Type.Tag.@"struct".create(&new_decl_arena.allocator, struct_obj);
    const struct_val = try Value.Tag.ty.create(&new_decl_arena.allocator, struct_ty);
    const type_name = try sema.createTypeName(block, small.name_strategy);
    const new_decl = try sema.mod.createAnonymousDeclNamed(&block.base, .{
        .ty = Type.initTag(.type),
        .val = struct_val,
    }, type_name);
    errdefer sema.mod.deleteAnonDecl(&block.base, new_decl);
    struct_obj.* = .{
        .owner_decl = new_decl,
        .fields = .{},
        .node_offset = src.node_offset,
        .zir_index = inst,
        .layout = small.layout,
        .status = .none,
        .namespace = .{
            .parent = sema.owner_decl.namespace,
            .ty = struct_ty,
            .file_scope = block.getFileScope(),
        },
    };
    std.log.scoped(.module).debug("create struct {*} owned by {*} ({s})", .{
        &struct_obj.namespace, new_decl, new_decl.name,
    });
    try sema.analyzeStructDecl(new_decl, inst, struct_obj);
    try new_decl.finalizeNewArena(&new_decl_arena);
    return sema.analyzeDeclVal(block, src, new_decl);
}

fn createTypeName(sema: *Sema, block: *Scope.Block, name_strategy: Zir.Inst.NameStrategy) ![:0]u8 {
    _ = block;
    switch (name_strategy) {
        .anon => {
            // It would be neat to have "struct:line:column" but this name has
            // to survive incremental updates, where it may have been shifted down
            // or up to a different line, but unchanged, and thus not unnecessarily
            // semantically analyzed.
            const name_index = sema.mod.getNextAnonNameIndex();
            return std.fmt.allocPrintZ(sema.gpa, "{s}__anon_{d}", .{
                sema.owner_decl.name, name_index,
            });
        },
        .parent => return sema.gpa.dupeZ(u8, mem.spanZ(sema.owner_decl.name)),
        .func => {
            const name_index = sema.mod.getNextAnonNameIndex();
            const name = try std.fmt.allocPrintZ(sema.gpa, "{s}__anon_{d}", .{
                sema.owner_decl.name, name_index,
            });
            log.warn("TODO: handle NameStrategy.func correctly instead of using anon name '{s}'", .{
                name,
            });
            return name;
        },
    }
}

fn zirEnumDecl(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const mod = sema.mod;
    const gpa = sema.gpa;
    const small = @bitCast(Zir.Inst.EnumDecl.Small, extended.small);
    var extra_index: usize = extended.operand;

    const src: LazySrcLoc = if (small.has_src_node) blk: {
        const node_offset = @bitCast(i32, sema.code.extra[extra_index]);
        extra_index += 1;
        break :blk .{ .node_offset = node_offset };
    } else sema.src;

    const tag_type_ref = if (small.has_tag_type) blk: {
        const tag_type_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
        extra_index += 1;
        break :blk tag_type_ref;
    } else .none;

    const body_len = if (small.has_body_len) blk: {
        const body_len = sema.code.extra[extra_index];
        extra_index += 1;
        break :blk body_len;
    } else 0;

    const fields_len = if (small.has_fields_len) blk: {
        const fields_len = sema.code.extra[extra_index];
        extra_index += 1;
        break :blk fields_len;
    } else 0;

    const decls_len = if (small.has_decls_len) blk: {
        const decls_len = sema.code.extra[extra_index];
        extra_index += 1;
        break :blk decls_len;
    } else 0;

    var new_decl_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer new_decl_arena.deinit();

    const tag_ty = blk: {
        if (tag_type_ref != .none) {
            // TODO better source location
            // TODO (needs AstGen fix too) move this eval to the block so it gets allocated
            // in the new decl arena.
            break :blk try sema.resolveType(block, src, tag_type_ref);
        }
        const bits = std.math.log2_int_ceil(usize, fields_len);
        break :blk try Type.Tag.int_unsigned.create(&new_decl_arena.allocator, bits);
    };

    const enum_obj = try new_decl_arena.allocator.create(Module.EnumFull);
    const enum_ty_payload = try new_decl_arena.allocator.create(Type.Payload.EnumFull);
    enum_ty_payload.* = .{
        .base = .{ .tag = if (small.nonexhaustive) .enum_nonexhaustive else .enum_full },
        .data = enum_obj,
    };
    const enum_ty = Type.initPayload(&enum_ty_payload.base);
    const enum_val = try Value.Tag.ty.create(&new_decl_arena.allocator, enum_ty);
    const type_name = try sema.createTypeName(block, small.name_strategy);
    const new_decl = try mod.createAnonymousDeclNamed(&block.base, .{
        .ty = Type.initTag(.type),
        .val = enum_val,
    }, type_name);
    errdefer sema.mod.deleteAnonDecl(&block.base, new_decl);

    enum_obj.* = .{
        .owner_decl = new_decl,
        .tag_ty = tag_ty,
        .fields = .{},
        .values = .{},
        .node_offset = src.node_offset,
        .namespace = .{
            .parent = sema.owner_decl.namespace,
            .ty = enum_ty,
            .file_scope = block.getFileScope(),
        },
    };
    std.log.scoped(.module).debug("create enum {*} owned by {*} ({s})", .{
        &enum_obj.namespace, new_decl, new_decl.name,
    });

    extra_index = try mod.scanNamespace(&enum_obj.namespace, extra_index, decls_len, new_decl);

    const body = sema.code.extra[extra_index..][0..body_len];
    if (fields_len == 0) {
        assert(body.len == 0);
        try new_decl.finalizeNewArena(&new_decl_arena);
        return sema.analyzeDeclVal(block, src, new_decl);
    }
    extra_index += body.len;

    const bit_bags_count = std.math.divCeil(usize, fields_len, 32) catch unreachable;
    const body_end = extra_index;
    extra_index += bit_bags_count;

    try enum_obj.fields.ensureCapacity(&new_decl_arena.allocator, fields_len);
    const any_values = for (sema.code.extra[body_end..][0..bit_bags_count]) |bag| {
        if (bag != 0) break true;
    } else false;
    if (any_values) {
        try enum_obj.values.ensureCapacity(&new_decl_arena.allocator, fields_len);
    }

    {
        // We create a block for the field type instructions because they
        // may need to reference Decls from inside the enum namespace.
        // Within the field type, default value, and alignment expressions, the "owner decl"
        // should be the enum itself. Thus we need a new Sema.
        var enum_sema: Sema = .{
            .mod = mod,
            .gpa = gpa,
            .arena = &new_decl_arena.allocator,
            .code = sema.code,
            .inst_map = sema.inst_map,
            .owner_decl = new_decl,
            .namespace = &enum_obj.namespace,
            .owner_func = null,
            .func = null,
            .param_inst_list = &.{},
            .branch_quota = sema.branch_quota,
            .branch_count = sema.branch_count,
        };

        var enum_block: Scope.Block = .{
            .parent = null,
            .sema = &enum_sema,
            .src_decl = new_decl,
            .instructions = .{},
            .inlining = null,
            .is_comptime = true,
        };
        defer assert(enum_block.instructions.items.len == 0); // should all be comptime instructions

        if (body.len != 0) {
            _ = try enum_sema.analyzeBody(&enum_block, body);
        }

        sema.branch_count = enum_sema.branch_count;
        sema.branch_quota = enum_sema.branch_quota;
    }
    var bit_bag_index: usize = body_end;
    var cur_bit_bag: u32 = undefined;
    var field_i: u32 = 0;
    while (field_i < fields_len) : (field_i += 1) {
        if (field_i % 32 == 0) {
            cur_bit_bag = sema.code.extra[bit_bag_index];
            bit_bag_index += 1;
        }
        const has_tag_value = @truncate(u1, cur_bit_bag) != 0;
        cur_bit_bag >>= 1;

        const field_name_zir = sema.code.nullTerminatedString(sema.code.extra[extra_index]);
        extra_index += 1;

        // This string needs to outlive the ZIR code.
        const field_name = try new_decl_arena.allocator.dupe(u8, field_name_zir);

        const gop = enum_obj.fields.getOrPutAssumeCapacity(field_name);
        if (gop.found_existing) {
            const tree = try sema.getAstTree(block);
            const field_src = enumFieldSrcLoc(block.src_decl, tree.*, src.node_offset, field_i);
            const other_tag_src = enumFieldSrcLoc(block.src_decl, tree.*, src.node_offset, gop.index);
            const msg = msg: {
                const msg = try mod.errMsg(&block.base, field_src, "duplicate enum tag", .{});
                errdefer msg.destroy(gpa);
                try mod.errNote(&block.base, other_tag_src, msg, "other tag here", .{});
                break :msg msg;
            };
            return mod.failWithOwnedErrorMsg(&block.base, msg);
        }

        if (has_tag_value) {
            const tag_val_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
            extra_index += 1;
            // TODO: if we need to report an error here, use a source location
            // that points to this default value expression rather than the struct.
            // But only resolve the source location if we need to emit a compile error.
            const tag_val = (try sema.resolveInstConst(block, src, tag_val_ref)).val;
            enum_obj.values.putAssumeCapacityNoClobber(tag_val, {});
        } else if (any_values) {
            const tag_val = try Value.Tag.int_u64.create(&new_decl_arena.allocator, field_i);
            enum_obj.values.putAssumeCapacityNoClobber(tag_val, {});
        }
    }

    try new_decl.finalizeNewArena(&new_decl_arena);
    return sema.analyzeDeclVal(block, src, new_decl);
}

fn zirUnionDecl(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
    inst: Zir.Inst.Index,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const small = @bitCast(Zir.Inst.UnionDecl.Small, extended.small);
    var extra_index: usize = extended.operand;

    const src: LazySrcLoc = if (small.has_src_node) blk: {
        const node_offset = @bitCast(i32, sema.code.extra[extra_index]);
        extra_index += 1;
        break :blk .{ .node_offset = node_offset };
    } else sema.src;

    extra_index += @boolToInt(small.has_tag_type);
    extra_index += @boolToInt(small.has_body_len);
    extra_index += @boolToInt(small.has_fields_len);

    const decls_len = if (small.has_decls_len) blk: {
        const decls_len = sema.code.extra[extra_index];
        extra_index += 1;
        break :blk decls_len;
    } else 0;

    var new_decl_arena = std.heap.ArenaAllocator.init(sema.gpa);
    errdefer new_decl_arena.deinit();

    const union_obj = try new_decl_arena.allocator.create(Module.Union);
    const union_ty = try Type.Tag.@"union".create(&new_decl_arena.allocator, union_obj);
    const union_val = try Value.Tag.ty.create(&new_decl_arena.allocator, union_ty);
    const type_name = try sema.createTypeName(block, small.name_strategy);
    const new_decl = try sema.mod.createAnonymousDeclNamed(&block.base, .{
        .ty = Type.initTag(.type),
        .val = union_val,
    }, type_name);
    errdefer sema.mod.deleteAnonDecl(&block.base, new_decl);
    union_obj.* = .{
        .owner_decl = new_decl,
        .tag_ty = Type.initTag(.@"null"),
        .fields = .{},
        .node_offset = src.node_offset,
        .zir_index = inst,
        .layout = small.layout,
        .status = .none,
        .namespace = .{
            .parent = sema.owner_decl.namespace,
            .ty = union_ty,
            .file_scope = block.getFileScope(),
        },
    };
    std.log.scoped(.module).debug("create union {*} owned by {*} ({s})", .{
        &union_obj.namespace, new_decl, new_decl.name,
    });

    _ = try sema.mod.scanNamespace(&union_obj.namespace, extra_index, decls_len, new_decl);

    try new_decl.finalizeNewArena(&new_decl_arena);
    return sema.analyzeDeclVal(block, src, new_decl);
}

fn zirOpaqueDecl(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    name_strategy: Zir.Inst.NameStrategy,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const extra = sema.code.extraData(Zir.Inst.Block, inst_data.payload_index);

    _ = name_strategy;
    _ = inst_data;
    _ = src;
    _ = extra;
    return sema.mod.fail(&block.base, sema.src, "TODO implement zirOpaqueDecl", .{});
}

fn zirErrorSetDecl(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    name_strategy: Zir.Inst.NameStrategy,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = sema.gpa;
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const extra = sema.code.extraData(Zir.Inst.ErrorSetDecl, inst_data.payload_index);
    const fields = sema.code.extra[extra.end..][0..extra.data.fields_len];

    var new_decl_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer new_decl_arena.deinit();

    const error_set = try new_decl_arena.allocator.create(Module.ErrorSet);
    const error_set_ty = try Type.Tag.error_set.create(&new_decl_arena.allocator, error_set);
    const error_set_val = try Value.Tag.ty.create(&new_decl_arena.allocator, error_set_ty);
    const type_name = try sema.createTypeName(block, name_strategy);
    const new_decl = try sema.mod.createAnonymousDeclNamed(&block.base, .{
        .ty = Type.initTag(.type),
        .val = error_set_val,
    }, type_name);
    errdefer sema.mod.deleteAnonDecl(&block.base, new_decl);
    const names = try new_decl_arena.allocator.alloc([]const u8, fields.len);
    for (fields) |str_index, i| {
        names[i] = try new_decl_arena.allocator.dupe(u8, sema.code.nullTerminatedString(str_index));
    }
    error_set.* = .{
        .owner_decl = new_decl,
        .node_offset = inst_data.src_node,
        .names_ptr = names.ptr,
        .names_len = @intCast(u32, names.len),
    };
    try new_decl.finalizeNewArena(&new_decl_arena);
    return sema.analyzeDeclVal(block, src, new_decl);
}

fn zirRetPtr(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const src: LazySrcLoc = .{ .node_offset = @bitCast(i32, extended.operand) };
    try sema.requireFunctionBlock(block, src);
    const fn_ty = sema.func.?.owner_decl.ty;
    const ret_type = fn_ty.fnReturnType();
    const ptr_type = try sema.mod.simplePtrType(sema.arena, ret_type, true, .One);
    return block.addNoOp(src, ptr_type, .alloc);
}

fn zirRef(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const operand = try sema.resolveInst(inst_data.operand);
    return sema.analyzeRef(block, inst_data.src(), operand);
}

fn zirRetType(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const src: LazySrcLoc = .{ .node_offset = @bitCast(i32, extended.operand) };
    try sema.requireFunctionBlock(block, src);
    const fn_ty = sema.func.?.owner_decl.ty;
    const ret_type = fn_ty.fnReturnType();
    return sema.mod.constType(sema.arena, src, ret_type);
}

fn zirEnsureResultUsed(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const operand = try sema.resolveInst(inst_data.operand);
    const src = inst_data.src();

    return sema.ensureResultUsed(block, operand, src);
}

fn ensureResultUsed(
    sema: *Sema,
    block: *Scope.Block,
    operand: *Inst,
    src: LazySrcLoc,
) InnerError!void {
    switch (operand.ty.zigTypeTag()) {
        .Void, .NoReturn => return,
        else => return sema.mod.fail(&block.base, src, "expression value is ignored", .{}),
    }
}

fn zirEnsureResultNonError(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const operand = try sema.resolveInst(inst_data.operand);
    const src = inst_data.src();
    switch (operand.ty.zigTypeTag()) {
        .ErrorSet, .ErrorUnion => return sema.mod.fail(&block.base, src, "error is discarded", .{}),
        else => return,
    }
}

fn zirIndexablePtrLen(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const array_ptr = try sema.resolveInst(inst_data.operand);

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
            errdefer msg.destroy(sema.gpa);
            try sema.mod.errNote(
                &block.base,
                cond_src,
                msg,
                "for loop operand must be an array, slice, tuple, or vector",
                .{},
            );
            break :msg msg;
        };
        return sema.mod.failWithOwnedErrorMsg(&block.base, msg);
    }
    const result_ptr = try sema.namedFieldPtr(block, src, array_ptr, "len", src);
    return sema.analyzeLoad(block, src, result_ptr, result_ptr.src);
}

fn zirArg(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].str_tok;
    const arg_name = inst_data.get(sema.code);
    const arg_index = sema.next_arg_index;
    sema.next_arg_index += 1;

    // TODO check if arg_name shadows a Decl

    if (block.inlining) |_| {
        return sema.param_inst_list[arg_index];
    }

    // Need to set the name of the Air.Arg instruction.
    const air_arg = sema.param_inst_list[arg_index].castTag(.arg).?;
    air_arg.name = arg_name;
    return &air_arg.base;
}

fn zirAllocExtended(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const extra = sema.code.extraData(Zir.Inst.AllocExtended, extended.operand);
    const src: LazySrcLoc = .{ .node_offset = extra.data.src_node };
    return sema.mod.fail(&block.base, src, "TODO implement Sema.zirAllocExtended", .{});
}

fn zirAllocComptime(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const ty_src: LazySrcLoc = .{ .node_offset_var_decl_ty = inst_data.src_node };
    const var_type = try sema.resolveType(block, ty_src, inst_data.operand);
    const ptr_type = try sema.mod.simplePtrType(sema.arena, var_type, true, .One);

    const val_payload = try sema.arena.create(Value.Payload.ComptimeAlloc);
    val_payload.* = .{
        .data = .{
            .runtime_index = block.runtime_index,
            .val = undefined, // astgen guarantees there will be a store before the first load
        },
    };
    return sema.mod.constInst(sema.arena, src, .{
        .ty = ptr_type,
        .val = Value.initPayload(&val_payload.base),
    });
}

fn zirAllocInferredComptime(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const src_node = sema.code.instructions.items(.data)[inst].node;
    const src: LazySrcLoc = .{ .node_offset = src_node };
    return sema.mod.fail(&block.base, src, "TODO implement Sema.zirAllocInferredComptime", .{});
}

fn zirAlloc(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const ty_src: LazySrcLoc = .{ .node_offset_var_decl_ty = inst_data.src_node };
    const var_decl_src = inst_data.src();
    const var_type = try sema.resolveType(block, ty_src, inst_data.operand);
    const ptr_type = try sema.mod.simplePtrType(sema.arena, var_type, true, .One);
    try sema.requireRuntimeBlock(block, var_decl_src);
    return block.addNoOp(var_decl_src, ptr_type, .alloc);
}

fn zirAllocMut(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const var_decl_src = inst_data.src();
    const ty_src: LazySrcLoc = .{ .node_offset_var_decl_ty = inst_data.src_node };
    const var_type = try sema.resolveType(block, ty_src, inst_data.operand);
    try sema.validateVarType(block, ty_src, var_type);
    const ptr_type = try sema.mod.simplePtrType(sema.arena, var_type, true, .One);
    try sema.requireRuntimeBlock(block, var_decl_src);
    return block.addNoOp(var_decl_src, ptr_type, .alloc);
}

fn zirAllocInferred(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    inferred_alloc_ty: Type,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const src_node = sema.code.instructions.items(.data)[inst].node;
    const src: LazySrcLoc = .{ .node_offset = src_node };

    const val_payload = try sema.arena.create(Value.Payload.InferredAlloc);
    val_payload.* = .{
        .data = .{},
    };
    // `Module.constInst` does not add the instruction to the block because it is
    // not needed in the case of constant values. However here, we plan to "downgrade"
    // to a normal instruction when we hit `resolve_inferred_alloc`. So we append
    // to the block even though it is currently a `.constant`.
    const result = try sema.mod.constInst(sema.arena, src, .{
        .ty = inferred_alloc_ty,
        .val = Value.initPayload(&val_payload.base),
    });
    try sema.requireFunctionBlock(block, src);
    try block.instructions.append(sema.gpa, result);
    return result;
}

fn zirResolveInferredAlloc(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const ty_src: LazySrcLoc = .{ .node_offset_var_decl_ty = inst_data.src_node };
    const ptr = try sema.resolveInst(inst_data.operand);
    const ptr_val = ptr.castTag(.constant).?.val;
    const inferred_alloc = ptr_val.castTag(.inferred_alloc).?;
    const peer_inst_list = inferred_alloc.data.stored_inst_list.items;
    const final_elem_ty = try sema.resolvePeerTypes(block, ty_src, peer_inst_list, .infer);
    const var_is_mut = switch (ptr.ty.tag()) {
        .inferred_alloc_const => false,
        .inferred_alloc_mut => true,
        else => unreachable,
    };
    if (var_is_mut) {
        try sema.validateVarType(block, ty_src, final_elem_ty);
    }
    const final_ptr_ty = try sema.mod.simplePtrType(sema.arena, final_elem_ty, true, .One);

    // Change it to a normal alloc.
    ptr.ty = final_ptr_ty;
    ptr.tag = .alloc;
}

fn zirValidateStructInitPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = sema.gpa;
    const mod = sema.mod;
    const validate_inst = sema.code.instructions.items(.data)[inst].pl_node;
    const struct_init_src = validate_inst.src();
    const validate_extra = sema.code.extraData(Zir.Inst.Block, validate_inst.payload_index);
    const instrs = sema.code.extra[validate_extra.end..][0..validate_extra.data.body_len];

    const struct_obj: *Module.Struct = s: {
        const field_ptr_data = sema.code.instructions.items(.data)[instrs[0]].pl_node;
        const field_ptr_extra = sema.code.extraData(Zir.Inst.Field, field_ptr_data.payload_index).data;
        const object_ptr = try sema.resolveInst(field_ptr_extra.lhs);
        break :s object_ptr.ty.elemType().castTag(.@"struct").?.data;
    };

    // Maps field index to field_ptr index of where it was already initialized.
    const found_fields = try gpa.alloc(Zir.Inst.Index, struct_obj.fields.count());
    defer gpa.free(found_fields);
    mem.set(Zir.Inst.Index, found_fields, 0);

    for (instrs) |field_ptr| {
        const field_ptr_data = sema.code.instructions.items(.data)[field_ptr].pl_node;
        const field_src: LazySrcLoc = .{ .node_offset_back2tok = field_ptr_data.src_node };
        const field_ptr_extra = sema.code.extraData(Zir.Inst.Field, field_ptr_data.payload_index).data;
        const field_name = sema.code.nullTerminatedString(field_ptr_extra.field_name_start);
        const field_index = struct_obj.fields.getIndex(field_name) orelse
            return sema.failWithBadFieldAccess(block, struct_obj, field_src, field_name);
        if (found_fields[field_index] != 0) {
            const other_field_ptr = found_fields[field_index];
            const other_field_ptr_data = sema.code.instructions.items(.data)[other_field_ptr].pl_node;
            const other_field_src: LazySrcLoc = .{ .node_offset_back2tok = other_field_ptr_data.src_node };
            const msg = msg: {
                const msg = try mod.errMsg(&block.base, field_src, "duplicate field", .{});
                errdefer msg.destroy(gpa);
                try mod.errNote(&block.base, other_field_src, msg, "other field here", .{});
                break :msg msg;
            };
            return mod.failWithOwnedErrorMsg(&block.base, msg);
        }
        found_fields[field_index] = field_ptr;
    }

    var root_msg: ?*Module.ErrorMsg = null;

    // TODO handle default struct field values
    for (found_fields) |field_ptr, i| {
        if (field_ptr != 0) continue;

        const field_name = struct_obj.fields.keys()[i];
        const template = "missing struct field: {s}";
        const args = .{field_name};
        if (root_msg) |msg| {
            try mod.errNote(&block.base, struct_init_src, msg, template, args);
        } else {
            root_msg = try mod.errMsg(&block.base, struct_init_src, template, args);
        }
    }
    if (root_msg) |msg| {
        const fqn = try struct_obj.getFullyQualifiedName(gpa);
        defer gpa.free(fqn);
        try mod.errNoteNonLazy(
            struct_obj.srcLoc(),
            msg,
            "struct '{s}' declared here",
            .{fqn},
        );
        return mod.failWithOwnedErrorMsg(&block.base, msg);
    }
}

fn zirValidateArrayInitPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO implement Sema.zirValidateArrayInitPtr", .{});
}

fn failWithBadFieldAccess(
    sema: *Sema,
    block: *Scope.Block,
    struct_obj: *Module.Struct,
    field_src: LazySrcLoc,
    field_name: []const u8,
) InnerError {
    const mod = sema.mod;
    const gpa = sema.gpa;

    const fqn = try struct_obj.getFullyQualifiedName(gpa);
    defer gpa.free(fqn);

    const msg = msg: {
        const msg = try mod.errMsg(
            &block.base,
            field_src,
            "no field named '{s}' in struct '{s}'",
            .{ field_name, fqn },
        );
        errdefer msg.destroy(gpa);
        try mod.errNoteNonLazy(struct_obj.srcLoc(), msg, "struct declared here", .{});
        break :msg msg;
    };
    return mod.failWithOwnedErrorMsg(&block.base, msg);
}

fn failWithBadUnionFieldAccess(
    sema: *Sema,
    block: *Scope.Block,
    union_obj: *Module.Union,
    field_src: LazySrcLoc,
    field_name: []const u8,
) InnerError {
    const mod = sema.mod;
    const gpa = sema.gpa;

    const fqn = try union_obj.getFullyQualifiedName(gpa);
    defer gpa.free(fqn);

    const msg = msg: {
        const msg = try mod.errMsg(
            &block.base,
            field_src,
            "no field named '{s}' in union '{s}'",
            .{ field_name, fqn },
        );
        errdefer msg.destroy(gpa);
        try mod.errNoteNonLazy(union_obj.srcLoc(), msg, "union declared here", .{});
        break :msg msg;
    };
    return mod.failWithOwnedErrorMsg(&block.base, msg);
}

fn zirStoreToBlockPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    if (bin_inst.lhs == .none) {
        // This is an elided instruction, but AstGen was not smart enough
        // to omit it.
        return;
    }
    const ptr = try sema.resolveInst(bin_inst.lhs);
    const value = try sema.resolveInst(bin_inst.rhs);
    const ptr_ty = try sema.mod.simplePtrType(sema.arena, value.ty, true, .One);
    // TODO detect when this store should be done at compile-time. For example,
    // if expressions should force it when the condition is compile-time known.
    const src: LazySrcLoc = .unneeded;
    try sema.requireRuntimeBlock(block, src);
    const bitcasted_ptr = try block.addUnOp(src, ptr_ty, .bitcast, ptr);
    return sema.storePtr(block, src, bitcasted_ptr, value);
}

fn zirStoreToInferredPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const src: LazySrcLoc = .unneeded;
    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const ptr = try sema.resolveInst(bin_inst.lhs);
    const value = try sema.resolveInst(bin_inst.rhs);
    const inferred_alloc = ptr.castTag(.constant).?.val.castTag(.inferred_alloc).?;
    // Add the stored instruction to the set we will use to resolve peer types
    // for the inferred allocation.
    try inferred_alloc.data.stored_inst_list.append(sema.arena, value);
    // Create a runtime bitcast instruction with exactly the type the pointer wants.
    const ptr_ty = try sema.mod.simplePtrType(sema.arena, value.ty, true, .One);
    try sema.requireRuntimeBlock(block, src);
    const bitcasted_ptr = try block.addUnOp(src, ptr_ty, .bitcast, ptr);
    return sema.storePtr(block, src, bitcasted_ptr, value);
}

fn zirSetEvalBranchQuota(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const quota = try sema.resolveAlreadyCoercedInt(block, src, inst_data.operand, u32);
    if (sema.branch_quota < quota)
        sema.branch_quota = quota;
}

fn zirStore(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const ptr = try sema.resolveInst(bin_inst.lhs);
    const value = try sema.resolveInst(bin_inst.rhs);
    return sema.storePtr(block, sema.src, ptr, value);
}

fn zirStoreNode(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    const ptr = try sema.resolveInst(extra.lhs);
    const value = try sema.resolveInst(extra.rhs);
    return sema.storePtr(block, src, ptr, value);
}

fn zirParamType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const src: LazySrcLoc = .unneeded;
    const inst_data = sema.code.instructions.items(.data)[inst].param_type;
    const fn_inst = try sema.resolveInst(inst_data.callee);
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
            return sema.mod.constType(sema.arena, src, Type.initTag(.var_args_param));
        }
        return sema.mod.fail(&block.base, src, "arg index {d} out of bounds; '{}' has {d} argument(s)", .{
            param_index,
            fn_ty,
            param_count,
        });
    }

    // TODO support generic functions
    const param_type = fn_ty.fnParamType(param_index);
    return sema.mod.constType(sema.arena, src, param_type);
}

fn zirStr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const zir_bytes = sema.code.instructions.items(.data)[inst].str.get(sema.code);

    // `zir_bytes` references memory inside the ZIR module, which can get deallocated
    // after semantic analysis is complete, for example in the case of the initialization
    // expression of a variable declaration. We need the memory to be in the new
    // anonymous Decl's arena.

    var new_decl_arena = std.heap.ArenaAllocator.init(sema.gpa);
    errdefer new_decl_arena.deinit();

    const bytes = try new_decl_arena.allocator.dupe(u8, zir_bytes);

    const decl_ty = try Type.Tag.array_u8_sentinel_0.create(&new_decl_arena.allocator, bytes.len);
    const decl_val = try Value.Tag.bytes.create(&new_decl_arena.allocator, bytes);

    const new_decl = try sema.mod.createAnonymousDecl(&block.base, .{
        .ty = decl_ty,
        .val = decl_val,
    });
    errdefer sema.mod.deleteAnonDecl(&block.base, new_decl);
    try new_decl.finalizeNewArena(&new_decl_arena);
    return sema.analyzeDeclRef(block, .unneeded, new_decl);
}

fn zirInt(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    _ = block;
    const tracy = trace(@src());
    defer tracy.end();

    const int = sema.code.instructions.items(.data)[inst].int;
    return sema.mod.constIntUnsigned(sema.arena, .unneeded, Type.initTag(.comptime_int), int);
}

fn zirIntBig(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    _ = block;
    const tracy = trace(@src());
    defer tracy.end();

    const arena = sema.arena;
    const int = sema.code.instructions.items(.data)[inst].str;
    const byte_count = int.len * @sizeOf(std.math.big.Limb);
    const limb_bytes = sema.code.string_bytes[int.start..][0..byte_count];
    const limbs = try arena.alloc(std.math.big.Limb, int.len);
    mem.copy(u8, mem.sliceAsBytes(limbs), limb_bytes);

    return sema.mod.constInst(arena, .unneeded, .{
        .ty = Type.initTag(.comptime_int),
        .val = try Value.Tag.int_big_positive.create(arena, limbs),
    });
}

fn zirFloat(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    _ = block;
    const arena = sema.arena;
    const inst_data = sema.code.instructions.items(.data)[inst].float;
    const src = inst_data.src();
    const number = inst_data.number;

    return sema.mod.constInst(arena, src, .{
        .ty = Type.initTag(.comptime_float),
        .val = try Value.Tag.float_32.create(arena, number),
    });
}

fn zirFloat128(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    _ = block;
    const arena = sema.arena;
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Float128, inst_data.payload_index).data;
    const src = inst_data.src();
    const number = extra.get();

    return sema.mod.constInst(arena, src, .{
        .ty = Type.initTag(.comptime_float),
        .val = try Value.Tag.float_128.create(arena, number),
    });
}

fn zirCompileError(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!Zir.Inst.Index {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const msg = try sema.resolveConstString(block, operand_src, inst_data.operand);
    return sema.mod.fail(&block.base, src, "{s}", .{msg});
}

fn zirCompileLog(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    var managed = sema.mod.compile_log_text.toManaged(sema.gpa);
    defer sema.mod.compile_log_text = managed.moveToUnmanaged();
    const writer = managed.writer();

    const extra = sema.code.extraData(Zir.Inst.NodeMultiOp, extended.operand);
    const src_node = extra.data.src_node;
    const src: LazySrcLoc = .{ .node_offset = src_node };
    const args = sema.code.refSlice(extra.end, extended.small);

    for (args) |arg_ref, i| {
        if (i != 0) try writer.print(", ", .{});

        const arg = try sema.resolveInst(arg_ref);
        if (try sema.resolvePossiblyUndefinedValue(block, src, arg)) |val| {
            try writer.print("@as({}, {})", .{ arg.ty, val });
        } else {
            try writer.print("@as({}, [runtime value])", .{arg.ty});
        }
    }
    try writer.print("\n", .{});

    const gop = try sema.mod.compile_log_decls.getOrPut(sema.gpa, sema.owner_decl);
    if (!gop.found_existing) {
        gop.value_ptr.* = src_node;
    }
    return sema.mod.constInst(sema.arena, src, .{
        .ty = Type.initTag(.void),
        .val = Value.initTag(.void_value),
    });
}

fn zirRepeat(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!Zir.Inst.Index {
    const tracy = trace(@src());
    defer tracy.end();

    const src_node = sema.code.instructions.items(.data)[inst].node;
    const src: LazySrcLoc = .{ .node_offset = src_node };
    try sema.requireRuntimeBlock(block, src);
    return always_noreturn;
}

fn zirPanic(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!Zir.Inst.Index {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src: LazySrcLoc = inst_data.src();
    const msg_inst = try sema.resolveInst(inst_data.operand);

    return sema.panicWithMsg(block, src, msg_inst);
}

fn zirLoop(sema: *Sema, parent_block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const extra = sema.code.extraData(Zir.Inst.Block, inst_data.payload_index);
    const body = sema.code.extra[extra.end..][0..extra.data.body_len];

    // AIR expects a block outside the loop block too.
    const block_inst = try sema.arena.create(Inst.Block);
    block_inst.* = .{
        .base = .{
            .tag = Inst.Block.base_tag,
            .ty = undefined,
            .src = src,
        },
        .body = undefined,
    };

    var label: Scope.Block.Label = .{
        .zir_block = inst,
        .merges = .{
            .results = .{},
            .br_list = .{},
            .block_inst = block_inst,
        },
    };
    var child_block = parent_block.makeSubBlock();
    child_block.label = &label;
    child_block.runtime_cond = null;
    child_block.runtime_loop = src;
    child_block.runtime_index += 1;
    const merges = &child_block.label.?.merges;

    defer child_block.instructions.deinit(sema.gpa);
    defer merges.results.deinit(sema.gpa);
    defer merges.br_list.deinit(sema.gpa);

    // Reserve space for a Loop instruction so that generated Break instructions can
    // point to it, even if it doesn't end up getting used because the code ends up being
    // comptime evaluated.
    const loop_inst = try sema.arena.create(Inst.Loop);
    loop_inst.* = .{
        .base = .{
            .tag = Inst.Loop.base_tag,
            .ty = Type.initTag(.noreturn),
            .src = src,
        },
        .body = undefined,
    };

    var loop_block = child_block.makeSubBlock();
    defer loop_block.instructions.deinit(sema.gpa);

    _ = try sema.analyzeBody(&loop_block, body);

    // Loop repetition is implied so the last instruction may or may not be a noreturn instruction.

    try child_block.instructions.append(sema.gpa, &loop_inst.base);
    loop_inst.body = .{ .instructions = try sema.arena.dupe(*Inst, loop_block.instructions.items) };

    return sema.analyzeBlockBody(parent_block, src, &child_block, merges);
}

fn zirCImport(sema: *Sema, parent_block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();

    return sema.mod.fail(&parent_block.base, src, "TODO: implement Sema.zirCImport", .{});
}

fn zirSuspendBlock(sema: *Sema, parent_block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&parent_block.base, src, "TODO: implement Sema.zirSuspendBlock", .{});
}

fn zirBlock(sema: *Sema, parent_block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const extra = sema.code.extraData(Zir.Inst.Block, inst_data.payload_index);
    const body = sema.code.extra[extra.end..][0..extra.data.body_len];

    // Reserve space for a Block instruction so that generated Break instructions can
    // point to it, even if it doesn't end up getting used because the code ends up being
    // comptime evaluated.
    const block_inst = try sema.arena.create(Inst.Block);
    block_inst.* = .{
        .base = .{
            .tag = Inst.Block.base_tag,
            .ty = undefined, // Set after analysis.
            .src = src,
        },
        .body = undefined,
    };

    var label: Scope.Block.Label = .{
        .zir_block = inst,
        .merges = .{
            .results = .{},
            .br_list = .{},
            .block_inst = block_inst,
        },
    };

    var child_block: Scope.Block = .{
        .parent = parent_block,
        .sema = sema,
        .src_decl = parent_block.src_decl,
        .instructions = .{},
        .label = &label,
        .inlining = parent_block.inlining,
        .is_comptime = parent_block.is_comptime,
    };
    const merges = &child_block.label.?.merges;

    defer child_block.instructions.deinit(sema.gpa);
    defer merges.results.deinit(sema.gpa);
    defer merges.br_list.deinit(sema.gpa);

    _ = try sema.analyzeBody(&child_block, body);

    return sema.analyzeBlockBody(parent_block, src, &child_block, merges);
}

fn resolveBlockBody(
    sema: *Sema,
    parent_block: *Scope.Block,
    src: LazySrcLoc,
    child_block: *Scope.Block,
    body: []const Zir.Inst.Index,
    merges: *Scope.Block.Merges,
) InnerError!*Inst {
    _ = try sema.analyzeBody(child_block, body);
    return sema.analyzeBlockBody(parent_block, src, child_block, merges);
}

fn analyzeBlockBody(
    sema: *Sema,
    parent_block: *Scope.Block,
    src: LazySrcLoc,
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
        const copied_instructions = try sema.arena.dupe(*Inst, child_block.instructions.items);
        try parent_block.instructions.appendSlice(sema.gpa, copied_instructions);
        return copied_instructions[copied_instructions.len - 1];
    }
    if (merges.results.items.len == 1) {
        const last_inst_index = child_block.instructions.items.len - 1;
        const last_inst = child_block.instructions.items[last_inst_index];
        if (last_inst.breakBlock()) |br_block| {
            if (br_block == merges.block_inst) {
                // No need for a block instruction. We can put the new instructions directly
                // into the parent block. Here we omit the break instruction.
                const copied_instructions = try sema.arena.dupe(*Inst, child_block.instructions.items[0..last_inst_index]);
                try parent_block.instructions.appendSlice(sema.gpa, copied_instructions);
                return merges.results.items[0];
            }
        }
    }
    // It is impossible to have the number of results be > 1 in a comptime scope.
    assert(!child_block.is_comptime); // Should already got a compile error in the condbr condition.

    // Need to set the type and emit the Block instruction. This allows machine code generation
    // to emit a jump instruction to after the block when it encounters the break.
    try parent_block.instructions.append(sema.gpa, &merges.block_inst.base);
    const resolved_ty = try sema.resolvePeerTypes(parent_block, src, merges.results.items, .infer);
    merges.block_inst.base.ty = resolved_ty;
    merges.block_inst.body = .{
        .instructions = try sema.arena.dupe(*Inst, child_block.instructions.items),
    };
    // Now that the block has its type resolved, we need to go back into all the break
    // instructions, and insert type coercion on the operands.
    for (merges.br_list.items) |br| {
        if (br.operand.ty.eql(resolved_ty)) {
            // No type coercion needed.
            continue;
        }
        var coerce_block = parent_block.makeSubBlock();
        defer coerce_block.instructions.deinit(sema.gpa);
        const coerced_operand = try sema.coerce(&coerce_block, resolved_ty, br.operand, br.operand.src);
        // If no instructions were produced, such as in the case of a coercion of a
        // constant value to a new type, we can simply point the br operand to it.
        if (coerce_block.instructions.items.len == 0) {
            br.operand = coerced_operand;
            continue;
        }
        assert(coerce_block.instructions.items[coerce_block.instructions.items.len - 1] == coerced_operand);
        // Here we depend on the br instruction having been over-allocated (if necessary)
        // inside zirBreak so that it can be converted into a br_block_flat instruction.
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
                .instructions = try sema.arena.dupe(*Inst, coerce_block.instructions.items),
            },
        };
    }
    return &merges.block_inst.base;
}

fn zirExport(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Export, inst_data.payload_index).data;
    const src = inst_data.src();
    const lhs_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const rhs_src: LazySrcLoc = .{ .node_offset_builtin_call_arg1 = inst_data.src_node };
    const decl_name = sema.code.nullTerminatedString(extra.decl_name);
    if (extra.namespace != .none) {
        return sema.mod.fail(&block.base, src, "TODO: implement exporting with field access", .{});
    }
    const decl = try sema.lookupIdentifier(block, lhs_src, decl_name);
    const options = try sema.resolveInstConst(block, rhs_src, extra.options);
    const struct_obj = options.ty.castTag(.@"struct").?.data;
    const fields = options.val.castTag(.@"struct").?.data[0..struct_obj.fields.count()];
    const name_index = struct_obj.fields.getIndex("name").?;
    const linkage_index = struct_obj.fields.getIndex("linkage").?;
    const section_index = struct_obj.fields.getIndex("section").?;
    const export_name = try fields[name_index].toAllocatedBytes(sema.arena);
    const linkage = fields[linkage_index].toEnum(
        struct_obj.fields.values()[linkage_index].ty,
        std.builtin.GlobalLinkage,
    );

    if (linkage != .Strong) {
        return sema.mod.fail(&block.base, src, "TODO: implement exporting with non-strong linkage", .{});
    }
    if (!fields[section_index].isNull()) {
        return sema.mod.fail(&block.base, src, "TODO: implement exporting with linksection", .{});
    }

    try sema.mod.analyzeExport(&block.base, src, export_name, decl);
}

fn zirSetAlignStack(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src: LazySrcLoc = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirSetAlignStack", .{});
}

fn zirSetCold(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const is_cold = try sema.resolveConstBool(block, operand_src, inst_data.operand);
    const func = sema.func orelse return; // does nothing outside a function
    func.is_cold = is_cold;
}

fn zirSetFloatMode(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src: LazySrcLoc = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirSetFloatMode", .{});
}

fn zirSetRuntimeSafety(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    block.want_safety = try sema.resolveConstBool(block, operand_src, inst_data.operand);
}

fn zirBreakpoint(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const src_node = sema.code.instructions.items(.data)[inst].node;
    const src: LazySrcLoc = .{ .node_offset = src_node };
    try sema.requireRuntimeBlock(block, src);
    _ = try block.addNoOp(src, Type.initTag(.void), .breakpoint);
}

fn zirFence(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const src_node = sema.code.instructions.items(.data)[inst].node;
    const src: LazySrcLoc = .{ .node_offset = src_node };
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirFence", .{});
}

fn zirBreak(sema: *Sema, start_block: *Scope.Block, inst: Zir.Inst.Index) InnerError!Zir.Inst.Index {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].@"break";
    const src = sema.src;
    const operand = try sema.resolveInst(inst_data.operand);
    const zir_block = inst_data.block_inst;

    var block = start_block;
    while (true) {
        if (block.label) |label| {
            if (label.zir_block == zir_block) {
                // Here we add a br instruction, but we over-allocate a little bit
                // (if necessary) to make it possible to convert the instruction into
                // a br_block_flat instruction later.
                const br = @ptrCast(*Inst.Br, try sema.arena.alignedAlloc(
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
                try start_block.instructions.append(sema.gpa, &br.base);
                try label.merges.results.append(sema.gpa, operand);
                try label.merges.br_list.append(sema.gpa, br);
                return inst;
            }
        }
        block = block.parent.?;
    }
}

fn zirDbgStmt(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    // We do not set sema.src here because dbg_stmt instructions are only emitted for
    // ZIR code that possibly will need to generate runtime code. So error messages
    // and other source locations must not rely on sema.src being set from dbg_stmt
    // instructions.
    if (block.is_comptime) return;

    const inst_data = sema.code.instructions.items(.data)[inst].dbg_stmt;
    _ = try block.addDbgStmt(.unneeded, inst_data.line, inst_data.column);
}

fn zirDeclRef(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].str_tok;
    const src = inst_data.src();
    const decl_name = inst_data.get(sema.code);
    const decl = try sema.lookupIdentifier(block, src, decl_name);
    return sema.analyzeDeclRef(block, src, decl);
}

fn zirDeclVal(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].str_tok;
    const src = inst_data.src();
    const decl_name = inst_data.get(sema.code);
    const decl = try sema.lookupIdentifier(block, src, decl_name);
    return sema.analyzeDeclVal(block, src, decl);
}

fn lookupIdentifier(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, name: []const u8) !*Decl {
    // TODO emit a compile error if more than one decl would be matched.
    var namespace = sema.namespace;
    while (true) {
        if (try sema.lookupInNamespace(namespace, name)) |decl| {
            return decl;
        }
        namespace = namespace.parent orelse break;
    }
    return sema.mod.fail(&block.base, src, "use of undeclared identifier '{s}'", .{name});
}

/// This looks up a member of a specific namespace. It is affected by `usingnamespace` but
/// only for ones in the specified namespace.
fn lookupInNamespace(
    sema: *Sema,
    namespace: *Scope.Namespace,
    ident_name: []const u8,
) InnerError!?*Decl {
    const namespace_decl = namespace.getDecl();
    if (namespace_decl.analysis == .file_failure) {
        try sema.mod.declareDeclDependency(sema.owner_decl, namespace_decl);
        return error.AnalysisFail;
    }

    // TODO implement usingnamespace
    if (namespace.decls.get(ident_name)) |decl| {
        try sema.mod.declareDeclDependency(sema.owner_decl, decl);
        return decl;
    }
    log.debug("{*} ({s}) depends on non-existence of '{s}' in {*} ({s})", .{
        sema.owner_decl, sema.owner_decl.name, ident_name, namespace_decl, namespace_decl.name,
    });
    // TODO This dependency is too strong. Really, it should only be a dependency
    // on the non-existence of `ident_name` in the namespace. We can lessen the number of
    // outdated declarations by making this dependency more sophisticated.
    try sema.mod.declareDeclDependency(sema.owner_decl, namespace_decl);
    return null;
}

fn zirCall(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    modifier: std.builtin.CallOptions.Modifier,
    ensure_result_used: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const func_src: LazySrcLoc = .{ .node_offset_call_func = inst_data.src_node };
    const call_src = inst_data.src();
    const extra = sema.code.extraData(Zir.Inst.Call, inst_data.payload_index);
    const args = sema.code.refSlice(extra.end, extra.data.args_len);

    const func = try sema.resolveInst(extra.data.callee);
    // TODO handle function calls of generic functions
    const resolved_args = try sema.arena.alloc(*Inst, args.len);
    for (args) |zir_arg, i| {
        // the args are already casted to the result of a param type instruction.
        resolved_args[i] = try sema.resolveInst(zir_arg);
    }

    return sema.analyzeCall(block, func, func_src, call_src, modifier, ensure_result_used, resolved_args);
}

fn analyzeCall(
    sema: *Sema,
    block: *Scope.Block,
    func: *ir.Inst,
    func_src: LazySrcLoc,
    call_src: LazySrcLoc,
    modifier: std.builtin.CallOptions.Modifier,
    ensure_result_used: bool,
    args: []const *ir.Inst,
) InnerError!*ir.Inst {
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
        if (args.len < fn_params_len) {
            // TODO add error note: declared here
            return sema.mod.fail(
                &block.base,
                func_src,
                "expected at least {d} argument(s), found {d}",
                .{ fn_params_len, args.len },
            );
        }
    } else if (fn_params_len != args.len) {
        // TODO add error note: declared here
        return sema.mod.fail(
            &block.base,
            func_src,
            "expected {d} argument(s), found {d}",
            .{ fn_params_len, args.len },
        );
    }

    switch (modifier) {
        .auto,
        .always_inline,
        .compile_time,
        => {},

        .async_kw,
        .never_tail,
        .never_inline,
        .no_async,
        .always_tail,
        => return sema.mod.fail(&block.base, call_src, "TODO implement call with modifier {}", .{
            modifier,
        }),
    }

    const ret_type = func.ty.fnReturnType();

    const is_comptime_call = block.is_comptime or modifier == .compile_time;
    const is_inline_call = is_comptime_call or modifier == .always_inline or
        func.ty.fnCallingConvention() == .Inline;
    const result: *Inst = if (is_inline_call) res: {
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
        const block_inst = try sema.arena.create(Inst.Block);
        block_inst.* = .{
            .base = .{
                .tag = Inst.Block.base_tag,
                .ty = ret_type,
                .src = call_src,
            },
            .body = undefined,
        };
        // This one is shared among sub-blocks within the same callee, but not
        // shared among the entire inline/comptime call stack.
        var inlining: Scope.Block.Inlining = .{
            .merges = .{
                .results = .{},
                .br_list = .{},
                .block_inst = block_inst,
            },
        };
        // In order to save a bit of stack space, directly modify Sema rather
        // than create a child one.
        const parent_zir = sema.code;
        sema.code = module_fn.owner_decl.namespace.file_scope.zir;
        defer sema.code = parent_zir;

        const parent_inst_map = sema.inst_map;
        sema.inst_map = .{};
        defer {
            sema.inst_map.deinit(sema.gpa);
            sema.inst_map = parent_inst_map;
        }

        const parent_namespace = sema.namespace;
        sema.namespace = module_fn.owner_decl.namespace;
        defer sema.namespace = parent_namespace;

        const parent_func = sema.func;
        sema.func = module_fn;
        defer sema.func = parent_func;

        const parent_param_inst_list = sema.param_inst_list;
        sema.param_inst_list = args;
        defer sema.param_inst_list = parent_param_inst_list;

        const parent_next_arg_index = sema.next_arg_index;
        sema.next_arg_index = 0;
        defer sema.next_arg_index = parent_next_arg_index;

        var child_block: Scope.Block = .{
            .parent = null,
            .sema = sema,
            .src_decl = module_fn.owner_decl,
            .instructions = .{},
            .label = null,
            .inlining = &inlining,
            .is_comptime = is_comptime_call,
        };

        const merges = &child_block.inlining.?.merges;

        defer child_block.instructions.deinit(sema.gpa);
        defer merges.results.deinit(sema.gpa);
        defer merges.br_list.deinit(sema.gpa);

        try sema.emitBackwardBranch(&child_block, call_src);

        // This will have return instructions analyzed as break instructions to
        // the block_inst above.
        try sema.analyzeFnBody(&child_block, module_fn.zir_body_inst);

        const result = try sema.analyzeBlockBody(block, call_src, &child_block, merges);

        break :res result;
    } else res: {
        try sema.requireRuntimeBlock(block, call_src);
        break :res try block.addCall(call_src, ret_type, func, args);
    };

    if (ensure_result_used) {
        try sema.ensureResultUsed(block, result, call_src);
    }
    return result;
}

fn zirIntType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    _ = block;
    const tracy = trace(@src());
    defer tracy.end();

    const int_type = sema.code.instructions.items(.data)[inst].int_type;
    const src = int_type.src();
    const ty = try Module.makeIntType(sema.arena, int_type.signedness, int_type.bit_count);

    return sema.mod.constType(sema.arena, src, ty);
}

fn zirOptionalType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const child_type = try sema.resolveType(block, src, inst_data.operand);
    const opt_type = try sema.mod.optionalType(sema.arena, child_type);

    return sema.mod.constType(sema.arena, src, opt_type);
}

fn zirElemType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const array_type = try sema.resolveType(block, src, inst_data.operand);
    const elem_type = array_type.elemType();
    return sema.mod.constType(sema.arena, src, elem_type);
}

fn zirVectorType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const elem_type_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const len_src: LazySrcLoc = .{ .node_offset_builtin_call_arg1 = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    const len = try sema.resolveAlreadyCoercedInt(block, len_src, extra.lhs, u32);
    const elem_type = try sema.resolveType(block, elem_type_src, extra.rhs);
    const vector_type = try Type.Tag.vector.create(sema.arena, .{
        .len = len,
        .elem_type = elem_type,
    });
    return sema.mod.constType(sema.arena, src, vector_type);
}

fn zirArrayType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    // TODO these should be lazily evaluated
    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const len = try sema.resolveInstConst(block, .unneeded, bin_inst.lhs);
    const elem_type = try sema.resolveType(block, .unneeded, bin_inst.rhs);
    const array_ty = try sema.mod.arrayType(sema.arena, len.val.toUnsignedInt(), null, elem_type);

    return sema.mod.constType(sema.arena, .unneeded, array_ty);
}

fn zirArrayTypeSentinel(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    // TODO these should be lazily evaluated
    const inst_data = sema.code.instructions.items(.data)[inst].array_type_sentinel;
    const len = try sema.resolveInstConst(block, .unneeded, inst_data.len);
    const extra = sema.code.extraData(Zir.Inst.ArrayTypeSentinel, inst_data.payload_index).data;
    const sentinel = try sema.resolveInstConst(block, .unneeded, extra.sentinel);
    const elem_type = try sema.resolveType(block, .unneeded, extra.elem_type);
    const array_ty = try sema.mod.arrayType(sema.arena, len.val.toUnsignedInt(), sentinel.val, elem_type);

    return sema.mod.constType(sema.arena, .unneeded, array_ty);
}

fn zirAnyframeType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_anyframe_type = inst_data.src_node };
    const return_type = try sema.resolveType(block, operand_src, inst_data.operand);
    const anyframe_type = try Type.Tag.anyframe_T.create(sema.arena, return_type);

    return sema.mod.constType(sema.arena, src, anyframe_type);
}

fn zirErrorUnionType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    const src: LazySrcLoc = .{ .node_offset_bin_op = inst_data.src_node };
    const lhs_src: LazySrcLoc = .{ .node_offset_bin_lhs = inst_data.src_node };
    const rhs_src: LazySrcLoc = .{ .node_offset_bin_rhs = inst_data.src_node };
    const error_union = try sema.resolveType(block, lhs_src, extra.lhs);
    const payload = try sema.resolveType(block, rhs_src, extra.rhs);

    if (error_union.zigTypeTag() != .ErrorSet) {
        return sema.mod.fail(&block.base, lhs_src, "expected error set type, found {}", .{
            error_union.elemType(),
        });
    }
    const err_union_ty = try sema.mod.errorUnionType(sema.arena, error_union, payload);
    return sema.mod.constType(sema.arena, src, err_union_ty);
}

fn zirErrorValue(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    _ = block;
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].str_tok;
    const src = inst_data.src();

    // Create an anonymous error set type with only this error value, and return the value.
    const kv = try sema.mod.getErrorValue(inst_data.get(sema.code));
    const result_type = try Type.Tag.error_set_single.create(sema.arena, kv.key);
    return sema.mod.constInst(sema.arena, src, .{
        .ty = result_type,
        .val = try Value.Tag.@"error".create(sema.arena, .{
            .name = kv.key,
        }),
    });
}

fn zirErrorToInt(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const op = try sema.resolveInst(inst_data.operand);
    const op_coerced = try sema.coerce(block, Type.initTag(.anyerror), op, operand_src);
    const result_ty = Type.initTag(.u16);

    if (try sema.resolvePossiblyUndefinedValue(block, src, op_coerced)) |val| {
        if (val.isUndef()) {
            return sema.mod.constUndef(sema.arena, src, result_ty);
        }
        const payload = try sema.arena.create(Value.Payload.U64);
        payload.* = .{
            .base = .{ .tag = .int_u64 },
            .data = (try sema.mod.getErrorValue(val.castTag(.@"error").?.data.name)).value,
        };
        return sema.mod.constInst(sema.arena, src, .{
            .ty = result_ty,
            .val = Value.initPayload(&payload.base),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, result_ty, .bitcast, op_coerced);
}

fn zirIntToError(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };

    const op = try sema.resolveInst(inst_data.operand);

    if (try sema.resolveDefinedValue(block, operand_src, op)) |value| {
        const int = value.toUnsignedInt();
        if (int > sema.mod.global_error_set.count() or int == 0)
            return sema.mod.fail(&block.base, operand_src, "integer value {d} represents no error", .{int});
        const payload = try sema.arena.create(Value.Payload.Error);
        payload.* = .{
            .base = .{ .tag = .@"error" },
            .data = .{ .name = sema.mod.error_name_list.items[@intCast(usize, int)] },
        };
        return sema.mod.constInst(sema.arena, src, .{
            .ty = Type.initTag(.anyerror),
            .val = Value.initPayload(&payload.base),
        });
    }
    try sema.requireRuntimeBlock(block, src);
    if (block.wantSafety()) {
        return sema.mod.fail(&block.base, src, "TODO: get max errors in compilation", .{});
        // const is_gt_max = @panic("TODO get max errors in compilation");
        // try sema.addSafetyCheck(block, is_gt_max, .invalid_error_code);
    }
    return block.addUnOp(src, Type.initTag(.anyerror), .bitcast, op);
}

fn zirMergeErrorSets(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    const src: LazySrcLoc = .{ .node_offset_bin_op = inst_data.src_node };
    const lhs_src: LazySrcLoc = .{ .node_offset_bin_lhs = inst_data.src_node };
    const rhs_src: LazySrcLoc = .{ .node_offset_bin_rhs = inst_data.src_node };
    const lhs = try sema.resolveInst(extra.lhs);
    const rhs = try sema.resolveInst(extra.rhs);
    if (rhs.ty.zigTypeTag() == .Bool and lhs.ty.zigTypeTag() == .Bool) {
        const msg = msg: {
            const msg = try sema.mod.errMsg(&block.base, lhs_src, "expected error set type, found 'bool'", .{});
            errdefer msg.destroy(sema.gpa);
            try sema.mod.errNote(&block.base, src, msg, "'||' merges error sets; 'or' performs boolean OR", .{});
            break :msg msg;
        };
        return sema.mod.failWithOwnedErrorMsg(&block.base, msg);
    }
    const rhs_ty = try sema.resolveAirAsType(block, rhs_src, rhs);
    const lhs_ty = try sema.resolveAirAsType(block, lhs_src, lhs);
    if (rhs_ty.zigTypeTag() != .ErrorSet)
        return sema.mod.fail(&block.base, rhs_src, "expected error set type, found {}", .{rhs_ty});
    if (lhs_ty.zigTypeTag() != .ErrorSet)
        return sema.mod.fail(&block.base, lhs_src, "expected error set type, found {}", .{lhs_ty});

    // Anything merged with anyerror is anyerror.
    if (lhs_ty.tag() == .anyerror or rhs_ty.tag() == .anyerror) {
        return sema.mod.constInst(sema.arena, src, .{
            .ty = Type.initTag(.type),
            .val = Value.initTag(.anyerror_type),
        });
    }
    // When we support inferred error sets, we'll want to use a data structure that can
    // represent a merged set of errors without forcing them to be resolved here. Until then
    // we re-use the same data structure that is used for explicit error set declarations.
    var set: std.StringHashMapUnmanaged(void) = .{};
    defer set.deinit(sema.gpa);

    switch (lhs_ty.tag()) {
        .error_set_single => {
            const name = lhs_ty.castTag(.error_set_single).?.data;
            try set.put(sema.gpa, name, {});
        },
        .error_set => {
            const lhs_set = lhs_ty.castTag(.error_set).?.data;
            try set.ensureCapacity(sema.gpa, set.count() + lhs_set.names_len);
            for (lhs_set.names_ptr[0..lhs_set.names_len]) |name| {
                set.putAssumeCapacityNoClobber(name, {});
            }
        },
        else => unreachable,
    }
    switch (rhs_ty.tag()) {
        .error_set_single => {
            const name = rhs_ty.castTag(.error_set_single).?.data;
            try set.put(sema.gpa, name, {});
        },
        .error_set => {
            const rhs_set = rhs_ty.castTag(.error_set).?.data;
            try set.ensureCapacity(sema.gpa, set.count() + rhs_set.names_len);
            for (rhs_set.names_ptr[0..rhs_set.names_len]) |name| {
                set.putAssumeCapacity(name, {});
            }
        },
        else => unreachable,
    }

    const new_names = try sema.arena.alloc([]const u8, set.count());
    var it = set.keyIterator();
    var i: usize = 0;
    while (it.next()) |key| : (i += 1) {
        new_names[i] = key.*;
    }

    const new_error_set = try sema.arena.create(Module.ErrorSet);
    new_error_set.* = .{
        .owner_decl = sema.owner_decl,
        .node_offset = inst_data.src_node,
        .names_ptr = new_names.ptr,
        .names_len = @intCast(u32, new_names.len),
    };
    const error_set_ty = try Type.Tag.error_set.create(sema.arena, new_error_set);
    return sema.mod.constInst(sema.arena, src, .{
        .ty = Type.initTag(.type),
        .val = try Value.Tag.ty.create(sema.arena, error_set_ty),
    });
}

fn zirEnumLiteral(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    _ = block;
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].str_tok;
    const src = inst_data.src();
    const duped_name = try sema.arena.dupe(u8, inst_data.get(sema.code));
    return sema.mod.constInst(sema.arena, src, .{
        .ty = Type.initTag(.enum_literal),
        .val = try Value.Tag.enum_literal.create(sema.arena, duped_name),
    });
}

fn zirEnumToInt(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const mod = sema.mod;
    const arena = sema.arena;
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const operand = try sema.resolveInst(inst_data.operand);

    const enum_tag: *Inst = switch (operand.ty.zigTypeTag()) {
        .Enum => operand,
        .Union => {
            //if (!operand.ty.unionHasTag()) {
            //    return mod.fail(
            //        &block.base,
            //        operand_src,
            //        "untagged union '{}' cannot be converted to integer",
            //        .{dest_ty_src},
            //    );
            //}
            return mod.fail(&block.base, operand_src, "TODO zirEnumToInt for tagged unions", .{});
        },
        else => {
            return mod.fail(&block.base, operand_src, "expected enum or tagged union, found {}", .{
                operand.ty,
            });
        },
    };

    var int_tag_type_buffer: Type.Payload.Bits = undefined;
    const int_tag_ty = try enum_tag.ty.intTagType(&int_tag_type_buffer).copy(arena);

    if (try sema.typeHasOnePossibleValue(block, src, enum_tag.ty)) |opv| {
        return mod.constInst(arena, src, .{
            .ty = int_tag_ty,
            .val = opv,
        });
    }

    if (enum_tag.value()) |enum_tag_val| {
        if (enum_tag_val.castTag(.enum_field_index)) |enum_field_payload| {
            const field_index = enum_field_payload.data;
            switch (enum_tag.ty.tag()) {
                .enum_full => {
                    const enum_full = enum_tag.ty.castTag(.enum_full).?.data;
                    if (enum_full.values.count() != 0) {
                        const val = enum_full.values.keys()[field_index];
                        return mod.constInst(arena, src, .{
                            .ty = int_tag_ty,
                            .val = val,
                        });
                    } else {
                        // Field index and integer values are the same.
                        const val = try Value.Tag.int_u64.create(arena, field_index);
                        return mod.constInst(arena, src, .{
                            .ty = int_tag_ty,
                            .val = val,
                        });
                    }
                },
                .enum_simple => {
                    // Field index and integer values are the same.
                    const val = try Value.Tag.int_u64.create(arena, field_index);
                    return mod.constInst(arena, src, .{
                        .ty = int_tag_ty,
                        .val = val,
                    });
                },
                else => unreachable,
            }
        } else {
            // Assume it is already an integer and return it directly.
            return mod.constInst(arena, src, .{
                .ty = int_tag_ty,
                .val = enum_tag_val,
            });
        }
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, int_tag_ty, .bitcast, enum_tag);
}

fn zirIntToEnum(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const mod = sema.mod;
    const target = mod.getTarget();
    const arena = sema.arena;
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    const src = inst_data.src();
    const dest_ty_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg1 = inst_data.src_node };
    const dest_ty = try sema.resolveType(block, dest_ty_src, extra.lhs);
    const operand = try sema.resolveInst(extra.rhs);

    if (dest_ty.zigTypeTag() != .Enum) {
        return mod.fail(&block.base, dest_ty_src, "expected enum, found {}", .{dest_ty});
    }

    if (dest_ty.isNonexhaustiveEnum()) {
        if (operand.value()) |int_val| {
            return mod.constInst(arena, src, .{
                .ty = dest_ty,
                .val = int_val,
            });
        }
    }

    if (try sema.resolveDefinedValue(block, operand_src, operand)) |int_val| {
        if (!dest_ty.enumHasInt(int_val, target)) {
            const msg = msg: {
                const msg = try mod.errMsg(
                    &block.base,
                    src,
                    "enum '{}' has no tag with value {}",
                    .{ dest_ty, int_val },
                );
                errdefer msg.destroy(sema.gpa);
                try mod.errNoteNonLazy(
                    dest_ty.declSrcLoc(),
                    msg,
                    "enum declared here",
                    .{},
                );
                break :msg msg;
            };
            return mod.failWithOwnedErrorMsg(&block.base, msg);
        }
        return mod.constInst(arena, src, .{
            .ty = dest_ty,
            .val = int_val,
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, dest_ty, .bitcast, operand);
}

/// Pointer in, pointer out.
fn zirOptionalPayloadPtr(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    safety_check: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const optional_ptr = try sema.resolveInst(inst_data.operand);
    assert(optional_ptr.ty.zigTypeTag() == .Pointer);
    const src = inst_data.src();

    const opt_type = optional_ptr.ty.elemType();
    if (opt_type.zigTypeTag() != .Optional) {
        return sema.mod.fail(&block.base, src, "expected optional type, found {}", .{opt_type});
    }

    const child_type = try opt_type.optionalChildAlloc(sema.arena);
    const child_pointer = try sema.mod.simplePtrType(sema.arena, child_type, !optional_ptr.ty.isConstPtr(), .One);

    if (optional_ptr.value()) |pointer_val| {
        const val = try pointer_val.pointerDeref(sema.arena);
        if (val.isNull()) {
            return sema.mod.fail(&block.base, src, "unable to unwrap null", .{});
        }
        // The same Value represents the pointer to the optional and the payload.
        return sema.mod.constInst(sema.arena, src, .{
            .ty = child_pointer,
            .val = pointer_val,
        });
    }

    try sema.requireRuntimeBlock(block, src);
    if (safety_check and block.wantSafety()) {
        const is_non_null = try block.addUnOp(src, Type.initTag(.bool), .is_non_null_ptr, optional_ptr);
        try sema.addSafetyCheck(block, is_non_null, .unwrap_null);
    }
    return block.addUnOp(src, child_pointer, .optional_payload_ptr, optional_ptr);
}

/// Value in, value out.
fn zirOptionalPayload(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    safety_check: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand = try sema.resolveInst(inst_data.operand);
    const opt_type = operand.ty;
    if (opt_type.zigTypeTag() != .Optional) {
        return sema.mod.fail(&block.base, src, "expected optional type, found {}", .{opt_type});
    }

    const child_type = try opt_type.optionalChildAlloc(sema.arena);

    if (operand.value()) |val| {
        if (val.isNull()) {
            return sema.mod.fail(&block.base, src, "unable to unwrap null", .{});
        }
        return sema.mod.constInst(sema.arena, src, .{
            .ty = child_type,
            .val = val,
        });
    }

    try sema.requireRuntimeBlock(block, src);
    if (safety_check and block.wantSafety()) {
        const is_non_null = try block.addUnOp(src, Type.initTag(.bool), .is_non_null, operand);
        try sema.addSafetyCheck(block, is_non_null, .unwrap_null);
    }
    return block.addUnOp(src, child_type, .optional_payload, operand);
}

/// Value in, value out
fn zirErrUnionPayload(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    safety_check: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand = try sema.resolveInst(inst_data.operand);
    if (operand.ty.zigTypeTag() != .ErrorUnion)
        return sema.mod.fail(&block.base, operand.src, "expected error union type, found '{}'", .{operand.ty});

    if (operand.value()) |val| {
        if (val.getError()) |name| {
            return sema.mod.fail(&block.base, src, "caught unexpected error '{s}'", .{name});
        }
        const data = val.castTag(.error_union).?.data;
        return sema.mod.constInst(sema.arena, src, .{
            .ty = operand.ty.castTag(.error_union).?.data.payload,
            .val = data,
        });
    }
    try sema.requireRuntimeBlock(block, src);
    if (safety_check and block.wantSafety()) {
        const is_non_err = try block.addUnOp(src, Type.initTag(.bool), .is_err, operand);
        try sema.addSafetyCheck(block, is_non_err, .unwrap_errunion);
    }
    return block.addUnOp(src, operand.ty.castTag(.error_union).?.data.payload, .unwrap_errunion_payload, operand);
}

/// Pointer in, pointer out.
fn zirErrUnionPayloadPtr(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    safety_check: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand = try sema.resolveInst(inst_data.operand);
    assert(operand.ty.zigTypeTag() == .Pointer);

    if (operand.ty.elemType().zigTypeTag() != .ErrorUnion)
        return sema.mod.fail(&block.base, src, "expected error union type, found {}", .{operand.ty.elemType()});

    const operand_pointer_ty = try sema.mod.simplePtrType(sema.arena, operand.ty.elemType().castTag(.error_union).?.data.payload, !operand.ty.isConstPtr(), .One);

    if (operand.value()) |pointer_val| {
        const val = try pointer_val.pointerDeref(sema.arena);
        if (val.getError()) |name| {
            return sema.mod.fail(&block.base, src, "caught unexpected error '{s}'", .{name});
        }
        const data = val.castTag(.error_union).?.data;
        // The same Value represents the pointer to the error union and the payload.
        return sema.mod.constInst(sema.arena, src, .{
            .ty = operand_pointer_ty,
            .val = try Value.Tag.ref_val.create(
                sema.arena,
                data,
            ),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    if (safety_check and block.wantSafety()) {
        const is_non_err = try block.addUnOp(src, Type.initTag(.bool), .is_err, operand);
        try sema.addSafetyCheck(block, is_non_err, .unwrap_errunion);
    }
    return block.addUnOp(src, operand_pointer_ty, .unwrap_errunion_payload_ptr, operand);
}

/// Value in, value out
fn zirErrUnionCode(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand = try sema.resolveInst(inst_data.operand);
    if (operand.ty.zigTypeTag() != .ErrorUnion)
        return sema.mod.fail(&block.base, src, "expected error union type, found '{}'", .{operand.ty});

    const result_ty = operand.ty.castTag(.error_union).?.data.error_set;

    if (operand.value()) |val| {
        assert(val.getError() != null);
        const data = val.castTag(.error_union).?.data;
        return sema.mod.constInst(sema.arena, src, .{
            .ty = result_ty,
            .val = data,
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, result_ty, .unwrap_errunion_err, operand);
}

/// Pointer in, value out
fn zirErrUnionCodePtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand = try sema.resolveInst(inst_data.operand);
    assert(operand.ty.zigTypeTag() == .Pointer);

    if (operand.ty.elemType().zigTypeTag() != .ErrorUnion)
        return sema.mod.fail(&block.base, src, "expected error union type, found {}", .{operand.ty.elemType()});

    const result_ty = operand.ty.elemType().castTag(.error_union).?.data.error_set;

    if (operand.value()) |pointer_val| {
        const val = try pointer_val.pointerDeref(sema.arena);
        assert(val.getError() != null);
        const data = val.castTag(.error_union).?.data;
        return sema.mod.constInst(sema.arena, src, .{
            .ty = result_ty,
            .val = data,
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, result_ty, .unwrap_errunion_err_ptr, operand);
}

fn zirEnsureErrPayloadVoid(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const src = inst_data.src();
    const operand = try sema.resolveInst(inst_data.operand);
    if (operand.ty.zigTypeTag() != .ErrorUnion)
        return sema.mod.fail(&block.base, src, "expected error union type, found '{}'", .{operand.ty});
    if (operand.ty.castTag(.error_union).?.data.payload.zigTypeTag() != .Void) {
        return sema.mod.fail(&block.base, src, "expression value is ignored", .{});
    }
}

fn zirFunc(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    inferred_error_set: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Func, inst_data.payload_index);
    const param_types = sema.code.refSlice(extra.end, extra.data.param_types_len);

    var body_inst: Zir.Inst.Index = 0;
    var src_locs: Zir.Inst.Func.SrcLocs = undefined;
    if (extra.data.body_len != 0) {
        body_inst = inst;
        const extra_index = extra.end + extra.data.param_types_len + extra.data.body_len;
        src_locs = sema.code.extraData(Zir.Inst.Func.SrcLocs, extra_index).data;
    }

    const cc: std.builtin.CallingConvention = if (sema.owner_decl.is_exported)
        .C
    else
        .Unspecified;

    return sema.funcCommon(
        block,
        inst_data.src_node,
        param_types,
        body_inst,
        extra.data.return_type,
        cc,
        Value.initTag(.null_value),
        false,
        inferred_error_set,
        false,
        src_locs,
        null,
    );
}

fn funcCommon(
    sema: *Sema,
    block: *Scope.Block,
    src_node_offset: i32,
    zir_param_types: []const Zir.Inst.Ref,
    body_inst: Zir.Inst.Index,
    zir_return_type: Zir.Inst.Ref,
    cc: std.builtin.CallingConvention,
    align_val: Value,
    var_args: bool,
    inferred_error_set: bool,
    is_extern: bool,
    src_locs: Zir.Inst.Func.SrcLocs,
    opt_lib_name: ?[]const u8,
) InnerError!*Inst {
    const src: LazySrcLoc = .{ .node_offset = src_node_offset };
    const ret_ty_src: LazySrcLoc = .{ .node_offset_fn_type_ret_ty = src_node_offset };
    const bare_return_type = try sema.resolveType(block, ret_ty_src, zir_return_type);

    const mod = sema.mod;

    const new_func = if (body_inst == 0) undefined else try sema.gpa.create(Module.Fn);
    errdefer if (body_inst != 0) sema.gpa.destroy(new_func);

    const fn_ty: Type = fn_ty: {
        // Hot path for some common function types.
        if (zir_param_types.len == 0 and !var_args and align_val.tag() == .null_value and
            !inferred_error_set)
        {
            if (bare_return_type.zigTypeTag() == .NoReturn and cc == .Unspecified) {
                break :fn_ty Type.initTag(.fn_noreturn_no_args);
            }

            if (bare_return_type.zigTypeTag() == .Void and cc == .Unspecified) {
                break :fn_ty Type.initTag(.fn_void_no_args);
            }

            if (bare_return_type.zigTypeTag() == .NoReturn and cc == .Naked) {
                break :fn_ty Type.initTag(.fn_naked_noreturn_no_args);
            }

            if (bare_return_type.zigTypeTag() == .Void and cc == .C) {
                break :fn_ty Type.initTag(.fn_ccc_void_no_args);
            }
        }

        const param_types = try sema.arena.alloc(Type, zir_param_types.len);
        for (zir_param_types) |param_type, i| {
            // TODO make a compile error from `resolveType` report the source location
            // of the specific parameter. Will need to take a similar strategy as
            // `resolveSwitchItemVal` to avoid resolving the source location unless
            // we actually need to report an error.
            param_types[i] = try sema.resolveType(block, src, param_type);
        }

        if (align_val.tag() != .null_value) {
            return mod.fail(&block.base, src, "TODO implement support for function prototypes to have alignment specified", .{});
        }

        const return_type = if (!inferred_error_set) bare_return_type else blk: {
            const error_set_ty = try Type.Tag.error_set_inferred.create(sema.arena, .{
                .func = new_func,
                .map = .{},
            });
            break :blk try Type.Tag.error_union.create(sema.arena, .{
                .error_set = error_set_ty,
                .payload = bare_return_type,
            });
        };

        break :fn_ty try Type.Tag.function.create(sema.arena, .{
            .param_types = param_types,
            .return_type = return_type,
            .cc = cc,
            .is_var_args = var_args,
        });
    };

    if (opt_lib_name) |lib_name| blk: {
        const lib_name_src: LazySrcLoc = .{ .node_offset_lib_name = src_node_offset };
        log.debug("extern fn symbol expected in lib '{s}'", .{lib_name});
        mod.comp.stage1AddLinkLib(lib_name) catch |err| {
            return mod.fail(&block.base, lib_name_src, "unable to add link lib '{s}': {s}", .{
                lib_name, @errorName(err),
            });
        };
        const target = mod.getTarget();
        if (target_util.is_libc_lib_name(target, lib_name)) {
            if (!mod.comp.bin_file.options.link_libc) {
                return mod.fail(
                    &block.base,
                    lib_name_src,
                    "dependency on libc must be explicitly specified in the build command",
                    .{},
                );
            }
            break :blk;
        }
        if (target_util.is_libcpp_lib_name(target, lib_name)) {
            if (!mod.comp.bin_file.options.link_libcpp) {
                return mod.fail(
                    &block.base,
                    lib_name_src,
                    "dependency on libc++ must be explicitly specified in the build command",
                    .{},
                );
            }
            break :blk;
        }
        if (!target.isWasm() and !mod.comp.bin_file.options.pic) {
            return mod.fail(
                &block.base,
                lib_name_src,
                "dependency on dynamic library '{s}' requires enabling Position Independent Code. Fixed by `-l{s}` or `-fPIC`.",
                .{ lib_name, lib_name },
            );
        }
    }

    if (is_extern) {
        return sema.mod.constInst(sema.arena, src, .{
            .ty = fn_ty,
            .val = try Value.Tag.extern_fn.create(sema.arena, sema.owner_decl),
        });
    }

    if (body_inst == 0) {
        return mod.constType(sema.arena, src, fn_ty);
    }

    const is_inline = fn_ty.fnCallingConvention() == .Inline;
    const anal_state: Module.Fn.Analysis = if (is_inline) .inline_only else .queued;

    const fn_payload = try sema.arena.create(Value.Payload.Function);
    new_func.* = .{
        .state = anal_state,
        .zir_body_inst = body_inst,
        .owner_decl = sema.owner_decl,
        .body = undefined,
        .lbrace_line = src_locs.lbrace_line,
        .rbrace_line = src_locs.rbrace_line,
        .lbrace_column = @truncate(u16, src_locs.columns),
        .rbrace_column = @truncate(u16, src_locs.columns >> 16),
    };
    fn_payload.* = .{
        .base = .{ .tag = .function },
        .data = new_func,
    };
    const result = try sema.mod.constInst(sema.arena, src, .{
        .ty = fn_ty,
        .val = Value.initPayload(&fn_payload.base),
    });
    return result;
}

fn zirAs(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    return sema.analyzeAs(block, .unneeded, bin_inst.lhs, bin_inst.rhs);
}

fn zirAsNode(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const extra = sema.code.extraData(Zir.Inst.As, inst_data.payload_index).data;
    return sema.analyzeAs(block, src, extra.dest_type, extra.operand);
}

fn analyzeAs(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    zir_dest_type: Zir.Inst.Ref,
    zir_operand: Zir.Inst.Ref,
) InnerError!*Inst {
    const dest_type = try sema.resolveType(block, src, zir_dest_type);
    const operand = try sema.resolveInst(zir_operand);
    return sema.coerce(block, dest_type, operand, src);
}

fn zirPtrToInt(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const ptr = try sema.resolveInst(inst_data.operand);
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

fn zirFieldVal(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const field_name_src: LazySrcLoc = .{ .node_offset_field_name = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.Field, inst_data.payload_index).data;
    const field_name = sema.code.nullTerminatedString(extra.field_name_start);
    const object = try sema.resolveInst(extra.lhs);
    const object_ptr = if (object.ty.zigTypeTag() == .Pointer)
        object
    else
        try sema.analyzeRef(block, src, object);
    const result_ptr = try sema.namedFieldPtr(block, src, object_ptr, field_name, field_name_src);
    return sema.analyzeLoad(block, src, result_ptr, result_ptr.src);
}

fn zirFieldPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const field_name_src: LazySrcLoc = .{ .node_offset_field_name = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.Field, inst_data.payload_index).data;
    const field_name = sema.code.nullTerminatedString(extra.field_name_start);
    const object_ptr = try sema.resolveInst(extra.lhs);
    return sema.namedFieldPtr(block, src, object_ptr, field_name, field_name_src);
}

fn zirFieldValNamed(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const field_name_src: LazySrcLoc = .{ .node_offset_builtin_call_arg1 = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.FieldNamed, inst_data.payload_index).data;
    const object = try sema.resolveInst(extra.lhs);
    const field_name = try sema.resolveConstString(block, field_name_src, extra.field_name);
    const object_ptr = try sema.analyzeRef(block, src, object);
    const result_ptr = try sema.namedFieldPtr(block, src, object_ptr, field_name, field_name_src);
    return sema.analyzeLoad(block, src, result_ptr, src);
}

fn zirFieldPtrNamed(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const field_name_src: LazySrcLoc = .{ .node_offset_builtin_call_arg1 = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.FieldNamed, inst_data.payload_index).data;
    const object_ptr = try sema.resolveInst(extra.lhs);
    const field_name = try sema.resolveConstString(block, field_name_src, extra.field_name);
    return sema.namedFieldPtr(block, src, object_ptr, field_name, field_name_src);
}

fn zirIntCast(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const dest_ty_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg1 = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;

    const dest_type = try sema.resolveType(block, dest_ty_src, extra.lhs);
    const operand = try sema.resolveInst(extra.rhs);

    const dest_is_comptime_int = switch (dest_type.zigTypeTag()) {
        .ComptimeInt => true,
        .Int => false,
        else => return sema.mod.fail(
            &block.base,
            dest_ty_src,
            "expected integer type, found '{}'",
            .{dest_type},
        ),
    };

    switch (operand.ty.zigTypeTag()) {
        .ComptimeInt, .Int => {},
        else => return sema.mod.fail(
            &block.base,
            operand_src,
            "expected integer type, found '{}'",
            .{operand.ty},
        ),
    }

    if (operand.value() != null) {
        return sema.coerce(block, dest_type, operand, operand_src);
    } else if (dest_is_comptime_int) {
        return sema.mod.fail(&block.base, src, "unable to cast runtime value to 'comptime_int'", .{});
    }

    return sema.mod.fail(&block.base, src, "TODO implement analyze widen or shorten int", .{});
}

fn zirBitcast(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const dest_ty_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;

    const dest_type = try sema.resolveType(block, dest_ty_src, extra.lhs);
    const operand = try sema.resolveInst(extra.rhs);
    return sema.bitcast(block, dest_type, operand);
}

fn zirFloatCast(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const dest_ty_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg1 = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;

    const dest_type = try sema.resolveType(block, dest_ty_src, extra.lhs);
    const operand = try sema.resolveInst(extra.rhs);

    const dest_is_comptime_float = switch (dest_type.zigTypeTag()) {
        .ComptimeFloat => true,
        .Float => false,
        else => return sema.mod.fail(
            &block.base,
            dest_ty_src,
            "expected float type, found '{}'",
            .{dest_type},
        ),
    };

    switch (operand.ty.zigTypeTag()) {
        .ComptimeFloat, .Float, .ComptimeInt => {},
        else => return sema.mod.fail(
            &block.base,
            operand_src,
            "expected float type, found '{}'",
            .{operand.ty},
        ),
    }

    if (operand.value() != null) {
        return sema.coerce(block, dest_type, operand, operand_src);
    } else if (dest_is_comptime_float) {
        return sema.mod.fail(&block.base, src, "unable to cast runtime value to 'comptime_float'", .{});
    }

    return sema.mod.fail(&block.base, src, "TODO implement analyze widen or shorten float", .{});
}

fn zirElemVal(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const array = try sema.resolveInst(bin_inst.lhs);
    const array_ptr = if (array.ty.zigTypeTag() == .Pointer)
        array
    else
        try sema.analyzeRef(block, sema.src, array);
    const elem_index = try sema.resolveInst(bin_inst.rhs);
    const result_ptr = try sema.elemPtr(block, sema.src, array_ptr, elem_index, sema.src);
    return sema.analyzeLoad(block, sema.src, result_ptr, sema.src);
}

fn zirElemValNode(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const elem_index_src: LazySrcLoc = .{ .node_offset_array_access_index = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    const array = try sema.resolveInst(extra.lhs);
    const array_ptr = if (array.ty.zigTypeTag() == .Pointer)
        array
    else
        try sema.analyzeRef(block, src, array);
    const elem_index = try sema.resolveInst(extra.rhs);
    const result_ptr = try sema.elemPtr(block, src, array_ptr, elem_index, elem_index_src);
    return sema.analyzeLoad(block, src, result_ptr, src);
}

fn zirElemPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const array_ptr = try sema.resolveInst(bin_inst.lhs);
    const elem_index = try sema.resolveInst(bin_inst.rhs);
    return sema.elemPtr(block, sema.src, array_ptr, elem_index, sema.src);
}

fn zirElemPtrNode(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const elem_index_src: LazySrcLoc = .{ .node_offset_array_access_index = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    const array_ptr = try sema.resolveInst(extra.lhs);
    const elem_index = try sema.resolveInst(extra.rhs);
    return sema.elemPtr(block, src, array_ptr, elem_index, elem_index_src);
}

fn zirSliceStart(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const extra = sema.code.extraData(Zir.Inst.SliceStart, inst_data.payload_index).data;
    const array_ptr = try sema.resolveInst(extra.lhs);
    const start = try sema.resolveInst(extra.start);

    return sema.analyzeSlice(block, src, array_ptr, start, null, null, .unneeded);
}

fn zirSliceEnd(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const extra = sema.code.extraData(Zir.Inst.SliceEnd, inst_data.payload_index).data;
    const array_ptr = try sema.resolveInst(extra.lhs);
    const start = try sema.resolveInst(extra.start);
    const end = try sema.resolveInst(extra.end);

    return sema.analyzeSlice(block, src, array_ptr, start, end, null, .unneeded);
}

fn zirSliceSentinel(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const sentinel_src: LazySrcLoc = .{ .node_offset_slice_sentinel = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.SliceSentinel, inst_data.payload_index).data;
    const array_ptr = try sema.resolveInst(extra.lhs);
    const start = try sema.resolveInst(extra.start);
    const end = try sema.resolveInst(extra.end);
    const sentinel = try sema.resolveInst(extra.sentinel);

    return sema.analyzeSlice(block, src, array_ptr, start, end, sentinel, sentinel_src);
}

fn zirSwitchCapture(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    is_multi: bool,
    is_ref: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const zir_datas = sema.code.instructions.items(.data);
    const capture_info = zir_datas[inst].switch_capture;
    const switch_info = zir_datas[capture_info.switch_inst].pl_node;
    const src = switch_info.src();

    _ = is_ref;
    _ = is_multi;
    return sema.mod.fail(&block.base, src, "TODO implement Sema for zirSwitchCapture", .{});
}

fn zirSwitchCaptureElse(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    is_ref: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const zir_datas = sema.code.instructions.items(.data);
    const capture_info = zir_datas[inst].switch_capture;
    const switch_info = zir_datas[capture_info.switch_inst].pl_node;
    const src = switch_info.src();

    _ = is_ref;
    return sema.mod.fail(&block.base, src, "TODO implement Sema for zirSwitchCaptureElse", .{});
}

fn zirSwitchBlock(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    is_ref: bool,
    special_prong: Zir.SpecialProng,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_switch_operand = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.SwitchBlock, inst_data.payload_index);

    const operand_ptr = try sema.resolveInst(extra.data.operand);
    const operand = if (is_ref)
        try sema.analyzeLoad(block, src, operand_ptr, operand_src)
    else
        operand_ptr;

    return sema.analyzeSwitch(
        block,
        operand,
        extra.end,
        special_prong,
        extra.data.cases_len,
        0,
        inst,
        inst_data.src_node,
    );
}

fn zirSwitchBlockMulti(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    is_ref: bool,
    special_prong: Zir.SpecialProng,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_switch_operand = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.SwitchBlockMulti, inst_data.payload_index);

    const operand_ptr = try sema.resolveInst(extra.data.operand);
    const operand = if (is_ref)
        try sema.analyzeLoad(block, src, operand_ptr, operand_src)
    else
        operand_ptr;

    return sema.analyzeSwitch(
        block,
        operand,
        extra.end,
        special_prong,
        extra.data.scalar_cases_len,
        extra.data.multi_cases_len,
        inst,
        inst_data.src_node,
    );
}

fn analyzeSwitch(
    sema: *Sema,
    block: *Scope.Block,
    operand: *Inst,
    extra_end: usize,
    special_prong: Zir.SpecialProng,
    scalar_cases_len: usize,
    multi_cases_len: usize,
    switch_inst: Zir.Inst.Index,
    src_node_offset: i32,
) InnerError!*Inst {
    const gpa = sema.gpa;
    const mod = sema.mod;

    const special: struct { body: []const Zir.Inst.Index, end: usize } = switch (special_prong) {
        .none => .{ .body = &.{}, .end = extra_end },
        .under, .@"else" => blk: {
            const body_len = sema.code.extra[extra_end];
            const extra_body_start = extra_end + 1;
            break :blk .{
                .body = sema.code.extra[extra_body_start..][0..body_len],
                .end = extra_body_start + body_len,
            };
        },
    };

    const src: LazySrcLoc = .{ .node_offset = src_node_offset };
    const special_prong_src: LazySrcLoc = .{ .node_offset_switch_special_prong = src_node_offset };
    const operand_src: LazySrcLoc = .{ .node_offset_switch_operand = src_node_offset };

    // Validate usage of '_' prongs.
    if (special_prong == .under and !operand.ty.isNonexhaustiveEnum()) {
        const msg = msg: {
            const msg = try mod.errMsg(
                &block.base,
                src,
                "'_' prong only allowed when switching on non-exhaustive enums",
                .{},
            );
            errdefer msg.destroy(gpa);
            try mod.errNote(
                &block.base,
                special_prong_src,
                msg,
                "'_' prong here",
                .{},
            );
            break :msg msg;
        };
        return mod.failWithOwnedErrorMsg(&block.base, msg);
    }

    // Validate for duplicate items, missing else prong, and invalid range.
    switch (operand.ty.zigTypeTag()) {
        .Enum => {
            var seen_fields = try gpa.alloc(?Module.SwitchProngSrc, operand.ty.enumFieldCount());
            defer gpa.free(seen_fields);

            mem.set(?Module.SwitchProngSrc, seen_fields, null);

            var extra_index: usize = special.end;
            {
                var scalar_i: u32 = 0;
                while (scalar_i < scalar_cases_len) : (scalar_i += 1) {
                    const item_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
                    extra_index += 1;
                    const body_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    extra_index += body_len;

                    try sema.validateSwitchItemEnum(
                        block,
                        seen_fields,
                        item_ref,
                        src_node_offset,
                        .{ .scalar = scalar_i },
                    );
                }
            }
            {
                var multi_i: u32 = 0;
                while (multi_i < multi_cases_len) : (multi_i += 1) {
                    const items_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const ranges_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const body_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const items = sema.code.refSlice(extra_index, items_len);
                    extra_index += items_len + body_len;

                    for (items) |item_ref, item_i| {
                        try sema.validateSwitchItemEnum(
                            block,
                            seen_fields,
                            item_ref,
                            src_node_offset,
                            .{ .multi = .{ .prong = multi_i, .item = @intCast(u32, item_i) } },
                        );
                    }

                    try sema.validateSwitchNoRange(block, ranges_len, operand.ty, src_node_offset);
                }
            }
            const all_tags_handled = for (seen_fields) |seen_src| {
                if (seen_src == null) break false;
            } else true;

            switch (special_prong) {
                .none => {
                    if (!all_tags_handled) {
                        const msg = msg: {
                            const msg = try mod.errMsg(
                                &block.base,
                                src,
                                "switch must handle all possibilities",
                                .{},
                            );
                            errdefer msg.destroy(sema.gpa);
                            for (seen_fields) |seen_src, i| {
                                if (seen_src != null) continue;

                                const field_name = operand.ty.enumFieldName(i);

                                // TODO have this point to the tag decl instead of here
                                try mod.errNote(
                                    &block.base,
                                    src,
                                    msg,
                                    "unhandled enumeration value: '{s}'",
                                    .{field_name},
                                );
                            }
                            try mod.errNoteNonLazy(
                                operand.ty.declSrcLoc(),
                                msg,
                                "enum '{}' declared here",
                                .{operand.ty},
                            );
                            break :msg msg;
                        };
                        return mod.failWithOwnedErrorMsg(&block.base, msg);
                    }
                },
                .under => {
                    if (all_tags_handled) return mod.fail(
                        &block.base,
                        special_prong_src,
                        "unreachable '_' prong; all cases already handled",
                        .{},
                    );
                },
                .@"else" => {
                    if (all_tags_handled) return mod.fail(
                        &block.base,
                        special_prong_src,
                        "unreachable else prong; all cases already handled",
                        .{},
                    );
                },
            }
        },

        .ErrorSet => return mod.fail(&block.base, src, "TODO validate switch .ErrorSet", .{}),
        .Union => return mod.fail(&block.base, src, "TODO validate switch .Union", .{}),
        .Int, .ComptimeInt => {
            var range_set = RangeSet.init(gpa);
            defer range_set.deinit();

            var extra_index: usize = special.end;
            {
                var scalar_i: u32 = 0;
                while (scalar_i < scalar_cases_len) : (scalar_i += 1) {
                    const item_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
                    extra_index += 1;
                    const body_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    extra_index += body_len;

                    try sema.validateSwitchItem(
                        block,
                        &range_set,
                        item_ref,
                        src_node_offset,
                        .{ .scalar = scalar_i },
                    );
                }
            }
            {
                var multi_i: u32 = 0;
                while (multi_i < multi_cases_len) : (multi_i += 1) {
                    const items_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const ranges_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const body_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const items = sema.code.refSlice(extra_index, items_len);
                    extra_index += items_len;

                    for (items) |item_ref, item_i| {
                        try sema.validateSwitchItem(
                            block,
                            &range_set,
                            item_ref,
                            src_node_offset,
                            .{ .multi = .{ .prong = multi_i, .item = @intCast(u32, item_i) } },
                        );
                    }

                    var range_i: u32 = 0;
                    while (range_i < ranges_len) : (range_i += 1) {
                        const item_first = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
                        extra_index += 1;
                        const item_last = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
                        extra_index += 1;

                        try sema.validateSwitchRange(
                            block,
                            &range_set,
                            item_first,
                            item_last,
                            src_node_offset,
                            .{ .range = .{ .prong = multi_i, .item = range_i } },
                        );
                    }

                    extra_index += body_len;
                }
            }

            check_range: {
                if (operand.ty.zigTypeTag() == .Int) {
                    var arena = std.heap.ArenaAllocator.init(gpa);
                    defer arena.deinit();

                    const min_int = try operand.ty.minInt(&arena, mod.getTarget());
                    const max_int = try operand.ty.maxInt(&arena, mod.getTarget());
                    if (try range_set.spans(min_int, max_int)) {
                        if (special_prong == .@"else") {
                            return mod.fail(
                                &block.base,
                                special_prong_src,
                                "unreachable else prong; all cases already handled",
                                .{},
                            );
                        }
                        break :check_range;
                    }
                }
                if (special_prong != .@"else") {
                    return mod.fail(
                        &block.base,
                        src,
                        "switch must handle all possibilities",
                        .{},
                    );
                }
            }
        },
        .Bool => {
            var true_count: u8 = 0;
            var false_count: u8 = 0;

            var extra_index: usize = special.end;
            {
                var scalar_i: u32 = 0;
                while (scalar_i < scalar_cases_len) : (scalar_i += 1) {
                    const item_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
                    extra_index += 1;
                    const body_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    extra_index += body_len;

                    try sema.validateSwitchItemBool(
                        block,
                        &true_count,
                        &false_count,
                        item_ref,
                        src_node_offset,
                        .{ .scalar = scalar_i },
                    );
                }
            }
            {
                var multi_i: u32 = 0;
                while (multi_i < multi_cases_len) : (multi_i += 1) {
                    const items_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const ranges_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const body_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const items = sema.code.refSlice(extra_index, items_len);
                    extra_index += items_len + body_len;

                    for (items) |item_ref, item_i| {
                        try sema.validateSwitchItemBool(
                            block,
                            &true_count,
                            &false_count,
                            item_ref,
                            src_node_offset,
                            .{ .multi = .{ .prong = multi_i, .item = @intCast(u32, item_i) } },
                        );
                    }

                    try sema.validateSwitchNoRange(block, ranges_len, operand.ty, src_node_offset);
                }
            }
            switch (special_prong) {
                .@"else" => {
                    if (true_count + false_count == 2) {
                        return mod.fail(
                            &block.base,
                            src,
                            "unreachable else prong; all cases already handled",
                            .{},
                        );
                    }
                },
                .under, .none => {
                    if (true_count + false_count < 2) {
                        return mod.fail(
                            &block.base,
                            src,
                            "switch must handle all possibilities",
                            .{},
                        );
                    }
                },
            }
        },
        .EnumLiteral, .Void, .Fn, .Pointer, .Type => {
            if (special_prong != .@"else") {
                return mod.fail(
                    &block.base,
                    src,
                    "else prong required when switching on type '{}'",
                    .{operand.ty},
                );
            }

            var seen_values = ValueSrcMap.init(gpa);
            defer seen_values.deinit();

            var extra_index: usize = special.end;
            {
                var scalar_i: u32 = 0;
                while (scalar_i < scalar_cases_len) : (scalar_i += 1) {
                    const item_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
                    extra_index += 1;
                    const body_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    extra_index += body_len;

                    try sema.validateSwitchItemSparse(
                        block,
                        &seen_values,
                        item_ref,
                        src_node_offset,
                        .{ .scalar = scalar_i },
                    );
                }
            }
            {
                var multi_i: u32 = 0;
                while (multi_i < multi_cases_len) : (multi_i += 1) {
                    const items_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const ranges_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const body_len = sema.code.extra[extra_index];
                    extra_index += 1;
                    const items = sema.code.refSlice(extra_index, items_len);
                    extra_index += items_len + body_len;

                    for (items) |item_ref, item_i| {
                        try sema.validateSwitchItemSparse(
                            block,
                            &seen_values,
                            item_ref,
                            src_node_offset,
                            .{ .multi = .{ .prong = multi_i, .item = @intCast(u32, item_i) } },
                        );
                    }

                    try sema.validateSwitchNoRange(block, ranges_len, operand.ty, src_node_offset);
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
        => return mod.fail(&block.base, operand_src, "invalid switch operand type '{}'", .{
            operand.ty,
        }),
    }

    const block_inst = try sema.arena.create(Inst.Block);
    block_inst.* = .{
        .base = .{
            .tag = Inst.Block.base_tag,
            .ty = undefined, // Set after analysis.
            .src = src,
        },
        .body = undefined,
    };

    var label: Scope.Block.Label = .{
        .zir_block = switch_inst,
        .merges = .{
            .results = .{},
            .br_list = .{},
            .block_inst = block_inst,
        },
    };

    var child_block: Scope.Block = .{
        .parent = block,
        .sema = sema,
        .src_decl = block.src_decl,
        .instructions = .{},
        .label = &label,
        .inlining = block.inlining,
        .is_comptime = block.is_comptime,
    };
    const merges = &child_block.label.?.merges;
    defer child_block.instructions.deinit(gpa);
    defer merges.results.deinit(gpa);
    defer merges.br_list.deinit(gpa);

    if (try sema.resolveDefinedValue(&child_block, src, operand)) |operand_val| {
        var extra_index: usize = special.end;
        {
            var scalar_i: usize = 0;
            while (scalar_i < scalar_cases_len) : (scalar_i += 1) {
                const item_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
                extra_index += 1;
                const body_len = sema.code.extra[extra_index];
                extra_index += 1;
                const body = sema.code.extra[extra_index..][0..body_len];
                extra_index += body_len;

                // Validation above ensured these will succeed.
                const item = sema.resolveInst(item_ref) catch unreachable;
                const item_val = sema.resolveConstValue(&child_block, .unneeded, item) catch unreachable;
                if (operand_val.eql(item_val)) {
                    return sema.resolveBlockBody(block, src, &child_block, body, merges);
                }
            }
        }
        {
            var multi_i: usize = 0;
            while (multi_i < multi_cases_len) : (multi_i += 1) {
                const items_len = sema.code.extra[extra_index];
                extra_index += 1;
                const ranges_len = sema.code.extra[extra_index];
                extra_index += 1;
                const body_len = sema.code.extra[extra_index];
                extra_index += 1;
                const items = sema.code.refSlice(extra_index, items_len);
                extra_index += items_len;
                const body = sema.code.extra[extra_index + 2 * ranges_len ..][0..body_len];

                for (items) |item_ref| {
                    // Validation above ensured these will succeed.
                    const item = sema.resolveInst(item_ref) catch unreachable;
                    const item_val = sema.resolveConstValue(&child_block, item.src, item) catch unreachable;
                    if (operand_val.eql(item_val)) {
                        return sema.resolveBlockBody(block, src, &child_block, body, merges);
                    }
                }

                var range_i: usize = 0;
                while (range_i < ranges_len) : (range_i += 1) {
                    const item_first = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
                    extra_index += 1;
                    const item_last = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
                    extra_index += 1;

                    // Validation above ensured these will succeed.
                    const first_tv = sema.resolveInstConst(&child_block, .unneeded, item_first) catch unreachable;
                    const last_tv = sema.resolveInstConst(&child_block, .unneeded, item_last) catch unreachable;
                    if (Value.compare(operand_val, .gte, first_tv.val) and
                        Value.compare(operand_val, .lte, last_tv.val))
                    {
                        return sema.resolveBlockBody(block, src, &child_block, body, merges);
                    }
                }

                extra_index += body_len;
            }
        }
        return sema.resolveBlockBody(block, src, &child_block, special.body, merges);
    }

    if (scalar_cases_len + multi_cases_len == 0) {
        return sema.resolveBlockBody(block, src, &child_block, special.body, merges);
    }

    try sema.requireRuntimeBlock(block, src);

    // TODO when reworking AIR memory layout make multi cases get generated as cases,
    // not as part of the "else" block.
    const cases = try sema.arena.alloc(Inst.SwitchBr.Case, scalar_cases_len);

    var case_block = child_block.makeSubBlock();
    case_block.runtime_loop = null;
    case_block.runtime_cond = operand.src;
    case_block.runtime_index += 1;
    defer case_block.instructions.deinit(gpa);

    var extra_index: usize = special.end;

    var scalar_i: usize = 0;
    while (scalar_i < scalar_cases_len) : (scalar_i += 1) {
        const item_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
        extra_index += 1;
        const body_len = sema.code.extra[extra_index];
        extra_index += 1;
        const body = sema.code.extra[extra_index..][0..body_len];
        extra_index += body_len;

        case_block.instructions.shrinkRetainingCapacity(0);
        // We validate these above; these two calls are guaranteed to succeed.
        const item = sema.resolveInst(item_ref) catch unreachable;
        const item_val = sema.resolveConstValue(&case_block, .unneeded, item) catch unreachable;

        _ = try sema.analyzeBody(&case_block, body);

        cases[scalar_i] = .{
            .item = item_val,
            .body = .{ .instructions = try sema.arena.dupe(*Inst, case_block.instructions.items) },
        };
    }

    var first_else_body: Body = undefined;
    var prev_condbr: ?*Inst.CondBr = null;

    var multi_i: usize = 0;
    while (multi_i < multi_cases_len) : (multi_i += 1) {
        const items_len = sema.code.extra[extra_index];
        extra_index += 1;
        const ranges_len = sema.code.extra[extra_index];
        extra_index += 1;
        const body_len = sema.code.extra[extra_index];
        extra_index += 1;
        const items = sema.code.refSlice(extra_index, items_len);
        extra_index += items_len;

        case_block.instructions.shrinkRetainingCapacity(0);

        var any_ok: ?*Inst = null;
        const bool_ty = comptime Type.initTag(.bool);

        for (items) |item_ref| {
            const item = try sema.resolveInst(item_ref);
            _ = try sema.resolveConstValue(&child_block, item.src, item);

            const cmp_ok = try case_block.addBinOp(item.src, bool_ty, .cmp_eq, operand, item);
            if (any_ok) |some| {
                any_ok = try case_block.addBinOp(item.src, bool_ty, .bool_or, some, cmp_ok);
            } else {
                any_ok = cmp_ok;
            }
        }

        var range_i: usize = 0;
        while (range_i < ranges_len) : (range_i += 1) {
            const first_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
            extra_index += 1;
            const last_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
            extra_index += 1;

            const item_first = try sema.resolveInst(first_ref);
            const item_last = try sema.resolveInst(last_ref);

            _ = try sema.resolveConstValue(&child_block, item_first.src, item_first);
            _ = try sema.resolveConstValue(&child_block, item_last.src, item_last);

            const range_src = item_first.src;

            // operand >= first and operand <= last
            const range_first_ok = try case_block.addBinOp(
                item_first.src,
                bool_ty,
                .cmp_gte,
                operand,
                item_first,
            );
            const range_last_ok = try case_block.addBinOp(
                item_last.src,
                bool_ty,
                .cmp_lte,
                operand,
                item_last,
            );
            const range_ok = try case_block.addBinOp(
                range_src,
                bool_ty,
                .bool_and,
                range_first_ok,
                range_last_ok,
            );
            if (any_ok) |some| {
                any_ok = try case_block.addBinOp(range_src, bool_ty, .bool_or, some, range_ok);
            } else {
                any_ok = range_ok;
            }
        }

        const new_condbr = try sema.arena.create(Inst.CondBr);
        new_condbr.* = .{
            .base = .{
                .tag = .condbr,
                .ty = Type.initTag(.noreturn),
                .src = src,
            },
            .condition = any_ok.?,
            .then_body = undefined,
            .else_body = undefined,
        };
        try case_block.instructions.append(gpa, &new_condbr.base);

        const cond_body: Body = .{
            .instructions = try sema.arena.dupe(*Inst, case_block.instructions.items),
        };

        case_block.instructions.shrinkRetainingCapacity(0);
        const body = sema.code.extra[extra_index..][0..body_len];
        extra_index += body_len;
        _ = try sema.analyzeBody(&case_block, body);
        new_condbr.then_body = .{
            .instructions = try sema.arena.dupe(*Inst, case_block.instructions.items),
        };
        if (prev_condbr) |condbr| {
            condbr.else_body = cond_body;
        } else {
            first_else_body = cond_body;
        }
        prev_condbr = new_condbr;
    }

    const final_else_body: Body = blk: {
        if (special.body.len != 0) {
            case_block.instructions.shrinkRetainingCapacity(0);
            _ = try sema.analyzeBody(&case_block, special.body);
            const else_body: Body = .{
                .instructions = try sema.arena.dupe(*Inst, case_block.instructions.items),
            };
            if (prev_condbr) |condbr| {
                condbr.else_body = else_body;
                break :blk first_else_body;
            } else {
                break :blk else_body;
            }
        } else {
            break :blk .{ .instructions = &.{} };
        }
    };

    _ = try child_block.addSwitchBr(src, operand, cases, final_else_body);
    return sema.analyzeBlockBody(block, src, &child_block, merges);
}

fn resolveSwitchItemVal(
    sema: *Sema,
    block: *Scope.Block,
    item_ref: Zir.Inst.Ref,
    switch_node_offset: i32,
    switch_prong_src: Module.SwitchProngSrc,
    range_expand: Module.SwitchProngSrc.RangeExpand,
) InnerError!TypedValue {
    const item = try sema.resolveInst(item_ref);
    // We have to avoid the other helper functions here because we cannot construct a LazySrcLoc
    // because we only have the switch AST node. Only if we know for sure we need to report
    // a compile error do we resolve the full source locations.
    if (item.value()) |val| {
        if (val.isUndef()) {
            const src = switch_prong_src.resolve(sema.gpa, block.src_decl, switch_node_offset, range_expand);
            return sema.failWithUseOfUndef(block, src);
        }
        return TypedValue{ .ty = item.ty, .val = val };
    }
    const src = switch_prong_src.resolve(sema.gpa, block.src_decl, switch_node_offset, range_expand);
    return sema.failWithNeededComptime(block, src);
}

fn validateSwitchRange(
    sema: *Sema,
    block: *Scope.Block,
    range_set: *RangeSet,
    first_ref: Zir.Inst.Ref,
    last_ref: Zir.Inst.Ref,
    src_node_offset: i32,
    switch_prong_src: Module.SwitchProngSrc,
) InnerError!void {
    const first_val = (try sema.resolveSwitchItemVal(block, first_ref, src_node_offset, switch_prong_src, .first)).val;
    const last_val = (try sema.resolveSwitchItemVal(block, last_ref, src_node_offset, switch_prong_src, .last)).val;
    const maybe_prev_src = try range_set.add(first_val, last_val, switch_prong_src);
    return sema.validateSwitchDupe(block, maybe_prev_src, switch_prong_src, src_node_offset);
}

fn validateSwitchItem(
    sema: *Sema,
    block: *Scope.Block,
    range_set: *RangeSet,
    item_ref: Zir.Inst.Ref,
    src_node_offset: i32,
    switch_prong_src: Module.SwitchProngSrc,
) InnerError!void {
    const item_val = (try sema.resolveSwitchItemVal(block, item_ref, src_node_offset, switch_prong_src, .none)).val;
    const maybe_prev_src = try range_set.add(item_val, item_val, switch_prong_src);
    return sema.validateSwitchDupe(block, maybe_prev_src, switch_prong_src, src_node_offset);
}

fn validateSwitchItemEnum(
    sema: *Sema,
    block: *Scope.Block,
    seen_fields: []?Module.SwitchProngSrc,
    item_ref: Zir.Inst.Ref,
    src_node_offset: i32,
    switch_prong_src: Module.SwitchProngSrc,
) InnerError!void {
    const mod = sema.mod;
    const item_tv = try sema.resolveSwitchItemVal(block, item_ref, src_node_offset, switch_prong_src, .none);
    const field_index = item_tv.ty.enumTagFieldIndex(item_tv.val) orelse {
        const msg = msg: {
            const src = switch_prong_src.resolve(sema.gpa, block.src_decl, src_node_offset, .none);
            const msg = try mod.errMsg(
                &block.base,
                src,
                "enum '{}' has no tag with value '{}'",
                .{ item_tv.ty, item_tv.val },
            );
            errdefer msg.destroy(sema.gpa);
            try mod.errNoteNonLazy(
                item_tv.ty.declSrcLoc(),
                msg,
                "enum declared here",
                .{},
            );
            break :msg msg;
        };
        return mod.failWithOwnedErrorMsg(&block.base, msg);
    };
    const maybe_prev_src = seen_fields[field_index];
    seen_fields[field_index] = switch_prong_src;
    return sema.validateSwitchDupe(block, maybe_prev_src, switch_prong_src, src_node_offset);
}

fn validateSwitchDupe(
    sema: *Sema,
    block: *Scope.Block,
    maybe_prev_src: ?Module.SwitchProngSrc,
    switch_prong_src: Module.SwitchProngSrc,
    src_node_offset: i32,
) InnerError!void {
    const prev_prong_src = maybe_prev_src orelse return;
    const mod = sema.mod;
    const gpa = sema.gpa;
    const src = switch_prong_src.resolve(gpa, block.src_decl, src_node_offset, .none);
    const prev_src = prev_prong_src.resolve(gpa, block.src_decl, src_node_offset, .none);
    const msg = msg: {
        const msg = try mod.errMsg(
            &block.base,
            src,
            "duplicate switch value",
            .{},
        );
        errdefer msg.destroy(sema.gpa);
        try mod.errNote(
            &block.base,
            prev_src,
            msg,
            "previous value here",
            .{},
        );
        break :msg msg;
    };
    return mod.failWithOwnedErrorMsg(&block.base, msg);
}

fn validateSwitchItemBool(
    sema: *Sema,
    block: *Scope.Block,
    true_count: *u8,
    false_count: *u8,
    item_ref: Zir.Inst.Ref,
    src_node_offset: i32,
    switch_prong_src: Module.SwitchProngSrc,
) InnerError!void {
    const item_val = (try sema.resolveSwitchItemVal(block, item_ref, src_node_offset, switch_prong_src, .none)).val;
    if (item_val.toBool()) {
        true_count.* += 1;
    } else {
        false_count.* += 1;
    }
    if (true_count.* + false_count.* > 2) {
        const src = switch_prong_src.resolve(sema.gpa, block.src_decl, src_node_offset, .none);
        return sema.mod.fail(&block.base, src, "duplicate switch value", .{});
    }
}

const ValueSrcMap = std.HashMap(Value, Module.SwitchProngSrc, Value.HashContext, std.hash_map.default_max_load_percentage);

fn validateSwitchItemSparse(
    sema: *Sema,
    block: *Scope.Block,
    seen_values: *ValueSrcMap,
    item_ref: Zir.Inst.Ref,
    src_node_offset: i32,
    switch_prong_src: Module.SwitchProngSrc,
) InnerError!void {
    const item_val = (try sema.resolveSwitchItemVal(block, item_ref, src_node_offset, switch_prong_src, .none)).val;
    const kv = (try seen_values.fetchPut(item_val, switch_prong_src)) orelse return;
    return sema.validateSwitchDupe(block, kv.value, switch_prong_src, src_node_offset);
}

fn validateSwitchNoRange(
    sema: *Sema,
    block: *Scope.Block,
    ranges_len: u32,
    operand_ty: Type,
    src_node_offset: i32,
) InnerError!void {
    if (ranges_len == 0)
        return;

    const operand_src: LazySrcLoc = .{ .node_offset_switch_operand = src_node_offset };
    const range_src: LazySrcLoc = .{ .node_offset_switch_range = src_node_offset };

    const msg = msg: {
        const msg = try sema.mod.errMsg(
            &block.base,
            operand_src,
            "ranges not allowed when switching on type '{}'",
            .{operand_ty},
        );
        errdefer msg.destroy(sema.gpa);
        try sema.mod.errNote(
            &block.base,
            range_src,
            msg,
            "range here",
            .{},
        );
        break :msg msg;
    };
    return sema.mod.failWithOwnedErrorMsg(&block.base, msg);
}

fn zirHasField(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    _ = extra;
    const src = inst_data.src();

    return sema.mod.fail(&block.base, src, "TODO implement zirHasField", .{});
}

fn zirHasDecl(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    const src = inst_data.src();
    const lhs_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const rhs_src: LazySrcLoc = .{ .node_offset_builtin_call_arg1 = inst_data.src_node };
    const container_type = try sema.resolveType(block, lhs_src, extra.lhs);
    const decl_name = try sema.resolveConstString(block, rhs_src, extra.rhs);
    const mod = sema.mod;
    const arena = sema.arena;

    const namespace = container_type.getNamespace() orelse return mod.fail(
        &block.base,
        lhs_src,
        "expected struct, enum, union, or opaque, found '{}'",
        .{container_type},
    );
    if (try sema.lookupInNamespace(namespace, decl_name)) |decl| {
        if (decl.is_pub or decl.namespace.file_scope == block.base.namespace().file_scope) {
            return mod.constBool(arena, src, true);
        }
    }
    return mod.constBool(arena, src, false);
}

fn zirImport(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const mod = sema.mod;
    const inst_data = sema.code.instructions.items(.data)[inst].str_tok;
    const src = inst_data.src();
    const operand = inst_data.get(sema.code);

    const result = mod.importFile(block.getFileScope(), operand) catch |err| switch (err) {
        error.ImportOutsidePkgPath => {
            return mod.fail(&block.base, src, "import of file outside package path: '{s}'", .{operand});
        },
        else => {
            // TODO: these errors are file system errors; make sure an update() will
            // retry this and not cache the file system error, which may be transient.
            return mod.fail(&block.base, src, "unable to open '{s}': {s}", .{ operand, @errorName(err) });
        },
    };
    try mod.semaFile(result.file);
    const file_root_decl = result.file.root_decl.?;
    try sema.mod.declareDeclDependency(sema.owner_decl, file_root_decl);
    return mod.constType(sema.arena, src, file_root_decl.ty);
}

fn zirRetErrValueCode(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    _ = block;
    _ = inst;
    return sema.mod.fail(&block.base, sema.src, "TODO implement zirRetErrValueCode", .{});
}

fn zirShl(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    _ = block;
    _ = inst;
    return sema.mod.fail(&block.base, sema.src, "TODO implement zirShl", .{});
}

fn zirShr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    _ = inst;
    return sema.mod.fail(&block.base, sema.src, "TODO implement zirShr", .{});
}

fn zirBitwise(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    ir_tag: ir.Inst.Tag,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src: LazySrcLoc = .{ .node_offset_bin_op = inst_data.src_node };
    const lhs_src: LazySrcLoc = .{ .node_offset_bin_lhs = inst_data.src_node };
    const rhs_src: LazySrcLoc = .{ .node_offset_bin_rhs = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    const lhs = try sema.resolveInst(extra.lhs);
    const rhs = try sema.resolveInst(extra.rhs);

    const instructions = &[_]*Inst{ lhs, rhs };
    const resolved_type = try sema.resolvePeerTypes(block, src, instructions, .{ .override = &[_]LazySrcLoc{ lhs_src, rhs_src } });
    const casted_lhs = try sema.coerce(block, resolved_type, lhs, lhs_src);
    const casted_rhs = try sema.coerce(block, resolved_type, rhs, rhs_src);

    const scalar_type = if (resolved_type.zigTypeTag() == .Vector)
        resolved_type.elemType()
    else
        resolved_type;

    const scalar_tag = scalar_type.zigTypeTag();

    if (lhs.ty.zigTypeTag() == .Vector and rhs.ty.zigTypeTag() == .Vector) {
        if (lhs.ty.arrayLen() != rhs.ty.arrayLen()) {
            return sema.mod.fail(&block.base, src, "vector length mismatch: {d} and {d}", .{
                lhs.ty.arrayLen(),
                rhs.ty.arrayLen(),
            });
        }
        return sema.mod.fail(&block.base, src, "TODO implement support for vectors in zirBitwise", .{});
    } else if (lhs.ty.zigTypeTag() == .Vector or rhs.ty.zigTypeTag() == .Vector) {
        return sema.mod.fail(&block.base, src, "mixed scalar and vector operands to binary expression: '{}' and '{}'", .{
            lhs.ty,
            rhs.ty,
        });
    }

    const is_int = scalar_tag == .Int or scalar_tag == .ComptimeInt;

    if (!is_int) {
        return sema.mod.fail(&block.base, src, "invalid operands to binary bitwise expression: '{s}' and '{s}'", .{ @tagName(lhs.ty.zigTypeTag()), @tagName(rhs.ty.zigTypeTag()) });
    }

    if (casted_lhs.value()) |lhs_val| {
        if (casted_rhs.value()) |rhs_val| {
            if (lhs_val.isUndef() or rhs_val.isUndef()) {
                return sema.mod.constUndef(sema.arena, src, resolved_type);
            }
            return sema.mod.fail(&block.base, src, "TODO implement comptime bitwise operations", .{});
        }
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addBinOp(src, scalar_type, ir_tag, casted_lhs, casted_rhs);
}

fn zirBitNot(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    _ = inst;
    return sema.mod.fail(&block.base, sema.src, "TODO implement zirBitNot", .{});
}

fn zirArrayCat(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    _ = inst;
    return sema.mod.fail(&block.base, sema.src, "TODO implement zirArrayCat", .{});
}

fn zirArrayMul(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    _ = inst;
    return sema.mod.fail(&block.base, sema.src, "TODO implement zirArrayMul", .{});
}

fn zirNegate(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    tag_override: Zir.Inst.Tag,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src: LazySrcLoc = .{ .node_offset_bin_op = inst_data.src_node };
    const lhs_src: LazySrcLoc = .{ .node_offset_bin_lhs = inst_data.src_node };
    const rhs_src: LazySrcLoc = .{ .node_offset_bin_rhs = inst_data.src_node };
    const lhs = try sema.resolveInst(.zero);
    const rhs = try sema.resolveInst(inst_data.operand);

    return sema.analyzeArithmetic(block, tag_override, lhs, rhs, src, lhs_src, rhs_src);
}

fn zirArithmetic(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const tag_override = block.sema.code.instructions.items(.tag)[inst];
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    sema.src = .{ .node_offset_bin_op = inst_data.src_node };
    const lhs_src: LazySrcLoc = .{ .node_offset_bin_lhs = inst_data.src_node };
    const rhs_src: LazySrcLoc = .{ .node_offset_bin_rhs = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    const lhs = try sema.resolveInst(extra.lhs);
    const rhs = try sema.resolveInst(extra.rhs);

    return sema.analyzeArithmetic(block, tag_override, lhs, rhs, sema.src, lhs_src, rhs_src);
}

fn zirOverflowArithmetic(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const extra = sema.code.extraData(Zir.Inst.OverflowArithmetic, extended.operand).data;
    const src: LazySrcLoc = .{ .node_offset = extra.node };

    return sema.mod.fail(&block.base, src, "TODO implement Sema.zirOverflowArithmetic", .{});
}

fn analyzeArithmetic(
    sema: *Sema,
    block: *Scope.Block,
    zir_tag: Zir.Inst.Tag,
    lhs: *Inst,
    rhs: *Inst,
    src: LazySrcLoc,
    lhs_src: LazySrcLoc,
    rhs_src: LazySrcLoc,
) InnerError!*Inst {
    const instructions = &[_]*Inst{ lhs, rhs };
    const resolved_type = try sema.resolvePeerTypes(block, src, instructions, .{ .override = &[_]LazySrcLoc{ lhs_src, rhs_src } });
    const casted_lhs = try sema.coerce(block, resolved_type, lhs, lhs_src);
    const casted_rhs = try sema.coerce(block, resolved_type, rhs, rhs_src);

    const scalar_type = if (resolved_type.zigTypeTag() == .Vector)
        resolved_type.elemType()
    else
        resolved_type;

    const scalar_tag = scalar_type.zigTypeTag();

    if (lhs.ty.zigTypeTag() == .Vector and rhs.ty.zigTypeTag() == .Vector) {
        if (lhs.ty.arrayLen() != rhs.ty.arrayLen()) {
            return sema.mod.fail(&block.base, src, "vector length mismatch: {d} and {d}", .{
                lhs.ty.arrayLen(),
                rhs.ty.arrayLen(),
            });
        }
        return sema.mod.fail(&block.base, src, "TODO implement support for vectors in zirBinOp", .{});
    } else if (lhs.ty.zigTypeTag() == .Vector or rhs.ty.zigTypeTag() == .Vector) {
        return sema.mod.fail(&block.base, src, "mixed scalar and vector operands to binary expression: '{}' and '{}'", .{
            lhs.ty,
            rhs.ty,
        });
    }

    const is_int = scalar_tag == .Int or scalar_tag == .ComptimeInt;
    const is_float = scalar_tag == .Float or scalar_tag == .ComptimeFloat;

    if (!is_int and !(is_float and floatOpAllowed(zir_tag))) {
        return sema.mod.fail(&block.base, src, "invalid operands to binary expression: '{s}' and '{s}'", .{ @tagName(lhs.ty.zigTypeTag()), @tagName(rhs.ty.zigTypeTag()) });
    }

    if (casted_lhs.value()) |lhs_val| {
        if (casted_rhs.value()) |rhs_val| {
            if (lhs_val.isUndef() or rhs_val.isUndef()) {
                return sema.mod.constUndef(sema.arena, src, resolved_type);
            }
            // incase rhs is 0, simply return lhs without doing any calculations
            // TODO Once division is implemented we should throw an error when dividing by 0.
            if (rhs_val.compareWithZero(.eq)) {
                switch (zir_tag) {
                    .add, .addwrap, .sub, .subwrap => {
                        return sema.mod.constInst(sema.arena, src, .{
                            .ty = scalar_type,
                            .val = lhs_val,
                        });
                    },
                    else => {},
                }
            }

            const value = switch (zir_tag) {
                .add => blk: {
                    const val = if (is_int)
                        try Module.intAdd(sema.arena, lhs_val, rhs_val)
                    else
                        try Module.floatAdd(sema.arena, scalar_type, src, lhs_val, rhs_val);
                    break :blk val;
                },
                .sub => blk: {
                    const val = if (is_int)
                        try Module.intSub(sema.arena, lhs_val, rhs_val)
                    else
                        try Module.floatSub(sema.arena, scalar_type, src, lhs_val, rhs_val);
                    break :blk val;
                },
                .div => blk: {
                    const val = if (is_int)
                        try Module.intDiv(sema.arena, lhs_val, rhs_val)
                    else
                        try Module.floatDiv(sema.arena, scalar_type, src, lhs_val, rhs_val);
                    break :blk val;
                },
                .mul => blk: {
                    const val = if (is_int)
                        try Module.intMul(sema.arena, lhs_val, rhs_val)
                    else
                        try Module.floatMul(sema.arena, scalar_type, src, lhs_val, rhs_val);
                    break :blk val;
                },
                else => return sema.mod.fail(&block.base, src, "TODO Implement arithmetic operand '{s}'", .{@tagName(zir_tag)}),
            };

            log.debug("{s}({}, {}) result: {}", .{ @tagName(zir_tag), lhs_val, rhs_val, value });

            return sema.mod.constInst(sema.arena, src, .{
                .ty = scalar_type,
                .val = value,
            });
        }
    }

    try sema.requireRuntimeBlock(block, src);
    const ir_tag: Inst.Tag = switch (zir_tag) {
        .add => .add,
        .addwrap => .addwrap,
        .sub => .sub,
        .subwrap => .subwrap,
        .mul => .mul,
        .mulwrap => .mulwrap,
        .div => .div,
        else => return sema.mod.fail(&block.base, src, "TODO implement arithmetic for operand '{s}''", .{@tagName(zir_tag)}),
    };

    return block.addBinOp(src, scalar_type, ir_tag, casted_lhs, casted_rhs);
}

fn zirLoad(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const ptr_src: LazySrcLoc = .{ .node_offset_deref_ptr = inst_data.src_node };
    const ptr = try sema.resolveInst(inst_data.operand);
    return sema.analyzeLoad(block, src, ptr, ptr_src);
}

fn zirAsm(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const extra = sema.code.extraData(Zir.Inst.Asm, extended.operand);
    const src: LazySrcLoc = .{ .node_offset = extra.data.src_node };
    const asm_source_src: LazySrcLoc = .{ .node_offset_asm_source = extra.data.src_node };
    const ret_ty_src: LazySrcLoc = .{ .node_offset_asm_ret_ty = extra.data.src_node };
    const asm_source = try sema.resolveConstString(block, asm_source_src, extra.data.asm_source);
    const outputs_len = @truncate(u5, extended.small);
    const inputs_len = @truncate(u5, extended.small >> 5);
    const clobbers_len = @truncate(u5, extended.small >> 10);
    const is_volatile = @truncate(u1, extended.small >> 15) != 0;

    if (outputs_len > 1) {
        return sema.mod.fail(&block.base, src, "TODO implement Sema for asm with more than 1 output", .{});
    }

    var extra_i = extra.end;
    var output_type_bits = extra.data.output_type_bits;

    const Output = struct { constraint: []const u8, ty: Type };
    const output: ?Output = if (outputs_len == 0) null else blk: {
        const output = sema.code.extraData(Zir.Inst.Asm.Output, extra_i);
        extra_i = output.end;

        const is_type = @truncate(u1, output_type_bits) != 0;
        output_type_bits >>= 1;

        if (!is_type) {
            return sema.mod.fail(&block.base, src, "TODO implement Sema for asm with non `->` output", .{});
        }

        const constraint = sema.code.nullTerminatedString(output.data.constraint);
        break :blk Output{
            .constraint = constraint,
            .ty = try sema.resolveType(block, ret_ty_src, output.data.operand),
        };
    };

    const args = try sema.arena.alloc(*Inst, inputs_len);
    const inputs = try sema.arena.alloc([]const u8, inputs_len);

    for (args) |*arg, arg_i| {
        const input = sema.code.extraData(Zir.Inst.Asm.Input, extra_i);
        extra_i = input.end;

        const name = sema.code.nullTerminatedString(input.data.name);
        _ = name; // TODO: use the name

        arg.* = try sema.resolveInst(input.data.operand);
        inputs[arg_i] = sema.code.nullTerminatedString(input.data.constraint);
    }

    const clobbers = try sema.arena.alloc([]const u8, clobbers_len);
    for (clobbers) |*name| {
        name.* = sema.code.nullTerminatedString(sema.code.extra[extra_i]);
        extra_i += 1;
    }

    try sema.requireRuntimeBlock(block, src);
    const asm_air = try sema.arena.create(Inst.Assembly);
    asm_air.* = .{
        .base = .{
            .tag = .assembly,
            .ty = if (output) |o| o.ty else Type.initTag(.void),
            .src = src,
        },
        .asm_source = asm_source,
        .is_volatile = is_volatile,
        .output_constraint = if (output) |o| o.constraint else null,
        .inputs = inputs,
        .clobbers = clobbers,
        .args = args,
    };
    try block.instructions.append(sema.gpa, &asm_air.base);
    return &asm_air.base;
}

fn zirCmp(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    op: std.math.CompareOperator,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const mod = sema.mod;

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;
    const src: LazySrcLoc = inst_data.src();
    const lhs_src: LazySrcLoc = .{ .node_offset_bin_lhs = inst_data.src_node };
    const rhs_src: LazySrcLoc = .{ .node_offset_bin_rhs = inst_data.src_node };
    const lhs = try sema.resolveInst(extra.lhs);
    const rhs = try sema.resolveInst(extra.rhs);

    const is_equality_cmp = switch (op) {
        .eq, .neq => true,
        else => false,
    };
    const lhs_ty_tag = lhs.ty.zigTypeTag();
    const rhs_ty_tag = rhs.ty.zigTypeTag();
    if (is_equality_cmp and lhs_ty_tag == .Null and rhs_ty_tag == .Null) {
        // null == null, null != null
        return mod.constBool(sema.arena, src, op == .eq);
    } else if (is_equality_cmp and
        ((lhs_ty_tag == .Null and rhs_ty_tag == .Optional) or
        rhs_ty_tag == .Null and lhs_ty_tag == .Optional))
    {
        // comparing null with optionals
        const opt_operand = if (lhs_ty_tag == .Optional) lhs else rhs;
        return sema.analyzeIsNull(block, src, opt_operand, op == .neq);
    } else if (is_equality_cmp and
        ((lhs_ty_tag == .Null and rhs.ty.isCPtr()) or (rhs_ty_tag == .Null and lhs.ty.isCPtr())))
    {
        return mod.fail(&block.base, src, "TODO implement C pointer cmp", .{});
    } else if (lhs_ty_tag == .Null or rhs_ty_tag == .Null) {
        const non_null_type = if (lhs_ty_tag == .Null) rhs.ty else lhs.ty;
        return mod.fail(&block.base, src, "comparison of '{}' with null", .{non_null_type});
    } else if (is_equality_cmp and
        ((lhs_ty_tag == .EnumLiteral and rhs_ty_tag == .Union) or
        (rhs_ty_tag == .EnumLiteral and lhs_ty_tag == .Union)))
    {
        return mod.fail(&block.base, src, "TODO implement equality comparison between a union's tag value and an enum literal", .{});
    } else if (lhs_ty_tag == .ErrorSet and rhs_ty_tag == .ErrorSet) {
        if (!is_equality_cmp) {
            return mod.fail(&block.base, src, "{s} operator not allowed for errors", .{@tagName(op)});
        }
        if (rhs.value()) |rval| {
            if (lhs.value()) |lval| {
                // TODO optimisation oppurtunity: evaluate if std.mem.eql is faster with the names, or calling to Module.getErrorValue to get the values and then compare them is faster
                return mod.constBool(sema.arena, src, std.mem.eql(u8, lval.castTag(.@"error").?.data.name, rval.castTag(.@"error").?.data.name) == (op == .eq));
            }
        }
        try sema.requireRuntimeBlock(block, src);
        return block.addBinOp(src, Type.initTag(.bool), if (op == .eq) .cmp_eq else .cmp_neq, lhs, rhs);
    } else if (lhs.ty.isNumeric() and rhs.ty.isNumeric()) {
        // This operation allows any combination of integer and float types, regardless of the
        // signed-ness, comptime-ness, and bit-width. So peer type resolution is incorrect for
        // numeric types.
        return sema.cmpNumeric(block, src, lhs, rhs, op);
    } else if (lhs_ty_tag == .Type and rhs_ty_tag == .Type) {
        if (!is_equality_cmp) {
            return mod.fail(&block.base, src, "{s} operator not allowed for types", .{@tagName(op)});
        }
        return mod.constBool(sema.arena, src, lhs.value().?.eql(rhs.value().?) == (op == .eq));
    }

    const instructions = &[_]*Inst{ lhs, rhs };
    const resolved_type = try sema.resolvePeerTypes(block, src, instructions, .{ .override = &[_]LazySrcLoc{ lhs_src, rhs_src } });
    if (!resolved_type.isSelfComparable(is_equality_cmp)) {
        return mod.fail(&block.base, src, "operator not allowed for type '{}'", .{resolved_type});
    }

    const casted_lhs = try sema.coerce(block, resolved_type, lhs, lhs_src);
    const casted_rhs = try sema.coerce(block, resolved_type, rhs, rhs_src);

    if (casted_lhs.value()) |lhs_val| {
        if (casted_rhs.value()) |rhs_val| {
            if (lhs_val.isUndef() or rhs_val.isUndef()) {
                return sema.mod.constUndef(sema.arena, src, resolved_type);
            }
            const result = lhs_val.compare(op, rhs_val);
            return sema.mod.constBool(sema.arena, src, result);
        }
    }

    try sema.requireRuntimeBlock(block, src);
    const tag: Inst.Tag = switch (op) {
        .lt => .cmp_lt,
        .lte => .cmp_lte,
        .eq => .cmp_eq,
        .gte => .cmp_gte,
        .gt => .cmp_gt,
        .neq => .cmp_neq,
    };
    const bool_type = Type.initTag(.bool); // TODO handle vectors
    return block.addBinOp(src, bool_type, tag, casted_lhs, casted_rhs);
}

fn zirSizeOf(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const operand_ty = try sema.resolveType(block, operand_src, inst_data.operand);
    const target = sema.mod.getTarget();
    const abi_size = operand_ty.abiSize(target);
    return sema.mod.constIntUnsigned(sema.arena, src, Type.initTag(.comptime_int), abi_size);
}

fn zirBitSizeOf(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const operand_ty = try sema.resolveType(block, operand_src, inst_data.operand);
    const target = sema.mod.getTarget();
    const bit_size = operand_ty.bitSize(target);
    return sema.mod.constIntUnsigned(sema.arena, src, Type.initTag(.comptime_int), bit_size);
}

fn zirThis(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const src: LazySrcLoc = .{ .node_offset = @bitCast(i32, extended.operand) };
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirThis", .{});
}

fn zirRetAddr(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const src: LazySrcLoc = .{ .node_offset = @bitCast(i32, extended.operand) };
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirRetAddr", .{});
}

fn zirBuiltinSrc(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const src: LazySrcLoc = .{ .node_offset = @bitCast(i32, extended.operand) };
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirBuiltinSrc", .{});
}

fn zirTypeInfo(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const ty = try sema.resolveType(block, src, inst_data.operand);
    const type_info_ty = try sema.getBuiltinType(block, src, "TypeInfo");
    const target = sema.mod.getTarget();

    switch (ty.zigTypeTag()) {
        .Fn => {
            const field_values = try sema.arena.alloc(Value, 6);
            // calling_convention: CallingConvention,
            field_values[0] = try Value.Tag.enum_field_index.create(
                sema.arena,
                @enumToInt(ty.fnCallingConvention()),
            );
            // alignment: comptime_int,
            field_values[1] = try Value.Tag.int_u64.create(sema.arena, ty.abiAlignment(target));
            // is_generic: bool,
            field_values[2] = Value.initTag(.bool_false); // TODO
            // is_var_args: bool,
            field_values[3] = Value.initTag(.bool_false); // TODO
            // return_type: ?type,
            field_values[4] = try Value.Tag.ty.create(sema.arena, ty.fnReturnType());
            // args: []const FnArg,
            field_values[5] = Value.initTag(.null_value); // TODO

            return sema.mod.constInst(sema.arena, src, .{
                .ty = type_info_ty,
                .val = try Value.Tag.@"union".create(sema.arena, .{
                    .tag = try Value.Tag.enum_field_index.create(
                        sema.arena,
                        @enumToInt(@typeInfo(std.builtin.TypeInfo).Union.tag_type.?.Fn),
                    ),
                    .val = try Value.Tag.@"struct".create(sema.arena, field_values.ptr),
                }),
            });
        },
        else => |t| return sema.mod.fail(&block.base, src, "TODO: implement zirTypeInfo for {s}", .{
            @tagName(t),
        }),
    }
}

fn zirTypeof(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    _ = block;
    const zir_datas = sema.code.instructions.items(.data);
    const inst_data = zir_datas[inst].un_node;
    const src = inst_data.src();
    const operand = try sema.resolveInst(inst_data.operand);
    return sema.mod.constType(sema.arena, src, operand.ty);
}

fn zirTypeofElem(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    _ = block;
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand_ptr = try sema.resolveInst(inst_data.operand);
    const elem_ty = operand_ptr.ty.elemType();
    return sema.mod.constType(sema.arena, src, elem_ty);
}

fn zirTypeofLog2IntType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirTypeofLog2IntType", .{});
}

fn zirLog2IntType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirLog2IntType", .{});
}

fn zirTypeofPeer(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const extra = sema.code.extraData(Zir.Inst.NodeMultiOp, extended.operand);
    const src: LazySrcLoc = .{ .node_offset = extra.data.src_node };
    const args = sema.code.refSlice(extra.end, extended.small);

    const inst_list = try sema.gpa.alloc(*ir.Inst, args.len);
    defer sema.gpa.free(inst_list);

    for (args) |arg_ref, i| {
        inst_list[i] = try sema.resolveInst(arg_ref);
    }

    const result_type = try sema.resolvePeerTypes(block, src, inst_list, .{ .typeof_builtin_call_node_offset = extra.data.src_node });
    return sema.mod.constType(sema.arena, src, result_type);
}

fn zirBoolNot(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const uncasted_operand = try sema.resolveInst(inst_data.operand);

    const bool_type = Type.initTag(.bool);
    const operand = try sema.coerce(block, bool_type, uncasted_operand, uncasted_operand.src);
    if (try sema.resolveDefinedValue(block, src, operand)) |val| {
        return sema.mod.constBool(sema.arena, src, !val.toBool());
    }
    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, bool_type, .not, operand);
}

fn zirBoolOp(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    comptime is_bool_or: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const src: LazySrcLoc = .unneeded;
    const bool_type = Type.initTag(.bool);
    const bin_inst = sema.code.instructions.items(.data)[inst].bin;
    const uncasted_lhs = try sema.resolveInst(bin_inst.lhs);
    const lhs = try sema.coerce(block, bool_type, uncasted_lhs, uncasted_lhs.src);
    const uncasted_rhs = try sema.resolveInst(bin_inst.rhs);
    const rhs = try sema.coerce(block, bool_type, uncasted_rhs, uncasted_rhs.src);

    if (lhs.value()) |lhs_val| {
        if (rhs.value()) |rhs_val| {
            if (is_bool_or) {
                return sema.mod.constBool(sema.arena, src, lhs_val.toBool() or rhs_val.toBool());
            } else {
                return sema.mod.constBool(sema.arena, src, lhs_val.toBool() and rhs_val.toBool());
            }
        }
    }
    try sema.requireRuntimeBlock(block, src);
    const tag: ir.Inst.Tag = if (is_bool_or) .bool_or else .bool_and;
    return block.addBinOp(src, bool_type, tag, lhs, rhs);
}

fn zirBoolBr(
    sema: *Sema,
    parent_block: *Scope.Block,
    inst: Zir.Inst.Index,
    is_bool_or: bool,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const datas = sema.code.instructions.items(.data);
    const inst_data = datas[inst].bool_br;
    const src: LazySrcLoc = .unneeded;
    const lhs = try sema.resolveInst(inst_data.lhs);
    const extra = sema.code.extraData(Zir.Inst.Block, inst_data.payload_index);
    const body = sema.code.extra[extra.end..][0..extra.data.body_len];

    if (try sema.resolveDefinedValue(parent_block, src, lhs)) |lhs_val| {
        if (lhs_val.toBool() == is_bool_or) {
            return sema.mod.constBool(sema.arena, src, is_bool_or);
        }
        // comptime-known left-hand side. No need for a block here; the result
        // is simply the rhs expression. Here we rely on there only being 1
        // break instruction (`break_inline`).
        return sema.resolveBody(parent_block, body);
    }

    const block_inst = try sema.arena.create(Inst.Block);
    block_inst.* = .{
        .base = .{
            .tag = Inst.Block.base_tag,
            .ty = Type.initTag(.bool),
            .src = src,
        },
        .body = undefined,
    };

    var child_block = parent_block.makeSubBlock();
    child_block.runtime_loop = null;
    child_block.runtime_cond = lhs.src;
    child_block.runtime_index += 1;
    defer child_block.instructions.deinit(sema.gpa);

    var then_block = child_block.makeSubBlock();
    defer then_block.instructions.deinit(sema.gpa);

    var else_block = child_block.makeSubBlock();
    defer else_block.instructions.deinit(sema.gpa);

    const lhs_block = if (is_bool_or) &then_block else &else_block;
    const rhs_block = if (is_bool_or) &else_block else &then_block;

    const lhs_result = try sema.mod.constInst(sema.arena, src, .{
        .ty = Type.initTag(.bool),
        .val = if (is_bool_or) Value.initTag(.bool_true) else Value.initTag(.bool_false),
    });
    _ = try lhs_block.addBr(src, block_inst, lhs_result);

    const rhs_result = try sema.resolveBody(rhs_block, body);
    _ = try rhs_block.addBr(src, block_inst, rhs_result);

    const air_then_body: ir.Body = .{ .instructions = try sema.arena.dupe(*Inst, then_block.instructions.items) };
    const air_else_body: ir.Body = .{ .instructions = try sema.arena.dupe(*Inst, else_block.instructions.items) };
    _ = try child_block.addCondBr(src, lhs, air_then_body, air_else_body);

    block_inst.body = .{
        .instructions = try sema.arena.dupe(*Inst, child_block.instructions.items),
    };
    try parent_block.instructions.append(sema.gpa, &block_inst.base);
    return &block_inst.base;
}

fn zirIsNonNull(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const operand = try sema.resolveInst(inst_data.operand);
    return sema.analyzeIsNull(block, src, operand, true);
}

fn zirIsNonNullPtr(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const ptr = try sema.resolveInst(inst_data.operand);
    const loaded = try sema.analyzeLoad(block, src, ptr, src);
    return sema.analyzeIsNull(block, src, loaded, true);
}

fn zirIsNonErr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const operand = try sema.resolveInst(inst_data.operand);
    return sema.analyzeIsNonErr(block, inst_data.src(), operand);
}

fn zirIsNonErrPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const ptr = try sema.resolveInst(inst_data.operand);
    const loaded = try sema.analyzeLoad(block, src, ptr, src);
    return sema.analyzeIsNonErr(block, src, loaded);
}

fn zirCondbr(
    sema: *Sema,
    parent_block: *Scope.Block,
    inst: Zir.Inst.Index,
) InnerError!Zir.Inst.Index {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    const cond_src: LazySrcLoc = .{ .node_offset_if_cond = inst_data.src_node };
    const extra = sema.code.extraData(Zir.Inst.CondBr, inst_data.payload_index);

    const then_body = sema.code.extra[extra.end..][0..extra.data.then_body_len];
    const else_body = sema.code.extra[extra.end + then_body.len ..][0..extra.data.else_body_len];

    const uncasted_cond = try sema.resolveInst(extra.data.condition);
    const cond = try sema.coerce(parent_block, Type.initTag(.bool), uncasted_cond, cond_src);

    if (try sema.resolveDefinedValue(parent_block, src, cond)) |cond_val| {
        const body = if (cond_val.toBool()) then_body else else_body;
        _ = try sema.analyzeBody(parent_block, body);
        return always_noreturn;
    }

    var sub_block = parent_block.makeSubBlock();
    sub_block.runtime_loop = null;
    sub_block.runtime_cond = cond.src;
    sub_block.runtime_index += 1;
    defer sub_block.instructions.deinit(sema.gpa);

    _ = try sema.analyzeBody(&sub_block, then_body);
    const air_then_body: ir.Body = .{
        .instructions = try sema.arena.dupe(*Inst, sub_block.instructions.items),
    };

    sub_block.instructions.shrinkRetainingCapacity(0);

    _ = try sema.analyzeBody(&sub_block, else_body);
    const air_else_body: ir.Body = .{
        .instructions = try sema.arena.dupe(*Inst, sub_block.instructions.items),
    };

    _ = try parent_block.addCondBr(src, cond, air_then_body, air_else_body);
    return always_noreturn;
}

fn zirUnreachable(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!Zir.Inst.Index {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].@"unreachable";
    const src = inst_data.src();
    const safety_check = inst_data.safety;
    try sema.requireRuntimeBlock(block, src);
    // TODO Add compile error for @optimizeFor occurring too late in a scope.
    if (safety_check and block.wantSafety()) {
        return sema.safetyPanic(block, src, .unreach);
    } else {
        _ = try block.addNoOp(src, Type.initTag(.noreturn), .unreach);
        return always_noreturn;
    }
}

fn zirRetErrValue(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
) InnerError!Zir.Inst.Index {
    const inst_data = sema.code.instructions.items(.data)[inst].str_tok;
    const err_name = inst_data.get(sema.code);
    const src = inst_data.src();

    // Add the error tag to the inferred error set of the in-scope function.
    if (sema.func) |func| {
        if (func.getInferredErrorSet()) |map| {
            _ = try map.getOrPut(sema.gpa, err_name);
        }
    }
    // Return the error code from the function.
    const kv = try sema.mod.getErrorValue(err_name);
    const result_inst = try sema.mod.constInst(sema.arena, src, .{
        .ty = try Type.Tag.error_set_single.create(sema.arena, kv.key),
        .val = try Value.Tag.@"error".create(sema.arena, .{ .name = kv.key }),
    });
    return sema.analyzeRet(block, result_inst, src, true);
}

fn zirRetCoerce(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    need_coercion: bool,
) InnerError!Zir.Inst.Index {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_tok;
    const operand = try sema.resolveInst(inst_data.operand);
    const src = inst_data.src();

    return sema.analyzeRet(block, operand, src, need_coercion);
}

fn zirRetNode(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!Zir.Inst.Index {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const operand = try sema.resolveInst(inst_data.operand);
    const src = inst_data.src();

    return sema.analyzeRet(block, operand, src, false);
}

fn analyzeRet(
    sema: *Sema,
    block: *Scope.Block,
    operand: *Inst,
    src: LazySrcLoc,
    need_coercion: bool,
) InnerError!Zir.Inst.Index {
    if (block.inlining) |inlining| {
        // We are inlining a function call; rewrite the `ret` as a `break`.
        try inlining.merges.results.append(sema.gpa, operand);
        _ = try block.addBr(src, inlining.merges.block_inst, operand);
        return always_noreturn;
    }

    if (need_coercion) {
        if (sema.func) |func| {
            const fn_ty = func.owner_decl.ty;
            const fn_ret_ty = fn_ty.fnReturnType();
            const casted_operand = try sema.coerce(block, fn_ret_ty, operand, src);
            if (fn_ret_ty.zigTypeTag() == .Void)
                _ = try block.addNoOp(src, Type.initTag(.noreturn), .retvoid)
            else
                _ = try block.addUnOp(src, Type.initTag(.noreturn), .ret, casted_operand);
            return always_noreturn;
        }
    }
    _ = try block.addUnOp(src, Type.initTag(.noreturn), .ret, operand);
    return always_noreturn;
}

fn floatOpAllowed(tag: Zir.Inst.Tag) bool {
    // extend this swich as additional operators are implemented
    return switch (tag) {
        .add, .sub, .mul, .div => true,
        else => false,
    };
}

fn zirPtrTypeSimple(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].ptr_type_simple;
    const elem_type = try sema.resolveType(block, .unneeded, inst_data.elem_type);
    const ty = try sema.mod.ptrType(
        sema.arena,
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
    return sema.mod.constType(sema.arena, .unneeded, ty);
}

fn zirPtrType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const src: LazySrcLoc = .unneeded;
    const inst_data = sema.code.instructions.items(.data)[inst].ptr_type;
    const extra = sema.code.extraData(Zir.Inst.PtrType, inst_data.payload_index);

    var extra_i = extra.end;

    const sentinel = if (inst_data.flags.has_sentinel) blk: {
        const ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_i]);
        extra_i += 1;
        break :blk (try sema.resolveInstConst(block, .unneeded, ref)).val;
    } else null;

    const abi_align = if (inst_data.flags.has_align) blk: {
        const ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_i]);
        extra_i += 1;
        break :blk try sema.resolveAlreadyCoercedInt(block, .unneeded, ref, u32);
    } else 0;

    const bit_start = if (inst_data.flags.has_bit_range) blk: {
        const ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_i]);
        extra_i += 1;
        break :blk try sema.resolveAlreadyCoercedInt(block, .unneeded, ref, u16);
    } else 0;

    const bit_end = if (inst_data.flags.has_bit_range) blk: {
        const ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_i]);
        extra_i += 1;
        break :blk try sema.resolveAlreadyCoercedInt(block, .unneeded, ref, u16);
    } else 0;

    if (bit_end != 0 and bit_start >= bit_end * 8)
        return sema.mod.fail(&block.base, src, "bit offset starts after end of host integer", .{});

    const elem_type = try sema.resolveType(block, .unneeded, extra.data.elem_type);

    const ty = try sema.mod.ptrType(
        sema.arena,
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
    return sema.mod.constType(sema.arena, src, ty);
}

fn zirStructInitEmpty(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    const struct_type = try sema.resolveType(block, src, inst_data.operand);

    return sema.mod.constInst(sema.arena, src, .{
        .ty = struct_type,
        .val = Value.initTag(.empty_struct_value),
    });
}

fn zirUnionInitPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirUnionInitPtr", .{});
}

fn zirStructInit(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index, is_ref: bool) InnerError!*Inst {
    const mod = sema.mod;
    const gpa = sema.gpa;
    const zir_datas = sema.code.instructions.items(.data);
    const inst_data = zir_datas[inst].pl_node;
    const extra = sema.code.extraData(Zir.Inst.StructInit, inst_data.payload_index);
    const src = inst_data.src();

    const first_item = sema.code.extraData(Zir.Inst.StructInit.Item, extra.end).data;
    const first_field_type_data = zir_datas[first_item.field_type].pl_node;
    const first_field_type_extra = sema.code.extraData(Zir.Inst.FieldType, first_field_type_data.payload_index).data;
    const unresolved_struct_type = try sema.resolveType(block, src, first_field_type_extra.container_type);
    const struct_ty = try sema.resolveTypeFields(block, src, unresolved_struct_type);
    const struct_obj = struct_ty.castTag(.@"struct").?.data;

    // Maps field index to field_type index of where it was already initialized.
    // For making sure all fields are accounted for and no fields are duplicated.
    const found_fields = try gpa.alloc(Zir.Inst.Index, struct_obj.fields.count());
    defer gpa.free(found_fields);
    mem.set(Zir.Inst.Index, found_fields, 0);

    // The init values to use for the struct instance.
    const field_inits = try gpa.alloc(*ir.Inst, struct_obj.fields.count());
    defer gpa.free(field_inits);

    var field_i: u32 = 0;
    var extra_index = extra.end;

    while (field_i < extra.data.fields_len) : (field_i += 1) {
        const item = sema.code.extraData(Zir.Inst.StructInit.Item, extra_index);
        extra_index = item.end;

        const field_type_data = zir_datas[item.data.field_type].pl_node;
        const field_src: LazySrcLoc = .{ .node_offset_back2tok = field_type_data.src_node };
        const field_type_extra = sema.code.extraData(Zir.Inst.FieldType, field_type_data.payload_index).data;
        const field_name = sema.code.nullTerminatedString(field_type_extra.name_start);
        const field_index = struct_obj.fields.getIndex(field_name) orelse
            return sema.failWithBadFieldAccess(block, struct_obj, field_src, field_name);
        if (found_fields[field_index] != 0) {
            const other_field_type = found_fields[field_index];
            const other_field_type_data = zir_datas[other_field_type].pl_node;
            const other_field_src: LazySrcLoc = .{ .node_offset_back2tok = other_field_type_data.src_node };
            const msg = msg: {
                const msg = try mod.errMsg(&block.base, field_src, "duplicate field", .{});
                errdefer msg.destroy(gpa);
                try mod.errNote(&block.base, other_field_src, msg, "other field here", .{});
                break :msg msg;
            };
            return mod.failWithOwnedErrorMsg(&block.base, msg);
        }
        found_fields[field_index] = item.data.field_type;
        field_inits[field_index] = try sema.resolveInst(item.data.init);
    }

    var root_msg: ?*Module.ErrorMsg = null;

    for (found_fields) |field_type_inst, i| {
        if (field_type_inst != 0) continue;

        // Check if the field has a default init.
        const field = struct_obj.fields.values()[i];
        if (field.default_val.tag() == .unreachable_value) {
            const field_name = struct_obj.fields.keys()[i];
            const template = "missing struct field: {s}";
            const args = .{field_name};
            if (root_msg) |msg| {
                try mod.errNote(&block.base, src, msg, template, args);
            } else {
                root_msg = try mod.errMsg(&block.base, src, template, args);
            }
        } else {
            field_inits[i] = try mod.constInst(sema.arena, src, .{
                .ty = field.ty,
                .val = field.default_val,
            });
        }
    }
    if (root_msg) |msg| {
        const fqn = try struct_obj.getFullyQualifiedName(gpa);
        defer gpa.free(fqn);
        try mod.errNoteNonLazy(
            struct_obj.srcLoc(),
            msg,
            "struct '{s}' declared here",
            .{fqn},
        );
        return mod.failWithOwnedErrorMsg(&block.base, msg);
    }

    if (is_ref) {
        return mod.fail(&block.base, src, "TODO: Sema.zirStructInit is_ref=true", .{});
    }

    const is_comptime = for (field_inits) |field_init| {
        if (field_init.value() == null) {
            break false;
        }
    } else true;

    if (is_comptime) {
        const values = try sema.arena.alloc(Value, field_inits.len);
        for (field_inits) |field_init, i| {
            values[i] = field_init.value().?;
        }
        return mod.constInst(sema.arena, src, .{
            .ty = struct_ty,
            .val = try Value.Tag.@"struct".create(sema.arena, values.ptr),
        });
    }

    return mod.fail(&block.base, src, "TODO: Sema.zirStructInit for runtime-known struct values", .{});
}

fn zirStructInitAnon(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index, is_ref: bool) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();

    _ = is_ref;
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirStructInitAnon", .{});
}

fn zirArrayInit(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index, is_ref: bool) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();

    _ = is_ref;
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirArrayInit", .{});
}

fn zirArrayInitAnon(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index, is_ref: bool) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();

    _ = is_ref;
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirArrayInitAnon", .{});
}

fn zirFieldTypeRef(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirFieldTypeRef", .{});
}

fn zirFieldType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const extra = sema.code.extraData(Zir.Inst.FieldType, inst_data.payload_index).data;
    const src = inst_data.src();
    const field_name = sema.code.nullTerminatedString(extra.name_start);
    const unresolved_struct_type = try sema.resolveType(block, src, extra.container_type);
    if (unresolved_struct_type.zigTypeTag() != .Struct) {
        return sema.mod.fail(&block.base, src, "expected struct; found '{}'", .{
            unresolved_struct_type,
        });
    }
    const struct_ty = try sema.resolveTypeFields(block, src, unresolved_struct_type);
    const struct_obj = struct_ty.castTag(.@"struct").?.data;
    const field = struct_obj.fields.get(field_name) orelse
        return sema.failWithBadFieldAccess(block, struct_obj, src, field_name);
    return sema.mod.constType(sema.arena, src, field.ty);
}

fn zirErrorReturnTrace(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const src: LazySrcLoc = .{ .node_offset = @bitCast(i32, extended.operand) };
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirErrorReturnTrace", .{});
}

fn zirFrame(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const src: LazySrcLoc = .{ .node_offset = @bitCast(i32, extended.operand) };
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirFrame", .{});
}

fn zirFrameAddress(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const src: LazySrcLoc = .{ .node_offset = @bitCast(i32, extended.operand) };
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirFrameAddress", .{});
}

fn zirAlignOf(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirAlignOf", .{});
}

fn zirBoolToInt(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirBoolToInt", .{});
}

fn zirEmbedFile(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirEmbedFile", .{});
}

fn zirErrorName(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirErrorName", .{});
}

fn zirUnaryMath(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirUnaryMath", .{});
}

fn zirTagName(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirTagName", .{});
}

fn zirReify(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirReify", .{});
}

fn zirTypeName(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirTypeName", .{});
}

fn zirFrameType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirFrameType", .{});
}

fn zirFrameSize(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirFrameSize", .{});
}

fn zirFloatToInt(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirFloatToInt", .{});
}

fn zirIntToFloat(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirIntToFloat", .{});
}

fn zirIntToPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();

    const extra = sema.code.extraData(Zir.Inst.Bin, inst_data.payload_index).data;

    const operand_src: LazySrcLoc = .{ .node_offset_builtin_call_arg1 = inst_data.src_node };
    const operand_res = try sema.resolveInst(extra.rhs);
    const operand_coerced = try sema.coerce(block, Type.initTag(.usize), operand_res, operand_src);

    const type_src: LazySrcLoc = .{ .node_offset_builtin_call_arg0 = inst_data.src_node };
    const type_res = try sema.resolveType(block, src, extra.lhs);
    if (type_res.zigTypeTag() != .Pointer)
        return sema.mod.fail(&block.base, type_src, "expected pointer, found '{}'", .{type_res});
    const ptr_align = type_res.ptrAlignment(sema.mod.getTarget());

    if (try sema.resolveDefinedValue(block, operand_src, operand_coerced)) |val| {
        const addr = val.toUnsignedInt();
        if (!type_res.isAllowzeroPtr() and addr == 0)
            return sema.mod.fail(&block.base, operand_src, "pointer type '{}' does not allow address zero", .{type_res});
        if (addr != 0 and addr % ptr_align != 0)
            return sema.mod.fail(&block.base, operand_src, "pointer type '{}' requires aligned address", .{type_res});

        const val_payload = try sema.arena.create(Value.Payload.U64);
        val_payload.* = .{
            .base = .{ .tag = .int_u64 },
            .data = addr,
        };
        return sema.mod.constInst(sema.arena, src, .{
            .ty = type_res,
            .val = Value.initPayload(&val_payload.base),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    if (block.wantSafety()) {
        const zero = try sema.mod.constInst(sema.arena, src, .{
            .ty = Type.initTag(.u64),
            .val = Value.initTag(.zero),
        });
        if (!type_res.isAllowzeroPtr()) {
            const is_non_zero = try block.addBinOp(src, Type.initTag(.bool), .cmp_neq, operand_coerced, zero);
            try sema.addSafetyCheck(block, is_non_zero, .cast_to_null);
        }

        if (ptr_align > 1) {
            const val_payload = try sema.arena.create(Value.Payload.U64);
            val_payload.* = .{
                .base = .{ .tag = .int_u64 },
                .data = ptr_align - 1,
            };
            const align_minus_1 = try sema.mod.constInst(sema.arena, src, .{
                .ty = Type.initTag(.u64),
                .val = Value.initPayload(&val_payload.base),
            });
            const remainder = try block.addBinOp(src, Type.initTag(.u64), .bit_and, operand_coerced, align_minus_1);
            const is_aligned = try block.addBinOp(src, Type.initTag(.bool), .cmp_eq, remainder, zero);
            try sema.addSafetyCheck(block, is_aligned, .incorrect_alignment);
        }
    }
    return block.addUnOp(src, type_res, .bitcast, operand_coerced);
}

fn zirErrSetCast(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirErrSetCast", .{});
}

fn zirPtrCast(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirPtrCast", .{});
}

fn zirTruncate(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirTruncate", .{});
}

fn zirAlignCast(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirAlignCast", .{});
}

fn zirClz(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirClz", .{});
}

fn zirCtz(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirCtz", .{});
}

fn zirPopCount(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirPopCount", .{});
}

fn zirByteSwap(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirByteSwap", .{});
}

fn zirBitReverse(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirBitReverse", .{});
}

fn zirDivExact(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirDivExact", .{});
}

fn zirDivFloor(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirDivFloor", .{});
}

fn zirDivTrunc(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirDivTrunc", .{});
}

fn zirMod(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirMod", .{});
}

fn zirRem(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirRem", .{});
}

fn zirShlExact(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirShlExact", .{});
}

fn zirShrExact(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirShrExact", .{});
}

fn zirBitOffsetOf(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirBitOffsetOf", .{});
}

fn zirOffsetOf(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirOffsetOf", .{});
}

fn zirCmpxchg(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirCmpxchg", .{});
}

fn zirSplat(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirSplat", .{});
}

fn zirReduce(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirReduce", .{});
}

fn zirShuffle(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirShuffle", .{});
}

fn zirAtomicLoad(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirAtomicLoad", .{});
}

fn zirAtomicRmw(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirAtomicRmw", .{});
}

fn zirAtomicStore(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirAtomicStore", .{});
}

fn zirMulAdd(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirMulAdd", .{});
}

fn zirBuiltinCall(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirBuiltinCall", .{});
}

fn zirFieldPtrType(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirFieldPtrType", .{});
}

fn zirFieldParentPtr(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirFieldParentPtr", .{});
}

fn zirMemcpy(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirMemcpy", .{});
}

fn zirMemset(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirMemset", .{});
}

fn zirBuiltinAsyncCall(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].pl_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirBuiltinAsyncCall", .{});
}

fn zirResume(sema: *Sema, block: *Scope.Block, inst: Zir.Inst.Index) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirResume", .{});
}

fn zirAwait(
    sema: *Sema,
    block: *Scope.Block,
    inst: Zir.Inst.Index,
    is_nosuspend: bool,
) InnerError!*Inst {
    const inst_data = sema.code.instructions.items(.data)[inst].un_node;
    const src = inst_data.src();

    _ = is_nosuspend;
    return sema.mod.fail(&block.base, src, "TODO: Sema.zirAwait", .{});
}

fn zirVarExtended(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const extra = sema.code.extraData(Zir.Inst.ExtendedVar, extended.operand);
    const src = sema.src;
    const ty_src: LazySrcLoc = src; // TODO add a LazySrcLoc that points at type
    const mut_src: LazySrcLoc = src; // TODO add a LazySrcLoc that points at mut token
    const init_src: LazySrcLoc = src; // TODO add a LazySrcLoc that points at init expr
    const small = @bitCast(Zir.Inst.ExtendedVar.Small, extended.small);
    const var_ty = try sema.resolveType(block, ty_src, extra.data.var_type);

    var extra_index: usize = extra.end;

    const lib_name: ?[]const u8 = if (small.has_lib_name) blk: {
        const lib_name = sema.code.nullTerminatedString(sema.code.extra[extra_index]);
        extra_index += 1;
        break :blk lib_name;
    } else null;

    // ZIR supports encoding this information but it is not used; the information
    // is encoded via the Decl entry.
    assert(!small.has_align);
    //const align_val: Value = if (small.has_align) blk: {
    //    const align_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
    //    extra_index += 1;
    //    const align_tv = try sema.resolveInstConst(block, align_src, align_ref);
    //    break :blk align_tv.val;
    //} else Value.initTag(.null_value);

    const init_val: Value = if (small.has_init) blk: {
        const init_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
        extra_index += 1;
        const init_tv = try sema.resolveInstConst(block, init_src, init_ref);
        break :blk init_tv.val;
    } else Value.initTag(.unreachable_value);

    if (!var_ty.isValidVarType(small.is_extern)) {
        return sema.mod.fail(&block.base, mut_src, "variable of type '{}' must be const", .{
            var_ty,
        });
    }

    if (lib_name != null) {
        // Look at the sema code for functions which has this logic, it just needs to
        // be extracted and shared by both var and func
        return sema.mod.fail(&block.base, src, "TODO: handle var with lib_name in Sema", .{});
    }

    const new_var = try sema.gpa.create(Module.Var);
    new_var.* = .{
        .owner_decl = sema.owner_decl,
        .init = init_val,
        .is_extern = small.is_extern,
        .is_mutable = true, // TODO get rid of this unused field
        .is_threadlocal = small.is_threadlocal,
    };
    const result = try sema.mod.constInst(sema.arena, src, .{
        .ty = var_ty,
        .val = try Value.Tag.variable.create(sema.arena, new_var),
    });
    return result;
}

fn zirFuncExtended(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
    inst: Zir.Inst.Index,
) InnerError!*Inst {
    const tracy = trace(@src());
    defer tracy.end();

    const extra = sema.code.extraData(Zir.Inst.ExtendedFunc, extended.operand);
    const src: LazySrcLoc = .{ .node_offset = extra.data.src_node };
    const cc_src: LazySrcLoc = .{ .node_offset_fn_type_cc = extra.data.src_node };
    const align_src: LazySrcLoc = src; // TODO add a LazySrcLoc that points at align
    const small = @bitCast(Zir.Inst.ExtendedFunc.Small, extended.small);

    var extra_index: usize = extra.end;

    const lib_name: ?[]const u8 = if (small.has_lib_name) blk: {
        const lib_name = sema.code.nullTerminatedString(sema.code.extra[extra_index]);
        extra_index += 1;
        break :blk lib_name;
    } else null;

    const cc: std.builtin.CallingConvention = if (small.has_cc) blk: {
        const cc_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
        extra_index += 1;
        const cc_tv = try sema.resolveInstConst(block, cc_src, cc_ref);
        break :blk cc_tv.val.toEnum(cc_tv.ty, std.builtin.CallingConvention);
    } else .Unspecified;

    const align_val: Value = if (small.has_align) blk: {
        const align_ref = @intToEnum(Zir.Inst.Ref, sema.code.extra[extra_index]);
        extra_index += 1;
        const align_tv = try sema.resolveInstConst(block, align_src, align_ref);
        break :blk align_tv.val;
    } else Value.initTag(.null_value);

    const param_types = sema.code.refSlice(extra_index, extra.data.param_types_len);
    extra_index += param_types.len;

    var body_inst: Zir.Inst.Index = 0;
    var src_locs: Zir.Inst.Func.SrcLocs = undefined;
    if (extra.data.body_len != 0) {
        body_inst = inst;
        extra_index += extra.data.body_len;
        src_locs = sema.code.extraData(Zir.Inst.Func.SrcLocs, extra_index).data;
    }

    const is_var_args = small.is_var_args;
    const is_inferred_error = small.is_inferred_error;
    const is_extern = small.is_extern;

    return sema.funcCommon(
        block,
        extra.data.src_node,
        param_types,
        body_inst,
        extra.data.return_type,
        cc,
        align_val,
        is_var_args,
        is_inferred_error,
        is_extern,
        src_locs,
        lib_name,
    );
}

fn zirCUndef(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const extra = sema.code.extraData(Zir.Inst.UnNode, extended.operand).data;
    const src: LazySrcLoc = .{ .node_offset = extra.node };
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirCUndef", .{});
}

fn zirCInclude(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const extra = sema.code.extraData(Zir.Inst.UnNode, extended.operand).data;
    const src: LazySrcLoc = .{ .node_offset = extra.node };
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirCInclude", .{});
}

fn zirCDefine(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const extra = sema.code.extraData(Zir.Inst.BinNode, extended.operand).data;
    const src: LazySrcLoc = .{ .node_offset = extra.node };
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirCDefine", .{});
}

fn zirWasmMemorySize(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const extra = sema.code.extraData(Zir.Inst.UnNode, extended.operand).data;
    const src: LazySrcLoc = .{ .node_offset = extra.node };
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirWasmMemorySize", .{});
}

fn zirWasmMemoryGrow(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const extra = sema.code.extraData(Zir.Inst.BinNode, extended.operand).data;
    const src: LazySrcLoc = .{ .node_offset = extra.node };
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirWasmMemoryGrow", .{});
}

fn zirBuiltinExtern(
    sema: *Sema,
    block: *Scope.Block,
    extended: Zir.Inst.Extended.InstData,
) InnerError!*Inst {
    const extra = sema.code.extraData(Zir.Inst.BinNode, extended.operand).data;
    const src: LazySrcLoc = .{ .node_offset = extra.node };
    return sema.mod.fail(&block.base, src, "TODO: implement Sema.zirBuiltinExtern", .{});
}

fn requireFunctionBlock(sema: *Sema, block: *Scope.Block, src: LazySrcLoc) !void {
    if (sema.func == null) {
        return sema.mod.fail(&block.base, src, "instruction illegal outside function body", .{});
    }
}

fn requireRuntimeBlock(sema: *Sema, block: *Scope.Block, src: LazySrcLoc) !void {
    if (block.is_comptime) {
        return sema.failWithNeededComptime(block, src);
    }
    try sema.requireFunctionBlock(block, src);
}

fn validateVarType(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, ty: Type) !void {
    if (!ty.isValidVarType(false)) {
        return sema.mod.fail(&block.base, src, "variable of type '{}' must be const or comptime", .{ty});
    }
}

pub const PanicId = enum {
    unreach,
    unwrap_null,
    unwrap_errunion,
    cast_to_null,
    incorrect_alignment,
    invalid_error_code,
};

fn addSafetyCheck(sema: *Sema, parent_block: *Scope.Block, ok: *Inst, panic_id: PanicId) !void {
    const block_inst = try sema.arena.create(Inst.Block);
    block_inst.* = .{
        .base = .{
            .tag = Inst.Block.base_tag,
            .ty = Type.initTag(.void),
            .src = ok.src,
        },
        .body = .{
            .instructions = try sema.arena.alloc(*Inst, 1), // Only need space for the condbr.
        },
    };

    const ok_body: ir.Body = .{
        .instructions = try sema.arena.alloc(*Inst, 1), // Only need space for the br_void.
    };
    const br_void = try sema.arena.create(Inst.BrVoid);
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
        .sema = sema,
        .src_decl = parent_block.src_decl,
        .instructions = .{},
        .inlining = parent_block.inlining,
        .is_comptime = parent_block.is_comptime,
    };

    defer fail_block.instructions.deinit(sema.gpa);

    _ = try sema.safetyPanic(&fail_block, ok.src, panic_id);

    const fail_body: ir.Body = .{ .instructions = try sema.arena.dupe(*Inst, fail_block.instructions.items) };

    const condbr = try sema.arena.create(Inst.CondBr);
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

    try parent_block.instructions.append(sema.gpa, &block_inst.base);
}

fn panicWithMsg(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    msg_inst: *ir.Inst,
) !Zir.Inst.Index {
    const mod = sema.mod;
    const arena = sema.arena;

    const this_feature_is_implemented_in_the_backend =
        mod.comp.bin_file.options.object_format == .c;
    if (!this_feature_is_implemented_in_the_backend) {
        // TODO implement this feature in all the backends and then delete this branch
        _ = try block.addNoOp(src, Type.initTag(.void), .breakpoint);
        _ = try block.addNoOp(src, Type.initTag(.noreturn), .unreach);
        return always_noreturn;
    }
    const panic_fn = try sema.getBuiltin(block, src, "panic");
    const unresolved_stack_trace_ty = try sema.getBuiltinType(block, src, "StackTrace");
    const stack_trace_ty = try sema.resolveTypeFields(block, src, unresolved_stack_trace_ty);
    const ptr_stack_trace_ty = try mod.simplePtrType(arena, stack_trace_ty, true, .One);
    const null_stack_trace = try mod.constInst(arena, src, .{
        .ty = try mod.optionalType(arena, ptr_stack_trace_ty),
        .val = Value.initTag(.null_value),
    });
    const args = try arena.create([2]*ir.Inst);
    args.* = .{ msg_inst, null_stack_trace };
    _ = try sema.analyzeCall(block, panic_fn, src, src, .auto, false, args);
    return always_noreturn;
}

fn safetyPanic(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    panic_id: PanicId,
) !Zir.Inst.Index {
    const msg = switch (panic_id) {
        .unreach => "reached unreachable code",
        .unwrap_null => "attempt to use null value",
        .unwrap_errunion => "unreachable error occurred",
        .cast_to_null => "cast causes pointer to be null",
        .incorrect_alignment => "incorrect alignment",
        .invalid_error_code => "invalid error code",
    };

    const msg_inst = msg_inst: {
        // TODO instead of making a new decl for every panic in the entire compilation,
        // introduce the concept of a reference-counted decl for these
        var new_decl_arena = std.heap.ArenaAllocator.init(sema.gpa);
        errdefer new_decl_arena.deinit();

        const decl_ty = try Type.Tag.array_u8.create(&new_decl_arena.allocator, msg.len);
        const decl_val = try Value.Tag.bytes.create(&new_decl_arena.allocator, msg);

        const new_decl = try sema.mod.createAnonymousDecl(&block.base, .{
            .ty = decl_ty,
            .val = decl_val,
        });
        errdefer sema.mod.deleteAnonDecl(&block.base, new_decl);
        try new_decl.finalizeNewArena(&new_decl_arena);
        break :msg_inst try sema.analyzeDeclRef(block, .unneeded, new_decl);
    };

    const casted_msg_inst = try sema.coerce(block, Type.initTag(.const_slice_u8), msg_inst, src);

    return sema.panicWithMsg(block, src, casted_msg_inst);
}

fn emitBackwardBranch(sema: *Sema, block: *Scope.Block, src: LazySrcLoc) !void {
    sema.branch_count += 1;
    if (sema.branch_count > sema.branch_quota) {
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
    const mod = sema.mod;
    const arena = sema.arena;

    const elem_ty = switch (object_ptr.ty.zigTypeTag()) {
        .Pointer => object_ptr.ty.elemType(),
        else => return mod.fail(&block.base, object_ptr.src, "expected pointer, found '{}'", .{object_ptr.ty}),
    };
    switch (elem_ty.zigTypeTag()) {
        .Array => {
            if (mem.eql(u8, field_name, "len")) {
                return mod.constInst(arena, src, .{
                    .ty = Type.initTag(.single_const_pointer_to_comptime_int),
                    .val = try Value.Tag.ref_val.create(
                        arena,
                        try Value.Tag.int_u64.create(arena, elem_ty.arrayLen()),
                    ),
                });
            } else {
                return mod.fail(
                    &block.base,
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
                        return mod.constInst(arena, src, .{
                            .ty = Type.initTag(.single_const_pointer_to_comptime_int),
                            .val = try Value.Tag.ref_val.create(
                                arena,
                                try Value.Tag.int_u64.create(arena, ptr_child.arrayLen()),
                            ),
                        });
                    } else {
                        return mod.fail(
                            &block.base,
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
            _ = try sema.resolveConstValue(block, object_ptr.src, object_ptr);
            const result = try sema.analyzeLoad(block, src, object_ptr, object_ptr.src);
            const val = result.value().?;
            const child_type = try val.toType(arena);
            switch (child_type.zigTypeTag()) {
                .ErrorSet => {
                    // TODO resolve inferred error sets
                    const name: []const u8 = if (child_type.castTag(.error_set)) |payload| blk: {
                        const error_set = payload.data;
                        // TODO this is O(N). I'm putting off solving this until we solve inferred
                        // error sets at the same time.
                        const names = error_set.names_ptr[0..error_set.names_len];
                        for (names) |name| {
                            if (mem.eql(u8, field_name, name)) {
                                break :blk name;
                            }
                        }
                        return mod.fail(&block.base, src, "no error named '{s}' in '{}'", .{
                            field_name,
                            child_type,
                        });
                    } else (try mod.getErrorValue(field_name)).key;

                    return mod.constInst(arena, src, .{
                        .ty = try mod.simplePtrType(arena, child_type, false, .One),
                        .val = try Value.Tag.ref_val.create(
                            arena,
                            try Value.Tag.@"error".create(arena, .{
                                .name = name,
                            }),
                        ),
                    });
                },
                .Struct, .Opaque, .Union => {
                    if (child_type.getNamespace()) |namespace| {
                        if (try sema.analyzeNamespaceLookup(block, src, namespace, field_name)) |inst| {
                            return inst;
                        }
                    }
                    // TODO add note: declared here
                    const kw_name = switch (child_type.zigTypeTag()) {
                        .Struct => "struct",
                        .Opaque => "opaque",
                        .Union => "union",
                        else => unreachable,
                    };
                    return mod.fail(&block.base, src, "{s} '{}' has no member named '{s}'", .{
                        kw_name, child_type, field_name,
                    });
                },
                .Enum => {
                    if (child_type.getNamespace()) |namespace| {
                        if (try sema.analyzeNamespaceLookup(block, src, namespace, field_name)) |inst| {
                            return inst;
                        }
                    }
                    const field_index = child_type.enumFieldIndex(field_name) orelse {
                        const msg = msg: {
                            const msg = try mod.errMsg(
                                &block.base,
                                src,
                                "enum '{}' has no member named '{s}'",
                                .{ child_type, field_name },
                            );
                            errdefer msg.destroy(sema.gpa);
                            try mod.errNoteNonLazy(
                                child_type.declSrcLoc(),
                                msg,
                                "enum declared here",
                                .{},
                            );
                            break :msg msg;
                        };
                        return mod.failWithOwnedErrorMsg(&block.base, msg);
                    };
                    const field_index_u32 = @intCast(u32, field_index);
                    const enum_val = try Value.Tag.enum_field_index.create(arena, field_index_u32);
                    return mod.constInst(arena, src, .{
                        .ty = try mod.simplePtrType(arena, child_type, false, .One),
                        .val = try Value.Tag.ref_val.create(arena, enum_val),
                    });
                },
                else => return mod.fail(&block.base, src, "type '{}' has no members", .{child_type}),
            }
        },
        .Struct => return sema.analyzeStructFieldPtr(block, src, object_ptr, field_name, field_name_src, elem_ty),
        .Union => return sema.analyzeUnionFieldPtr(block, src, object_ptr, field_name, field_name_src, elem_ty),
        else => {},
    }
    return mod.fail(&block.base, src, "type '{}' does not support field access", .{elem_ty});
}

fn analyzeNamespaceLookup(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    namespace: *Scope.Namespace,
    decl_name: []const u8,
) InnerError!?*Inst {
    const mod = sema.mod;
    const gpa = sema.gpa;
    if (try sema.lookupInNamespace(namespace, decl_name)) |decl| {
        if (!decl.is_pub and decl.namespace.file_scope != block.getFileScope()) {
            const msg = msg: {
                const msg = try mod.errMsg(&block.base, src, "'{s}' is not marked 'pub'", .{
                    decl_name,
                });
                errdefer msg.destroy(gpa);
                try mod.errNoteNonLazy(decl.srcLoc(), msg, "declared here", .{});
                break :msg msg;
            };
            return mod.failWithOwnedErrorMsg(&block.base, msg);
        }
        return try sema.analyzeDeclRef(block, src, decl);
    }
    return null;
}

fn analyzeStructFieldPtr(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    struct_ptr: *Inst,
    field_name: []const u8,
    field_name_src: LazySrcLoc,
    unresolved_struct_ty: Type,
) InnerError!*Inst {
    const mod = sema.mod;
    const arena = sema.arena;
    assert(unresolved_struct_ty.zigTypeTag() == .Struct);

    const struct_ty = try sema.resolveTypeFields(block, src, unresolved_struct_ty);
    const struct_obj = struct_ty.castTag(.@"struct").?.data;

    const field_index = struct_obj.fields.getIndex(field_name) orelse
        return sema.failWithBadFieldAccess(block, struct_obj, field_name_src, field_name);
    const field = struct_obj.fields.values()[field_index];
    const ptr_field_ty = try mod.simplePtrType(arena, field.ty, true, .One);

    if (try sema.resolveDefinedValue(block, src, struct_ptr)) |struct_ptr_val| {
        return mod.constInst(arena, src, .{
            .ty = ptr_field_ty,
            .val = try Value.Tag.field_ptr.create(arena, .{
                .container_ptr = struct_ptr_val,
                .field_index = field_index,
            }),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addStructFieldPtr(src, ptr_field_ty, struct_ptr, @intCast(u32, field_index));
}

fn analyzeUnionFieldPtr(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    union_ptr: *Inst,
    field_name: []const u8,
    field_name_src: LazySrcLoc,
    unresolved_union_ty: Type,
) InnerError!*Inst {
    const mod = sema.mod;
    const arena = sema.arena;
    assert(unresolved_union_ty.zigTypeTag() == .Union);

    const union_ty = try sema.resolveTypeFields(block, src, unresolved_union_ty);
    const union_obj = union_ty.cast(Type.Payload.Union).?.data;

    const field_index = union_obj.fields.getIndex(field_name) orelse
        return sema.failWithBadUnionFieldAccess(block, union_obj, field_name_src, field_name);

    const field = union_obj.fields.values()[field_index];
    const ptr_field_ty = try mod.simplePtrType(arena, field.ty, true, .One);

    if (try sema.resolveDefinedValue(block, src, union_ptr)) |union_ptr_val| {
        // TODO detect inactive union field and emit compile error
        return mod.constInst(arena, src, .{
            .ty = ptr_field_ty,
            .val = try Value.Tag.field_ptr.create(arena, .{
                .container_ptr = union_ptr_val,
                .field_index = field_index,
            }),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return mod.fail(&block.base, src, "TODO implement runtime union field access", .{});
}

fn elemPtr(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    array_ptr: *Inst,
    elem_index: *Inst,
    elem_index_src: LazySrcLoc,
) InnerError!*Inst {
    const array_ty = switch (array_ptr.ty.zigTypeTag()) {
        .Pointer => array_ptr.ty.elemType(),
        else => return sema.mod.fail(&block.base, array_ptr.src, "expected pointer, found '{}'", .{array_ptr.ty}),
    };
    if (!array_ty.isIndexable()) {
        return sema.mod.fail(&block.base, src, "array access of non-array type '{}'", .{array_ty});
    }
    if (array_ty.isSinglePointer() and array_ty.elemType().zigTypeTag() == .Array) {
        // we have to deref the ptr operand to get the actual array pointer
        const array_ptr_deref = try sema.analyzeLoad(block, src, array_ptr, array_ptr.src);
        return sema.elemPtrArray(block, src, array_ptr_deref, elem_index, elem_index_src);
    }
    if (array_ty.zigTypeTag() == .Array) {
        return sema.elemPtrArray(block, src, array_ptr, elem_index, elem_index_src);
    }

    return sema.mod.fail(&block.base, src, "TODO implement more analyze elemptr", .{});
}

fn elemPtrArray(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    array_ptr: *Inst,
    elem_index: *Inst,
    elem_index_src: LazySrcLoc,
) InnerError!*Inst {
    if (array_ptr.value()) |array_ptr_val| {
        if (elem_index.value()) |index_val| {
            // Both array pointer and index are compile-time known.
            const index_u64 = index_val.toUnsignedInt();
            // @intCast here because it would have been impossible to construct a value that
            // required a larger index.
            const elem_ptr = try array_ptr_val.elemPtr(sema.arena, @intCast(usize, index_u64));
            const pointee_type = array_ptr.ty.elemType().elemType();

            return sema.mod.constInst(sema.arena, src, .{
                .ty = try Type.Tag.single_const_pointer.create(sema.arena, pointee_type),
                .val = elem_ptr,
            });
        }
    }
    _ = elem_index;
    _ = elem_index_src;
    return sema.mod.fail(&block.base, src, "TODO implement more analyze elemptr for arrays", .{});
}

fn coerce(
    sema: *Sema,
    block: *Scope.Block,
    dest_type: Type,
    inst: *Inst,
    inst_src: LazySrcLoc,
) InnerError!*Inst {
    if (dest_type.tag() == .var_args_param) {
        return sema.coerceVarArgParam(block, inst);
    }
    // If the types are the same, we can return the operand.
    if (dest_type.eql(inst.ty))
        return inst;

    const in_memory_result = coerceInMemoryAllowed(dest_type, inst.ty);
    if (in_memory_result == .ok) {
        return sema.bitcast(block, dest_type, inst);
    }

    const mod = sema.mod;
    const arena = sema.arena;

    // undefined to anything
    if (inst.value()) |val| {
        if (val.isUndef() or inst.ty.zigTypeTag() == .Undefined) {
            return mod.constInst(arena, inst_src, .{ .ty = dest_type, .val = val });
        }
    }
    assert(inst.ty.zigTypeTag() != .Undefined);

    // T to E!T or E to E!T
    if (dest_type.tag() == .error_union) {
        return try sema.wrapErrorUnion(block, dest_type, inst);
    }

    // comptime known number to other number
    if (try sema.coerceNum(block, dest_type, inst)) |some|
        return some;

    const target = mod.getTarget();

    switch (dest_type.zigTypeTag()) {
        .Optional => {
            // null to ?T
            if (inst.ty.zigTypeTag() == .Null) {
                return mod.constInst(arena, inst_src, .{ .ty = dest_type, .val = Value.initTag(.null_value) });
            }

            // T to ?T
            var buf: Type.Payload.ElemType = undefined;
            const child_type = dest_type.optionalChild(&buf);
            if (child_type.eql(inst.ty)) {
                return sema.wrapOptional(block, dest_type, inst);
            } else if (try sema.coerceNum(block, child_type, inst)) |some| {
                return sema.wrapOptional(block, dest_type, some);
            }
        },
        .Pointer => {
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
                        return sema.coerceArrayPtrToSlice(block, dest_type, inst);
                    },
                    .C => {
                        // *[N]T to [*c]T
                        return sema.coerceArrayPtrToMany(block, dest_type, inst);
                    },
                    .Many => {
                        // *[N]T to [*]T
                        // *[N:s]T to [*:s]T
                        const src_sentinel = array_type.sentinel();
                        const dst_sentinel = dest_type.sentinel();
                        if (src_sentinel == null and dst_sentinel == null)
                            return sema.coerceArrayPtrToMany(block, dest_type, inst);

                        if (src_sentinel) |src_s| {
                            if (dst_sentinel) |dst_s| {
                                if (src_s.eql(dst_s)) {
                                    return sema.coerceArrayPtrToMany(block, dest_type, inst);
                                }
                            }
                        }
                    },
                    .One => {},
                }
            }
        },
        .Int => {
            // integer widening
            if (inst.ty.zigTypeTag() == .Int) {
                assert(inst.value() == null); // handled above

                const dst_info = dest_type.intInfo(target);
                const src_info = inst.ty.intInfo(target);
                if ((src_info.signedness == dst_info.signedness and dst_info.bits >= src_info.bits) or
                    // small enough unsigned ints can get casted to large enough signed ints
                    (src_info.signedness == .signed and dst_info.signedness == .unsigned and dst_info.bits > src_info.bits))
                {
                    try sema.requireRuntimeBlock(block, inst_src);
                    return block.addUnOp(inst_src, dest_type, .intcast, inst);
                }
            }
        },
        .Float => {
            // float widening
            if (inst.ty.zigTypeTag() == .Float) {
                assert(inst.value() == null); // handled above

                const src_bits = inst.ty.floatBits(target);
                const dst_bits = dest_type.floatBits(target);
                if (dst_bits >= src_bits) {
                    try sema.requireRuntimeBlock(block, inst_src);
                    return block.addUnOp(inst_src, dest_type, .floatcast, inst);
                }
            }
        },
        .Enum => {
            // enum literal to enum
            if (inst.ty.zigTypeTag() == .EnumLiteral) {
                const val = try sema.resolveConstValue(block, inst_src, inst);
                const bytes = val.castTag(.enum_literal).?.data;
                const resolved_dest_type = try sema.resolveTypeFields(block, inst_src, dest_type);
                const field_index = resolved_dest_type.enumFieldIndex(bytes) orelse {
                    const msg = msg: {
                        const msg = try mod.errMsg(
                            &block.base,
                            inst_src,
                            "enum '{}' has no field named '{s}'",
                            .{ resolved_dest_type, bytes },
                        );
                        errdefer msg.destroy(sema.gpa);
                        try mod.errNoteNonLazy(
                            resolved_dest_type.declSrcLoc(),
                            msg,
                            "enum declared here",
                            .{},
                        );
                        break :msg msg;
                    };
                    return mod.failWithOwnedErrorMsg(&block.base, msg);
                };
                return mod.constInst(arena, inst_src, .{
                    .ty = resolved_dest_type,
                    .val = try Value.Tag.enum_field_index.create(arena, @intCast(u32, field_index)),
                });
            }
        },
        else => {},
    }

    return mod.fail(&block.base, inst_src, "expected {}, found {}", .{ dest_type, inst.ty });
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

    const target = sema.mod.getTarget();

    if (dst_zig_tag == .ComptimeInt or dst_zig_tag == .Int) {
        if (src_zig_tag == .Float or src_zig_tag == .ComptimeFloat) {
            if (val.floatHasFraction()) {
                return sema.mod.fail(&block.base, inst.src, "fractional component prevents float value {} from being casted to type '{}'", .{ val, inst.ty });
            }
            return sema.mod.fail(&block.base, inst.src, "TODO float to int", .{});
        } else if (src_zig_tag == .Int or src_zig_tag == .ComptimeInt) {
            if (!val.intFitsInType(dest_type, target)) {
                return sema.mod.fail(&block.base, inst.src, "type {} cannot represent integer value {}", .{ inst.ty, val });
            }
            return sema.mod.constInst(sema.arena, inst.src, .{ .ty = dest_type, .val = val });
        }
    } else if (dst_zig_tag == .ComptimeFloat or dst_zig_tag == .Float) {
        if (src_zig_tag == .Float or src_zig_tag == .ComptimeFloat) {
            const res = val.floatCast(sema.arena, dest_type, target) catch |err| switch (err) {
                error.Overflow => return sema.mod.fail(
                    &block.base,
                    inst.src,
                    "cast of value {} to type '{}' loses information",
                    .{ val, dest_type },
                ),
                error.OutOfMemory => return error.OutOfMemory,
            };
            return sema.mod.constInst(sema.arena, inst.src, .{ .ty = dest_type, .val = res });
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

fn storePtr(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    ptr: *Inst,
    uncasted_value: *Inst,
) !void {
    if (ptr.ty.isConstPtr())
        return sema.mod.fail(&block.base, src, "cannot assign to constant", .{});

    const elem_ty = ptr.ty.elemType();
    const value = try sema.coerce(block, elem_ty, uncasted_value, src);
    if ((try sema.typeHasOnePossibleValue(block, src, elem_ty)) != null)
        return;

    if (try sema.resolvePossiblyUndefinedValue(block, src, ptr)) |ptr_val| blk: {
        const const_val = (try sema.resolvePossiblyUndefinedValue(block, src, value)) orelse
            return sema.mod.fail(&block.base, src, "cannot store runtime value in compile time variable", .{});

        if (ptr_val.tag() == .int_u64)
            break :blk; // propogate it down to runtime

        const comptime_alloc = ptr_val.castTag(.comptime_alloc).?;
        if (comptime_alloc.data.runtime_index < block.runtime_index) {
            if (block.runtime_cond) |cond_src| {
                const msg = msg: {
                    const msg = try sema.mod.errMsg(&block.base, src, "store to comptime variable depends on runtime condition", .{});
                    errdefer msg.destroy(sema.gpa);
                    try sema.mod.errNote(&block.base, cond_src, msg, "runtime condition here", .{});
                    break :msg msg;
                };
                return sema.mod.failWithOwnedErrorMsg(&block.base, msg);
            }
            if (block.runtime_loop) |loop_src| {
                const msg = msg: {
                    const msg = try sema.mod.errMsg(&block.base, src, "cannot store to comptime variable in non-inline loop", .{});
                    errdefer msg.destroy(sema.gpa);
                    try sema.mod.errNote(&block.base, loop_src, msg, "non-inline loop here", .{});
                    break :msg msg;
                };
                return sema.mod.failWithOwnedErrorMsg(&block.base, msg);
            }
            unreachable;
        }
        comptime_alloc.data.val = const_val;
        return;
    }
    // TODO handle if the element type requires comptime

    try sema.requireRuntimeBlock(block, src);
    _ = try block.addBinOp(src, Type.initTag(.void), .store, ptr, value);
}

fn bitcast(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        // Keep the comptime Value representation; take the new type.
        return sema.mod.constInst(sema.arena, inst.src, .{ .ty = dest_type, .val = val });
    }
    // TODO validate the type size and other compile errors
    try sema.requireRuntimeBlock(block, inst.src);
    return block.addUnOp(inst.src, dest_type, .bitcast, inst);
}

fn coerceArrayPtrToSlice(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        // The comptime Value representation is compatible with both types.
        return sema.mod.constInst(sema.arena, inst.src, .{ .ty = dest_type, .val = val });
    }
    return sema.mod.fail(&block.base, inst.src, "TODO implement coerceArrayPtrToSlice runtime instruction", .{});
}

fn coerceArrayPtrToMany(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        // The comptime Value representation is compatible with both types.
        return sema.mod.constInst(sema.arena, inst.src, .{ .ty = dest_type, .val = val });
    }
    return sema.mod.fail(&block.base, inst.src, "TODO implement coerceArrayPtrToMany runtime instruction", .{});
}

fn analyzeDeclVal(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, decl: *Decl) InnerError!*Inst {
    const decl_ref = try sema.analyzeDeclRef(block, src, decl);
    return sema.analyzeLoad(block, src, decl_ref, src);
}

fn analyzeDeclRef(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, decl: *Decl) InnerError!*Inst {
    try sema.mod.declareDeclDependency(sema.owner_decl, decl);
    sema.mod.ensureDeclAnalyzed(decl) catch |err| {
        if (sema.func) |func| {
            func.state = .dependency_failure;
        } else {
            sema.owner_decl.analysis = .dependency_failure;
        }
        return err;
    };

    const decl_tv = try decl.typedValue();
    if (decl_tv.val.tag() == .variable) {
        return sema.analyzeVarRef(block, src, decl_tv);
    }
    return sema.mod.constInst(sema.arena, src, .{
        .ty = try sema.mod.simplePtrType(sema.arena, decl_tv.ty, false, .One),
        .val = try Value.Tag.decl_ref.create(sema.arena, decl),
    });
}

fn analyzeVarRef(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, tv: TypedValue) InnerError!*Inst {
    const variable = tv.val.castTag(.variable).?.data;

    const ty = try sema.mod.simplePtrType(sema.arena, tv.ty, variable.is_mutable, .One);
    if (!variable.is_mutable and !variable.is_extern) {
        return sema.mod.constInst(sema.arena, src, .{
            .ty = ty,
            .val = try Value.Tag.ref_val.create(sema.arena, variable.init),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    const inst = try sema.arena.create(Inst.VarPtr);
    inst.* = .{
        .base = .{
            .tag = .varptr,
            .ty = ty,
            .src = src,
        },
        .variable = variable,
    };
    try block.instructions.append(sema.gpa, &inst.base);
    return &inst.base;
}

fn analyzeRef(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    operand: *Inst,
) InnerError!*Inst {
    const ptr_type = try sema.mod.simplePtrType(sema.arena, operand.ty, false, .One);

    if (try sema.resolvePossiblyUndefinedValue(block, src, operand)) |val| {
        return sema.mod.constInst(sema.arena, src, .{
            .ty = ptr_type,
            .val = try Value.Tag.ref_val.create(sema.arena, val),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, ptr_type, .ref, operand);
}

fn analyzeLoad(
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
    if (try sema.resolveDefinedValue(block, ptr_src, ptr)) |ptr_val| blk: {
        if (ptr_val.tag() == .int_u64)
            break :blk; // do it at runtime

        return sema.mod.constInst(sema.arena, src, .{
            .ty = elem_ty,
            .val = try ptr_val.pointerDeref(sema.arena),
        });
    }

    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, elem_ty, .load, ptr);
}

fn analyzeIsNull(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    operand: *Inst,
    invert_logic: bool,
) InnerError!*Inst {
    const result_ty = Type.initTag(.bool);
    if (try sema.resolvePossiblyUndefinedValue(block, src, operand)) |opt_val| {
        if (opt_val.isUndef()) {
            return sema.mod.constUndef(sema.arena, src, result_ty);
        }
        const is_null = opt_val.isNull();
        const bool_value = if (invert_logic) !is_null else is_null;
        return sema.mod.constBool(sema.arena, src, bool_value);
    }
    try sema.requireRuntimeBlock(block, src);
    const inst_tag: Inst.Tag = if (invert_logic) .is_non_null else .is_null;
    return block.addUnOp(src, result_ty, inst_tag, operand);
}

fn analyzeIsNonErr(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    operand: *Inst,
) InnerError!*Inst {
    const ot = operand.ty.zigTypeTag();
    if (ot != .ErrorSet and ot != .ErrorUnion) return sema.mod.constBool(sema.arena, src, true);
    if (ot == .ErrorSet) return sema.mod.constBool(sema.arena, src, false);
    assert(ot == .ErrorUnion);
    const result_ty = Type.initTag(.bool);
    if (try sema.resolvePossiblyUndefinedValue(block, src, operand)) |err_union| {
        if (err_union.isUndef()) {
            return sema.mod.constUndef(sema.arena, src, result_ty);
        }
        return sema.mod.constBool(sema.arena, src, err_union.getError() == null);
    }
    try sema.requireRuntimeBlock(block, src);
    return block.addUnOp(src, result_ty, .is_non_err, operand);
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
        const casted = try sema.coerce(block, elem_type, sentinel, sentinel.src);
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
                return_elem_type = try sema.mod.arrayType(sema.arena, len, array_sentinel, elem_type);
                return_ptr_size = .One;
            }
        }
    }
    const return_type = try sema.mod.ptrType(
        sema.arena,
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
    _ = return_type;

    return sema.mod.fail(&block.base, src, "TODO implement analysis of slice", .{});
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
            return sema.mod.constBool(sema.arena, src, Value.compare(lhs_val, op, rhs_val));
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
    const target = sema.mod.getTarget();
    if (lhs_is_float and rhs_is_float) {
        // Implicit cast the smaller one to the larger one.
        const dest_type = x: {
            if (lhs_ty_tag == .ComptimeFloat) {
                break :x rhs.ty;
            } else if (rhs_ty_tag == .ComptimeFloat) {
                break :x lhs.ty;
            }
            if (lhs.ty.floatBits(target) >= rhs.ty.floatBits(target)) {
                break :x lhs.ty;
            } else {
                break :x rhs.ty;
            }
        };
        const casted_lhs = try sema.coerce(block, dest_type, lhs, lhs.src);
        const casted_rhs = try sema.coerce(block, dest_type, rhs, rhs.src);
        return block.addBinOp(src, dest_type, Inst.Tag.fromCmpOp(op), casted_lhs, casted_rhs);
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
            return sema.mod.constUndef(sema.arena, src, Type.initTag(.bool));
        const is_unsigned = if (lhs_is_float) x: {
            var bigint_space: Value.BigIntSpace = undefined;
            var bigint = try lhs_val.toBigInt(&bigint_space).toManaged(sema.gpa);
            defer bigint.deinit();
            const zcmp = lhs_val.orderAgainstZero();
            if (lhs_val.floatHasFraction()) {
                switch (op) {
                    .eq => return sema.mod.constBool(sema.arena, src, false),
                    .neq => return sema.mod.constBool(sema.arena, src, true),
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
        const int_info = lhs.ty.intInfo(target);
        lhs_bits = int_info.bits + @boolToInt(int_info.signedness == .unsigned and dest_int_is_signed);
    }

    var rhs_bits: usize = undefined;
    if (rhs.value()) |rhs_val| {
        if (rhs_val.isUndef())
            return sema.mod.constUndef(sema.arena, src, Type.initTag(.bool));
        const is_unsigned = if (rhs_is_float) x: {
            var bigint_space: Value.BigIntSpace = undefined;
            var bigint = try rhs_val.toBigInt(&bigint_space).toManaged(sema.gpa);
            defer bigint.deinit();
            const zcmp = rhs_val.orderAgainstZero();
            if (rhs_val.floatHasFraction()) {
                switch (op) {
                    .eq => return sema.mod.constBool(sema.arena, src, false),
                    .neq => return sema.mod.constBool(sema.arena, src, true),
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
        const int_info = rhs.ty.intInfo(target);
        rhs_bits = int_info.bits + @boolToInt(int_info.signedness == .unsigned and dest_int_is_signed);
    }

    const dest_type = if (dest_float_type) |ft| ft else blk: {
        const max_bits = std.math.max(lhs_bits, rhs_bits);
        const casted_bits = std.math.cast(u16, max_bits) catch |err| switch (err) {
            error.Overflow => return sema.mod.fail(&block.base, src, "{d} exceeds maximum integer bit count", .{max_bits}),
        };
        const signedness: std.builtin.Signedness = if (dest_int_is_signed) .signed else .unsigned;
        break :blk try Module.makeIntType(sema.arena, signedness, casted_bits);
    };
    const casted_lhs = try sema.coerce(block, dest_type, lhs, lhs.src);
    const casted_rhs = try sema.coerce(block, dest_type, rhs, rhs.src);

    return block.addBinOp(src, Type.initTag(.bool), Inst.Tag.fromCmpOp(op), casted_lhs, casted_rhs);
}

fn wrapOptional(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) !*Inst {
    if (inst.value()) |val| {
        return sema.mod.constInst(sema.arena, inst.src, .{ .ty = dest_type, .val = val });
    }

    try sema.requireRuntimeBlock(block, inst.src);
    return block.addUnOp(inst.src, dest_type, .wrap_optional, inst);
}

fn wrapErrorUnion(sema: *Sema, block: *Scope.Block, dest_type: Type, inst: *Inst) !*Inst {
    const err_union = dest_type.castTag(.error_union).?;
    if (inst.value()) |val| {
        if (inst.ty.zigTypeTag() != .ErrorSet) {
            _ = try sema.coerce(block, err_union.data.payload, inst, inst.src);
        } else switch (err_union.data.error_set.tag()) {
            .anyerror => {},
            .error_set_single => {
                const expected_name = val.castTag(.@"error").?.data.name;
                const n = err_union.data.error_set.castTag(.error_set_single).?.data;
                if (!mem.eql(u8, expected_name, n)) {
                    return sema.mod.fail(
                        &block.base,
                        inst.src,
                        "expected type '{}', found type '{}'",
                        .{ err_union.data.error_set, inst.ty },
                    );
                }
            },
            .error_set => {
                const expected_name = val.castTag(.@"error").?.data.name;
                const error_set = err_union.data.error_set.castTag(.error_set).?.data;
                const names = error_set.names_ptr[0..error_set.names_len];
                // TODO this is O(N). I'm putting off solving this until we solve inferred
                // error sets at the same time.
                const found = for (names) |name| {
                    if (mem.eql(u8, expected_name, name)) break true;
                } else false;
                if (!found) {
                    return sema.mod.fail(
                        &block.base,
                        inst.src,
                        "expected type '{}', found type '{}'",
                        .{ err_union.data.error_set, inst.ty },
                    );
                }
            },
            .error_set_inferred => {
                const expected_name = val.castTag(.@"error").?.data.name;
                const map = &err_union.data.error_set.castTag(.error_set_inferred).?.data.map;
                if (!map.contains(expected_name)) {
                    return sema.mod.fail(
                        &block.base,
                        inst.src,
                        "expected type '{}', found type '{}'",
                        .{ err_union.data.error_set, inst.ty },
                    );
                }
            },
            else => unreachable,
        }

        return sema.mod.constInst(sema.arena, inst.src, .{
            .ty = dest_type,
            // creating a SubValue for the error_union payload
            .val = try Value.Tag.error_union.create(sema.arena, val),
        });
    }

    try sema.requireRuntimeBlock(block, inst.src);

    // we are coercing from E to E!T
    if (inst.ty.zigTypeTag() == .ErrorSet) {
        var coerced = try sema.coerce(block, err_union.data.error_set, inst, inst.src);
        return block.addUnOp(inst.src, dest_type, .wrap_errunion_err, coerced);
    } else {
        var coerced = try sema.coerce(block, err_union.data.payload, inst, inst.src);
        return block.addUnOp(inst.src, dest_type, .wrap_errunion_payload, coerced);
    }
}

fn resolvePeerTypes(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    instructions: []*Inst,
    candidate_srcs: Module.PeerTypeCandidateSrc,
) !Type {
    if (instructions.len == 0)
        return Type.initTag(.noreturn);

    if (instructions.len == 1)
        return instructions[0].ty;

    const target = sema.mod.getTarget();

    var chosen = instructions[0];
    var chosen_i: usize = 0;
    for (instructions[1..]) |candidate, candidate_i| {
        if (candidate.ty.eql(chosen.ty))
            continue;
        if (candidate.ty.zigTypeTag() == .NoReturn)
            continue;
        if (chosen.ty.zigTypeTag() == .NoReturn) {
            chosen = candidate;
            chosen_i = candidate_i + 1;
            continue;
        }
        if (candidate.ty.zigTypeTag() == .Undefined)
            continue;
        if (chosen.ty.zigTypeTag() == .Undefined) {
            chosen = candidate;
            chosen_i = candidate_i + 1;
            continue;
        }
        if (chosen.ty.isInt() and
            candidate.ty.isInt() and
            chosen.ty.isSignedInt() == candidate.ty.isSignedInt())
        {
            if (chosen.ty.intInfo(target).bits < candidate.ty.intInfo(target).bits) {
                chosen = candidate;
                chosen_i = candidate_i + 1;
            }
            continue;
        }
        if (chosen.ty.isFloat() and candidate.ty.isFloat()) {
            if (chosen.ty.floatBits(target) < candidate.ty.floatBits(target)) {
                chosen = candidate;
                chosen_i = candidate_i + 1;
            }
            continue;
        }

        if (chosen.ty.zigTypeTag() == .ComptimeInt and candidate.ty.isInt()) {
            chosen = candidate;
            chosen_i = candidate_i + 1;
            continue;
        }

        if (chosen.ty.isInt() and candidate.ty.zigTypeTag() == .ComptimeInt) {
            continue;
        }

        if (chosen.ty.zigTypeTag() == .ComptimeFloat and candidate.ty.isFloat()) {
            chosen = candidate;
            chosen_i = candidate_i + 1;
            continue;
        }

        if (chosen.ty.isFloat() and candidate.ty.zigTypeTag() == .ComptimeFloat) {
            continue;
        }

        if (chosen.ty.zigTypeTag() == .Enum and candidate.ty.zigTypeTag() == .EnumLiteral) {
            continue;
        }
        if (chosen.ty.zigTypeTag() == .EnumLiteral and candidate.ty.zigTypeTag() == .Enum) {
            chosen = candidate;
            chosen_i = candidate_i + 1;
            continue;
        }

        // At this point, we hit a compile error. We need to recover
        // the source locations.
        const chosen_src = candidate_srcs.resolve(
            sema.gpa,
            block.src_decl,
            instructions.len,
            chosen_i,
            chosen.src,
        );
        const candidate_src = candidate_srcs.resolve(
            sema.gpa,
            block.src_decl,
            instructions.len,
            candidate_i + 1,
            candidate.src,
        );

        const msg = msg: {
            const msg = try sema.mod.errMsg(&block.base, src, "incompatible types: '{}' and '{}'", .{ chosen.ty, candidate.ty });
            errdefer msg.destroy(sema.gpa);
            try sema.mod.errNote(&block.base, chosen_src, msg, "type '{}' here", .{chosen.ty});
            try sema.mod.errNote(&block.base, candidate_src, msg, "type '{}' here", .{candidate.ty});
            break :msg msg;
        };
        return sema.mod.failWithOwnedErrorMsg(&block.base, msg);
    }

    return chosen.ty;
}

fn resolveTypeFields(sema: *Sema, block: *Scope.Block, src: LazySrcLoc, ty: Type) InnerError!Type {
    switch (ty.tag()) {
        .@"struct" => {
            const struct_obj = ty.castTag(.@"struct").?.data;
            switch (struct_obj.status) {
                .none => {},
                .field_types_wip => {
                    return sema.mod.fail(&block.base, src, "struct {} depends on itself", .{
                        ty,
                    });
                },
                .have_field_types, .have_layout, .layout_wip => return ty,
            }
            struct_obj.status = .field_types_wip;
            try sema.mod.analyzeStructFields(struct_obj);
            struct_obj.status = .have_field_types;
            return ty;
        },
        .extern_options => return sema.resolveBuiltinTypeFields(block, src, "ExternOptions"),
        .export_options => return sema.resolveBuiltinTypeFields(block, src, "ExportOptions"),
        .atomic_ordering => return sema.resolveBuiltinTypeFields(block, src, "AtomicOrdering"),
        .atomic_rmw_op => return sema.resolveBuiltinTypeFields(block, src, "AtomicRmwOp"),
        .calling_convention => return sema.resolveBuiltinTypeFields(block, src, "CallingConvention"),
        .float_mode => return sema.resolveBuiltinTypeFields(block, src, "FloatMode"),
        .reduce_op => return sema.resolveBuiltinTypeFields(block, src, "ReduceOp"),
        .call_options => return sema.resolveBuiltinTypeFields(block, src, "CallOptions"),

        .@"union", .union_tagged => {
            const union_obj = ty.cast(Type.Payload.Union).?.data;
            switch (union_obj.status) {
                .none => {},
                .field_types_wip => {
                    return sema.mod.fail(&block.base, src, "union {} depends on itself", .{
                        ty,
                    });
                },
                .have_field_types, .have_layout, .layout_wip => return ty,
            }
            union_obj.status = .field_types_wip;
            try sema.mod.analyzeUnionFields(union_obj);
            union_obj.status = .have_field_types;
            return ty;
        },
        else => return ty,
    }
}

fn resolveBuiltinTypeFields(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    name: []const u8,
) InnerError!Type {
    const resolved_ty = try sema.getBuiltinType(block, src, name);
    return sema.resolveTypeFields(block, src, resolved_ty);
}

fn getBuiltin(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    name: []const u8,
) InnerError!*ir.Inst {
    const mod = sema.mod;
    const std_pkg = mod.root_pkg.table.get("std").?;
    const std_file = (mod.importPkg(std_pkg) catch unreachable).file;
    const opt_builtin_inst = try sema.analyzeNamespaceLookup(
        block,
        src,
        std_file.root_decl.?.namespace,
        "builtin",
    );
    const builtin_inst = try sema.analyzeLoad(block, src, opt_builtin_inst.?, src);
    const builtin_ty = try sema.resolveAirAsType(block, src, builtin_inst);
    const opt_ty_inst = try sema.analyzeNamespaceLookup(
        block,
        src,
        builtin_ty.getNamespace().?,
        name,
    );
    return sema.analyzeLoad(block, src, opt_ty_inst.?, src);
}

fn getBuiltinType(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    name: []const u8,
) InnerError!Type {
    const ty_inst = try sema.getBuiltin(block, src, name);
    return sema.resolveAirAsType(block, src, ty_inst);
}

/// There is another implementation of this in `Type.onePossibleValue`. This one
/// in `Sema` is for calling during semantic analysis, and peforms field resolution
/// to get the answer. The one in `Type` is for calling during codegen and asserts
/// that the types are already resolved.
fn typeHasOnePossibleValue(
    sema: *Sema,
    block: *Scope.Block,
    src: LazySrcLoc,
    starting_type: Type,
) InnerError!?Value {
    var ty = starting_type;
    while (true) switch (ty.tag()) {
        .f16,
        .f32,
        .f64,
        .f128,
        .c_longdouble,
        .comptime_int,
        .comptime_float,
        .u8,
        .i8,
        .u16,
        .i16,
        .u32,
        .i32,
        .u64,
        .i64,
        .u128,
        .i128,
        .usize,
        .isize,
        .c_short,
        .c_ushort,
        .c_int,
        .c_uint,
        .c_long,
        .c_ulong,
        .c_longlong,
        .c_ulonglong,
        .bool,
        .type,
        .anyerror,
        .fn_noreturn_no_args,
        .fn_void_no_args,
        .fn_naked_noreturn_no_args,
        .fn_ccc_void_no_args,
        .function,
        .single_const_pointer_to_comptime_int,
        .array_sentinel,
        .array_u8_sentinel_0,
        .const_slice_u8,
        .const_slice,
        .mut_slice,
        .c_void,
        .optional,
        .optional_single_mut_pointer,
        .optional_single_const_pointer,
        .enum_literal,
        .anyerror_void_error_union,
        .error_union,
        .error_set,
        .error_set_single,
        .error_set_inferred,
        .@"opaque",
        .var_args_param,
        .manyptr_u8,
        .manyptr_const_u8,
        .atomic_ordering,
        .atomic_rmw_op,
        .calling_convention,
        .float_mode,
        .reduce_op,
        .call_options,
        .export_options,
        .extern_options,
        .@"anyframe",
        .anyframe_T,
        .many_const_pointer,
        .many_mut_pointer,
        .c_const_pointer,
        .c_mut_pointer,
        .single_const_pointer,
        .single_mut_pointer,
        .pointer,
        => return null,

        .@"struct" => {
            const resolved_ty = try sema.resolveTypeFields(block, src, ty);
            const s = resolved_ty.castTag(.@"struct").?.data;
            for (s.fields.values()) |value| {
                if ((try sema.typeHasOnePossibleValue(block, src, value.ty)) == null) {
                    return null;
                }
            }
            return Value.initTag(.empty_struct_value);
        },
        .enum_full => {
            const resolved_ty = try sema.resolveTypeFields(block, src, ty);
            const enum_full = resolved_ty.castTag(.enum_full).?.data;
            if (enum_full.fields.count() == 1) {
                return enum_full.values.keys()[0];
            } else {
                return null;
            }
        },
        .enum_simple => {
            const resolved_ty = try sema.resolveTypeFields(block, src, ty);
            const enum_simple = resolved_ty.castTag(.enum_simple).?.data;
            if (enum_simple.fields.count() == 1) {
                return Value.initTag(.zero);
            } else {
                return null;
            }
        },
        .enum_nonexhaustive => ty = ty.castTag(.enum_nonexhaustive).?.data.tag_ty,
        .@"union" => {
            return null; // TODO
        },
        .union_tagged => {
            return null; // TODO
        },

        .empty_struct, .empty_struct_literal => return Value.initTag(.empty_struct_value),
        .void => return Value.initTag(.void_value),
        .noreturn => return Value.initTag(.unreachable_value),
        .@"null" => return Value.initTag(.null_value),
        .@"undefined" => return Value.initTag(.undef),

        .int_unsigned, .int_signed => {
            if (ty.cast(Type.Payload.Bits).?.data == 0) {
                return Value.initTag(.zero);
            } else {
                return null;
            }
        },
        .vector, .array, .array_u8 => {
            if (ty.arrayLen() == 0)
                return Value.initTag(.empty_array);
            ty = ty.elemType();
            continue;
        },

        .inferred_alloc_const => unreachable,
        .inferred_alloc_mut => unreachable,
    };
}

fn getAstTree(sema: *Sema, block: *Scope.Block) InnerError!*const std.zig.ast.Tree {
    return block.src_decl.namespace.file_scope.getTree(sema.gpa) catch |err| {
        log.err("unable to load AST to report compile error: {s}", .{@errorName(err)});
        return error.AnalysisFail;
    };
}

fn enumFieldSrcLoc(
    decl: *Decl,
    tree: std.zig.ast.Tree,
    node_offset: i32,
    field_index: usize,
) LazySrcLoc {
    @setCold(true);
    const enum_node = decl.relativeToNodeIndex(node_offset);
    const node_tags = tree.nodes.items(.tag);
    var buffer: [2]std.zig.ast.Node.Index = undefined;
    const container_decl = switch (node_tags[enum_node]) {
        .container_decl,
        .container_decl_trailing,
        => tree.containerDecl(enum_node),

        .container_decl_two,
        .container_decl_two_trailing,
        => tree.containerDeclTwo(&buffer, enum_node),

        .container_decl_arg,
        .container_decl_arg_trailing,
        => tree.containerDeclArg(enum_node),

        else => unreachable,
    };
    var it_index: usize = 0;
    for (container_decl.ast.members) |member_node| {
        switch (node_tags[member_node]) {
            .container_field_init,
            .container_field_align,
            .container_field,
            => {
                if (it_index == field_index) {
                    return .{ .node_offset = decl.nodeIndexToRelative(member_node) };
                }
                it_index += 1;
            },

            else => continue,
        }
    } else unreachable;
}
