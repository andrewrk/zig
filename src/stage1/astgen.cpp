/*
 * Copyright (c) 2021 Andrew Kelley
 *
 * This file is part of zig, which is MIT licensed.
 * See http://opensource.org/licenses/MIT
 */

#include "astgen.hpp"
#include "analyze.hpp"
#include "util.hpp"
#include "os.hpp"
#include "parser.hpp"

struct Stage1AstGen {
    CodeGen *codegen;
    Stage1Zir *exec;
    Stage1ZirBasicBlock *current_basic_block;
    AstNode *main_block_node;
    size_t next_debug_id;
    ZigFn *fn;
    bool in_c_import_scope;
};

static Stage1ZirInst *astgen_node(Stage1AstGen *ag, AstNode *node, Scope *scope);
static Stage1ZirInst *astgen_node_extra(Stage1AstGen *ag, AstNode *node, Scope *scope, LVal lval,
        ResultLoc *result_loc);

static Stage1ZirInst *ir_lval_wrap(Stage1AstGen *ag, Scope *scope, Stage1ZirInst *value, LVal lval,
        ResultLoc *result_loc);
static Stage1ZirInst *ir_expr_wrap(Stage1AstGen *ag, Scope *scope, Stage1ZirInst *inst,
        ResultLoc *result_loc);
static Stage1ZirInst *astgen_union_init_expr(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *union_type, Stage1ZirInst *field_name, AstNode *expr_node,
    LVal lval, ResultLoc *parent_result_loc);
static ResultLocCast *ir_build_cast_result_loc(Stage1AstGen *ag, Stage1ZirInst *dest_type,
        ResultLoc *parent_result_loc);
static ZigVar *ir_create_var(Stage1AstGen *ag, AstNode *node, Scope *scope, Buf *name,
        bool src_is_const, bool gen_is_const, bool is_shadowable, Stage1ZirInst *is_comptime);
static void build_decl_var_and_init(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        ZigVar *var, Stage1ZirInst *init, const char *name_hint, Stage1ZirInst *is_comptime);

static void ir_assert_impl(bool ok, Stage1ZirInst *source_instruction, char const *file, unsigned int line) {
    if (ok) return;
    src_assert_impl(ok, source_instruction->source_node, file, line);
}

static ErrorMsg *exec_add_error_node(CodeGen *codegen, Stage1Zir *exec, AstNode *source_node, Buf *msg) {
    ErrorMsg *err_msg = add_node_error(codegen, source_node, msg);
    invalidate_exec(exec, err_msg);
    return err_msg;
}


#define ir_assert(OK, SOURCE_INSTRUCTION) ir_assert_impl((OK), (SOURCE_INSTRUCTION), __FILE__, __LINE__)


static bool instr_is_unreachable(Stage1ZirInst *instruction) {
    switch (instruction->id) {
        case Stage1ZirInstIdCondBr:
        case Stage1ZirInstIdReturn:
        case Stage1ZirInstIdBr:
        case Stage1ZirInstIdUnreachable:
        case Stage1ZirInstIdSwitchBr:
        case Stage1ZirInstIdPanic:
            return true;
        default:
            return false;
    }
}

void destroy_instruction_src(Stage1ZirInst *inst) {
    switch (inst->id) {
        case Stage1ZirInstIdInvalid:
            zig_unreachable();
        case Stage1ZirInstIdReturn:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstReturn *>(inst));
        case Stage1ZirInstIdConst:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstConst *>(inst));
        case Stage1ZirInstIdBinOp:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstBinOp *>(inst));
        case Stage1ZirInstIdMergeErrSets:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstMergeErrSets *>(inst));
        case Stage1ZirInstIdDeclVar:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstDeclVar *>(inst));
        case Stage1ZirInstIdCall:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCall *>(inst));
        case Stage1ZirInstIdCallExtra:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCallExtra *>(inst));
        case Stage1ZirInstIdAsyncCallExtra:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstAsyncCallExtra *>(inst));
        case Stage1ZirInstIdUnOp:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstUnOp *>(inst));
        case Stage1ZirInstIdCondBr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCondBr *>(inst));
        case Stage1ZirInstIdBr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstBr *>(inst));
        case Stage1ZirInstIdPhi:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstPhi *>(inst));
        case Stage1ZirInstIdContainerInitList:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstContainerInitList *>(inst));
        case Stage1ZirInstIdContainerInitFields:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstContainerInitFields *>(inst));
        case Stage1ZirInstIdUnreachable:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstUnreachable *>(inst));
        case Stage1ZirInstIdElemPtr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstElemPtr *>(inst));
        case Stage1ZirInstIdVarPtr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstVarPtr *>(inst));
        case Stage1ZirInstIdLoadPtr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstLoadPtr *>(inst));
        case Stage1ZirInstIdStorePtr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstStorePtr *>(inst));
        case Stage1ZirInstIdTypeOf:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstTypeOf *>(inst));
        case Stage1ZirInstIdFieldPtr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstFieldPtr *>(inst));
        case Stage1ZirInstIdSetCold:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSetCold *>(inst));
        case Stage1ZirInstIdSetRuntimeSafety:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSetRuntimeSafety *>(inst));
        case Stage1ZirInstIdSetFloatMode:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSetFloatMode *>(inst));
        case Stage1ZirInstIdArrayType:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstArrayType *>(inst));
        case Stage1ZirInstIdSliceType:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSliceType *>(inst));
        case Stage1ZirInstIdAnyFrameType:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstAnyFrameType *>(inst));
        case Stage1ZirInstIdAsm:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstAsm *>(inst));
        case Stage1ZirInstIdSizeOf:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSizeOf *>(inst));
        case Stage1ZirInstIdTestNonNull:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstTestNonNull *>(inst));
        case Stage1ZirInstIdOptionalUnwrapPtr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstOptionalUnwrapPtr *>(inst));
        case Stage1ZirInstIdPopCount:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstPopCount *>(inst));
        case Stage1ZirInstIdClz:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstClz *>(inst));
        case Stage1ZirInstIdCtz:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCtz *>(inst));
        case Stage1ZirInstIdBswap:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstBswap *>(inst));
        case Stage1ZirInstIdBitReverse:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstBitReverse *>(inst));
        case Stage1ZirInstIdSwitchBr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSwitchBr *>(inst));
        case Stage1ZirInstIdSwitchVar:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSwitchVar *>(inst));
        case Stage1ZirInstIdSwitchElseVar:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSwitchElseVar *>(inst));
        case Stage1ZirInstIdSwitchTarget:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSwitchTarget *>(inst));
        case Stage1ZirInstIdImport:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstImport *>(inst));
        case Stage1ZirInstIdRef:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstRef *>(inst));
        case Stage1ZirInstIdCompileErr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCompileErr *>(inst));
        case Stage1ZirInstIdCompileLog:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCompileLog *>(inst));
        case Stage1ZirInstIdErrName:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstErrName *>(inst));
        case Stage1ZirInstIdCImport:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCImport *>(inst));
        case Stage1ZirInstIdCInclude:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCInclude *>(inst));
        case Stage1ZirInstIdCDefine:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCDefine *>(inst));
        case Stage1ZirInstIdCUndef:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCUndef *>(inst));
        case Stage1ZirInstIdEmbedFile:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstEmbedFile *>(inst));
        case Stage1ZirInstIdCmpxchg:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCmpxchg *>(inst));
        case Stage1ZirInstIdFence:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstFence *>(inst));
        case Stage1ZirInstIdReduce:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstReduce *>(inst));
        case Stage1ZirInstIdTruncate:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstTruncate *>(inst));
        case Stage1ZirInstIdIntCast:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstIntCast *>(inst));
        case Stage1ZirInstIdFloatCast:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstFloatCast *>(inst));
        case Stage1ZirInstIdErrSetCast:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstErrSetCast *>(inst));
        case Stage1ZirInstIdIntToFloat:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstIntToFloat *>(inst));
        case Stage1ZirInstIdFloatToInt:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstFloatToInt *>(inst));
        case Stage1ZirInstIdBoolToInt:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstBoolToInt *>(inst));
        case Stage1ZirInstIdVectorType:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstVectorType *>(inst));
        case Stage1ZirInstIdShuffleVector:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstShuffleVector *>(inst));
        case Stage1ZirInstIdSplat:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSplat *>(inst));
        case Stage1ZirInstIdBoolNot:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstBoolNot *>(inst));
        case Stage1ZirInstIdMemset:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstMemset *>(inst));
        case Stage1ZirInstIdMemcpy:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstMemcpy *>(inst));
        case Stage1ZirInstIdSlice:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSlice *>(inst));
        case Stage1ZirInstIdBreakpoint:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstBreakpoint *>(inst));
        case Stage1ZirInstIdReturnAddress:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstReturnAddress *>(inst));
        case Stage1ZirInstIdFrameAddress:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstFrameAddress *>(inst));
        case Stage1ZirInstIdFrameHandle:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstFrameHandle *>(inst));
        case Stage1ZirInstIdFrameType:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstFrameType *>(inst));
        case Stage1ZirInstIdFrameSize:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstFrameSize *>(inst));
        case Stage1ZirInstIdAlignOf:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstAlignOf *>(inst));
        case Stage1ZirInstIdOverflowOp:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstOverflowOp *>(inst));
        case Stage1ZirInstIdTestErr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstTestErr *>(inst));
        case Stage1ZirInstIdUnwrapErrCode:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstUnwrapErrCode *>(inst));
        case Stage1ZirInstIdUnwrapErrPayload:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstUnwrapErrPayload *>(inst));
        case Stage1ZirInstIdFnProto:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstFnProto *>(inst));
        case Stage1ZirInstIdTestComptime:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstTestComptime *>(inst));
        case Stage1ZirInstIdPtrCast:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstPtrCast *>(inst));
        case Stage1ZirInstIdBitCast:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstBitCast *>(inst));
        case Stage1ZirInstIdPtrToInt:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstPtrToInt *>(inst));
        case Stage1ZirInstIdIntToPtr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstIntToPtr *>(inst));
        case Stage1ZirInstIdIntToEnum:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstIntToEnum *>(inst));
        case Stage1ZirInstIdIntToErr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstIntToErr *>(inst));
        case Stage1ZirInstIdErrToInt:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstErrToInt *>(inst));
        case Stage1ZirInstIdCheckSwitchProngsUnderNo:
        case Stage1ZirInstIdCheckSwitchProngsUnderYes:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCheckSwitchProngs *>(inst));
        case Stage1ZirInstIdCheckStatementIsVoid:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCheckStatementIsVoid *>(inst));
        case Stage1ZirInstIdTypeName:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstTypeName *>(inst));
        case Stage1ZirInstIdTagName:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstTagName *>(inst));
        case Stage1ZirInstIdPtrType:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstPtrType *>(inst));
        case Stage1ZirInstIdPtrTypeSimple:
        case Stage1ZirInstIdPtrTypeSimpleConst:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstPtrTypeSimple *>(inst));
        case Stage1ZirInstIdDeclRef:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstDeclRef *>(inst));
        case Stage1ZirInstIdPanic:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstPanic *>(inst));
        case Stage1ZirInstIdFieldParentPtr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstFieldParentPtr *>(inst));
        case Stage1ZirInstIdOffsetOf:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstOffsetOf *>(inst));
        case Stage1ZirInstIdBitOffsetOf:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstBitOffsetOf *>(inst));
        case Stage1ZirInstIdTypeInfo:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstTypeInfo *>(inst));
        case Stage1ZirInstIdType:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstType *>(inst));
        case Stage1ZirInstIdHasField:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstHasField *>(inst));
        case Stage1ZirInstIdSetEvalBranchQuota:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSetEvalBranchQuota *>(inst));
        case Stage1ZirInstIdAlignCast:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstAlignCast *>(inst));
        case Stage1ZirInstIdImplicitCast:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstImplicitCast *>(inst));
        case Stage1ZirInstIdResolveResult:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstResolveResult *>(inst));
        case Stage1ZirInstIdResetResult:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstResetResult *>(inst));
        case Stage1ZirInstIdSetAlignStack:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSetAlignStack *>(inst));
        case Stage1ZirInstIdArgTypeAllowVarFalse:
        case Stage1ZirInstIdArgTypeAllowVarTrue:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstArgType *>(inst));
        case Stage1ZirInstIdExport:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstExport *>(inst));
        case Stage1ZirInstIdExtern:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstExtern *>(inst));
        case Stage1ZirInstIdErrorReturnTrace:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstErrorReturnTrace *>(inst));
        case Stage1ZirInstIdErrorUnion:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstErrorUnion *>(inst));
        case Stage1ZirInstIdAtomicRmw:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstAtomicRmw *>(inst));
        case Stage1ZirInstIdSaveErrRetAddr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSaveErrRetAddr *>(inst));
        case Stage1ZirInstIdAddImplicitReturnType:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstAddImplicitReturnType *>(inst));
        case Stage1ZirInstIdFloatOp:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstFloatOp *>(inst));
        case Stage1ZirInstIdMulAdd:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstMulAdd *>(inst));
        case Stage1ZirInstIdAtomicLoad:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstAtomicLoad *>(inst));
        case Stage1ZirInstIdAtomicStore:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstAtomicStore *>(inst));
        case Stage1ZirInstIdEnumToInt:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstEnumToInt *>(inst));
        case Stage1ZirInstIdCheckRuntimeScope:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCheckRuntimeScope *>(inst));
        case Stage1ZirInstIdHasDecl:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstHasDecl *>(inst));
        case Stage1ZirInstIdUndeclaredIdent:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstUndeclaredIdent *>(inst));
        case Stage1ZirInstIdAlloca:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstAlloca *>(inst));
        case Stage1ZirInstIdEndExpr:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstEndExpr *>(inst));
        case Stage1ZirInstIdUnionInitNamedField:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstUnionInitNamedField *>(inst));
        case Stage1ZirInstIdSuspendBegin:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSuspendBegin *>(inst));
        case Stage1ZirInstIdSuspendFinish:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSuspendFinish *>(inst));
        case Stage1ZirInstIdResume:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstResume *>(inst));
        case Stage1ZirInstIdAwait:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstAwait *>(inst));
        case Stage1ZirInstIdSpillBegin:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSpillBegin *>(inst));
        case Stage1ZirInstIdSpillEnd:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSpillEnd *>(inst));
        case Stage1ZirInstIdCallArgs:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstCallArgs *>(inst));
        case Stage1ZirInstIdWasmMemorySize:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstWasmMemorySize *>(inst));
        case Stage1ZirInstIdWasmMemoryGrow:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstWasmMemoryGrow *>(inst));
        case Stage1ZirInstIdSrc:
            return heap::c_allocator.destroy(reinterpret_cast<Stage1ZirInstSrc *>(inst));
    }
    zig_unreachable();
}


bool ir_should_inline(Stage1Zir *exec, Scope *scope) {
    if (exec->is_inline)
        return true;

    while (scope != nullptr) {
        if (scope->id == ScopeIdCompTime)
            return true;
        if (scope->id == ScopeIdTypeOf)
            return false;
        if (scope->id == ScopeIdFnDef)
            break;
        scope = scope->parent;
    }
    return false;
}

static void ir_instruction_append(Stage1ZirBasicBlock *basic_block, Stage1ZirInst *instruction) {
    assert(basic_block);
    assert(instruction);
    basic_block->instruction_list.append(instruction);
}

static size_t irb_next_debug_id(Stage1AstGen *ag) {
    size_t result = ag->next_debug_id;
    ag->next_debug_id += 1;
    return result;
}

static void ir_ref_bb(Stage1ZirBasicBlock *bb) {
    bb->ref_count += 1;
}

static void ir_ref_instruction(Stage1ZirInst *instruction, Stage1ZirBasicBlock *cur_bb) {
    assert(instruction->id != Stage1ZirInstIdInvalid);
    instruction->ref_count += 1;
    if (instruction->owner_bb != cur_bb && !instr_is_unreachable(instruction)
        && instruction->id != Stage1ZirInstIdConst)
    {
        ir_ref_bb(instruction->owner_bb);
    }
}

static Stage1ZirBasicBlock *ir_create_basic_block(Stage1AstGen *ag, Scope *scope, const char *name_hint) {
    Stage1ZirBasicBlock *result = heap::c_allocator.create<Stage1ZirBasicBlock>();
    result->scope = scope;
    result->name_hint = name_hint;
    result->debug_id = irb_next_debug_id(ag);
    result->index = UINT32_MAX; // set later
    return result;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstDeclVar *) {
    return Stage1ZirInstIdDeclVar;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstBr *) {
    return Stage1ZirInstIdBr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCondBr *) {
    return Stage1ZirInstIdCondBr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSwitchBr *) {
    return Stage1ZirInstIdSwitchBr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSwitchVar *) {
    return Stage1ZirInstIdSwitchVar;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSwitchElseVar *) {
    return Stage1ZirInstIdSwitchElseVar;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSwitchTarget *) {
    return Stage1ZirInstIdSwitchTarget;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstPhi *) {
    return Stage1ZirInstIdPhi;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstUnOp *) {
    return Stage1ZirInstIdUnOp;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstBinOp *) {
    return Stage1ZirInstIdBinOp;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstMergeErrSets *) {
    return Stage1ZirInstIdMergeErrSets;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstLoadPtr *) {
    return Stage1ZirInstIdLoadPtr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstStorePtr *) {
    return Stage1ZirInstIdStorePtr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstFieldPtr *) {
    return Stage1ZirInstIdFieldPtr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstElemPtr *) {
    return Stage1ZirInstIdElemPtr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstVarPtr *) {
    return Stage1ZirInstIdVarPtr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCall *) {
    return Stage1ZirInstIdCall;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCallArgs *) {
    return Stage1ZirInstIdCallArgs;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCallExtra *) {
    return Stage1ZirInstIdCallExtra;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstAsyncCallExtra *) {
    return Stage1ZirInstIdAsyncCallExtra;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstConst *) {
    return Stage1ZirInstIdConst;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstReturn *) {
    return Stage1ZirInstIdReturn;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstContainerInitList *) {
    return Stage1ZirInstIdContainerInitList;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstContainerInitFields *) {
    return Stage1ZirInstIdContainerInitFields;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstUnreachable *) {
    return Stage1ZirInstIdUnreachable;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstTypeOf *) {
    return Stage1ZirInstIdTypeOf;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSetCold *) {
    return Stage1ZirInstIdSetCold;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSetRuntimeSafety *) {
    return Stage1ZirInstIdSetRuntimeSafety;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSetFloatMode *) {
    return Stage1ZirInstIdSetFloatMode;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstArrayType *) {
    return Stage1ZirInstIdArrayType;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstAnyFrameType *) {
    return Stage1ZirInstIdAnyFrameType;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSliceType *) {
    return Stage1ZirInstIdSliceType;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstAsm *) {
    return Stage1ZirInstIdAsm;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSizeOf *) {
    return Stage1ZirInstIdSizeOf;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstTestNonNull *) {
    return Stage1ZirInstIdTestNonNull;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstOptionalUnwrapPtr *) {
    return Stage1ZirInstIdOptionalUnwrapPtr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstClz *) {
    return Stage1ZirInstIdClz;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCtz *) {
    return Stage1ZirInstIdCtz;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstPopCount *) {
    return Stage1ZirInstIdPopCount;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstBswap *) {
    return Stage1ZirInstIdBswap;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstBitReverse *) {
    return Stage1ZirInstIdBitReverse;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstImport *) {
    return Stage1ZirInstIdImport;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCImport *) {
    return Stage1ZirInstIdCImport;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCInclude *) {
    return Stage1ZirInstIdCInclude;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCDefine *) {
    return Stage1ZirInstIdCDefine;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCUndef *) {
    return Stage1ZirInstIdCUndef;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstRef *) {
    return Stage1ZirInstIdRef;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCompileErr *) {
    return Stage1ZirInstIdCompileErr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCompileLog *) {
    return Stage1ZirInstIdCompileLog;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstErrName *) {
    return Stage1ZirInstIdErrName;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstEmbedFile *) {
    return Stage1ZirInstIdEmbedFile;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCmpxchg *) {
    return Stage1ZirInstIdCmpxchg;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstFence *) {
    return Stage1ZirInstIdFence;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstReduce *) {
    return Stage1ZirInstIdReduce;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstTruncate *) {
    return Stage1ZirInstIdTruncate;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstIntCast *) {
    return Stage1ZirInstIdIntCast;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstFloatCast *) {
    return Stage1ZirInstIdFloatCast;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstIntToFloat *) {
    return Stage1ZirInstIdIntToFloat;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstFloatToInt *) {
    return Stage1ZirInstIdFloatToInt;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstBoolToInt *) {
    return Stage1ZirInstIdBoolToInt;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstVectorType *) {
    return Stage1ZirInstIdVectorType;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstShuffleVector *) {
    return Stage1ZirInstIdShuffleVector;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSplat *) {
    return Stage1ZirInstIdSplat;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstBoolNot *) {
    return Stage1ZirInstIdBoolNot;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstMemset *) {
    return Stage1ZirInstIdMemset;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstMemcpy *) {
    return Stage1ZirInstIdMemcpy;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSlice *) {
    return Stage1ZirInstIdSlice;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstBreakpoint *) {
    return Stage1ZirInstIdBreakpoint;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstReturnAddress *) {
    return Stage1ZirInstIdReturnAddress;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstFrameAddress *) {
    return Stage1ZirInstIdFrameAddress;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstFrameHandle *) {
    return Stage1ZirInstIdFrameHandle;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstFrameType *) {
    return Stage1ZirInstIdFrameType;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstFrameSize *) {
    return Stage1ZirInstIdFrameSize;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstAlignOf *) {
    return Stage1ZirInstIdAlignOf;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstOverflowOp *) {
    return Stage1ZirInstIdOverflowOp;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstTestErr *) {
    return Stage1ZirInstIdTestErr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstMulAdd *) {
    return Stage1ZirInstIdMulAdd;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstFloatOp *) {
    return Stage1ZirInstIdFloatOp;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstUnwrapErrCode *) {
    return Stage1ZirInstIdUnwrapErrCode;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstUnwrapErrPayload *) {
    return Stage1ZirInstIdUnwrapErrPayload;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstFnProto *) {
    return Stage1ZirInstIdFnProto;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstTestComptime *) {
    return Stage1ZirInstIdTestComptime;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstPtrCast *) {
    return Stage1ZirInstIdPtrCast;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstBitCast *) {
    return Stage1ZirInstIdBitCast;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstIntToPtr *) {
    return Stage1ZirInstIdIntToPtr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstPtrToInt *) {
    return Stage1ZirInstIdPtrToInt;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstIntToEnum *) {
    return Stage1ZirInstIdIntToEnum;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstEnumToInt *) {
    return Stage1ZirInstIdEnumToInt;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstIntToErr *) {
    return Stage1ZirInstIdIntToErr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstErrToInt *) {
    return Stage1ZirInstIdErrToInt;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCheckStatementIsVoid *) {
    return Stage1ZirInstIdCheckStatementIsVoid;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstTypeName *) {
    return Stage1ZirInstIdTypeName;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstDeclRef *) {
    return Stage1ZirInstIdDeclRef;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstPanic *) {
    return Stage1ZirInstIdPanic;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstTagName *) {
    return Stage1ZirInstIdTagName;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstFieldParentPtr *) {
    return Stage1ZirInstIdFieldParentPtr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstOffsetOf *) {
    return Stage1ZirInstIdOffsetOf;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstBitOffsetOf *) {
    return Stage1ZirInstIdBitOffsetOf;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstTypeInfo *) {
    return Stage1ZirInstIdTypeInfo;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstType *) {
    return Stage1ZirInstIdType;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstHasField *) {
    return Stage1ZirInstIdHasField;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSetEvalBranchQuota *) {
    return Stage1ZirInstIdSetEvalBranchQuota;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstPtrType *) {
    return Stage1ZirInstIdPtrType;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstAlignCast *) {
    return Stage1ZirInstIdAlignCast;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstImplicitCast *) {
    return Stage1ZirInstIdImplicitCast;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstResolveResult *) {
    return Stage1ZirInstIdResolveResult;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstResetResult *) {
    return Stage1ZirInstIdResetResult;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSetAlignStack *) {
    return Stage1ZirInstIdSetAlignStack;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstExport *) {
    return Stage1ZirInstIdExport;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstExtern *) {
    return Stage1ZirInstIdExtern;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstErrorReturnTrace *) {
    return Stage1ZirInstIdErrorReturnTrace;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstErrorUnion *) {
    return Stage1ZirInstIdErrorUnion;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstAtomicRmw *) {
    return Stage1ZirInstIdAtomicRmw;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstAtomicLoad *) {
    return Stage1ZirInstIdAtomicLoad;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstAtomicStore *) {
    return Stage1ZirInstIdAtomicStore;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSaveErrRetAddr *) {
    return Stage1ZirInstIdSaveErrRetAddr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstAddImplicitReturnType *) {
    return Stage1ZirInstIdAddImplicitReturnType;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstErrSetCast *) {
    return Stage1ZirInstIdErrSetCast;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstCheckRuntimeScope *) {
    return Stage1ZirInstIdCheckRuntimeScope;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstHasDecl *) {
    return Stage1ZirInstIdHasDecl;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstUndeclaredIdent *) {
    return Stage1ZirInstIdUndeclaredIdent;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstAlloca *) {
    return Stage1ZirInstIdAlloca;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstEndExpr *) {
    return Stage1ZirInstIdEndExpr;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstUnionInitNamedField *) {
    return Stage1ZirInstIdUnionInitNamedField;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSuspendBegin *) {
    return Stage1ZirInstIdSuspendBegin;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSuspendFinish *) {
    return Stage1ZirInstIdSuspendFinish;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstAwait *) {
    return Stage1ZirInstIdAwait;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstResume *) {
    return Stage1ZirInstIdResume;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSpillBegin *) {
    return Stage1ZirInstIdSpillBegin;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSpillEnd *) {
    return Stage1ZirInstIdSpillEnd;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstWasmMemorySize *) {
    return Stage1ZirInstIdWasmMemorySize;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstWasmMemoryGrow *) {
    return Stage1ZirInstIdWasmMemoryGrow;
}

static constexpr Stage1ZirInstId ir_inst_id(Stage1ZirInstSrc *) {
    return Stage1ZirInstIdSrc;
}

template<typename T>
static T *ir_create_instruction(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    T *special_instruction = heap::c_allocator.create<T>();
    special_instruction->base.id = ir_inst_id(special_instruction);
    special_instruction->base.scope = scope;
    special_instruction->base.source_node = source_node;
    special_instruction->base.debug_id = irb_next_debug_id(ag);
    special_instruction->base.owner_bb = ag->current_basic_block;
    return special_instruction;
}

template<typename T>
static T *ir_build_instruction(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    T *special_instruction = ir_create_instruction<T>(ag, scope, source_node);
    ir_instruction_append(ag->current_basic_block, &special_instruction->base);
    return special_instruction;
}

static Stage1ZirInst *ir_build_cond_br(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *condition,
        Stage1ZirBasicBlock *then_block, Stage1ZirBasicBlock *else_block, Stage1ZirInst *is_comptime)
{
    Stage1ZirInstCondBr *inst = ir_build_instruction<Stage1ZirInstCondBr>(ag, scope, source_node);
    inst->condition = condition;
    inst->then_block = then_block;
    inst->else_block = else_block;
    inst->is_comptime = is_comptime;

    ir_ref_instruction(condition, ag->current_basic_block);
    ir_ref_bb(then_block);
    ir_ref_bb(else_block);
    if (is_comptime != nullptr) ir_ref_instruction(is_comptime, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_return_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *operand) {
    Stage1ZirInstReturn *inst = ir_build_instruction<Stage1ZirInstReturn>(ag, scope, source_node);
    inst->operand = operand;

    if (operand != nullptr) ir_ref_instruction(operand, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_const_void(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    Stage1ZirInstConst *const_instruction = ir_create_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    ir_instruction_append(ag->current_basic_block, &const_instruction->base);
    const_instruction->value = ag->codegen->intern.for_void();
    return &const_instruction->base;
}

static Stage1ZirInst *ir_build_const_undefined(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    Stage1ZirInstConst *const_instruction = ir_create_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    ir_instruction_append(ag->current_basic_block, &const_instruction->base);
    const_instruction->value = ag->codegen->intern.for_undefined();
    const_instruction->value->special = ConstValSpecialUndef;
    return &const_instruction->base;
}

static Stage1ZirInst *ir_build_const_uint(Stage1AstGen *ag, Scope *scope, AstNode *source_node, uint64_t value) {
    Stage1ZirInstConst *const_instruction = ir_build_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    const_instruction->value = ag->codegen->pass1_arena->create<ZigValue>();
    const_instruction->value->type = ag->codegen->builtin_types.entry_num_lit_int;
    const_instruction->value->special = ConstValSpecialStatic;
    bigint_init_unsigned(&const_instruction->value->data.x_bigint, value);
    return &const_instruction->base;
}

static Stage1ZirInst *ir_build_const_bigint(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        BigInt bigint)
{
    Stage1ZirInstConst *const_instruction = ir_build_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    const_instruction->value = ag->codegen->pass1_arena->create<ZigValue>();
    const_instruction->value->type = ag->codegen->builtin_types.entry_num_lit_int;
    const_instruction->value->special = ConstValSpecialStatic;
    const_instruction->value->data.x_bigint = bigint;
    return &const_instruction->base;
}

static Stage1ZirInst *ir_build_const_bigfloat(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        BigFloat bigfloat)
{
    Stage1ZirInstConst *const_instruction = ir_build_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    const_instruction->value = ag->codegen->pass1_arena->create<ZigValue>();
    const_instruction->value->type = ag->codegen->builtin_types.entry_num_lit_float;
    const_instruction->value->special = ConstValSpecialStatic;
    const_instruction->value->data.x_bigfloat = bigfloat;
    return &const_instruction->base;
}

static Stage1ZirInst *ir_build_const_null(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    Stage1ZirInstConst *const_instruction = ir_create_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    ir_instruction_append(ag->current_basic_block, &const_instruction->base);
    const_instruction->value = ag->codegen->intern.for_null();
    return &const_instruction->base;
}

static Stage1ZirInst *ir_build_const_usize(Stage1AstGen *ag, Scope *scope, AstNode *source_node, uint64_t value) {
    Stage1ZirInstConst *const_instruction = ir_build_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    const_instruction->value = ag->codegen->pass1_arena->create<ZigValue>();
    const_instruction->value->type = ag->codegen->builtin_types.entry_usize;
    const_instruction->value->special = ConstValSpecialStatic;
    bigint_init_unsigned(&const_instruction->value->data.x_bigint, value);
    return &const_instruction->base;
}

static Stage1ZirInst *ir_create_const_type(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        ZigType *type_entry)
{
    Stage1ZirInstConst *const_instruction = ir_create_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    const_instruction->value = ag->codegen->pass1_arena->create<ZigValue>();
    const_instruction->value->type = ag->codegen->builtin_types.entry_type;
    const_instruction->value->special = ConstValSpecialStatic;
    const_instruction->value->data.x_type = type_entry;
    return &const_instruction->base;
}

static Stage1ZirInst *ir_build_const_type(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        ZigType *type_entry)
{
    Stage1ZirInst *instruction = ir_create_const_type(ag, scope, source_node, type_entry);
    ir_instruction_append(ag->current_basic_block, instruction);
    return instruction;
}

static Stage1ZirInst *ir_build_const_import(Stage1AstGen *ag, Scope *scope, AstNode *source_node, ZigType *import) {
    Stage1ZirInstConst *const_instruction = ir_build_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    const_instruction->value = ag->codegen->pass1_arena->create<ZigValue>();
    const_instruction->value->type = ag->codegen->builtin_types.entry_type;
    const_instruction->value->special = ConstValSpecialStatic;
    const_instruction->value->data.x_type = import;
    return &const_instruction->base;
}

static Stage1ZirInst *ir_build_const_bool(Stage1AstGen *ag, Scope *scope, AstNode *source_node, bool value) {
    Stage1ZirInstConst *const_instruction = ir_build_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    const_instruction->value = ag->codegen->pass1_arena->create<ZigValue>();
    const_instruction->value->type = ag->codegen->builtin_types.entry_bool;
    const_instruction->value->special = ConstValSpecialStatic;
    const_instruction->value->data.x_bool = value;
    return &const_instruction->base;
}

static Stage1ZirInst *ir_build_const_enum_literal(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Buf *name) {
    Stage1ZirInstConst *const_instruction = ir_build_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    const_instruction->value = ag->codegen->pass1_arena->create<ZigValue>();
    const_instruction->value->type = ag->codegen->builtin_types.entry_enum_literal;
    const_instruction->value->special = ConstValSpecialStatic;
    const_instruction->value->data.x_enum_literal = name;
    return &const_instruction->base;
}

// Consumes `str`.
static Stage1ZirInst *ir_create_const_str_lit(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Buf *str) {
    Stage1ZirInstConst *const_instruction = ir_create_instruction<Stage1ZirInstConst>(ag, scope, source_node);
    const_instruction->value = ag->codegen->pass1_arena->create<ZigValue>();
    init_const_str_lit(ag->codegen, const_instruction->value, str, true);

    return &const_instruction->base;
}

// Consumes `str`.
static Stage1ZirInst *ir_build_const_str_lit(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Buf *str) {
    Stage1ZirInst *instruction = ir_create_const_str_lit(ag, scope, source_node, str);
    ir_instruction_append(ag->current_basic_block, instruction);
    return instruction;
}

static Stage1ZirInst *ir_build_bin_op(Stage1AstGen *ag, Scope *scope, AstNode *source_node, IrBinOp op_id,
        Stage1ZirInst *op1, Stage1ZirInst *op2, bool safety_check_on)
{
    Stage1ZirInstBinOp *inst = ir_build_instruction<Stage1ZirInstBinOp>(ag, scope, source_node);
    inst->op_id = op_id;
    inst->op1 = op1;
    inst->op2 = op2;
    inst->safety_check_on = safety_check_on;

    ir_ref_instruction(op1, ag->current_basic_block);
    ir_ref_instruction(op2, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_merge_err_sets(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *op1, Stage1ZirInst *op2, Buf *type_name)
{
    Stage1ZirInstMergeErrSets *inst = ir_build_instruction<Stage1ZirInstMergeErrSets>(ag, scope, source_node);
    inst->op1 = op1;
    inst->op2 = op2;
    inst->type_name = type_name;

    ir_ref_instruction(op1, ag->current_basic_block);
    ir_ref_instruction(op2, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_var_ptr_x(Stage1AstGen *ag, Scope *scope, AstNode *source_node, ZigVar *var,
        ScopeFnDef *crossed_fndef_scope)
{
    Stage1ZirInstVarPtr *instruction = ir_build_instruction<Stage1ZirInstVarPtr>(ag, scope, source_node);
    instruction->var = var;
    instruction->crossed_fndef_scope = crossed_fndef_scope;

    var->ref_count += 1;

    return &instruction->base;
}

static Stage1ZirInst *ir_build_var_ptr(Stage1AstGen *ag, Scope *scope, AstNode *source_node, ZigVar *var) {
    return ir_build_var_ptr_x(ag, scope, source_node, var, nullptr);
}

static Stage1ZirInst *ir_build_elem_ptr(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *array_ptr, Stage1ZirInst *elem_index, bool safety_check_on, PtrLen ptr_len,
        AstNode *init_array_type_source_node)
{
    Stage1ZirInstElemPtr *instruction = ir_build_instruction<Stage1ZirInstElemPtr>(ag, scope, source_node);
    instruction->array_ptr = array_ptr;
    instruction->elem_index = elem_index;
    instruction->safety_check_on = safety_check_on;
    instruction->ptr_len = ptr_len;
    instruction->init_array_type_source_node = init_array_type_source_node;

    ir_ref_instruction(array_ptr, ag->current_basic_block);
    ir_ref_instruction(elem_index, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_field_ptr_instruction(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *container_ptr, Stage1ZirInst *field_name_expr, bool initializing)
{
    Stage1ZirInstFieldPtr *instruction = ir_build_instruction<Stage1ZirInstFieldPtr>(ag, scope, source_node);
    instruction->container_ptr = container_ptr;
    instruction->field_name_buffer = nullptr;
    instruction->field_name_expr = field_name_expr;
    instruction->initializing = initializing;

    ir_ref_instruction(container_ptr, ag->current_basic_block);
    ir_ref_instruction(field_name_expr, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_field_ptr(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *container_ptr, Buf *field_name, bool initializing)
{
    Stage1ZirInstFieldPtr *instruction = ir_build_instruction<Stage1ZirInstFieldPtr>(ag, scope, source_node);
    instruction->container_ptr = container_ptr;
    instruction->field_name_buffer = field_name;
    instruction->field_name_expr = nullptr;
    instruction->initializing = initializing;

    ir_ref_instruction(container_ptr, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_has_field(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *container_type, Stage1ZirInst *field_name)
{
    Stage1ZirInstHasField *instruction = ir_build_instruction<Stage1ZirInstHasField>(ag, scope, source_node);
    instruction->container_type = container_type;
    instruction->field_name = field_name;

    ir_ref_instruction(container_type, ag->current_basic_block);
    ir_ref_instruction(field_name, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_call_extra(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *options, Stage1ZirInst *fn_ref, Stage1ZirInst *args, ResultLoc *result_loc)
{
    Stage1ZirInstCallExtra *call_instruction = ir_build_instruction<Stage1ZirInstCallExtra>(ag, scope, source_node);
    call_instruction->options = options;
    call_instruction->fn_ref = fn_ref;
    call_instruction->args = args;
    call_instruction->result_loc = result_loc;

    ir_ref_instruction(options, ag->current_basic_block);
    ir_ref_instruction(fn_ref, ag->current_basic_block);
    ir_ref_instruction(args, ag->current_basic_block);

    return &call_instruction->base;
}

static Stage1ZirInst *ir_build_async_call_extra(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        CallModifier modifier, Stage1ZirInst *fn_ref, Stage1ZirInst *ret_ptr, Stage1ZirInst *new_stack, Stage1ZirInst *args, ResultLoc *result_loc)
{
    Stage1ZirInstAsyncCallExtra *call_instruction = ir_build_instruction<Stage1ZirInstAsyncCallExtra>(ag, scope, source_node);
    call_instruction->modifier = modifier;
    call_instruction->fn_ref = fn_ref;
    call_instruction->ret_ptr = ret_ptr;
    call_instruction->new_stack = new_stack;
    call_instruction->args = args;
    call_instruction->result_loc = result_loc;

    ir_ref_instruction(fn_ref, ag->current_basic_block);
    if (ret_ptr != nullptr) ir_ref_instruction(ret_ptr, ag->current_basic_block);
    ir_ref_instruction(new_stack, ag->current_basic_block);
    ir_ref_instruction(args, ag->current_basic_block);

    return &call_instruction->base;
}

static Stage1ZirInst *ir_build_call_args(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *options, Stage1ZirInst *fn_ref, Stage1ZirInst **args_ptr, size_t args_len,
        ResultLoc *result_loc)
{
    Stage1ZirInstCallArgs *call_instruction = ir_build_instruction<Stage1ZirInstCallArgs>(ag, scope, source_node);
    call_instruction->options = options;
    call_instruction->fn_ref = fn_ref;
    call_instruction->args_ptr = args_ptr;
    call_instruction->args_len = args_len;
    call_instruction->result_loc = result_loc;

    ir_ref_instruction(options, ag->current_basic_block);
    ir_ref_instruction(fn_ref, ag->current_basic_block);
    for (size_t i = 0; i < args_len; i += 1)
        ir_ref_instruction(args_ptr[i], ag->current_basic_block);

    return &call_instruction->base;
}

static Stage1ZirInst *ir_build_call_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        ZigFn *fn_entry, Stage1ZirInst *fn_ref, size_t arg_count, Stage1ZirInst **args,
        Stage1ZirInst *ret_ptr, CallModifier modifier, bool is_async_call_builtin,
        Stage1ZirInst *new_stack, ResultLoc *result_loc)
{
    Stage1ZirInstCall *call_instruction = ir_build_instruction<Stage1ZirInstCall>(ag, scope, source_node);
    call_instruction->fn_entry = fn_entry;
    call_instruction->fn_ref = fn_ref;
    call_instruction->args = args;
    call_instruction->arg_count = arg_count;
    call_instruction->modifier = modifier;
    call_instruction->is_async_call_builtin = is_async_call_builtin;
    call_instruction->new_stack = new_stack;
    call_instruction->result_loc = result_loc;
    call_instruction->ret_ptr = ret_ptr;

    if (fn_ref != nullptr) ir_ref_instruction(fn_ref, ag->current_basic_block);
    for (size_t i = 0; i < arg_count; i += 1)
        ir_ref_instruction(args[i], ag->current_basic_block);
    if (ret_ptr != nullptr) ir_ref_instruction(ret_ptr, ag->current_basic_block);
    if (new_stack != nullptr) ir_ref_instruction(new_stack, ag->current_basic_block);

    return &call_instruction->base;
}

static Stage1ZirInst *ir_build_phi(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        size_t incoming_count, Stage1ZirBasicBlock **incoming_blocks, Stage1ZirInst **incoming_values,
        ResultLocPeerParent *peer_parent)
{
    assert(incoming_count != 0);
    assert(incoming_count != SIZE_MAX);

    Stage1ZirInstPhi *phi_instruction = ir_build_instruction<Stage1ZirInstPhi>(ag, scope, source_node);
    phi_instruction->incoming_count = incoming_count;
    phi_instruction->incoming_blocks = incoming_blocks;
    phi_instruction->incoming_values = incoming_values;
    phi_instruction->peer_parent = peer_parent;

    for (size_t i = 0; i < incoming_count; i += 1) {
        ir_ref_bb(incoming_blocks[i]);
        ir_ref_instruction(incoming_values[i], ag->current_basic_block);
    }

    return &phi_instruction->base;
}

static Stage1ZirInst *ir_build_br(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirBasicBlock *dest_block, Stage1ZirInst *is_comptime)
{
    Stage1ZirInstBr *inst = ir_build_instruction<Stage1ZirInstBr>(ag, scope, source_node);
    inst->dest_block = dest_block;
    inst->is_comptime = is_comptime;

    ir_ref_bb(dest_block);
    if (is_comptime) ir_ref_instruction(is_comptime, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_ptr_type_simple(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *child_type, bool is_const)
{
    Stage1ZirInstPtrTypeSimple *inst = heap::c_allocator.create<Stage1ZirInstPtrTypeSimple>();
    inst->base.id = is_const ? Stage1ZirInstIdPtrTypeSimpleConst : Stage1ZirInstIdPtrTypeSimple;
    inst->base.scope = scope;
    inst->base.source_node = source_node;
    inst->base.debug_id = irb_next_debug_id(ag);
    inst->base.owner_bb = ag->current_basic_block;
    ir_instruction_append(ag->current_basic_block, &inst->base);

    inst->child_type = child_type;

    ir_ref_instruction(child_type, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_ptr_type(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *child_type, bool is_const, bool is_volatile, PtrLen ptr_len,
        Stage1ZirInst *sentinel, Stage1ZirInst *align_value,
        uint32_t bit_offset_start, uint32_t host_int_bytes, bool is_allow_zero)
{
    if (!is_volatile && ptr_len == PtrLenSingle && sentinel == nullptr && align_value == nullptr &&
            bit_offset_start == 0 && host_int_bytes == 0 && is_allow_zero == 0)
    {
        return ir_build_ptr_type_simple(ag, scope, source_node, child_type, is_const);
    }

    Stage1ZirInstPtrType *inst = ir_build_instruction<Stage1ZirInstPtrType>(ag, scope, source_node);
    inst->sentinel = sentinel;
    inst->align_value = align_value;
    inst->child_type = child_type;
    inst->is_const = is_const;
    inst->is_volatile = is_volatile;
    inst->ptr_len = ptr_len;
    inst->bit_offset_start = bit_offset_start;
    inst->host_int_bytes = host_int_bytes;
    inst->is_allow_zero = is_allow_zero;

    if (sentinel) ir_ref_instruction(sentinel, ag->current_basic_block);
    if (align_value) ir_ref_instruction(align_value, ag->current_basic_block);
    ir_ref_instruction(child_type, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_un_op_lval(Stage1AstGen *ag, Scope *scope, AstNode *source_node, IrUnOp op_id,
        Stage1ZirInst *value, LVal lval, ResultLoc *result_loc)
{
    Stage1ZirInstUnOp *instruction = ir_build_instruction<Stage1ZirInstUnOp>(ag, scope, source_node);
    instruction->op_id = op_id;
    instruction->value = value;
    instruction->lval = lval;
    instruction->result_loc = result_loc;

    ir_ref_instruction(value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_un_op(Stage1AstGen *ag, Scope *scope, AstNode *source_node, IrUnOp op_id,
        Stage1ZirInst *value)
{
    return ir_build_un_op_lval(ag, scope, source_node, op_id, value, LValNone, nullptr);
}

static Stage1ZirInst *ir_build_container_init_list(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        size_t item_count, Stage1ZirInst **elem_result_loc_list, Stage1ZirInst *result_loc,
        AstNode *init_array_type_source_node)
{
    Stage1ZirInstContainerInitList *container_init_list_instruction =
        ir_build_instruction<Stage1ZirInstContainerInitList>(ag, scope, source_node);
    container_init_list_instruction->item_count = item_count;
    container_init_list_instruction->elem_result_loc_list = elem_result_loc_list;
    container_init_list_instruction->result_loc = result_loc;
    container_init_list_instruction->init_array_type_source_node = init_array_type_source_node;

    for (size_t i = 0; i < item_count; i += 1) {
        ir_ref_instruction(elem_result_loc_list[i], ag->current_basic_block);
    }
    if (result_loc != nullptr) ir_ref_instruction(result_loc, ag->current_basic_block);

    return &container_init_list_instruction->base;
}

static Stage1ZirInst *ir_build_container_init_fields(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        size_t field_count, Stage1ZirInstContainerInitFieldsField *fields, Stage1ZirInst *result_loc)
{
    Stage1ZirInstContainerInitFields *container_init_fields_instruction =
        ir_build_instruction<Stage1ZirInstContainerInitFields>(ag, scope, source_node);
    container_init_fields_instruction->field_count = field_count;
    container_init_fields_instruction->fields = fields;
    container_init_fields_instruction->result_loc = result_loc;

    for (size_t i = 0; i < field_count; i += 1) {
        ir_ref_instruction(fields[i].result_loc, ag->current_basic_block);
    }
    if (result_loc != nullptr) ir_ref_instruction(result_loc, ag->current_basic_block);

    return &container_init_fields_instruction->base;
}

static Stage1ZirInst *ir_build_unreachable(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    Stage1ZirInstUnreachable *inst = ir_build_instruction<Stage1ZirInstUnreachable>(ag, scope, source_node);
    return &inst->base;
}

static Stage1ZirInstStorePtr *ir_build_store_ptr(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *ptr, Stage1ZirInst *value)
{
    Stage1ZirInstStorePtr *instruction = ir_build_instruction<Stage1ZirInstStorePtr>(ag, scope, source_node);
    instruction->ptr = ptr;
    instruction->value = value;

    ir_ref_instruction(ptr, ag->current_basic_block);
    ir_ref_instruction(value, ag->current_basic_block);

    return instruction;
}

static Stage1ZirInst *ir_build_var_decl_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        ZigVar *var, Stage1ZirInst *align_value, Stage1ZirInst *ptr)
{
    Stage1ZirInstDeclVar *inst = ir_build_instruction<Stage1ZirInstDeclVar>(ag, scope, source_node);
    inst->var = var;
    inst->align_value = align_value;
    inst->ptr = ptr;

    if (align_value != nullptr) ir_ref_instruction(align_value, ag->current_basic_block);
    ir_ref_instruction(ptr, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_export(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *target, Stage1ZirInst *options)
{
    Stage1ZirInstExport *export_instruction = ir_build_instruction<Stage1ZirInstExport>(
            ag, scope, source_node);
    export_instruction->target = target;
    export_instruction->options = options;

    ir_ref_instruction(target, ag->current_basic_block);
    ir_ref_instruction(options, ag->current_basic_block);

    return &export_instruction->base;
}

static Stage1ZirInst *ir_build_extern(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *type, Stage1ZirInst *options)
{
    Stage1ZirInstExtern *extern_instruction = ir_build_instruction<Stage1ZirInstExtern>(
            ag, scope, source_node);
    extern_instruction->type = type;
    extern_instruction->options = options;

    ir_ref_instruction(type, ag->current_basic_block);
    ir_ref_instruction(options, ag->current_basic_block);

    return &extern_instruction->base;
}

static Stage1ZirInst *ir_build_load_ptr(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *ptr) {
    Stage1ZirInstLoadPtr *instruction = ir_build_instruction<Stage1ZirInstLoadPtr>(ag, scope, source_node);
    instruction->ptr = ptr;

    ir_ref_instruction(ptr, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_typeof_n(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst **values, size_t value_count)
{
    assert(value_count >= 2);

    Stage1ZirInstTypeOf *instruction = ir_build_instruction<Stage1ZirInstTypeOf>(ag, scope, source_node);
    instruction->value.list = values;
    instruction->value_count = value_count;

    for (size_t i = 0; i < value_count; i++)
        ir_ref_instruction(values[i], ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_typeof_1(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *value) {
    Stage1ZirInstTypeOf *instruction = ir_build_instruction<Stage1ZirInstTypeOf>(ag, scope, source_node);
    instruction->value.scalar = value;

    ir_ref_instruction(value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_set_cold(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *is_cold) {
    Stage1ZirInstSetCold *instruction = ir_build_instruction<Stage1ZirInstSetCold>(ag, scope, source_node);
    instruction->is_cold = is_cold;

    ir_ref_instruction(is_cold, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_set_runtime_safety(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *safety_on)
{
    Stage1ZirInstSetRuntimeSafety *inst = ir_build_instruction<Stage1ZirInstSetRuntimeSafety>(ag, scope, source_node);
    inst->safety_on = safety_on;

    ir_ref_instruction(safety_on, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_set_float_mode(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *mode_value)
{
    Stage1ZirInstSetFloatMode *instruction = ir_build_instruction<Stage1ZirInstSetFloatMode>(ag, scope, source_node);
    instruction->mode_value = mode_value;

    ir_ref_instruction(mode_value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_array_type(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *size,
        Stage1ZirInst *sentinel, Stage1ZirInst *child_type)
{
    Stage1ZirInstArrayType *instruction = ir_build_instruction<Stage1ZirInstArrayType>(ag, scope, source_node);
    instruction->size = size;
    instruction->sentinel = sentinel;
    instruction->child_type = child_type;

    ir_ref_instruction(size, ag->current_basic_block);
    if (sentinel != nullptr) ir_ref_instruction(sentinel, ag->current_basic_block);
    ir_ref_instruction(child_type, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_anyframe_type(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *payload_type)
{
    Stage1ZirInstAnyFrameType *instruction = ir_build_instruction<Stage1ZirInstAnyFrameType>(ag, scope, source_node);
    instruction->payload_type = payload_type;

    if (payload_type != nullptr) ir_ref_instruction(payload_type, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_slice_type(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *child_type, bool is_const, bool is_volatile,
        Stage1ZirInst *sentinel, Stage1ZirInst *align_value, bool is_allow_zero)
{
    Stage1ZirInstSliceType *instruction = ir_build_instruction<Stage1ZirInstSliceType>(ag, scope, source_node);
    instruction->is_const = is_const;
    instruction->is_volatile = is_volatile;
    instruction->child_type = child_type;
    instruction->sentinel = sentinel;
    instruction->align_value = align_value;
    instruction->is_allow_zero = is_allow_zero;

    if (sentinel != nullptr) ir_ref_instruction(sentinel, ag->current_basic_block);
    if (align_value != nullptr) ir_ref_instruction(align_value, ag->current_basic_block);
    ir_ref_instruction(child_type, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_asm_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *asm_template, Stage1ZirInst **input_list, Stage1ZirInst **output_types,
        ZigVar **output_vars, size_t return_count, bool has_side_effects, bool is_global)
{
    Stage1ZirInstAsm *instruction = ir_build_instruction<Stage1ZirInstAsm>(ag, scope, source_node);
    instruction->asm_template = asm_template;
    instruction->input_list = input_list;
    instruction->output_types = output_types;
    instruction->output_vars = output_vars;
    instruction->return_count = return_count;
    instruction->has_side_effects = has_side_effects;
    instruction->is_global = is_global;

    assert(source_node->type == NodeTypeAsmExpr);
    for (size_t i = 0; i < source_node->data.asm_expr.output_list.length; i += 1) {
        Stage1ZirInst *output_type = output_types[i];
        if (output_type) ir_ref_instruction(output_type, ag->current_basic_block);
    }

    for (size_t i = 0; i < source_node->data.asm_expr.input_list.length; i += 1) {
        Stage1ZirInst *input_value = input_list[i];
        ir_ref_instruction(input_value, ag->current_basic_block);
    }

    return &instruction->base;
}

static Stage1ZirInst *ir_build_size_of(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *type_value,
        bool bit_size)
{
    Stage1ZirInstSizeOf *instruction = ir_build_instruction<Stage1ZirInstSizeOf>(ag, scope, source_node);
    instruction->type_value = type_value;
    instruction->bit_size = bit_size;

    ir_ref_instruction(type_value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_test_non_null_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *value)
{
    Stage1ZirInstTestNonNull *instruction = ir_build_instruction<Stage1ZirInstTestNonNull>(ag, scope, source_node);
    instruction->value = value;

    ir_ref_instruction(value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_optional_unwrap_ptr(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *base_ptr, bool safety_check_on)
{
    Stage1ZirInstOptionalUnwrapPtr *instruction = ir_build_instruction<Stage1ZirInstOptionalUnwrapPtr>(ag, scope, source_node);
    instruction->base_ptr = base_ptr;
    instruction->safety_check_on = safety_check_on;

    ir_ref_instruction(base_ptr, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_clz(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *type,
        Stage1ZirInst *op)
{
    Stage1ZirInstClz *instruction = ir_build_instruction<Stage1ZirInstClz>(ag, scope, source_node);
    instruction->type = type;
    instruction->op = op;

    ir_ref_instruction(type, ag->current_basic_block);
    ir_ref_instruction(op, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_ctz(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *type,
        Stage1ZirInst *op)
{
    Stage1ZirInstCtz *instruction = ir_build_instruction<Stage1ZirInstCtz>(ag, scope, source_node);
    instruction->type = type;
    instruction->op = op;

    ir_ref_instruction(type, ag->current_basic_block);
    ir_ref_instruction(op, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_pop_count(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *type,
        Stage1ZirInst *op)
{
    Stage1ZirInstPopCount *instruction = ir_build_instruction<Stage1ZirInstPopCount>(ag, scope, source_node);
    instruction->type = type;
    instruction->op = op;

    ir_ref_instruction(type, ag->current_basic_block);
    ir_ref_instruction(op, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_bswap(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *type,
        Stage1ZirInst *op)
{
    Stage1ZirInstBswap *instruction = ir_build_instruction<Stage1ZirInstBswap>(ag, scope, source_node);
    instruction->type = type;
    instruction->op = op;

    ir_ref_instruction(type, ag->current_basic_block);
    ir_ref_instruction(op, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_bit_reverse(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *type,
        Stage1ZirInst *op)
{
    Stage1ZirInstBitReverse *instruction = ir_build_instruction<Stage1ZirInstBitReverse>(ag, scope, source_node);
    instruction->type = type;
    instruction->op = op;

    ir_ref_instruction(type, ag->current_basic_block);
    ir_ref_instruction(op, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInstSwitchBr *ir_build_switch_br_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *target_value, Stage1ZirBasicBlock *else_block, size_t case_count, Stage1ZirInstSwitchBrCase *cases,
        Stage1ZirInst *is_comptime, Stage1ZirInst *switch_prongs_void)
{
    Stage1ZirInstSwitchBr *instruction = ir_build_instruction<Stage1ZirInstSwitchBr>(ag, scope, source_node);
    instruction->target_value = target_value;
    instruction->else_block = else_block;
    instruction->case_count = case_count;
    instruction->cases = cases;
    instruction->is_comptime = is_comptime;
    instruction->switch_prongs_void = switch_prongs_void;

    ir_ref_instruction(target_value, ag->current_basic_block);
    ir_ref_instruction(is_comptime, ag->current_basic_block);
    ir_ref_bb(else_block);
    ir_ref_instruction(switch_prongs_void, ag->current_basic_block);

    for (size_t i = 0; i < case_count; i += 1) {
        ir_ref_instruction(cases[i].value, ag->current_basic_block);
        ir_ref_bb(cases[i].block);
    }

    return instruction;
}

static Stage1ZirInst *ir_build_switch_target(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *target_value_ptr)
{
    Stage1ZirInstSwitchTarget *instruction = ir_build_instruction<Stage1ZirInstSwitchTarget>(ag, scope, source_node);
    instruction->target_value_ptr = target_value_ptr;

    ir_ref_instruction(target_value_ptr, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_switch_var(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *target_value_ptr, Stage1ZirInst **prongs_ptr, size_t prongs_len)
{
    Stage1ZirInstSwitchVar *instruction = ir_build_instruction<Stage1ZirInstSwitchVar>(ag, scope, source_node);
    instruction->target_value_ptr = target_value_ptr;
    instruction->prongs_ptr = prongs_ptr;
    instruction->prongs_len = prongs_len;

    ir_ref_instruction(target_value_ptr, ag->current_basic_block);
    for (size_t i = 0; i < prongs_len; i += 1) {
        ir_ref_instruction(prongs_ptr[i], ag->current_basic_block);
    }

    return &instruction->base;
}

// For this instruction the switch_br must be set later.
static Stage1ZirInstSwitchElseVar *ir_build_switch_else_var(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *target_value_ptr)
{
    Stage1ZirInstSwitchElseVar *instruction = ir_build_instruction<Stage1ZirInstSwitchElseVar>(ag, scope, source_node);
    instruction->target_value_ptr = target_value_ptr;

    ir_ref_instruction(target_value_ptr, ag->current_basic_block);

    return instruction;
}

static Stage1ZirInst *ir_build_import(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *name) {
    Stage1ZirInstImport *instruction = ir_build_instruction<Stage1ZirInstImport>(ag, scope, source_node);
    instruction->name = name;

    ir_ref_instruction(name, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_ref_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *value) {
    Stage1ZirInstRef *instruction = ir_build_instruction<Stage1ZirInstRef>(ag, scope, source_node);
    instruction->value = value;

    ir_ref_instruction(value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_compile_err(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *msg) {
    Stage1ZirInstCompileErr *instruction = ir_build_instruction<Stage1ZirInstCompileErr>(ag, scope, source_node);
    instruction->msg = msg;

    ir_ref_instruction(msg, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_compile_log(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        size_t msg_count, Stage1ZirInst **msg_list)
{
    Stage1ZirInstCompileLog *instruction = ir_build_instruction<Stage1ZirInstCompileLog>(ag, scope, source_node);
    instruction->msg_count = msg_count;
    instruction->msg_list = msg_list;

    for (size_t i = 0; i < msg_count; i += 1) {
        ir_ref_instruction(msg_list[i], ag->current_basic_block);
    }

    return &instruction->base;
}

static Stage1ZirInst *ir_build_err_name(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *value) {
    Stage1ZirInstErrName *instruction = ir_build_instruction<Stage1ZirInstErrName>(ag, scope, source_node);
    instruction->value = value;

    ir_ref_instruction(value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_c_import(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    Stage1ZirInstCImport *instruction = ir_build_instruction<Stage1ZirInstCImport>(ag, scope, source_node);
    return &instruction->base;
}

static Stage1ZirInst *ir_build_c_include(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *name) {
    Stage1ZirInstCInclude *instruction = ir_build_instruction<Stage1ZirInstCInclude>(ag, scope, source_node);
    instruction->name = name;

    ir_ref_instruction(name, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_c_define(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *name, Stage1ZirInst *value) {
    Stage1ZirInstCDefine *instruction = ir_build_instruction<Stage1ZirInstCDefine>(ag, scope, source_node);
    instruction->name = name;
    instruction->value = value;

    ir_ref_instruction(name, ag->current_basic_block);
    ir_ref_instruction(value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_c_undef(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *name) {
    Stage1ZirInstCUndef *instruction = ir_build_instruction<Stage1ZirInstCUndef>(ag, scope, source_node);
    instruction->name = name;

    ir_ref_instruction(name, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_embed_file(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *name) {
    Stage1ZirInstEmbedFile *instruction = ir_build_instruction<Stage1ZirInstEmbedFile>(ag, scope, source_node);
    instruction->name = name;

    ir_ref_instruction(name, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_cmpxchg_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *type_value, Stage1ZirInst *ptr, Stage1ZirInst *cmp_value, Stage1ZirInst *new_value,
    Stage1ZirInst *success_order_value, Stage1ZirInst *failure_order_value, bool is_weak, ResultLoc *result_loc)
{
    Stage1ZirInstCmpxchg *instruction = ir_build_instruction<Stage1ZirInstCmpxchg>(ag, scope, source_node);
    instruction->type_value = type_value;
    instruction->ptr = ptr;
    instruction->cmp_value = cmp_value;
    instruction->new_value = new_value;
    instruction->success_order_value = success_order_value;
    instruction->failure_order_value = failure_order_value;
    instruction->is_weak = is_weak;
    instruction->result_loc = result_loc;

    ir_ref_instruction(type_value, ag->current_basic_block);
    ir_ref_instruction(ptr, ag->current_basic_block);
    ir_ref_instruction(cmp_value, ag->current_basic_block);
    ir_ref_instruction(new_value, ag->current_basic_block);
    ir_ref_instruction(success_order_value, ag->current_basic_block);
    ir_ref_instruction(failure_order_value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_fence(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *order) {
    Stage1ZirInstFence *instruction = ir_build_instruction<Stage1ZirInstFence>(ag, scope, source_node);
    instruction->order = order;

    ir_ref_instruction(order, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_reduce(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *op, Stage1ZirInst *value) {
    Stage1ZirInstReduce *instruction = ir_build_instruction<Stage1ZirInstReduce>(ag, scope, source_node);
    instruction->op = op;
    instruction->value = value;

    ir_ref_instruction(op, ag->current_basic_block);
    ir_ref_instruction(value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_truncate(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *dest_type, Stage1ZirInst *target)
{
    Stage1ZirInstTruncate *instruction = ir_build_instruction<Stage1ZirInstTruncate>(ag, scope, source_node);
    instruction->dest_type = dest_type;
    instruction->target = target;

    ir_ref_instruction(dest_type, ag->current_basic_block);
    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_int_cast(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *dest_type,
        Stage1ZirInst *target)
{
    Stage1ZirInstIntCast *instruction = ir_build_instruction<Stage1ZirInstIntCast>(ag, scope, source_node);
    instruction->dest_type = dest_type;
    instruction->target = target;

    ir_ref_instruction(dest_type, ag->current_basic_block);
    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_float_cast(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *dest_type,
        Stage1ZirInst *target)
{
    Stage1ZirInstFloatCast *instruction = ir_build_instruction<Stage1ZirInstFloatCast>(ag, scope, source_node);
    instruction->dest_type = dest_type;
    instruction->target = target;

    ir_ref_instruction(dest_type, ag->current_basic_block);
    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_err_set_cast(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *dest_type, Stage1ZirInst *target)
{
    Stage1ZirInstErrSetCast *instruction = ir_build_instruction<Stage1ZirInstErrSetCast>(ag, scope, source_node);
    instruction->dest_type = dest_type;
    instruction->target = target;

    ir_ref_instruction(dest_type, ag->current_basic_block);
    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_int_to_float(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *dest_type, Stage1ZirInst *target)
{
    Stage1ZirInstIntToFloat *instruction = ir_build_instruction<Stage1ZirInstIntToFloat>(ag, scope, source_node);
    instruction->dest_type = dest_type;
    instruction->target = target;

    ir_ref_instruction(dest_type, ag->current_basic_block);
    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_float_to_int(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *dest_type, Stage1ZirInst *target)
{
    Stage1ZirInstFloatToInt *instruction = ir_build_instruction<Stage1ZirInstFloatToInt>(ag, scope, source_node);
    instruction->dest_type = dest_type;
    instruction->target = target;

    ir_ref_instruction(dest_type, ag->current_basic_block);
    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_bool_to_int(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *target) {
    Stage1ZirInstBoolToInt *instruction = ir_build_instruction<Stage1ZirInstBoolToInt>(ag, scope, source_node);
    instruction->target = target;

    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_vector_type(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *len,
        Stage1ZirInst *elem_type)
{
    Stage1ZirInstVectorType *instruction = ir_build_instruction<Stage1ZirInstVectorType>(ag, scope, source_node);
    instruction->len = len;
    instruction->elem_type = elem_type;

    ir_ref_instruction(len, ag->current_basic_block);
    ir_ref_instruction(elem_type, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_shuffle_vector(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *scalar_type, Stage1ZirInst *a, Stage1ZirInst *b, Stage1ZirInst *mask)
{
    Stage1ZirInstShuffleVector *instruction = ir_build_instruction<Stage1ZirInstShuffleVector>(ag, scope, source_node);
    instruction->scalar_type = scalar_type;
    instruction->a = a;
    instruction->b = b;
    instruction->mask = mask;

    if (scalar_type != nullptr) ir_ref_instruction(scalar_type, ag->current_basic_block);
    ir_ref_instruction(a, ag->current_basic_block);
    ir_ref_instruction(b, ag->current_basic_block);
    ir_ref_instruction(mask, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_splat_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *len, Stage1ZirInst *scalar)
{
    Stage1ZirInstSplat *instruction = ir_build_instruction<Stage1ZirInstSplat>(ag, scope, source_node);
    instruction->len = len;
    instruction->scalar = scalar;

    ir_ref_instruction(len, ag->current_basic_block);
    ir_ref_instruction(scalar, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_bool_not(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *value) {
    Stage1ZirInstBoolNot *instruction = ir_build_instruction<Stage1ZirInstBoolNot>(ag, scope, source_node);
    instruction->value = value;

    ir_ref_instruction(value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_memset_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *dest_ptr, Stage1ZirInst *byte, Stage1ZirInst *count)
{
    Stage1ZirInstMemset *instruction = ir_build_instruction<Stage1ZirInstMemset>(ag, scope, source_node);
    instruction->dest_ptr = dest_ptr;
    instruction->byte = byte;
    instruction->count = count;

    ir_ref_instruction(dest_ptr, ag->current_basic_block);
    ir_ref_instruction(byte, ag->current_basic_block);
    ir_ref_instruction(count, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_memcpy_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *dest_ptr, Stage1ZirInst *src_ptr, Stage1ZirInst *count)
{
    Stage1ZirInstMemcpy *instruction = ir_build_instruction<Stage1ZirInstMemcpy>(ag, scope, source_node);
    instruction->dest_ptr = dest_ptr;
    instruction->src_ptr = src_ptr;
    instruction->count = count;

    ir_ref_instruction(dest_ptr, ag->current_basic_block);
    ir_ref_instruction(src_ptr, ag->current_basic_block);
    ir_ref_instruction(count, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_slice_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *ptr, Stage1ZirInst *start, Stage1ZirInst *end, Stage1ZirInst *sentinel,
    bool safety_check_on, ResultLoc *result_loc)
{
    Stage1ZirInstSlice *instruction = ir_build_instruction<Stage1ZirInstSlice>(ag, scope, source_node);
    instruction->ptr = ptr;
    instruction->start = start;
    instruction->end = end;
    instruction->sentinel = sentinel;
    instruction->safety_check_on = safety_check_on;
    instruction->result_loc = result_loc;

    ir_ref_instruction(ptr, ag->current_basic_block);
    ir_ref_instruction(start, ag->current_basic_block);
    if (end) ir_ref_instruction(end, ag->current_basic_block);
    if (sentinel) ir_ref_instruction(sentinel, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_breakpoint(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    Stage1ZirInstBreakpoint *instruction = ir_build_instruction<Stage1ZirInstBreakpoint>(ag, scope, source_node);
    return &instruction->base;
}

static Stage1ZirInst *ir_build_return_address_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    Stage1ZirInstReturnAddress *instruction = ir_build_instruction<Stage1ZirInstReturnAddress>(ag, scope, source_node);
    return &instruction->base;
}

static Stage1ZirInst *ir_build_frame_address_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    Stage1ZirInstFrameAddress *inst = ir_build_instruction<Stage1ZirInstFrameAddress>(ag, scope, source_node);
    return &inst->base;
}

static Stage1ZirInst *ir_build_handle_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    Stage1ZirInstFrameHandle *inst = ir_build_instruction<Stage1ZirInstFrameHandle>(ag, scope, source_node);
    return &inst->base;
}

static Stage1ZirInst *ir_build_frame_type(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *fn) {
    Stage1ZirInstFrameType *inst = ir_build_instruction<Stage1ZirInstFrameType>(ag, scope, source_node);
    inst->fn = fn;

    ir_ref_instruction(fn, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_frame_size_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *fn) {
    Stage1ZirInstFrameSize *inst = ir_build_instruction<Stage1ZirInstFrameSize>(ag, scope, source_node);
    inst->fn = fn;

    ir_ref_instruction(fn, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_overflow_op_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        IrOverflowOp op, Stage1ZirInst *type_value, Stage1ZirInst *op1, Stage1ZirInst *op2, Stage1ZirInst *result_ptr)
{
    Stage1ZirInstOverflowOp *instruction = ir_build_instruction<Stage1ZirInstOverflowOp>(ag, scope, source_node);
    instruction->op = op;
    instruction->type_value = type_value;
    instruction->op1 = op1;
    instruction->op2 = op2;
    instruction->result_ptr = result_ptr;

    ir_ref_instruction(type_value, ag->current_basic_block);
    ir_ref_instruction(op1, ag->current_basic_block);
    ir_ref_instruction(op2, ag->current_basic_block);
    ir_ref_instruction(result_ptr, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_float_op_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *operand,
        BuiltinFnId fn_id)
{
    Stage1ZirInstFloatOp *instruction = ir_build_instruction<Stage1ZirInstFloatOp>(ag, scope, source_node);
    instruction->operand = operand;
    instruction->fn_id = fn_id;

    ir_ref_instruction(operand, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_mul_add_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *type_value, Stage1ZirInst *op1, Stage1ZirInst *op2, Stage1ZirInst *op3)
{
    Stage1ZirInstMulAdd *instruction = ir_build_instruction<Stage1ZirInstMulAdd>(ag, scope, source_node);
    instruction->type_value = type_value;
    instruction->op1 = op1;
    instruction->op2 = op2;
    instruction->op3 = op3;

    ir_ref_instruction(type_value, ag->current_basic_block);
    ir_ref_instruction(op1, ag->current_basic_block);
    ir_ref_instruction(op2, ag->current_basic_block);
    ir_ref_instruction(op3, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_align_of(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *type_value) {
    Stage1ZirInstAlignOf *instruction = ir_build_instruction<Stage1ZirInstAlignOf>(ag, scope, source_node);
    instruction->type_value = type_value;

    ir_ref_instruction(type_value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_test_err_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *base_ptr, bool resolve_err_set, bool base_ptr_is_payload)
{
    Stage1ZirInstTestErr *instruction = ir_build_instruction<Stage1ZirInstTestErr>(ag, scope, source_node);
    instruction->base_ptr = base_ptr;
    instruction->resolve_err_set = resolve_err_set;
    instruction->base_ptr_is_payload = base_ptr_is_payload;

    ir_ref_instruction(base_ptr, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_unwrap_err_code_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *err_union_ptr)
{
    Stage1ZirInstUnwrapErrCode *inst = ir_build_instruction<Stage1ZirInstUnwrapErrCode>(ag, scope, source_node);
    inst->err_union_ptr = err_union_ptr;

    ir_ref_instruction(err_union_ptr, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_unwrap_err_payload_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *value, bool safety_check_on, bool initializing)
{
    Stage1ZirInstUnwrapErrPayload *inst = ir_build_instruction<Stage1ZirInstUnwrapErrPayload>(ag, scope, source_node);
    inst->value = value;
    inst->safety_check_on = safety_check_on;
    inst->initializing = initializing;

    ir_ref_instruction(value, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_fn_proto(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst **param_types, Stage1ZirInst *align_value, Stage1ZirInst *callconv_value,
    Stage1ZirInst *return_type, bool is_var_args)
{
    Stage1ZirInstFnProto *instruction = ir_build_instruction<Stage1ZirInstFnProto>(ag, scope, source_node);
    instruction->param_types = param_types;
    instruction->align_value = align_value;
    instruction->callconv_value = callconv_value;
    instruction->return_type = return_type;
    instruction->is_var_args = is_var_args;

    assert(source_node->type == NodeTypeFnProto);
    size_t param_count = source_node->data.fn_proto.params.length;
    if (is_var_args) param_count -= 1;
    for (size_t i = 0; i < param_count; i += 1) {
        if (param_types[i] != nullptr) ir_ref_instruction(param_types[i], ag->current_basic_block);
    }
    if (align_value != nullptr) ir_ref_instruction(align_value, ag->current_basic_block);
    if (callconv_value != nullptr) ir_ref_instruction(callconv_value, ag->current_basic_block);
    ir_ref_instruction(return_type, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_test_comptime(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *value) {
    Stage1ZirInstTestComptime *instruction = ir_build_instruction<Stage1ZirInstTestComptime>(ag, scope, source_node);
    instruction->value = value;

    ir_ref_instruction(value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_ptr_cast_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *dest_type, Stage1ZirInst *ptr, bool safety_check_on)
{
    Stage1ZirInstPtrCast *instruction = ir_build_instruction<Stage1ZirInstPtrCast>(
            ag, scope, source_node);
    instruction->dest_type = dest_type;
    instruction->ptr = ptr;
    instruction->safety_check_on = safety_check_on;

    ir_ref_instruction(dest_type, ag->current_basic_block);
    ir_ref_instruction(ptr, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_implicit_cast(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *operand, ResultLocCast *result_loc_cast)
{
    Stage1ZirInstImplicitCast *instruction = ir_build_instruction<Stage1ZirInstImplicitCast>(ag, scope, source_node);
    instruction->operand = operand;
    instruction->result_loc_cast = result_loc_cast;

    ir_ref_instruction(operand, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_bit_cast_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *operand, ResultLocBitCast *result_loc_bit_cast)
{
    Stage1ZirInstBitCast *instruction = ir_build_instruction<Stage1ZirInstBitCast>(ag, scope, source_node);
    instruction->operand = operand;
    instruction->result_loc_bit_cast = result_loc_bit_cast;

    ir_ref_instruction(operand, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_int_to_ptr_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *dest_type, Stage1ZirInst *target)
{
    Stage1ZirInstIntToPtr *instruction = ir_build_instruction<Stage1ZirInstIntToPtr>(ag, scope, source_node);
    instruction->dest_type = dest_type;
    instruction->target = target;

    ir_ref_instruction(dest_type, ag->current_basic_block);
    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_ptr_to_int_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *target)
{
    Stage1ZirInstPtrToInt *inst = ir_build_instruction<Stage1ZirInstPtrToInt>(ag, scope, source_node);
    inst->target = target;

    ir_ref_instruction(target, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_int_to_enum_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *dest_type, Stage1ZirInst *target)
{
    Stage1ZirInstIntToEnum *instruction = ir_build_instruction<Stage1ZirInstIntToEnum>(ag, scope, source_node);
    instruction->dest_type = dest_type;
    instruction->target = target;

    if (dest_type) ir_ref_instruction(dest_type, ag->current_basic_block);
    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_enum_to_int(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *target)
{
    Stage1ZirInstEnumToInt *instruction = ir_build_instruction<Stage1ZirInstEnumToInt>(
            ag, scope, source_node);
    instruction->target = target;

    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_int_to_err_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *target)
{
    Stage1ZirInstIntToErr *instruction = ir_build_instruction<Stage1ZirInstIntToErr>(ag, scope, source_node);
    instruction->target = target;

    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_err_to_int_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *target)
{
    Stage1ZirInstErrToInt *instruction = ir_build_instruction<Stage1ZirInstErrToInt>(
            ag, scope, source_node);
    instruction->target = target;

    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_check_switch_prongs(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *target_value, Stage1ZirInstCheckSwitchProngsRange *ranges, size_t range_count,
        AstNode* else_prong, bool have_underscore_prong)
{
    Stage1ZirInstCheckSwitchProngs *instruction = heap::c_allocator.create<Stage1ZirInstCheckSwitchProngs>();
    instruction->base.id = have_underscore_prong ?
        Stage1ZirInstIdCheckSwitchProngsUnderYes : Stage1ZirInstIdCheckSwitchProngsUnderNo;
    instruction->base.scope = scope;
    instruction->base.source_node = source_node;
    instruction->base.debug_id = irb_next_debug_id(ag);
    instruction->base.owner_bb = ag->current_basic_block;
    ir_instruction_append(ag->current_basic_block, &instruction->base);

    instruction->target_value = target_value;
    instruction->ranges = ranges;
    instruction->range_count = range_count;
    instruction->else_prong = else_prong;

    ir_ref_instruction(target_value, ag->current_basic_block);
    for (size_t i = 0; i < range_count; i += 1) {
        ir_ref_instruction(ranges[i].start, ag->current_basic_block);
        ir_ref_instruction(ranges[i].end, ag->current_basic_block);
    }

    return &instruction->base;
}

static Stage1ZirInst *ir_build_check_statement_is_void(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst* statement_value)
{
    Stage1ZirInstCheckStatementIsVoid *instruction = ir_build_instruction<Stage1ZirInstCheckStatementIsVoid>(
            ag, scope, source_node);
    instruction->statement_value = statement_value;

    ir_ref_instruction(statement_value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_type_name(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *type_value)
{
    Stage1ZirInstTypeName *instruction = ir_build_instruction<Stage1ZirInstTypeName>(ag, scope, source_node);
    instruction->type_value = type_value;

    ir_ref_instruction(type_value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_decl_ref(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Tld *tld, LVal lval) {
    Stage1ZirInstDeclRef *instruction = ir_build_instruction<Stage1ZirInstDeclRef>(ag, scope, source_node);
    instruction->tld = tld;
    instruction->lval = lval;

    return &instruction->base;
}

static Stage1ZirInst *ir_build_panic_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *msg) {
    Stage1ZirInstPanic *instruction = ir_build_instruction<Stage1ZirInstPanic>(ag, scope, source_node);
    instruction->msg = msg;

    ir_ref_instruction(msg, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_tag_name_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *target) {
    Stage1ZirInstTagName *instruction = ir_build_instruction<Stage1ZirInstTagName>(ag, scope, source_node);
    instruction->target = target;

    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_field_parent_ptr_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *type_value, Stage1ZirInst *field_name, Stage1ZirInst *field_ptr)
{
    Stage1ZirInstFieldParentPtr *inst = ir_build_instruction<Stage1ZirInstFieldParentPtr>(
            ag, scope, source_node);
    inst->type_value = type_value;
    inst->field_name = field_name;
    inst->field_ptr = field_ptr;

    ir_ref_instruction(type_value, ag->current_basic_block);
    ir_ref_instruction(field_name, ag->current_basic_block);
    ir_ref_instruction(field_ptr, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_offset_of(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *type_value, Stage1ZirInst *field_name)
{
    Stage1ZirInstOffsetOf *instruction = ir_build_instruction<Stage1ZirInstOffsetOf>(ag, scope, source_node);
    instruction->type_value = type_value;
    instruction->field_name = field_name;

    ir_ref_instruction(type_value, ag->current_basic_block);
    ir_ref_instruction(field_name, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_bit_offset_of(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *type_value, Stage1ZirInst *field_name)
{
    Stage1ZirInstBitOffsetOf *instruction = ir_build_instruction<Stage1ZirInstBitOffsetOf>(ag, scope, source_node);
    instruction->type_value = type_value;
    instruction->field_name = field_name;

    ir_ref_instruction(type_value, ag->current_basic_block);
    ir_ref_instruction(field_name, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_type_info(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *type_value) {
    Stage1ZirInstTypeInfo *instruction = ir_build_instruction<Stage1ZirInstTypeInfo>(ag, scope, source_node);
    instruction->type_value = type_value;

    ir_ref_instruction(type_value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_type(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *type_info) {
    Stage1ZirInstType *instruction = ir_build_instruction<Stage1ZirInstType>(ag, scope, source_node);
    instruction->type_info = type_info;

    ir_ref_instruction(type_info, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_set_eval_branch_quota(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *new_quota)
{
    Stage1ZirInstSetEvalBranchQuota *instruction = ir_build_instruction<Stage1ZirInstSetEvalBranchQuota>(ag, scope, source_node);
    instruction->new_quota = new_quota;

    ir_ref_instruction(new_quota, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_align_cast_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *align_bytes, Stage1ZirInst *target)
{
    Stage1ZirInstAlignCast *instruction = ir_build_instruction<Stage1ZirInstAlignCast>(ag, scope, source_node);
    instruction->align_bytes = align_bytes;
    instruction->target = target;

    ir_ref_instruction(align_bytes, ag->current_basic_block);
    ir_ref_instruction(target, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_resolve_result(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        ResultLoc *result_loc, Stage1ZirInst *ty)
{
    Stage1ZirInstResolveResult *instruction = ir_build_instruction<Stage1ZirInstResolveResult>(ag, scope, source_node);
    instruction->result_loc = result_loc;
    instruction->ty = ty;

    if (ty != nullptr) ir_ref_instruction(ty, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_reset_result(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        ResultLoc *result_loc)
{
    Stage1ZirInstResetResult *instruction = ir_build_instruction<Stage1ZirInstResetResult>(ag, scope, source_node);
    instruction->result_loc = result_loc;

    return &instruction->base;
}

static Stage1ZirInst *ir_build_set_align_stack(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *align_bytes)
{
    Stage1ZirInstSetAlignStack *instruction = ir_build_instruction<Stage1ZirInstSetAlignStack>(ag, scope, source_node);
    instruction->align_bytes = align_bytes;

    ir_ref_instruction(align_bytes, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_arg_type(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *fn_type, Stage1ZirInst *arg_index, bool allow_var)
{
    Stage1ZirInstArgType *instruction = heap::c_allocator.create<Stage1ZirInstArgType>();
    instruction->base.id = allow_var ?
        Stage1ZirInstIdArgTypeAllowVarTrue : Stage1ZirInstIdArgTypeAllowVarFalse;
    instruction->base.scope = scope;
    instruction->base.source_node = source_node;
    instruction->base.debug_id = irb_next_debug_id(ag);
    instruction->base.owner_bb = ag->current_basic_block;
    ir_instruction_append(ag->current_basic_block, &instruction->base);

    instruction->fn_type = fn_type;
    instruction->arg_index = arg_index;

    ir_ref_instruction(fn_type, ag->current_basic_block);
    ir_ref_instruction(arg_index, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_error_return_trace_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        IrInstErrorReturnTraceOptional optional)
{
    Stage1ZirInstErrorReturnTrace *inst = ir_build_instruction<Stage1ZirInstErrorReturnTrace>(ag, scope, source_node);
    inst->optional = optional;

    return &inst->base;
}

static Stage1ZirInst *ir_build_error_union(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *err_set, Stage1ZirInst *payload)
{
    Stage1ZirInstErrorUnion *instruction = ir_build_instruction<Stage1ZirInstErrorUnion>(ag, scope, source_node);
    instruction->err_set = err_set;
    instruction->payload = payload;

    ir_ref_instruction(err_set, ag->current_basic_block);
    ir_ref_instruction(payload, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_atomic_rmw_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *operand_type, Stage1ZirInst *ptr, Stage1ZirInst *op, Stage1ZirInst *operand,
        Stage1ZirInst *ordering)
{
    Stage1ZirInstAtomicRmw *instruction = ir_build_instruction<Stage1ZirInstAtomicRmw>(ag, scope, source_node);
    instruction->operand_type = operand_type;
    instruction->ptr = ptr;
    instruction->op = op;
    instruction->operand = operand;
    instruction->ordering = ordering;

    ir_ref_instruction(operand_type, ag->current_basic_block);
    ir_ref_instruction(ptr, ag->current_basic_block);
    ir_ref_instruction(op, ag->current_basic_block);
    ir_ref_instruction(operand, ag->current_basic_block);
    ir_ref_instruction(ordering, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_atomic_load_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *operand_type, Stage1ZirInst *ptr, Stage1ZirInst *ordering)
{
    Stage1ZirInstAtomicLoad *instruction = ir_build_instruction<Stage1ZirInstAtomicLoad>(ag, scope, source_node);
    instruction->operand_type = operand_type;
    instruction->ptr = ptr;
    instruction->ordering = ordering;

    ir_ref_instruction(operand_type, ag->current_basic_block);
    ir_ref_instruction(ptr, ag->current_basic_block);
    ir_ref_instruction(ordering, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_atomic_store_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *operand_type, Stage1ZirInst *ptr, Stage1ZirInst *value, Stage1ZirInst *ordering)
{
    Stage1ZirInstAtomicStore *instruction = ir_build_instruction<Stage1ZirInstAtomicStore>(ag, scope, source_node);
    instruction->operand_type = operand_type;
    instruction->ptr = ptr;
    instruction->value = value;
    instruction->ordering = ordering;

    ir_ref_instruction(operand_type, ag->current_basic_block);
    ir_ref_instruction(ptr, ag->current_basic_block);
    ir_ref_instruction(value, ag->current_basic_block);
    ir_ref_instruction(ordering, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_save_err_ret_addr_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    Stage1ZirInstSaveErrRetAddr *inst = ir_build_instruction<Stage1ZirInstSaveErrRetAddr>(ag, scope, source_node);
    return &inst->base;
}

static Stage1ZirInst *ir_build_add_implicit_return_type(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *value, ResultLocReturn *result_loc_ret)
{
    Stage1ZirInstAddImplicitReturnType *inst = ir_build_instruction<Stage1ZirInstAddImplicitReturnType>(ag, scope, source_node);
    inst->value = value;
    inst->result_loc_ret = result_loc_ret;

    ir_ref_instruction(value, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_has_decl(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *container, Stage1ZirInst *name)
{
    Stage1ZirInstHasDecl *instruction = ir_build_instruction<Stage1ZirInstHasDecl>(ag, scope, source_node);
    instruction->container = container;
    instruction->name = name;

    ir_ref_instruction(container, ag->current_basic_block);
    ir_ref_instruction(name, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_undeclared_identifier(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Buf *name) {
    Stage1ZirInstUndeclaredIdent *instruction = ir_build_instruction<Stage1ZirInstUndeclaredIdent>(ag, scope, source_node);
    instruction->name = name;

    return &instruction->base;
}

static Stage1ZirInst *ir_build_check_runtime_scope(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *scope_is_comptime, Stage1ZirInst *is_comptime) {
    Stage1ZirInstCheckRuntimeScope *instruction = ir_build_instruction<Stage1ZirInstCheckRuntimeScope>(ag, scope, source_node);
    instruction->scope_is_comptime = scope_is_comptime;
    instruction->is_comptime = is_comptime;

    ir_ref_instruction(scope_is_comptime, ag->current_basic_block);
    ir_ref_instruction(is_comptime, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_union_init_named_field(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *union_type, Stage1ZirInst *field_name, Stage1ZirInst *field_result_loc, Stage1ZirInst *result_loc)
{
    Stage1ZirInstUnionInitNamedField *instruction = ir_build_instruction<Stage1ZirInstUnionInitNamedField>(ag, scope, source_node);
    instruction->union_type = union_type;
    instruction->field_name = field_name;
    instruction->field_result_loc = field_result_loc;
    instruction->result_loc = result_loc;

    ir_ref_instruction(union_type, ag->current_basic_block);
    ir_ref_instruction(field_name, ag->current_basic_block);
    ir_ref_instruction(field_result_loc, ag->current_basic_block);
    if (result_loc != nullptr) ir_ref_instruction(result_loc, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_alloca_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *align, const char *name_hint, Stage1ZirInst *is_comptime)
{
    Stage1ZirInstAlloca *instruction = ir_build_instruction<Stage1ZirInstAlloca>(ag, scope, source_node);
    instruction->align = align;
    instruction->name_hint = name_hint;
    instruction->is_comptime = is_comptime;

    if (align != nullptr) ir_ref_instruction(align, ag->current_basic_block);
    if (is_comptime != nullptr) ir_ref_instruction(is_comptime, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_end_expr(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *value, ResultLoc *result_loc)
{
    Stage1ZirInstEndExpr *instruction = ir_build_instruction<Stage1ZirInstEndExpr>(ag, scope, source_node);
    instruction->value = value;
    instruction->result_loc = result_loc;

    ir_ref_instruction(value, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInstSuspendBegin *ir_build_suspend_begin_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    return ir_build_instruction<Stage1ZirInstSuspendBegin>(ag, scope, source_node);
}

static Stage1ZirInst *ir_build_suspend_finish_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInstSuspendBegin *begin)
{
    Stage1ZirInstSuspendFinish *inst = ir_build_instruction<Stage1ZirInstSuspendFinish>(ag, scope, source_node);
    inst->begin = begin;

    ir_ref_instruction(&begin->base, ag->current_basic_block);

    return &inst->base;
}

static Stage1ZirInst *ir_build_await_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *frame, ResultLoc *result_loc, bool is_nosuspend)
{
    Stage1ZirInstAwait *instruction = ir_build_instruction<Stage1ZirInstAwait>(ag, scope, source_node);
    instruction->frame = frame;
    instruction->result_loc = result_loc;
    instruction->is_nosuspend = is_nosuspend;

    ir_ref_instruction(frame, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_resume_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *frame) {
    Stage1ZirInstResume *instruction = ir_build_instruction<Stage1ZirInstResume>(ag, scope, source_node);
    instruction->frame = frame;

    ir_ref_instruction(frame, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInstSpillBegin *ir_build_spill_begin_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInst *operand, SpillId spill_id)
{
    Stage1ZirInstSpillBegin *instruction = ir_build_instruction<Stage1ZirInstSpillBegin>(ag, scope, source_node);
    instruction->operand = operand;
    instruction->spill_id = spill_id;

    ir_ref_instruction(operand, ag->current_basic_block);

    return instruction;
}

static Stage1ZirInst *ir_build_spill_end_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        Stage1ZirInstSpillBegin *begin)
{
    Stage1ZirInstSpillEnd *instruction = ir_build_instruction<Stage1ZirInstSpillEnd>(ag, scope, source_node);
    instruction->begin = begin;

    ir_ref_instruction(&begin->base, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_wasm_memory_size_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *index) {
    Stage1ZirInstWasmMemorySize *instruction = ir_build_instruction<Stage1ZirInstWasmMemorySize>(ag, scope, source_node);
    instruction->index = index;

    ir_ref_instruction(index, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_wasm_memory_grow_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node, Stage1ZirInst *index, Stage1ZirInst *delta) {
    Stage1ZirInstWasmMemoryGrow *instruction = ir_build_instruction<Stage1ZirInstWasmMemoryGrow>(ag, scope, source_node);
    instruction->index = index;
    instruction->delta = delta;

    ir_ref_instruction(index, ag->current_basic_block);
    ir_ref_instruction(delta, ag->current_basic_block);

    return &instruction->base;
}

static Stage1ZirInst *ir_build_src(Stage1AstGen *ag, Scope *scope, AstNode *source_node) {
    Stage1ZirInstSrc *instruction = ir_build_instruction<Stage1ZirInstSrc>(ag, scope, source_node);

    return &instruction->base;
}

static void ir_count_defers(Stage1AstGen *ag, Scope *inner_scope, Scope *outer_scope, size_t *results) {
    results[ReturnKindUnconditional] = 0;
    results[ReturnKindError] = 0;

    Scope *scope = inner_scope;

    while (scope != outer_scope) {
        assert(scope);
        switch (scope->id) {
            case ScopeIdDefer: {
                AstNode *defer_node = scope->source_node;
                assert(defer_node->type == NodeTypeDefer);
                ReturnKind defer_kind = defer_node->data.defer.kind;
                results[defer_kind] += 1;
                scope = scope->parent;
                continue;
            }
            case ScopeIdDecls:
            case ScopeIdFnDef:
                return;
            case ScopeIdBlock:
            case ScopeIdVarDecl:
            case ScopeIdLoop:
            case ScopeIdSuspend:
            case ScopeIdCompTime:
            case ScopeIdNoSuspend:
            case ScopeIdRuntime:
            case ScopeIdTypeOf:
            case ScopeIdExpr:
                scope = scope->parent;
                continue;
            case ScopeIdDeferExpr:
            case ScopeIdCImport:
                zig_unreachable();
        }
    }
}

static bool astgen_defers_for_block(Stage1AstGen *ag, Scope *inner_scope, Scope *outer_scope, bool *is_noreturn, Stage1ZirInst *err_value) {
    Scope *scope = inner_scope;
    if (is_noreturn != nullptr) *is_noreturn = false;
    while (scope != outer_scope) {
        if (!scope)
            return true;

        switch (scope->id) {
            case ScopeIdDefer: {
                AstNode *defer_node = scope->source_node;
                assert(defer_node->type == NodeTypeDefer);
                ReturnKind defer_kind = defer_node->data.defer.kind;
                AstNode *defer_expr_node = defer_node->data.defer.expr;
                AstNode *defer_var_node = defer_node->data.defer.err_payload;

                if (defer_kind == ReturnKindError && err_value == nullptr) {
                    // This is an `errdefer` but we're generating code for a
                    // `return` that doesn't return an error, skip it
                    scope = scope->parent;
                    continue;
                }

                Scope *defer_expr_scope = defer_node->data.defer.expr_scope;
                if (defer_var_node != nullptr) {
                    assert(defer_kind == ReturnKindError);
                    assert(defer_var_node->type == NodeTypeIdentifier);
                    Buf *var_name = node_identifier_buf(defer_var_node);

                    if (defer_expr_node->type == NodeTypeUnreachable) {
                        add_node_error(ag->codegen, defer_var_node,
                            buf_sprintf("unused variable: '%s'", buf_ptr(var_name)));
                        return false;
                    }

                    Stage1ZirInst *is_comptime;
                    if (ir_should_inline(ag->exec, defer_expr_scope)) {
                        is_comptime = ir_build_const_bool(ag, defer_expr_scope,
                            defer_expr_node, true);
                    } else {
                        is_comptime = ir_build_test_comptime(ag, defer_expr_scope,
                            defer_expr_node, err_value);
                    }

                    ZigVar *err_var = ir_create_var(ag, defer_var_node, defer_expr_scope,
                        var_name, true, true, false, is_comptime);
                    build_decl_var_and_init(ag, defer_expr_scope, defer_var_node, err_var, err_value,
                        buf_ptr(var_name), is_comptime);

                    defer_expr_scope = err_var->child_scope;
                }

                Stage1ZirInst *defer_expr_value = astgen_node(ag, defer_expr_node, defer_expr_scope);
                if (defer_expr_value == ag->codegen->invalid_inst_src)
                    return ag->codegen->invalid_inst_src;

                if (instr_is_unreachable(defer_expr_value)) {
                    if (is_noreturn != nullptr) *is_noreturn = true;
                } else {
                    ir_build_check_statement_is_void(ag, defer_expr_scope, defer_expr_node,
                                defer_expr_value);
                }
                scope = scope->parent;
                continue;
            }
            case ScopeIdDecls:
            case ScopeIdFnDef:
                return true;
            case ScopeIdBlock:
            case ScopeIdVarDecl:
            case ScopeIdLoop:
            case ScopeIdSuspend:
            case ScopeIdCompTime:
            case ScopeIdNoSuspend:
            case ScopeIdRuntime:
            case ScopeIdTypeOf:
            case ScopeIdExpr:
                scope = scope->parent;
                continue;
            case ScopeIdDeferExpr:
            case ScopeIdCImport:
                zig_unreachable();
        }
    }
    return true;
}

static void ir_set_cursor_at_end(Stage1AstGen *ag, Stage1ZirBasicBlock *basic_block) {
    assert(basic_block);
    ag->current_basic_block = basic_block;
}

static void ir_set_cursor_at_end_and_append_block(Stage1AstGen *ag, Stage1ZirBasicBlock *basic_block) {
    basic_block->index = ag->exec->basic_block_list.length;
    ag->exec->basic_block_list.append(basic_block);
    ir_set_cursor_at_end(ag, basic_block);
}

static ScopeSuspend *get_scope_suspend(Scope *scope) {
    while (scope) {
        if (scope->id == ScopeIdSuspend)
            return (ScopeSuspend *)scope;
        if (scope->id == ScopeIdFnDef)
            return nullptr;

        scope = scope->parent;
    }
    return nullptr;
}

static ScopeDeferExpr *get_scope_defer_expr(Scope *scope) {
    while (scope) {
        if (scope->id == ScopeIdDeferExpr)
            return (ScopeDeferExpr *)scope;
        if (scope->id == ScopeIdFnDef)
            return nullptr;

        scope = scope->parent;
    }
    return nullptr;
}

static Stage1ZirInst *astgen_return(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval, ResultLoc *result_loc) {
    assert(node->type == NodeTypeReturnExpr);

    ScopeDeferExpr *scope_defer_expr = get_scope_defer_expr(scope);
    if (scope_defer_expr) {
        if (!scope_defer_expr->reported_err) {
            add_node_error(ag->codegen, node, buf_sprintf("cannot return from defer expression"));
            scope_defer_expr->reported_err = true;
        }
        return ag->codegen->invalid_inst_src;
    }

    Scope *outer_scope = ag->exec->begin_scope;

    AstNode *expr_node = node->data.return_expr.expr;
    switch (node->data.return_expr.kind) {
        case ReturnKindUnconditional:
            {
                ResultLocReturn *result_loc_ret = heap::c_allocator.create<ResultLocReturn>();
                result_loc_ret->base.id = ResultLocIdReturn;
                ir_build_reset_result(ag, scope, node, &result_loc_ret->base);

                Stage1ZirInst *return_value;
                if (expr_node) {
                    // Temporarily set this so that if we return a type it gets the name of the function
                    ZigFn *prev_name_fn = ag->exec->name_fn;
                    ag->exec->name_fn = ag->fn;
                    return_value = astgen_node_extra(ag, expr_node, scope, LValNone, &result_loc_ret->base);
                    ag->exec->name_fn = prev_name_fn;
                    if (return_value == ag->codegen->invalid_inst_src)
                        return ag->codegen->invalid_inst_src;
                } else {
                    return_value = ir_build_const_void(ag, scope, node);
                    ir_build_end_expr(ag, scope, node, return_value, &result_loc_ret->base);
                }

                ir_build_add_implicit_return_type(ag, scope, node, return_value, result_loc_ret);

                size_t defer_counts[2];
                ir_count_defers(ag, scope, outer_scope, defer_counts);
                bool have_err_defers = defer_counts[ReturnKindError] > 0;
                if (!have_err_defers && !ag->codegen->have_err_ret_tracing) {
                    // only generate unconditional defers
                    if (!astgen_defers_for_block(ag, scope, outer_scope, nullptr, nullptr))
                        return ag->codegen->invalid_inst_src;
                    Stage1ZirInst *result = ir_build_return_src(ag, scope, node, nullptr);
                    result_loc_ret->base.source_instruction = result;
                    return result;
                }
                bool should_inline = ir_should_inline(ag->exec, scope);

                Stage1ZirBasicBlock *err_block = ir_create_basic_block(ag, scope, "ErrRetErr");
                Stage1ZirBasicBlock *ok_block = ir_create_basic_block(ag, scope, "ErrRetOk");

                Stage1ZirInst *is_err = ir_build_test_err_src(ag, scope, node, return_value, false, true);

                Stage1ZirInst *is_comptime;
                if (should_inline) {
                    is_comptime = ir_build_const_bool(ag, scope, node, should_inline);
                } else {
                    is_comptime = ir_build_test_comptime(ag, scope, node, is_err);
                }

                ir_build_cond_br(ag, scope, node, is_err, err_block, ok_block, is_comptime);
                Stage1ZirBasicBlock *ret_stmt_block = ir_create_basic_block(ag, scope, "RetStmt");

                ir_set_cursor_at_end_and_append_block(ag, err_block);
                if (!astgen_defers_for_block(ag, scope, outer_scope, nullptr, return_value))
                    return ag->codegen->invalid_inst_src;
                if (ag->codegen->have_err_ret_tracing && !should_inline) {
                    ir_build_save_err_ret_addr_src(ag, scope, node);
                }
                ir_build_br(ag, scope, node, ret_stmt_block, is_comptime);

                ir_set_cursor_at_end_and_append_block(ag, ok_block);
                if (!astgen_defers_for_block(ag, scope, outer_scope, nullptr, nullptr))
                    return ag->codegen->invalid_inst_src;
                ir_build_br(ag, scope, node, ret_stmt_block, is_comptime);

                ir_set_cursor_at_end_and_append_block(ag, ret_stmt_block);
                Stage1ZirInst *result = ir_build_return_src(ag, scope, node, nullptr);
                result_loc_ret->base.source_instruction = result;
                return result;
            }
        case ReturnKindError:
            {
                assert(expr_node);
                Stage1ZirInst *err_union_ptr = astgen_node_extra(ag, expr_node, scope, LValPtr, nullptr);
                if (err_union_ptr == ag->codegen->invalid_inst_src)
                    return ag->codegen->invalid_inst_src;
                Stage1ZirInst *is_err_val = ir_build_test_err_src(ag, scope, node, err_union_ptr, true, false);

                Stage1ZirBasicBlock *return_block = ir_create_basic_block(ag, scope, "ErrRetReturn");
                Stage1ZirBasicBlock *continue_block = ir_create_basic_block(ag, scope, "ErrRetContinue");
                Stage1ZirInst *is_comptime;
                bool should_inline = ir_should_inline(ag->exec, scope);
                if (should_inline) {
                    is_comptime = ir_build_const_bool(ag, scope, node, true);
                } else {
                    is_comptime = ir_build_test_comptime(ag, scope, node, is_err_val);
                }
                ir_build_cond_br(ag, scope, node, is_err_val, return_block, continue_block, is_comptime);

                ir_set_cursor_at_end_and_append_block(ag, return_block);
                Stage1ZirInst *err_val_ptr = ir_build_unwrap_err_code_src(ag, scope, node, err_union_ptr);
                Stage1ZirInst *err_val = ir_build_load_ptr(ag, scope, node, err_val_ptr);
                ir_build_add_implicit_return_type(ag, scope, node, err_val, nullptr);
                Stage1ZirInstSpillBegin *spill_begin = ir_build_spill_begin_src(ag, scope, node, err_val,
                        SpillIdRetErrCode);
                ResultLocReturn *result_loc_ret = heap::c_allocator.create<ResultLocReturn>();
                result_loc_ret->base.id = ResultLocIdReturn;
                ir_build_reset_result(ag, scope, node, &result_loc_ret->base);
                ir_build_end_expr(ag, scope, node, err_val, &result_loc_ret->base);

                bool is_noreturn = false;
                if (!astgen_defers_for_block(ag, scope, outer_scope, &is_noreturn, err_val)) {
                    return ag->codegen->invalid_inst_src;
                }
                if (!is_noreturn) {
                    if (ag->codegen->have_err_ret_tracing && !should_inline) {
                        ir_build_save_err_ret_addr_src(ag, scope, node);
                    }
                    err_val = ir_build_spill_end_src(ag, scope, node, spill_begin);
                    Stage1ZirInst *ret_inst = ir_build_return_src(ag, scope, node, err_val);
                    result_loc_ret->base.source_instruction = ret_inst;
                }

                ir_set_cursor_at_end_and_append_block(ag, continue_block);
                Stage1ZirInst *unwrapped_ptr = ir_build_unwrap_err_payload_src(ag, scope, node, err_union_ptr, false, false);
                if (lval == LValPtr)
                    return unwrapped_ptr;
                else
                    return ir_expr_wrap(ag, scope, ir_build_load_ptr(ag, scope, node, unwrapped_ptr), result_loc);
            }
    }
    zig_unreachable();
}

ZigVar *create_local_var(CodeGen *codegen, AstNode *node, Scope *parent_scope,
        Buf *name, bool src_is_const, bool gen_is_const, bool is_shadowable, Stage1ZirInst *is_comptime,
        bool skip_name_check)
{
    ZigVar *variable_entry = heap::c_allocator.create<ZigVar>();
    variable_entry->parent_scope = parent_scope;
    variable_entry->shadowable = is_shadowable;
    variable_entry->is_comptime = is_comptime;
    variable_entry->src_arg_index = SIZE_MAX;
    variable_entry->const_value = codegen->pass1_arena->create<ZigValue>();

    if (is_comptime != nullptr) {
        is_comptime->ref_count += 1;
    }

    if (name) {
        variable_entry->name = strdup(buf_ptr(name));

        if (!skip_name_check) {
            ZigVar *existing_var = find_variable(codegen, parent_scope, name, nullptr);
            if (existing_var && !existing_var->shadowable) {
                if (existing_var->var_type == nullptr || !type_is_invalid(existing_var->var_type)) {
                    ErrorMsg *msg = add_node_error(codegen, node,
                            buf_sprintf("redeclaration of variable '%s'", buf_ptr(name)));
                    add_error_note(codegen, msg, existing_var->decl_node, buf_sprintf("previous declaration here"));
                }
                variable_entry->var_type = codegen->builtin_types.entry_invalid;
            } else {
                ZigType *type;
                if (get_primitive_type(codegen, name, &type) != ErrorPrimitiveTypeNotFound) {
                    add_node_error(codegen, node,
                            buf_sprintf("variable shadows primitive type '%s'", buf_ptr(name)));
                    variable_entry->var_type = codegen->builtin_types.entry_invalid;
                } else {
                    Tld *tld = find_decl(codegen, parent_scope, name);
                    if (tld != nullptr) {
                        bool want_err_msg = true;
                        if (tld->id == TldIdVar) {
                            ZigVar *var = reinterpret_cast<TldVar *>(tld)->var;
                            if (var != nullptr && var->var_type != nullptr && type_is_invalid(var->var_type)) {
                                want_err_msg = false;
                            }
                        }
                        if (want_err_msg) {
                            ErrorMsg *msg = add_node_error(codegen, node,
                                    buf_sprintf("redefinition of '%s'", buf_ptr(name)));
                            add_error_note(codegen, msg, tld->source_node, buf_sprintf("previous definition here"));
                        }
                        variable_entry->var_type = codegen->builtin_types.entry_invalid;
                    }
                }
            }
        }
    } else {
        assert(is_shadowable);
        // TODO make this name not actually be in scope. user should be able to make a variable called "_anon"
        // might already be solved, let's just make sure it has test coverage
        // maybe we put a prefix on this so the debug info doesn't clobber user debug info for same named variables
        variable_entry->name = "_anon";
    }

    variable_entry->src_is_const = src_is_const;
    variable_entry->gen_is_const = gen_is_const;
    variable_entry->decl_node = node;
    variable_entry->child_scope = create_var_scope(codegen, node, parent_scope, variable_entry);

    return variable_entry;
}


// Set name to nullptr to make the variable anonymous (not visible to programmer).
// After you call this function var->child_scope has the variable in scope
static ZigVar *ir_create_var(Stage1AstGen *ag, AstNode *node, Scope *scope, Buf *name,
        bool src_is_const, bool gen_is_const, bool is_shadowable, Stage1ZirInst *is_comptime)
{
    bool is_underscored = name ? buf_eql_str(name, "_") : false;
    ZigVar *var = create_local_var(ag->codegen, node, scope,
            (is_underscored ? nullptr : name), src_is_const, gen_is_const,
            (is_underscored ? true : is_shadowable), is_comptime, false);
    assert(var->child_scope);
    return var;
}

static ResultLocPeer *create_peer_result(ResultLocPeerParent *peer_parent) {
    ResultLocPeer *result = heap::c_allocator.create<ResultLocPeer>();
    result->base.id = ResultLocIdPeer;
    result->base.source_instruction = peer_parent->base.source_instruction;
    result->parent = peer_parent;
    result->base.allow_write_through_const = peer_parent->parent->allow_write_through_const;
    return result;
}

static bool is_duplicate_label(CodeGen *g, Scope *scope, AstNode *node, Buf *name) {
    if (name == nullptr) return false;

    for (;;) {
        if (scope == nullptr || scope->id == ScopeIdFnDef) {
            break;
        } else if (scope->id == ScopeIdBlock || scope->id == ScopeIdLoop) {
            Buf *this_block_name = scope->id == ScopeIdBlock ? ((ScopeBlock *)scope)->name : ((ScopeLoop *)scope)->name;
            if (this_block_name != nullptr && buf_eql_buf(name, this_block_name)) {
                ErrorMsg *msg = add_node_error(g, node, buf_sprintf("redeclaration of label '%s'", buf_ptr(name)));
                add_error_note(g, msg, scope->source_node, buf_sprintf("previous declaration here"));
                return true;
            }
        }
        scope = scope->parent;
    }
    return false;
}

static Stage1ZirInst *astgen_block(Stage1AstGen *ag, Scope *parent_scope, AstNode *block_node, LVal lval,
        ResultLoc *result_loc)
{
    assert(block_node->type == NodeTypeBlock);

    ZigList<Stage1ZirInst *> incoming_values = {0};
    ZigList<Stage1ZirBasicBlock *> incoming_blocks = {0};

    if (is_duplicate_label(ag->codegen, parent_scope, block_node, block_node->data.block.name))
        return ag->codegen->invalid_inst_src;

    ScopeBlock *scope_block = create_block_scope(ag->codegen, block_node, parent_scope);

    Scope *outer_block_scope = &scope_block->base;
    Scope *child_scope = outer_block_scope;

    ZigFn *fn_entry = scope_fn_entry(parent_scope);
    if (fn_entry && fn_entry->child_scope == parent_scope) {
        fn_entry->def_scope = scope_block;
    }

    if (block_node->data.block.statements.length == 0) {
        if (scope_block->name != nullptr) {
            add_node_error(ag->codegen, block_node, buf_sprintf("unused block label"));
        }
        // {}
        return ir_lval_wrap(ag, parent_scope, ir_build_const_void(ag, child_scope, block_node), lval, result_loc);
    }

    if (block_node->data.block.name != nullptr) {
        scope_block->lval = lval;
        scope_block->incoming_blocks = &incoming_blocks;
        scope_block->incoming_values = &incoming_values;
        scope_block->end_block = ir_create_basic_block(ag, parent_scope, "BlockEnd");
        scope_block->is_comptime = ir_build_const_bool(ag, parent_scope, block_node,
                ir_should_inline(ag->exec, parent_scope));

        scope_block->peer_parent = heap::c_allocator.create<ResultLocPeerParent>();
        scope_block->peer_parent->base.id = ResultLocIdPeerParent;
        scope_block->peer_parent->base.source_instruction = scope_block->is_comptime;
        scope_block->peer_parent->base.allow_write_through_const = result_loc->allow_write_through_const;
        scope_block->peer_parent->end_bb = scope_block->end_block;
        scope_block->peer_parent->is_comptime = scope_block->is_comptime;
        scope_block->peer_parent->parent = result_loc;
        ir_build_reset_result(ag, parent_scope, block_node, &scope_block->peer_parent->base);
    }

    bool is_continuation_unreachable = false;
    bool found_invalid_inst = false;
    Stage1ZirInst *noreturn_return_value = nullptr;
    for (size_t i = 0; i < block_node->data.block.statements.length; i += 1) {
        AstNode *statement_node = block_node->data.block.statements.at(i);

        Stage1ZirInst *statement_value = astgen_node(ag, statement_node, child_scope);
        if (statement_value == ag->codegen->invalid_inst_src) {
            // keep generating all the elements of the block in case of error,
            // we want to collect other compile errors
            found_invalid_inst = true;
            continue;
        }

        is_continuation_unreachable = instr_is_unreachable(statement_value);
        if (is_continuation_unreachable) {
            // keep the last noreturn statement value around in case we need to return it
            noreturn_return_value = statement_value;
        }
        // This logic must be kept in sync with
        // [STMT_EXPR_TEST_THING] <--- (search this token)
        if (statement_node->type == NodeTypeDefer) {
            // defer starts a new scope
            child_scope = statement_node->data.defer.child_scope;
            assert(child_scope);
        } else if (statement_value->id == Stage1ZirInstIdDeclVar) {
            // variable declarations start a new scope
            Stage1ZirInstDeclVar *decl_var_instruction = (Stage1ZirInstDeclVar *)statement_value;
            child_scope = decl_var_instruction->var->child_scope;
        } else if (!is_continuation_unreachable) {
            // this statement's value must be void
            ir_build_check_statement_is_void(ag, child_scope, statement_node, statement_value);
        }
    }

    if (scope_block->name != nullptr && scope_block->name_used == false) {
        add_node_error(ag->codegen, block_node, buf_sprintf("unused block label"));
    }

    if (found_invalid_inst)
        return ag->codegen->invalid_inst_src;

    if (is_continuation_unreachable) {
        assert(noreturn_return_value != nullptr);
        if (block_node->data.block.name == nullptr || incoming_blocks.length == 0) {
            return noreturn_return_value;
        }

        if (scope_block->peer_parent != nullptr && scope_block->peer_parent->peers.length != 0) {
            scope_block->peer_parent->peers.last()->next_bb = scope_block->end_block;
        }
        ir_set_cursor_at_end_and_append_block(ag, scope_block->end_block);
        Stage1ZirInst *phi = ir_build_phi(ag, parent_scope, block_node, incoming_blocks.length,
                incoming_blocks.items, incoming_values.items, scope_block->peer_parent);
        return ir_expr_wrap(ag, parent_scope, phi, result_loc);
    } else {
        incoming_blocks.append(ag->current_basic_block);
        Stage1ZirInst *else_expr_result = ir_build_const_void(ag, parent_scope, block_node);

        if (scope_block->peer_parent != nullptr) {
            ResultLocPeer *peer_result = create_peer_result(scope_block->peer_parent);
            scope_block->peer_parent->peers.append(peer_result);
            ir_build_end_expr(ag, parent_scope, block_node, else_expr_result, &peer_result->base);

            if (scope_block->peer_parent->peers.length != 0) {
                scope_block->peer_parent->peers.last()->next_bb = scope_block->end_block;
            }
        }

        incoming_values.append(else_expr_result);
    }

    bool is_return_from_fn = block_node == ag->main_block_node;
    if (!is_return_from_fn) {
        if (!astgen_defers_for_block(ag, child_scope, outer_block_scope, nullptr, nullptr))
            return ag->codegen->invalid_inst_src;
    }

    Stage1ZirInst *result;
    if (block_node->data.block.name != nullptr) {
        ir_build_br(ag, parent_scope, block_node, scope_block->end_block, scope_block->is_comptime);
        ir_set_cursor_at_end_and_append_block(ag, scope_block->end_block);
        Stage1ZirInst *phi = ir_build_phi(ag, parent_scope, block_node, incoming_blocks.length,
                incoming_blocks.items, incoming_values.items, scope_block->peer_parent);
        result = ir_expr_wrap(ag, parent_scope, phi, result_loc);
    } else {
        Stage1ZirInst *void_inst = ir_build_const_void(ag, child_scope, block_node);
        result = ir_lval_wrap(ag, parent_scope, void_inst, lval, result_loc);
    }
    if (!is_return_from_fn)
        return result;

    // no need for save_err_ret_addr because this cannot return error
    // only generate unconditional defers

    ir_build_add_implicit_return_type(ag, child_scope, block_node, result, nullptr);
    ResultLocReturn *result_loc_ret = heap::c_allocator.create<ResultLocReturn>();
    result_loc_ret->base.id = ResultLocIdReturn;
    ir_build_reset_result(ag, parent_scope, block_node, &result_loc_ret->base);
    ir_build_end_expr(ag, parent_scope, block_node, result, &result_loc_ret->base);
    if (!astgen_defers_for_block(ag, child_scope, outer_block_scope, nullptr, nullptr))
        return ag->codegen->invalid_inst_src;
    return ir_build_return_src(ag, child_scope, result->source_node, result);
}

static Stage1ZirInst *astgen_bin_op_id(Stage1AstGen *ag, Scope *scope, AstNode *node, IrBinOp op_id) {
    Scope *inner_scope = scope;
    if (op_id == IrBinOpArrayCat || op_id == IrBinOpArrayMult) {
        inner_scope = create_comptime_scope(ag->codegen, node, scope);
    }

    Stage1ZirInst *op1 = astgen_node(ag, node->data.bin_op_expr.op1, inner_scope);
    Stage1ZirInst *op2 = astgen_node(ag, node->data.bin_op_expr.op2, inner_scope);

    if (op1 == ag->codegen->invalid_inst_src || op2 == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    return ir_build_bin_op(ag, scope, node, op_id, op1, op2, true);
}

static Stage1ZirInst *astgen_merge_err_sets(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    Stage1ZirInst *op1 = astgen_node(ag, node->data.bin_op_expr.op1, scope);
    Stage1ZirInst *op2 = astgen_node(ag, node->data.bin_op_expr.op2, scope);

    if (op1 == ag->codegen->invalid_inst_src || op2 == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    // TODO only pass type_name when the || operator is the top level AST node in the var decl expr
    Buf bare_name = BUF_INIT;
    Buf *type_name = get_anon_type_name(ag->codegen, ag->exec, "error", scope, node, &bare_name);

    return ir_build_merge_err_sets(ag, scope, node, op1, op2, type_name);
}

static Stage1ZirInst *astgen_assign(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    Stage1ZirInst *lvalue = astgen_node_extra(ag, node->data.bin_op_expr.op1, scope, LValAssign, nullptr);
    if (lvalue == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    ResultLocInstruction *result_loc_inst = heap::c_allocator.create<ResultLocInstruction>();
    result_loc_inst->base.id = ResultLocIdInstruction;
    result_loc_inst->base.source_instruction = lvalue;
    ir_ref_instruction(lvalue, ag->current_basic_block);
    ir_build_reset_result(ag, scope, node, &result_loc_inst->base);

    Stage1ZirInst *rvalue = astgen_node_extra(ag, node->data.bin_op_expr.op2, scope, LValNone,
            &result_loc_inst->base);
    if (rvalue == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    return ir_build_const_void(ag, scope, node);
}

static Stage1ZirInst *astgen_assign_op(Stage1AstGen *ag, Scope *scope, AstNode *node, IrBinOp op_id) {
    Stage1ZirInst *lvalue = astgen_node_extra(ag, node->data.bin_op_expr.op1, scope, LValAssign, nullptr);
    if (lvalue == ag->codegen->invalid_inst_src)
        return lvalue;
    Stage1ZirInst *op1 = ir_build_load_ptr(ag, scope, node->data.bin_op_expr.op1, lvalue);
    Stage1ZirInst *op2 = astgen_node(ag, node->data.bin_op_expr.op2, scope);
    if (op2 == ag->codegen->invalid_inst_src)
        return op2;
    Stage1ZirInst *result = ir_build_bin_op(ag, scope, node, op_id, op1, op2, true);
    ir_build_store_ptr(ag, scope, node, lvalue, result);
    return ir_build_const_void(ag, scope, node);
}

static Stage1ZirInst *astgen_bool_or(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeBinOpExpr);

    Stage1ZirInst *val1 = astgen_node(ag, node->data.bin_op_expr.op1, scope);
    if (val1 == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;
    Stage1ZirBasicBlock *post_val1_block = ag->current_basic_block;

    Stage1ZirInst *is_comptime;
    if (ir_should_inline(ag->exec, scope)) {
        is_comptime = ir_build_const_bool(ag, scope, node, true);
    } else {
        is_comptime = ir_build_test_comptime(ag, scope, node, val1);
    }

    // block for when val1 == false
    Stage1ZirBasicBlock *false_block = ir_create_basic_block(ag, scope, "BoolOrFalse");
    // block for when val1 == true (don't even evaluate the second part)
    Stage1ZirBasicBlock *true_block = ir_create_basic_block(ag, scope, "BoolOrTrue");

    ir_build_cond_br(ag, scope, node, val1, true_block, false_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, false_block);
    Stage1ZirInst *val2 = astgen_node(ag, node->data.bin_op_expr.op2, scope);
    if (val2 == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;
    Stage1ZirBasicBlock *post_val2_block = ag->current_basic_block;

    ir_build_br(ag, scope, node, true_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, true_block);

    Stage1ZirInst **incoming_values = heap::c_allocator.allocate<Stage1ZirInst *>(2);
    incoming_values[0] = val1;
    incoming_values[1] = val2;
    Stage1ZirBasicBlock **incoming_blocks = heap::c_allocator.allocate<Stage1ZirBasicBlock *>(2);
    incoming_blocks[0] = post_val1_block;
    incoming_blocks[1] = post_val2_block;

    return ir_build_phi(ag, scope, node, 2, incoming_blocks, incoming_values, nullptr);
}

static Stage1ZirInst *astgen_bool_and(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeBinOpExpr);

    Stage1ZirInst *val1 = astgen_node(ag, node->data.bin_op_expr.op1, scope);
    if (val1 == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;
    Stage1ZirBasicBlock *post_val1_block = ag->current_basic_block;

    Stage1ZirInst *is_comptime;
    if (ir_should_inline(ag->exec, scope)) {
        is_comptime = ir_build_const_bool(ag, scope, node, true);
    } else {
        is_comptime = ir_build_test_comptime(ag, scope, node, val1);
    }

    // block for when val1 == true
    Stage1ZirBasicBlock *true_block = ir_create_basic_block(ag, scope, "BoolAndTrue");
    // block for when val1 == false (don't even evaluate the second part)
    Stage1ZirBasicBlock *false_block = ir_create_basic_block(ag, scope, "BoolAndFalse");

    ir_build_cond_br(ag, scope, node, val1, true_block, false_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, true_block);
    Stage1ZirInst *val2 = astgen_node(ag, node->data.bin_op_expr.op2, scope);
    if (val2 == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;
    Stage1ZirBasicBlock *post_val2_block = ag->current_basic_block;

    ir_build_br(ag, scope, node, false_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, false_block);

    Stage1ZirInst **incoming_values = heap::c_allocator.allocate<Stage1ZirInst *>(2);
    incoming_values[0] = val1;
    incoming_values[1] = val2;
    Stage1ZirBasicBlock **incoming_blocks = heap::c_allocator.allocate<Stage1ZirBasicBlock *>(2);
    incoming_blocks[0] = post_val1_block;
    incoming_blocks[1] = post_val2_block;

    return ir_build_phi(ag, scope, node, 2, incoming_blocks, incoming_values, nullptr);
}

static ResultLocPeerParent *ir_build_result_peers(Stage1AstGen *ag, Stage1ZirInst *cond_br_inst,
        Stage1ZirBasicBlock *end_block, ResultLoc *parent, Stage1ZirInst *is_comptime)
{
    ResultLocPeerParent *peer_parent = heap::c_allocator.create<ResultLocPeerParent>();
    peer_parent->base.id = ResultLocIdPeerParent;
    peer_parent->base.source_instruction = cond_br_inst;
    peer_parent->base.allow_write_through_const = parent->allow_write_through_const;
    peer_parent->end_bb = end_block;
    peer_parent->is_comptime = is_comptime;
    peer_parent->parent = parent;

    Stage1ZirInst *popped_inst = ag->current_basic_block->instruction_list.pop();
    ir_assert(popped_inst == cond_br_inst, cond_br_inst);

    ir_build_reset_result(ag, cond_br_inst->scope, cond_br_inst->source_node, &peer_parent->base);
    ag->current_basic_block->instruction_list.append(popped_inst);

    return peer_parent;
}

static ResultLocPeerParent *ir_build_binary_result_peers(Stage1AstGen *ag, Stage1ZirInst *cond_br_inst,
        Stage1ZirBasicBlock *else_block, Stage1ZirBasicBlock *end_block, ResultLoc *parent, Stage1ZirInst *is_comptime)
{
    ResultLocPeerParent *peer_parent = ir_build_result_peers(ag, cond_br_inst, end_block, parent, is_comptime);

    peer_parent->peers.append(create_peer_result(peer_parent));
    peer_parent->peers.last()->next_bb = else_block;

    peer_parent->peers.append(create_peer_result(peer_parent));
    peer_parent->peers.last()->next_bb = end_block;

    return peer_parent;
}

static Stage1ZirInst *astgen_orelse(Stage1AstGen *ag, Scope *parent_scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeBinOpExpr);

    AstNode *op1_node = node->data.bin_op_expr.op1;
    AstNode *op2_node = node->data.bin_op_expr.op2;

    Stage1ZirInst *maybe_ptr = astgen_node_extra(ag, op1_node, parent_scope, LValPtr, nullptr);
    if (maybe_ptr == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *maybe_val = ir_build_load_ptr(ag, parent_scope, node, maybe_ptr);
    Stage1ZirInst *is_non_null = ir_build_test_non_null_src(ag, parent_scope, node, maybe_val);

    Stage1ZirInst *is_comptime;
    if (ir_should_inline(ag->exec, parent_scope)) {
        is_comptime = ir_build_const_bool(ag, parent_scope, node, true);
    } else {
        is_comptime = ir_build_test_comptime(ag, parent_scope, node, is_non_null);
    }

    Stage1ZirBasicBlock *ok_block = ir_create_basic_block(ag, parent_scope, "OptionalNonNull");
    Stage1ZirBasicBlock *null_block = ir_create_basic_block(ag, parent_scope, "OptionalNull");
    Stage1ZirBasicBlock *end_block = ir_create_basic_block(ag, parent_scope, "OptionalEnd");
    Stage1ZirInst *cond_br_inst = ir_build_cond_br(ag, parent_scope, node, is_non_null, ok_block, null_block, is_comptime);

    ResultLocPeerParent *peer_parent = ir_build_binary_result_peers(ag, cond_br_inst, ok_block, end_block,
            result_loc, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, null_block);
    Stage1ZirInst *null_result = astgen_node_extra(ag, op2_node, parent_scope, LValNone,
            &peer_parent->peers.at(0)->base);
    if (null_result == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;
    Stage1ZirBasicBlock *after_null_block = ag->current_basic_block;
    if (!instr_is_unreachable(null_result))
        ir_build_br(ag, parent_scope, node, end_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, ok_block);
    Stage1ZirInst *unwrapped_ptr = ir_build_optional_unwrap_ptr(ag, parent_scope, node, maybe_ptr, false);
    Stage1ZirInst *unwrapped_payload = ir_build_load_ptr(ag, parent_scope, node, unwrapped_ptr);
    ir_build_end_expr(ag, parent_scope, node, unwrapped_payload, &peer_parent->peers.at(1)->base);
    Stage1ZirBasicBlock *after_ok_block = ag->current_basic_block;
    ir_build_br(ag, parent_scope, node, end_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, end_block);
    Stage1ZirInst **incoming_values = heap::c_allocator.allocate<Stage1ZirInst *>(2);
    incoming_values[0] = null_result;
    incoming_values[1] = unwrapped_payload;
    Stage1ZirBasicBlock **incoming_blocks = heap::c_allocator.allocate<Stage1ZirBasicBlock *>(2);
    incoming_blocks[0] = after_null_block;
    incoming_blocks[1] = after_ok_block;
    Stage1ZirInst *phi = ir_build_phi(ag, parent_scope, node, 2, incoming_blocks, incoming_values, peer_parent);
    return ir_lval_wrap(ag, parent_scope, phi, lval, result_loc);
}

static Stage1ZirInst *astgen_error_union(Stage1AstGen *ag, Scope *parent_scope, AstNode *node) {
    assert(node->type == NodeTypeBinOpExpr);

    AstNode *op1_node = node->data.bin_op_expr.op1;
    AstNode *op2_node = node->data.bin_op_expr.op2;

    Stage1ZirInst *err_set = astgen_node(ag, op1_node, parent_scope);
    if (err_set == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *payload = astgen_node(ag, op2_node, parent_scope);
    if (payload == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    return ir_build_error_union(ag, parent_scope, node, err_set, payload);
}

static Stage1ZirInst *astgen_bin_op(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval, ResultLoc *result_loc) {
    assert(node->type == NodeTypeBinOpExpr);

    BinOpType bin_op_type = node->data.bin_op_expr.bin_op;
    switch (bin_op_type) {
        case BinOpTypeInvalid:
            zig_unreachable();
        case BinOpTypeAssign:
            return ir_lval_wrap(ag, scope, astgen_assign(ag, scope, node), lval, result_loc);
        case BinOpTypeAssignTimes:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpMult), lval, result_loc);
        case BinOpTypeAssignTimesWrap:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpMultWrap), lval, result_loc);
        case BinOpTypeAssignDiv:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpDivUnspecified), lval, result_loc);
        case BinOpTypeAssignMod:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpRemUnspecified), lval, result_loc);
        case BinOpTypeAssignPlus:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpAdd), lval, result_loc);
        case BinOpTypeAssignPlusWrap:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpAddWrap), lval, result_loc);
        case BinOpTypeAssignMinus:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpSub), lval, result_loc);
        case BinOpTypeAssignMinusWrap:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpSubWrap), lval, result_loc);
        case BinOpTypeAssignBitShiftLeft:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpBitShiftLeftLossy), lval, result_loc);
        case BinOpTypeAssignBitShiftRight:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpBitShiftRightLossy), lval, result_loc);
        case BinOpTypeAssignBitAnd:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpBinAnd), lval, result_loc);
        case BinOpTypeAssignBitXor:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpBinXor), lval, result_loc);
        case BinOpTypeAssignBitOr:
            return ir_lval_wrap(ag, scope, astgen_assign_op(ag, scope, node, IrBinOpBinOr), lval, result_loc);
        case BinOpTypeBoolOr:
            return ir_lval_wrap(ag, scope, astgen_bool_or(ag, scope, node), lval, result_loc);
        case BinOpTypeBoolAnd:
            return ir_lval_wrap(ag, scope, astgen_bool_and(ag, scope, node), lval, result_loc);
        case BinOpTypeCmpEq:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpCmpEq), lval, result_loc);
        case BinOpTypeCmpNotEq:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpCmpNotEq), lval, result_loc);
        case BinOpTypeCmpLessThan:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpCmpLessThan), lval, result_loc);
        case BinOpTypeCmpGreaterThan:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpCmpGreaterThan), lval, result_loc);
        case BinOpTypeCmpLessOrEq:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpCmpLessOrEq), lval, result_loc);
        case BinOpTypeCmpGreaterOrEq:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpCmpGreaterOrEq), lval, result_loc);
        case BinOpTypeBinOr:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpBinOr), lval, result_loc);
        case BinOpTypeBinXor:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpBinXor), lval, result_loc);
        case BinOpTypeBinAnd:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpBinAnd), lval, result_loc);
        case BinOpTypeBitShiftLeft:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpBitShiftLeftLossy), lval, result_loc);
        case BinOpTypeBitShiftRight:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpBitShiftRightLossy), lval, result_loc);
        case BinOpTypeAdd:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpAdd), lval, result_loc);
        case BinOpTypeAddWrap:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpAddWrap), lval, result_loc);
        case BinOpTypeSub:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpSub), lval, result_loc);
        case BinOpTypeSubWrap:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpSubWrap), lval, result_loc);
        case BinOpTypeMult:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpMult), lval, result_loc);
        case BinOpTypeMultWrap:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpMultWrap), lval, result_loc);
        case BinOpTypeDiv:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpDivUnspecified), lval, result_loc);
        case BinOpTypeMod:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpRemUnspecified), lval, result_loc);
        case BinOpTypeArrayCat:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpArrayCat), lval, result_loc);
        case BinOpTypeArrayMult:
            return ir_lval_wrap(ag, scope, astgen_bin_op_id(ag, scope, node, IrBinOpArrayMult), lval, result_loc);
        case BinOpTypeMergeErrorSets:
            return ir_lval_wrap(ag, scope, astgen_merge_err_sets(ag, scope, node), lval, result_loc);
        case BinOpTypeUnwrapOptional:
            return astgen_orelse(ag, scope, node, lval, result_loc);
        case BinOpTypeErrorUnion:
            return ir_lval_wrap(ag, scope, astgen_error_union(ag, scope, node), lval, result_loc);
    }
    zig_unreachable();
}

static Stage1ZirInst *astgen_int_lit(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeIntLiteral);

    RootStruct *root_struct = node->owner->data.structure.root_struct;
    BigInt bigint;
    token_number_literal_bigint(root_struct, &bigint, node->main_token);
    return ir_build_const_bigint(ag, scope, node, bigint);
}

static Stage1ZirInst *astgen_float_lit(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    Error err;
    assert(node->type == NodeTypeFloatLiteral);

    RootStruct *root_struct = node->owner->data.structure.root_struct;
    const char *source = buf_ptr(root_struct->source_code);
    uint32_t byte_offset = root_struct->token_locs[node->main_token].offset;

    BigFloat bigfloat;
    if ((err = bigfloat_init_buf(&bigfloat, (const uint8_t *)source + byte_offset))) {
        add_node_error(ag->codegen, node, buf_sprintf("float literal out of range of any type"));
        return ag->codegen->invalid_inst_src;
    }

    return ir_build_const_bigfloat(ag, scope, node, bigfloat);
}

static Stage1ZirInst *astgen_char_lit(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    Error err;
    assert(node->type == NodeTypeCharLiteral);

    RootStruct *root_struct = node->owner->data.structure.root_struct;
    const char *source = buf_ptr(root_struct->source_code);
    uint32_t byte_offset = root_struct->token_locs[node->main_token].offset;

    src_assert(source[byte_offset] == '\'', node);
    byte_offset += 1;

    uint32_t codepoint;
    size_t bad_index;
    if ((err = source_char_literal(source + byte_offset, &codepoint, &bad_index))) {
        add_node_error(ag->codegen, node, buf_sprintf("invalid character"));
        return ag->codegen->invalid_inst_src;
    }
    return ir_build_const_uint(ag, scope, node, codepoint);
}

static Stage1ZirInst *astgen_null_literal(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeNullLiteral);

    return ir_build_const_null(ag, scope, node);
}

static Stage1ZirInst *astgen_identifier(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    Error err;
    assert(node->type == NodeTypeIdentifier);

    Buf *variable_name = node_identifier_buf(node);

    if (buf_eql_str(variable_name, "_")) {
        if (lval == LValAssign) {
            Stage1ZirInstConst *const_instruction = ir_build_instruction<Stage1ZirInstConst>(ag, scope, node);
            const_instruction->value = ag->codegen->pass1_arena->create<ZigValue>();
            const_instruction->value->type = get_pointer_to_type(ag->codegen,
                    ag->codegen->builtin_types.entry_void, false);
            const_instruction->value->special = ConstValSpecialStatic;
            const_instruction->value->data.x_ptr.special = ConstPtrSpecialDiscard;
            return &const_instruction->base;
        }
    }

    ZigType *primitive_type;
    if ((err = get_primitive_type(ag->codegen, variable_name, &primitive_type))) {
        if (err == ErrorOverflow) {
            add_node_error(ag->codegen, node,
                buf_sprintf("primitive integer type '%s' exceeds maximum bit width of 65535",
                    buf_ptr(variable_name)));
            return ag->codegen->invalid_inst_src;
        }
        assert(err == ErrorPrimitiveTypeNotFound);
    } else {
        Stage1ZirInst *value = ir_build_const_type(ag, scope, node, primitive_type);
        if (lval == LValPtr || lval == LValAssign) {
            return ir_build_ref_src(ag, scope, node, value);
        } else {
            return ir_expr_wrap(ag, scope, value, result_loc);
        }
    }

    ScopeFnDef *crossed_fndef_scope;
    ZigVar *var = find_variable(ag->codegen, scope, variable_name, &crossed_fndef_scope);
    if (var) {
        Stage1ZirInst *var_ptr = ir_build_var_ptr_x(ag, scope, node, var, crossed_fndef_scope);
        if (lval == LValPtr || lval == LValAssign) {
            return var_ptr;
        } else {
            return ir_expr_wrap(ag, scope, ir_build_load_ptr(ag, scope, node, var_ptr), result_loc);
        }
    }

    Tld *tld = find_decl(ag->codegen, scope, variable_name);
    if (tld) {
        Stage1ZirInst *decl_ref = ir_build_decl_ref(ag, scope, node, tld, lval);
        if (lval == LValPtr || lval == LValAssign) {
            return decl_ref;
        } else {
            return ir_expr_wrap(ag, scope, decl_ref, result_loc);
        }
    }

    if (get_container_scope(node->owner)->any_imports_failed) {
        // skip the error message since we had a failing import in this file
        // if an import breaks we don't need redundant undeclared identifier errors
        return ag->codegen->invalid_inst_src;
    }

    return ir_build_undeclared_identifier(ag, scope, node, variable_name);
}

static Stage1ZirInst *astgen_array_access(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeArrayAccessExpr);

    AstNode *array_ref_node = node->data.array_access_expr.array_ref_expr;
    Stage1ZirInst *array_ref_instruction = astgen_node_extra(ag, array_ref_node, scope, LValPtr, nullptr);
    if (array_ref_instruction == ag->codegen->invalid_inst_src)
        return array_ref_instruction;

    // Create an usize-typed result location to hold the subscript value, this
    // makes it possible for the compiler to infer the subscript expression type
    // if needed
    Stage1ZirInst *usize_type_inst = ir_build_const_type(ag, scope, node, ag->codegen->builtin_types.entry_usize);
    ResultLocCast *result_loc_cast = ir_build_cast_result_loc(ag, usize_type_inst, no_result_loc());

    AstNode *subscript_node = node->data.array_access_expr.subscript;
    Stage1ZirInst *subscript_value = astgen_node_extra(ag, subscript_node, scope, LValNone, &result_loc_cast->base);
    if (subscript_value == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *subscript_instruction = ir_build_implicit_cast(ag, scope, subscript_node, subscript_value, result_loc_cast);

    Stage1ZirInst *ptr_instruction = ir_build_elem_ptr(ag, scope, node, array_ref_instruction,
            subscript_instruction, true, PtrLenSingle, nullptr);
    if (lval == LValPtr || lval == LValAssign)
        return ptr_instruction;

    Stage1ZirInst *load_ptr = ir_build_load_ptr(ag, scope, node, ptr_instruction);
    return ir_expr_wrap(ag, scope, load_ptr, result_loc);
}

static Stage1ZirInst *astgen_field_access(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeFieldAccessExpr);

    AstNode *container_ref_node = node->data.field_access_expr.struct_expr;
    Buf *field_name = node->data.field_access_expr.field_name;

    Stage1ZirInst *container_ref_instruction = astgen_node_extra(ag, container_ref_node, scope, LValPtr, nullptr);
    if (container_ref_instruction == ag->codegen->invalid_inst_src)
        return container_ref_instruction;

    return ir_build_field_ptr(ag, scope, node, container_ref_instruction, field_name, false);
}

static Stage1ZirInst *astgen_overflow_op(Stage1AstGen *ag, Scope *scope, AstNode *node, IrOverflowOp op) {
    assert(node->type == NodeTypeFnCallExpr);

    AstNode *type_node = node->data.fn_call_expr.params.at(0);
    AstNode *op1_node = node->data.fn_call_expr.params.at(1);
    AstNode *op2_node = node->data.fn_call_expr.params.at(2);
    AstNode *result_ptr_node = node->data.fn_call_expr.params.at(3);


    Stage1ZirInst *type_value = astgen_node(ag, type_node, scope);
    if (type_value == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *op1 = astgen_node(ag, op1_node, scope);
    if (op1 == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *op2 = astgen_node(ag, op2_node, scope);
    if (op2 == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *result_ptr = astgen_node(ag, result_ptr_node, scope);
    if (result_ptr == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    return ir_build_overflow_op_src(ag, scope, node, op, type_value, op1, op2, result_ptr);
}

static Stage1ZirInst *astgen_mul_add(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeFnCallExpr);

    AstNode *type_node = node->data.fn_call_expr.params.at(0);
    AstNode *op1_node = node->data.fn_call_expr.params.at(1);
    AstNode *op2_node = node->data.fn_call_expr.params.at(2);
    AstNode *op3_node = node->data.fn_call_expr.params.at(3);

    Stage1ZirInst *type_value = astgen_node(ag, type_node, scope);
    if (type_value == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *op1 = astgen_node(ag, op1_node, scope);
    if (op1 == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *op2 = astgen_node(ag, op2_node, scope);
    if (op2 == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *op3 = astgen_node(ag, op3_node, scope);
    if (op3 == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    return ir_build_mul_add_src(ag, scope, node, type_value, op1, op2, op3);
}

static Stage1ZirInst *astgen_this(Stage1AstGen *ag, Scope *orig_scope, AstNode *node) {
    for (Scope *it_scope = orig_scope; it_scope != nullptr; it_scope = it_scope->parent) {
        if (it_scope->id == ScopeIdDecls) {
            ScopeDecls *decls_scope = (ScopeDecls *)it_scope;
            ZigType *container_type = decls_scope->container_type;
            if (container_type != nullptr) {
                return ir_build_const_type(ag, orig_scope, node, container_type);
            } else {
                return ir_build_const_import(ag, orig_scope, node, decls_scope->import);
            }
        }
    }
    zig_unreachable();
}

static Stage1ZirInst *astgen_async_call(Stage1AstGen *ag, Scope *scope, AstNode *await_node, AstNode *call_node,
        LVal lval, ResultLoc *result_loc)
{
    if (call_node->data.fn_call_expr.params.length != 4) {
        add_node_error(ag->codegen, call_node,
            buf_sprintf("expected 4 arguments, found %" ZIG_PRI_usize,
                call_node->data.fn_call_expr.params.length));
        return ag->codegen->invalid_inst_src;
    }

    AstNode *bytes_node = call_node->data.fn_call_expr.params.at(0);
    Stage1ZirInst *bytes = astgen_node(ag, bytes_node, scope);
    if (bytes == ag->codegen->invalid_inst_src)
        return bytes;

    AstNode *ret_ptr_node = call_node->data.fn_call_expr.params.at(1);
    Stage1ZirInst *ret_ptr = astgen_node(ag, ret_ptr_node, scope);
    if (ret_ptr == ag->codegen->invalid_inst_src)
        return ret_ptr;

    AstNode *fn_ref_node = call_node->data.fn_call_expr.params.at(2);
    Stage1ZirInst *fn_ref = astgen_node(ag, fn_ref_node, scope);
    if (fn_ref == ag->codegen->invalid_inst_src)
        return fn_ref;

    CallModifier modifier = (await_node == nullptr) ? CallModifierAsync : CallModifierNone;
    bool is_async_call_builtin = true;
    AstNode *args_node = call_node->data.fn_call_expr.params.at(3);
    if (args_node->type == NodeTypeContainerInitExpr) {
        if (args_node->data.container_init_expr.kind == ContainerInitKindArray ||
            args_node->data.container_init_expr.entries.length == 0)
        {
            size_t arg_count = args_node->data.container_init_expr.entries.length;
            Stage1ZirInst **args = heap::c_allocator.allocate<Stage1ZirInst*>(arg_count);
            for (size_t i = 0; i < arg_count; i += 1) {
                AstNode *arg_node = args_node->data.container_init_expr.entries.at(i);
                Stage1ZirInst *arg = astgen_node(ag, arg_node, scope);
                if (arg == ag->codegen->invalid_inst_src)
                    return arg;
                args[i] = arg;
            }

            Stage1ZirInst *call = ir_build_call_src(ag, scope, call_node, nullptr, fn_ref, arg_count, args,
                ret_ptr, modifier, is_async_call_builtin, bytes, result_loc);
            return ir_lval_wrap(ag, scope, call, lval, result_loc);
        } else {
            exec_add_error_node(ag->codegen, ag->exec, args_node,
                    buf_sprintf("TODO: @asyncCall with anon struct literal"));
            return ag->codegen->invalid_inst_src;
        }
    }
    Stage1ZirInst *args = astgen_node(ag, args_node, scope);
    if (args == ag->codegen->invalid_inst_src)
        return args;

    Stage1ZirInst *call = ir_build_async_call_extra(ag, scope, call_node, modifier, fn_ref, ret_ptr, bytes, args, result_loc);
    return ir_lval_wrap(ag, scope, call, lval, result_loc);
}

static Stage1ZirInst *astgen_fn_call_with_args(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        AstNode *fn_ref_node, CallModifier modifier, Stage1ZirInst *options,
        AstNode **args_ptr, size_t args_len, LVal lval, ResultLoc *result_loc)
{
    Stage1ZirInst *fn_ref = astgen_node(ag, fn_ref_node, scope);
    if (fn_ref == ag->codegen->invalid_inst_src)
        return fn_ref;

    Stage1ZirInst *fn_type = ir_build_typeof_1(ag, scope, source_node, fn_ref);

    Stage1ZirInst **args = heap::c_allocator.allocate<Stage1ZirInst*>(args_len);
    for (size_t i = 0; i < args_len; i += 1) {
        AstNode *arg_node = args_ptr[i];

        Stage1ZirInst *arg_index = ir_build_const_usize(ag, scope, arg_node, i);
        Stage1ZirInst *arg_type = ir_build_arg_type(ag, scope, source_node, fn_type, arg_index, true);
        ResultLoc *no_result = no_result_loc();
        ir_build_reset_result(ag, scope, source_node, no_result);
        ResultLocCast *result_loc_cast = ir_build_cast_result_loc(ag, arg_type, no_result);

        Stage1ZirInst *arg = astgen_node_extra(ag, arg_node, scope, LValNone, &result_loc_cast->base);
        if (arg == ag->codegen->invalid_inst_src)
            return arg;

        args[i] = ir_build_implicit_cast(ag, scope, arg_node, arg, result_loc_cast);
    }

    Stage1ZirInst *fn_call;
    if (options != nullptr) {
        fn_call = ir_build_call_args(ag, scope, source_node, options, fn_ref, args, args_len, result_loc);
    } else {
        fn_call = ir_build_call_src(ag, scope, source_node, nullptr, fn_ref, args_len, args, nullptr,
                modifier, false, nullptr, result_loc);
    }
    return ir_lval_wrap(ag, scope, fn_call, lval, result_loc);
}

static Stage1ZirInst *astgen_builtin_fn_call(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeFnCallExpr);

    AstNode *fn_ref_expr = node->data.fn_call_expr.fn_ref_expr;
    Buf *name = node_identifier_buf(fn_ref_expr);
    auto entry = ag->codegen->builtin_fn_table.maybe_get(name);

    if (!entry) {
        add_node_error(ag->codegen, node,
                buf_sprintf("invalid builtin function: '%s'", buf_ptr(name)));
        return ag->codegen->invalid_inst_src;
    }

    BuiltinFnEntry *builtin_fn = entry->value;
    size_t actual_param_count = node->data.fn_call_expr.params.length;

    if (builtin_fn->param_count != SIZE_MAX && builtin_fn->param_count != actual_param_count) {
        add_node_error(ag->codegen, node,
                buf_sprintf("expected %" ZIG_PRI_usize " argument(s), found %" ZIG_PRI_usize,
                    builtin_fn->param_count, actual_param_count));
        return ag->codegen->invalid_inst_src;
    }

    switch (builtin_fn->id) {
        case BuiltinFnIdInvalid:
            zig_unreachable();
        case BuiltinFnIdTypeof:
            {
                Scope *sub_scope = create_typeof_scope(ag->codegen, node, scope);

                size_t arg_count = node->data.fn_call_expr.params.length;

                Stage1ZirInst *type_of;

                if (arg_count == 0) {
                    add_node_error(ag->codegen, node,
                        buf_sprintf("expected at least 1 argument, found 0"));
                    return ag->codegen->invalid_inst_src;
                } else if (arg_count == 1) {
                    AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                    Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, sub_scope);
                    if (arg0_value == ag->codegen->invalid_inst_src)
                        return arg0_value;

                    type_of = ir_build_typeof_1(ag, scope, node, arg0_value);
                } else {
                    Stage1ZirInst **args = heap::c_allocator.allocate<Stage1ZirInst*>(arg_count);
                    for (size_t i = 0; i < arg_count; i += 1) {
                        AstNode *arg_node = node->data.fn_call_expr.params.at(i);
                        Stage1ZirInst *arg = astgen_node(ag, arg_node, sub_scope);
                        if (arg == ag->codegen->invalid_inst_src)
                            return ag->codegen->invalid_inst_src;
                        args[i] = arg;
                    }

                    type_of = ir_build_typeof_n(ag, scope, node, args, arg_count);
                }
                return ir_lval_wrap(ag, scope, type_of, lval, result_loc);
            }
        case BuiltinFnIdSetCold:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *set_cold = ir_build_set_cold(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, set_cold, lval, result_loc);
            }
        case BuiltinFnIdSetRuntimeSafety:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *set_safety = ir_build_set_runtime_safety(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, set_safety, lval, result_loc);
            }
        case BuiltinFnIdSetFloatMode:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *set_float_mode = ir_build_set_float_mode(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, set_float_mode, lval, result_loc);
            }
        case BuiltinFnIdSizeof:
        case BuiltinFnIdBitSizeof:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *size_of = ir_build_size_of(ag, scope, node, arg0_value, builtin_fn->id == BuiltinFnIdBitSizeof);
                return ir_lval_wrap(ag, scope, size_of, lval, result_loc);
            }
        case BuiltinFnIdImport:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *import = ir_build_import(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, import, lval, result_loc);
            }
        case BuiltinFnIdCImport:
            {
                Stage1ZirInst *c_import = ir_build_c_import(ag, scope, node);
                return ir_lval_wrap(ag, scope, c_import, lval, result_loc);
            }
        case BuiltinFnIdCInclude:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                if (!ag->in_c_import_scope) {
                    add_node_error(ag->codegen, node, buf_sprintf("C include valid only inside C import block"));
                    return ag->codegen->invalid_inst_src;
                }

                Stage1ZirInst *c_include = ir_build_c_include(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, c_include, lval, result_loc);
            }
        case BuiltinFnIdCDefine:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                if (!ag->in_c_import_scope) {
                    add_node_error(ag->codegen, node, buf_sprintf("C define valid only inside C import block"));
                    return ag->codegen->invalid_inst_src;
                }

                Stage1ZirInst *c_define = ir_build_c_define(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, c_define, lval, result_loc);
            }
        case BuiltinFnIdCUndef:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                if (!ag->in_c_import_scope) {
                    add_node_error(ag->codegen, node, buf_sprintf("C undef valid only inside C import block"));
                    return ag->codegen->invalid_inst_src;
                }

                Stage1ZirInst *c_undef = ir_build_c_undef(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, c_undef, lval, result_loc);
            }
        case BuiltinFnIdCompileErr:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *compile_err = ir_build_compile_err(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, compile_err, lval, result_loc);
            }
        case BuiltinFnIdCompileLog:
            {
                Stage1ZirInst **args = heap::c_allocator.allocate<Stage1ZirInst*>(actual_param_count);

                for (size_t i = 0; i < actual_param_count; i += 1) {
                    AstNode *arg_node = node->data.fn_call_expr.params.at(i);
                    args[i] = astgen_node(ag, arg_node, scope);
                    if (args[i] == ag->codegen->invalid_inst_src)
                        return ag->codegen->invalid_inst_src;
                }

                Stage1ZirInst *compile_log = ir_build_compile_log(ag, scope, node, actual_param_count, args);
                return ir_lval_wrap(ag, scope, compile_log, lval, result_loc);
            }
        case BuiltinFnIdErrName:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *err_name = ir_build_err_name(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, err_name, lval, result_loc);
            }
        case BuiltinFnIdEmbedFile:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *embed_file = ir_build_embed_file(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, embed_file, lval, result_loc);
            }
        case BuiltinFnIdCmpxchgWeak:
        case BuiltinFnIdCmpxchgStrong:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                AstNode *arg2_node = node->data.fn_call_expr.params.at(2);
                Stage1ZirInst *arg2_value = astgen_node(ag, arg2_node, scope);
                if (arg2_value == ag->codegen->invalid_inst_src)
                    return arg2_value;

                AstNode *arg3_node = node->data.fn_call_expr.params.at(3);
                Stage1ZirInst *arg3_value = astgen_node(ag, arg3_node, scope);
                if (arg3_value == ag->codegen->invalid_inst_src)
                    return arg3_value;

                AstNode *arg4_node = node->data.fn_call_expr.params.at(4);
                Stage1ZirInst *arg4_value = astgen_node(ag, arg4_node, scope);
                if (arg4_value == ag->codegen->invalid_inst_src)
                    return arg4_value;

                AstNode *arg5_node = node->data.fn_call_expr.params.at(5);
                Stage1ZirInst *arg5_value = astgen_node(ag, arg5_node, scope);
                if (arg5_value == ag->codegen->invalid_inst_src)
                    return arg5_value;

                Stage1ZirInst *cmpxchg = ir_build_cmpxchg_src(ag, scope, node, arg0_value, arg1_value,
                    arg2_value, arg3_value, arg4_value, arg5_value, (builtin_fn->id == BuiltinFnIdCmpxchgWeak),
                    result_loc);
                return ir_lval_wrap(ag, scope, cmpxchg, lval, result_loc);
            }
        case BuiltinFnIdFence:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *fence = ir_build_fence(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, fence, lval, result_loc);
            }
        case BuiltinFnIdReduce:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *reduce = ir_build_reduce(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, reduce, lval, result_loc);
            }
        case BuiltinFnIdDivExact:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *bin_op = ir_build_bin_op(ag, scope, node, IrBinOpDivExact, arg0_value, arg1_value, true);
                return ir_lval_wrap(ag, scope, bin_op, lval, result_loc);
            }
        case BuiltinFnIdDivTrunc:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *bin_op = ir_build_bin_op(ag, scope, node, IrBinOpDivTrunc, arg0_value, arg1_value, true);
                return ir_lval_wrap(ag, scope, bin_op, lval, result_loc);
            }
        case BuiltinFnIdDivFloor:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *bin_op = ir_build_bin_op(ag, scope, node, IrBinOpDivFloor, arg0_value, arg1_value, true);
                return ir_lval_wrap(ag, scope, bin_op, lval, result_loc);
            }
        case BuiltinFnIdRem:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *bin_op = ir_build_bin_op(ag, scope, node, IrBinOpRemRem, arg0_value, arg1_value, true);
                return ir_lval_wrap(ag, scope, bin_op, lval, result_loc);
            }
        case BuiltinFnIdMod:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *bin_op = ir_build_bin_op(ag, scope, node, IrBinOpRemMod, arg0_value, arg1_value, true);
                return ir_lval_wrap(ag, scope, bin_op, lval, result_loc);
            }
        case BuiltinFnIdSqrt:
        case BuiltinFnIdSin:
        case BuiltinFnIdCos:
        case BuiltinFnIdExp:
        case BuiltinFnIdExp2:
        case BuiltinFnIdLog:
        case BuiltinFnIdLog2:
        case BuiltinFnIdLog10:
        case BuiltinFnIdFabs:
        case BuiltinFnIdFloor:
        case BuiltinFnIdCeil:
        case BuiltinFnIdTrunc:
        case BuiltinFnIdNearbyInt:
        case BuiltinFnIdRound:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *inst = ir_build_float_op_src(ag, scope, node, arg0_value, builtin_fn->id);
                return ir_lval_wrap(ag, scope, inst, lval, result_loc);
            }
        case BuiltinFnIdTruncate:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *truncate = ir_build_truncate(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, truncate, lval, result_loc);
            }
        case BuiltinFnIdIntCast:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *result = ir_build_int_cast(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdFloatCast:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *result = ir_build_float_cast(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdErrSetCast:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *result = ir_build_err_set_cast(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdIntToFloat:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *result = ir_build_int_to_float(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdFloatToInt:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *result = ir_build_float_to_int(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdErrToInt:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *result = ir_build_err_to_int_src(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdIntToErr:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *result = ir_build_int_to_err_src(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdBoolToInt:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *result = ir_build_bool_to_int(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdVectorType:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *vector_type = ir_build_vector_type(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, vector_type, lval, result_loc);
            }
        case BuiltinFnIdShuffle:
            {
                // Used for the type expr and the mask expr
                Scope *comptime_scope = create_comptime_scope(ag->codegen, node, scope);

                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, comptime_scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                AstNode *arg2_node = node->data.fn_call_expr.params.at(2);
                Stage1ZirInst *arg2_value = astgen_node(ag, arg2_node, scope);
                if (arg2_value == ag->codegen->invalid_inst_src)
                    return arg2_value;

                AstNode *arg3_node = node->data.fn_call_expr.params.at(3);
                Stage1ZirInst *arg3_value = astgen_node(ag, arg3_node, comptime_scope);
                if (arg3_value == ag->codegen->invalid_inst_src)
                    return arg3_value;

                Stage1ZirInst *shuffle_vector = ir_build_shuffle_vector(ag, scope, node,
                    arg0_value, arg1_value, arg2_value, arg3_value);
                return ir_lval_wrap(ag, scope, shuffle_vector, lval, result_loc);
            }
        case BuiltinFnIdSplat:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *splat = ir_build_splat_src(ag, scope, node,
                    arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, splat, lval, result_loc);
            }
        case BuiltinFnIdMemcpy:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                AstNode *arg2_node = node->data.fn_call_expr.params.at(2);
                Stage1ZirInst *arg2_value = astgen_node(ag, arg2_node, scope);
                if (arg2_value == ag->codegen->invalid_inst_src)
                    return arg2_value;

                Stage1ZirInst *ir_memcpy = ir_build_memcpy_src(ag, scope, node, arg0_value, arg1_value, arg2_value);
                return ir_lval_wrap(ag, scope, ir_memcpy, lval, result_loc);
            }
        case BuiltinFnIdMemset:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                AstNode *arg2_node = node->data.fn_call_expr.params.at(2);
                Stage1ZirInst *arg2_value = astgen_node(ag, arg2_node, scope);
                if (arg2_value == ag->codegen->invalid_inst_src)
                    return arg2_value;

                Stage1ZirInst *ir_memset = ir_build_memset_src(ag, scope, node, arg0_value, arg1_value, arg2_value);
                return ir_lval_wrap(ag, scope, ir_memset, lval, result_loc);
            }
        case BuiltinFnIdWasmMemorySize:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *ir_wasm_memory_size = ir_build_wasm_memory_size_src(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, ir_wasm_memory_size, lval, result_loc);
            }
        case BuiltinFnIdWasmMemoryGrow:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *ir_wasm_memory_grow = ir_build_wasm_memory_grow_src(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, ir_wasm_memory_grow, lval, result_loc);
            }
        case BuiltinFnIdField:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node_extra(ag, arg0_node, scope, LValPtr, nullptr);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *ptr_instruction = ir_build_field_ptr_instruction(ag, scope, node,
                        arg0_value, arg1_value, false);

                if (lval == LValPtr || lval == LValAssign)
                    return ptr_instruction;

                Stage1ZirInst *load_ptr = ir_build_load_ptr(ag, scope, node, ptr_instruction);
                return ir_expr_wrap(ag, scope, load_ptr, result_loc);
            }
        case BuiltinFnIdHasField:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *type_info = ir_build_has_field(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, type_info, lval, result_loc);
            }
        case BuiltinFnIdTypeInfo:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *type_info = ir_build_type_info(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, type_info, lval, result_loc);
            }
        case BuiltinFnIdType:
            {
                AstNode *arg_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg = astgen_node(ag, arg_node, scope);
                if (arg == ag->codegen->invalid_inst_src)
                    return arg;

                Stage1ZirInst *type = ir_build_type(ag, scope, node, arg);
                return ir_lval_wrap(ag, scope, type, lval, result_loc);
            }
        case BuiltinFnIdBreakpoint:
            return ir_lval_wrap(ag, scope, ir_build_breakpoint(ag, scope, node), lval, result_loc);
        case BuiltinFnIdReturnAddress:
            return ir_lval_wrap(ag, scope, ir_build_return_address_src(ag, scope, node), lval, result_loc);
        case BuiltinFnIdFrameAddress:
            return ir_lval_wrap(ag, scope, ir_build_frame_address_src(ag, scope, node), lval, result_loc);
        case BuiltinFnIdFrameHandle:
            if (ag->fn == nullptr) {
                add_node_error(ag->codegen, node,
                        buf_sprintf("@frame() called outside of function definition"));
                return ag->codegen->invalid_inst_src;
            }
            return ir_lval_wrap(ag, scope, ir_build_handle_src(ag, scope, node), lval, result_loc);
        case BuiltinFnIdFrameType: {
            AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
            Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
            if (arg0_value == ag->codegen->invalid_inst_src)
                return arg0_value;

            Stage1ZirInst *frame_type = ir_build_frame_type(ag, scope, node, arg0_value);
            return ir_lval_wrap(ag, scope, frame_type, lval, result_loc);
        }
        case BuiltinFnIdFrameSize: {
            AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
            Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
            if (arg0_value == ag->codegen->invalid_inst_src)
                return arg0_value;

            Stage1ZirInst *frame_size = ir_build_frame_size_src(ag, scope, node, arg0_value);
            return ir_lval_wrap(ag, scope, frame_size, lval, result_loc);
        }
        case BuiltinFnIdAlignOf:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *align_of = ir_build_align_of(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, align_of, lval, result_loc);
            }
        case BuiltinFnIdAddWithOverflow:
            return ir_lval_wrap(ag, scope, astgen_overflow_op(ag, scope, node, IrOverflowOpAdd), lval, result_loc);
        case BuiltinFnIdSubWithOverflow:
            return ir_lval_wrap(ag, scope, astgen_overflow_op(ag, scope, node, IrOverflowOpSub), lval, result_loc);
        case BuiltinFnIdMulWithOverflow:
            return ir_lval_wrap(ag, scope, astgen_overflow_op(ag, scope, node, IrOverflowOpMul), lval, result_loc);
        case BuiltinFnIdShlWithOverflow:
            return ir_lval_wrap(ag, scope, astgen_overflow_op(ag, scope, node, IrOverflowOpShl), lval, result_loc);
        case BuiltinFnIdMulAdd:
            return ir_lval_wrap(ag, scope, astgen_mul_add(ag, scope, node), lval, result_loc);
        case BuiltinFnIdTypeName:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *type_name = ir_build_type_name(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, type_name, lval, result_loc);
            }
        case BuiltinFnIdPanic:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *panic = ir_build_panic_src(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, panic, lval, result_loc);
            }
        case BuiltinFnIdPtrCast:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *ptr_cast = ir_build_ptr_cast_src(ag, scope, node, arg0_value, arg1_value, true);
                return ir_lval_wrap(ag, scope, ptr_cast, lval, result_loc);
            }
        case BuiltinFnIdBitCast:
            {
                AstNode *dest_type_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *dest_type = astgen_node(ag, dest_type_node, scope);
                if (dest_type == ag->codegen->invalid_inst_src)
                    return dest_type;

                ResultLocBitCast *result_loc_bit_cast = heap::c_allocator.create<ResultLocBitCast>();
                result_loc_bit_cast->base.id = ResultLocIdBitCast;
                result_loc_bit_cast->base.source_instruction = dest_type;
                result_loc_bit_cast->base.allow_write_through_const = result_loc->allow_write_through_const;
                ir_ref_instruction(dest_type, ag->current_basic_block);
                result_loc_bit_cast->parent = result_loc;

                ir_build_reset_result(ag, scope, node, &result_loc_bit_cast->base);

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node_extra(ag, arg1_node, scope, LValNone,
                        &result_loc_bit_cast->base);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *bitcast = ir_build_bit_cast_src(ag, scope, arg1_node, arg1_value, result_loc_bit_cast);
                return ir_lval_wrap(ag, scope, bitcast, lval, result_loc);
            }
        case BuiltinFnIdAs:
            {
                AstNode *dest_type_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *dest_type = astgen_node(ag, dest_type_node, scope);
                if (dest_type == ag->codegen->invalid_inst_src)
                    return dest_type;

                ResultLocCast *result_loc_cast = ir_build_cast_result_loc(ag, dest_type, result_loc);

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node_extra(ag, arg1_node, scope, LValNone,
                        &result_loc_cast->base);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *result = ir_build_implicit_cast(ag, scope, node, arg1_value, result_loc_cast);
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdIntToPtr:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *int_to_ptr = ir_build_int_to_ptr_src(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, int_to_ptr, lval, result_loc);
            }
        case BuiltinFnIdPtrToInt:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *ptr_to_int = ir_build_ptr_to_int_src(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, ptr_to_int, lval, result_loc);
            }
        case BuiltinFnIdTagName:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *tag_name = ir_build_tag_name_src(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, tag_name, lval, result_loc);
            }
        case BuiltinFnIdFieldParentPtr:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                AstNode *arg2_node = node->data.fn_call_expr.params.at(2);
                Stage1ZirInst *arg2_value = astgen_node(ag, arg2_node, scope);
                if (arg2_value == ag->codegen->invalid_inst_src)
                    return arg2_value;

                Stage1ZirInst *field_parent_ptr = ir_build_field_parent_ptr_src(ag, scope, node,
                        arg0_value, arg1_value, arg2_value);
                return ir_lval_wrap(ag, scope, field_parent_ptr, lval, result_loc);
            }
        case BuiltinFnIdOffsetOf:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *offset_of = ir_build_offset_of(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, offset_of, lval, result_loc);
            }
        case BuiltinFnIdBitOffsetOf:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *offset_of = ir_build_bit_offset_of(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, offset_of, lval, result_loc);
            }
        case BuiltinFnIdCall: {
            // Cast the options parameter to the options type
            ZigType *options_type = get_builtin_type(ag->codegen, "CallOptions");
            Stage1ZirInst *options_type_inst = ir_build_const_type(ag, scope, node, options_type);
            ResultLocCast *result_loc_cast = ir_build_cast_result_loc(ag, options_type_inst, no_result_loc());

            AstNode *options_node = node->data.fn_call_expr.params.at(0);
            Stage1ZirInst *options_inner = astgen_node_extra(ag, options_node, scope,
                    LValNone, &result_loc_cast->base);
            if (options_inner == ag->codegen->invalid_inst_src)
                return options_inner;
            Stage1ZirInst *options = ir_build_implicit_cast(ag, scope, options_node, options_inner, result_loc_cast);

            AstNode *fn_ref_node = node->data.fn_call_expr.params.at(1);
            AstNode *args_node = node->data.fn_call_expr.params.at(2);
            if (args_node->type == NodeTypeContainerInitExpr) {
                if (args_node->data.container_init_expr.kind == ContainerInitKindArray ||
                    args_node->data.container_init_expr.entries.length == 0)
                {
                    return astgen_fn_call_with_args(ag, scope, node,
                            fn_ref_node, CallModifierNone, options,
                            args_node->data.container_init_expr.entries.items,
                            args_node->data.container_init_expr.entries.length,
                            lval, result_loc);
                } else {
                    exec_add_error_node(ag->codegen, ag->exec, args_node,
                            buf_sprintf("TODO: @call with anon struct literal"));
                    return ag->codegen->invalid_inst_src;
                }
            } else {
                Stage1ZirInst *fn_ref = astgen_node(ag, fn_ref_node, scope);
                if (fn_ref == ag->codegen->invalid_inst_src)
                    return fn_ref;

                Stage1ZirInst *args = astgen_node(ag, args_node, scope);
                if (args == ag->codegen->invalid_inst_src)
                    return args;

                Stage1ZirInst *call = ir_build_call_extra(ag, scope, node, options, fn_ref, args, result_loc);
                return ir_lval_wrap(ag, scope, call, lval, result_loc);
            }
        }
        case BuiltinFnIdAsyncCall:
            return astgen_async_call(ag, scope, nullptr, node, lval, result_loc);
        case BuiltinFnIdShlExact:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *bin_op = ir_build_bin_op(ag, scope, node, IrBinOpBitShiftLeftExact, arg0_value, arg1_value, true);
                return ir_lval_wrap(ag, scope, bin_op, lval, result_loc);
            }
        case BuiltinFnIdShrExact:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *bin_op = ir_build_bin_op(ag, scope, node, IrBinOpBitShiftRightExact, arg0_value, arg1_value, true);
                return ir_lval_wrap(ag, scope, bin_op, lval, result_loc);
            }
        case BuiltinFnIdSetEvalBranchQuota:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *set_eval_branch_quota = ir_build_set_eval_branch_quota(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, set_eval_branch_quota, lval, result_loc);
            }
        case BuiltinFnIdAlignCast:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *align_cast = ir_build_align_cast_src(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, align_cast, lval, result_loc);
            }
        case BuiltinFnIdThis:
            {
                Stage1ZirInst *this_inst = astgen_this(ag, scope, node);
                return ir_lval_wrap(ag, scope, this_inst, lval, result_loc);
            }
        case BuiltinFnIdSetAlignStack:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *set_align_stack = ir_build_set_align_stack(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, set_align_stack, lval, result_loc);
            }
        case BuiltinFnIdExport:
            {
                // Cast the options parameter to the options type
                ZigType *options_type = get_builtin_type(ag->codegen, "ExportOptions");
                Stage1ZirInst *options_type_inst = ir_build_const_type(ag, scope, node, options_type);
                ResultLocCast *result_loc_cast = ir_build_cast_result_loc(ag, options_type_inst, no_result_loc());

                AstNode *target_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *target_value = astgen_node(ag, target_node, scope);
                if (target_value == ag->codegen->invalid_inst_src)
                    return target_value;

                AstNode *options_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *options_value = astgen_node_extra(ag, options_node,
                    scope, LValNone, &result_loc_cast->base);
                if (options_value == ag->codegen->invalid_inst_src)
                    return options_value;

                Stage1ZirInst *casted_options_value = ir_build_implicit_cast(
                    ag, scope, options_node, options_value, result_loc_cast);

                Stage1ZirInst *ir_export = ir_build_export(ag, scope, node, target_value, casted_options_value);
                return ir_lval_wrap(ag, scope, ir_export, lval, result_loc);
            }
        case BuiltinFnIdExtern:
            {
                // Cast the options parameter to the options type
                ZigType *options_type = get_builtin_type(ag->codegen, "ExternOptions");
                Stage1ZirInst *options_type_inst = ir_build_const_type(ag, scope, node, options_type);
                ResultLocCast *result_loc_cast = ir_build_cast_result_loc(ag, options_type_inst, no_result_loc());

                AstNode *type_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *type_value = astgen_node(ag, type_node, scope);
                if (type_value == ag->codegen->invalid_inst_src)
                    return type_value;

                AstNode *options_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *options_value = astgen_node_extra(ag, options_node,
                    scope, LValNone, &result_loc_cast->base);
                if (options_value == ag->codegen->invalid_inst_src)
                    return options_value;

                Stage1ZirInst *casted_options_value = ir_build_implicit_cast(
                    ag, scope, options_node, options_value, result_loc_cast);

                Stage1ZirInst *ir_extern = ir_build_extern(ag, scope, node, type_value, casted_options_value);
                return ir_lval_wrap(ag, scope, ir_extern, lval, result_loc);
            }
        case BuiltinFnIdErrorReturnTrace:
            {
                Stage1ZirInst *error_return_trace = ir_build_error_return_trace_src(ag, scope, node,
                        IrInstErrorReturnTraceNull);
                return ir_lval_wrap(ag, scope, error_return_trace, lval, result_loc);
            }
        case BuiltinFnIdAtomicRmw:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                AstNode *arg2_node = node->data.fn_call_expr.params.at(2);
                Stage1ZirInst *arg2_value = astgen_node(ag, arg2_node, scope);
                if (arg2_value == ag->codegen->invalid_inst_src)
                    return arg2_value;

                AstNode *arg3_node = node->data.fn_call_expr.params.at(3);
                Stage1ZirInst *arg3_value = astgen_node(ag, arg3_node, scope);
                if (arg3_value == ag->codegen->invalid_inst_src)
                    return arg3_value;

                AstNode *arg4_node = node->data.fn_call_expr.params.at(4);
                Stage1ZirInst *arg4_value = astgen_node(ag, arg4_node, scope);
                if (arg4_value == ag->codegen->invalid_inst_src)
                    return arg4_value;

                Stage1ZirInst *inst = ir_build_atomic_rmw_src(ag, scope, node,
                        arg0_value, arg1_value, arg2_value, arg3_value, arg4_value);
                return ir_lval_wrap(ag, scope, inst, lval, result_loc);
            }
        case BuiltinFnIdAtomicLoad:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                AstNode *arg2_node = node->data.fn_call_expr.params.at(2);
                Stage1ZirInst *arg2_value = astgen_node(ag, arg2_node, scope);
                if (arg2_value == ag->codegen->invalid_inst_src)
                    return arg2_value;

                Stage1ZirInst *inst = ir_build_atomic_load_src(ag, scope, node, arg0_value, arg1_value, arg2_value);
                return ir_lval_wrap(ag, scope, inst, lval, result_loc);
            }
        case BuiltinFnIdAtomicStore:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                AstNode *arg2_node = node->data.fn_call_expr.params.at(2);
                Stage1ZirInst *arg2_value = astgen_node(ag, arg2_node, scope);
                if (arg2_value == ag->codegen->invalid_inst_src)
                    return arg2_value;

                AstNode *arg3_node = node->data.fn_call_expr.params.at(3);
                Stage1ZirInst *arg3_value = astgen_node(ag, arg3_node, scope);
                if (arg3_value == ag->codegen->invalid_inst_src)
                    return arg3_value;

                Stage1ZirInst *inst = ir_build_atomic_store_src(ag, scope, node, arg0_value, arg1_value,
                        arg2_value, arg3_value);
                return ir_lval_wrap(ag, scope, inst, lval, result_loc);
            }
        case BuiltinFnIdIntToEnum:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *result = ir_build_int_to_enum_src(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdEnumToInt:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                Stage1ZirInst *result = ir_build_enum_to_int(ag, scope, node, arg0_value);
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdCtz:
        case BuiltinFnIdPopCount:
        case BuiltinFnIdClz:
        case BuiltinFnIdBswap:
        case BuiltinFnIdBitReverse:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *result;
                switch (builtin_fn->id) {
                case BuiltinFnIdCtz:
                    result = ir_build_ctz(ag, scope, node, arg0_value, arg1_value);
                    break;
                case BuiltinFnIdPopCount:
                    result = ir_build_pop_count(ag, scope, node, arg0_value, arg1_value);
                    break;
                case BuiltinFnIdClz:
                    result = ir_build_clz(ag, scope, node, arg0_value, arg1_value);
                    break;
                case BuiltinFnIdBswap:
                    result = ir_build_bswap(ag, scope, node, arg0_value, arg1_value);
                    break;
                case BuiltinFnIdBitReverse:
                    result = ir_build_bit_reverse(ag, scope, node, arg0_value, arg1_value);
                    break;
                default:
                    zig_unreachable();
                }
                return ir_lval_wrap(ag, scope, result, lval, result_loc);
            }
        case BuiltinFnIdHasDecl:
            {
                AstNode *arg0_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *arg0_value = astgen_node(ag, arg0_node, scope);
                if (arg0_value == ag->codegen->invalid_inst_src)
                    return arg0_value;

                AstNode *arg1_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *arg1_value = astgen_node(ag, arg1_node, scope);
                if (arg1_value == ag->codegen->invalid_inst_src)
                    return arg1_value;

                Stage1ZirInst *has_decl = ir_build_has_decl(ag, scope, node, arg0_value, arg1_value);
                return ir_lval_wrap(ag, scope, has_decl, lval, result_loc);
            }
        case BuiltinFnIdUnionInit:
            {
                AstNode *union_type_node = node->data.fn_call_expr.params.at(0);
                Stage1ZirInst *union_type_inst = astgen_node(ag, union_type_node, scope);
                if (union_type_inst == ag->codegen->invalid_inst_src)
                    return union_type_inst;

                AstNode *name_node = node->data.fn_call_expr.params.at(1);
                Stage1ZirInst *name_inst = astgen_node(ag, name_node, scope);
                if (name_inst == ag->codegen->invalid_inst_src)
                    return name_inst;

                AstNode *init_node = node->data.fn_call_expr.params.at(2);

                return astgen_union_init_expr(ag, scope, node, union_type_inst, name_inst, init_node,
                        lval, result_loc);
            }
        case BuiltinFnIdSrc:
            {
                Stage1ZirInst *src_inst = ir_build_src(ag, scope, node);
                return ir_lval_wrap(ag, scope, src_inst, lval, result_loc);
            }
    }
    zig_unreachable();
}

static ScopeNoSuspend *get_scope_nosuspend(Scope *scope) {
    while (scope) {
        if (scope->id == ScopeIdNoSuspend)
            return (ScopeNoSuspend *)scope;
        if (scope->id == ScopeIdFnDef)
            return nullptr;

        scope = scope->parent;
    }
    return nullptr;
}

static Stage1ZirInst *astgen_fn_call(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeFnCallExpr);

    if (node->data.fn_call_expr.modifier == CallModifierBuiltin)
        return astgen_builtin_fn_call(ag, scope, node, lval, result_loc);

    bool is_nosuspend = get_scope_nosuspend(scope) != nullptr;
    CallModifier modifier = node->data.fn_call_expr.modifier;
    if (is_nosuspend && modifier != CallModifierAsync) {
        modifier = CallModifierNoSuspend;
    }

    AstNode *fn_ref_node = node->data.fn_call_expr.fn_ref_expr;
    return astgen_fn_call_with_args(ag, scope, node, fn_ref_node, modifier,
        nullptr, node->data.fn_call_expr.params.items, node->data.fn_call_expr.params.length, lval, result_loc);
}

static Stage1ZirInst *astgen_if_bool_expr(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeIfBoolExpr);

    Stage1ZirInst *condition = astgen_node(ag, node->data.if_bool_expr.condition, scope);
    if (condition == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *is_comptime;
    if (ir_should_inline(ag->exec, scope)) {
        is_comptime = ir_build_const_bool(ag, scope, node, true);
    } else {
        is_comptime = ir_build_test_comptime(ag, scope, node, condition);
    }

    AstNode *then_node = node->data.if_bool_expr.then_block;
    AstNode *else_node = node->data.if_bool_expr.else_node;

    Stage1ZirBasicBlock *then_block = ir_create_basic_block(ag, scope, "Then");
    Stage1ZirBasicBlock *else_block = ir_create_basic_block(ag, scope, "Else");
    Stage1ZirBasicBlock *endif_block = ir_create_basic_block(ag, scope, "EndIf");

    Stage1ZirInst *cond_br_inst = ir_build_cond_br(ag, scope, node, condition,
            then_block, else_block, is_comptime);
    ResultLocPeerParent *peer_parent = ir_build_binary_result_peers(ag, cond_br_inst, else_block, endif_block,
            result_loc, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, then_block);

    Scope *subexpr_scope = create_runtime_scope(ag->codegen, node, scope, is_comptime);
    Stage1ZirInst *then_expr_result = astgen_node_extra(ag, then_node, subexpr_scope, lval,
            &peer_parent->peers.at(0)->base);
    if (then_expr_result == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;
    Stage1ZirBasicBlock *after_then_block = ag->current_basic_block;
    if (!instr_is_unreachable(then_expr_result))
        ir_build_br(ag, scope, node, endif_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, else_block);
    Stage1ZirInst *else_expr_result;
    if (else_node) {
        else_expr_result = astgen_node_extra(ag, else_node, subexpr_scope, lval, &peer_parent->peers.at(1)->base);
        if (else_expr_result == ag->codegen->invalid_inst_src)
            return ag->codegen->invalid_inst_src;
    } else {
        else_expr_result = ir_build_const_void(ag, scope, node);
        ir_build_end_expr(ag, scope, node, else_expr_result, &peer_parent->peers.at(1)->base);
    }
    Stage1ZirBasicBlock *after_else_block = ag->current_basic_block;
    if (!instr_is_unreachable(else_expr_result))
        ir_build_br(ag, scope, node, endif_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, endif_block);
    Stage1ZirInst **incoming_values = heap::c_allocator.allocate<Stage1ZirInst *>(2);
    incoming_values[0] = then_expr_result;
    incoming_values[1] = else_expr_result;
    Stage1ZirBasicBlock **incoming_blocks = heap::c_allocator.allocate<Stage1ZirBasicBlock *>(2);
    incoming_blocks[0] = after_then_block;
    incoming_blocks[1] = after_else_block;

    Stage1ZirInst *phi = ir_build_phi(ag, scope, node, 2, incoming_blocks, incoming_values, peer_parent);
    return ir_expr_wrap(ag, scope, phi, result_loc);
}

static Stage1ZirInst *astgen_prefix_op_id_lval(Stage1AstGen *ag, Scope *scope, AstNode *node, IrUnOp op_id, LVal lval) {
    assert(node->type == NodeTypePrefixOpExpr);
    AstNode *expr_node = node->data.prefix_op_expr.primary_expr;

    Stage1ZirInst *value = astgen_node_extra(ag, expr_node, scope, lval, nullptr);
    if (value == ag->codegen->invalid_inst_src)
        return value;

    return ir_build_un_op(ag, scope, node, op_id, value);
}

static Stage1ZirInst *astgen_prefix_op_id(Stage1AstGen *ag, Scope *scope, AstNode *node, IrUnOp op_id) {
    return astgen_prefix_op_id_lval(ag, scope, node, op_id, LValNone);
}

static Stage1ZirInst *ir_expr_wrap(Stage1AstGen *ag, Scope *scope, Stage1ZirInst *inst, ResultLoc *result_loc) {
    if (inst == ag->codegen->invalid_inst_src) return inst;
    ir_build_end_expr(ag, scope, inst->source_node, inst, result_loc);
    return inst;
}

static Stage1ZirInst *ir_lval_wrap(Stage1AstGen *ag, Scope *scope, Stage1ZirInst *value, LVal lval,
        ResultLoc *result_loc)
{
    // This logic must be kept in sync with
    // [STMT_EXPR_TEST_THING] <--- (search this token)
    if (value == ag->codegen->invalid_inst_src ||
        instr_is_unreachable(value) ||
        value->source_node->type == NodeTypeDefer ||
        value->id == Stage1ZirInstIdDeclVar)
    {
        return value;
    }

    assert(lval != LValAssign);
    if (lval == LValPtr) {
        // We needed a pointer to a value, but we got a value. So we create
        // an instruction which just makes a pointer of it.
        return ir_build_ref_src(ag, scope, value->source_node, value);
    } else if (result_loc != nullptr) {
        return ir_expr_wrap(ag, scope, value, result_loc);
    } else {
        return value;
    }

}

static PtrLen star_token_to_ptr_len(TokenId token_id) {
    switch (token_id) {
        case TokenIdStar:
        case TokenIdStarStar:
            return PtrLenSingle;
        case TokenIdLBracket:
            return PtrLenUnknown;
        case TokenIdIdentifier:
            return PtrLenC;
        default:
            zig_unreachable();
    }
}

static Error token_number_literal_u32(Stage1AstGen *ag, AstNode *source_node,
    RootStruct *root_struct, uint32_t *result, TokenIndex token)
{
    BigInt bigint;
    token_number_literal_bigint(root_struct, &bigint, token);

    if (!bigint_fits_in_bits(&bigint, 32, false)) {
        Buf *val_buf = buf_alloc();
        bigint_append_buf(val_buf, &bigint, 10);
        exec_add_error_node(ag->codegen, ag->exec, source_node,
                buf_sprintf("value %s too large for u32", buf_ptr(val_buf)));
        bigint_deinit(&bigint);
        return ErrorSemanticAnalyzeFail;
    }
    *result = bigint_as_u32(&bigint);
    bigint_deinit(&bigint);
    return ErrorNone;

}

static Stage1ZirInst *astgen_pointer_type(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    Error err;
    assert(node->type == NodeTypePointerType);

    RootStruct *root_struct = node->owner->data.structure.root_struct;
    TokenId star_tok_id = root_struct->token_ids[node->data.pointer_type.star_token];
    PtrLen ptr_len = star_token_to_ptr_len(star_tok_id);

    bool is_const = node->data.pointer_type.is_const;
    bool is_volatile = node->data.pointer_type.is_volatile;
    bool is_allow_zero = node->data.pointer_type.allow_zero_token != 0;
    AstNode *sentinel_expr = node->data.pointer_type.sentinel;
    AstNode *expr_node = node->data.pointer_type.op_expr;
    AstNode *align_expr = node->data.pointer_type.align_expr;

    Stage1ZirInst *sentinel;
    if (sentinel_expr != nullptr) {
        sentinel = astgen_node(ag, sentinel_expr, scope);
        if (sentinel == ag->codegen->invalid_inst_src)
            return sentinel;
    } else {
        sentinel = nullptr;
    }

    Stage1ZirInst *align_value;
    if (align_expr != nullptr) {
        align_value = astgen_node(ag, align_expr, scope);
        if (align_value == ag->codegen->invalid_inst_src)
            return align_value;
    } else {
        align_value = nullptr;
    }

    Stage1ZirInst *child_type = astgen_node(ag, expr_node, scope);
    if (child_type == ag->codegen->invalid_inst_src)
        return child_type;

    uint32_t bit_offset_start = 0;
    if (node->data.pointer_type.bit_offset_start != 0) {
        if ((err = token_number_literal_u32(ag, node, root_struct, &bit_offset_start,
            node->data.pointer_type.bit_offset_start)))
        {
            return ag->codegen->invalid_inst_src;
        }
    }

    uint32_t host_int_bytes = 0;
    if (node->data.pointer_type.host_int_bytes != 0) {
        if ((err = token_number_literal_u32(ag, node, root_struct, &host_int_bytes,
            node->data.pointer_type.host_int_bytes)))
        {
            return ag->codegen->invalid_inst_src;
        }
    }

    if (host_int_bytes != 0 && bit_offset_start >= host_int_bytes * 8) {
        exec_add_error_node(ag->codegen, ag->exec, node,
                buf_sprintf("bit offset starts after end of host integer"));
        return ag->codegen->invalid_inst_src;
    }

    return ir_build_ptr_type(ag, scope, node, child_type, is_const, is_volatile,
            ptr_len, sentinel, align_value, bit_offset_start, host_int_bytes, is_allow_zero);
}

static Stage1ZirInst *astgen_catch_unreachable(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
        AstNode *expr_node, LVal lval, ResultLoc *result_loc)
{
    Stage1ZirInst *err_union_ptr = astgen_node_extra(ag, expr_node, scope, LValPtr, nullptr);
    if (err_union_ptr == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *payload_ptr = ir_build_unwrap_err_payload_src(ag, scope, source_node, err_union_ptr, true, false);
    if (payload_ptr == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    if (lval == LValPtr)
        return payload_ptr;

    Stage1ZirInst *load_ptr = ir_build_load_ptr(ag, scope, source_node, payload_ptr);
    return ir_expr_wrap(ag, scope, load_ptr, result_loc);
}

static Stage1ZirInst *astgen_bool_not(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypePrefixOpExpr);
    AstNode *expr_node = node->data.prefix_op_expr.primary_expr;

    Stage1ZirInst *value = astgen_node(ag, expr_node, scope);
    if (value == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    return ir_build_bool_not(ag, scope, node, value);
}

static Stage1ZirInst *astgen_prefix_op_expr(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypePrefixOpExpr);

    PrefixOp prefix_op = node->data.prefix_op_expr.prefix_op;

    switch (prefix_op) {
        case PrefixOpInvalid:
            zig_unreachable();
        case PrefixOpBoolNot:
            return ir_lval_wrap(ag, scope, astgen_bool_not(ag, scope, node), lval, result_loc);
        case PrefixOpBinNot:
            return ir_lval_wrap(ag, scope, astgen_prefix_op_id(ag, scope, node, IrUnOpBinNot), lval, result_loc);
        case PrefixOpNegation:
            return ir_lval_wrap(ag, scope, astgen_prefix_op_id(ag, scope, node, IrUnOpNegation), lval, result_loc);
        case PrefixOpNegationWrap:
            return ir_lval_wrap(ag, scope, astgen_prefix_op_id(ag, scope, node, IrUnOpNegationWrap), lval, result_loc);
        case PrefixOpOptional:
            return ir_lval_wrap(ag, scope, astgen_prefix_op_id(ag, scope, node, IrUnOpOptional), lval, result_loc);
        case PrefixOpAddrOf: {
            AstNode *expr_node = node->data.prefix_op_expr.primary_expr;
            return ir_lval_wrap(ag, scope, astgen_node_extra(ag, expr_node, scope, LValPtr, nullptr), lval, result_loc);
        }
    }
    zig_unreachable();
}

static Stage1ZirInst *astgen_union_init_expr(Stage1AstGen *ag, Scope *scope, AstNode *source_node,
    Stage1ZirInst *union_type, Stage1ZirInst *field_name, AstNode *expr_node,
    LVal lval, ResultLoc *parent_result_loc)
{
    Stage1ZirInst *container_ptr = ir_build_resolve_result(ag, scope, source_node, parent_result_loc, union_type);
    Stage1ZirInst *field_ptr = ir_build_field_ptr_instruction(ag, scope, source_node, container_ptr,
            field_name, true);

    ResultLocInstruction *result_loc_inst = heap::c_allocator.create<ResultLocInstruction>();
    result_loc_inst->base.id = ResultLocIdInstruction;
    result_loc_inst->base.source_instruction = field_ptr;
    ir_ref_instruction(field_ptr, ag->current_basic_block);
    ir_build_reset_result(ag, scope, expr_node, &result_loc_inst->base);

    Stage1ZirInst *expr_value = astgen_node_extra(ag, expr_node, scope, LValNone,
            &result_loc_inst->base);
    if (expr_value == ag->codegen->invalid_inst_src)
        return expr_value;

    Stage1ZirInst *init_union = ir_build_union_init_named_field(ag, scope, source_node, union_type,
            field_name, field_ptr, container_ptr);

    return ir_lval_wrap(ag, scope, init_union, lval, parent_result_loc);
}

static Stage1ZirInst *astgen_container_init_expr(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *parent_result_loc)
{
    assert(node->type == NodeTypeContainerInitExpr);

    AstNodeContainerInitExpr *container_init_expr = &node->data.container_init_expr;
    ContainerInitKind kind = container_init_expr->kind;

    ResultLocCast *result_loc_cast = nullptr;
    ResultLoc *child_result_loc;
    AstNode *init_array_type_source_node;
    if (container_init_expr->type != nullptr) {
        Stage1ZirInst *container_type;
        if (container_init_expr->type->type == NodeTypeInferredArrayType) {
            if (kind == ContainerInitKindStruct) {
                add_node_error(ag->codegen, container_init_expr->type,
                        buf_sprintf("initializing array with struct syntax"));
                return ag->codegen->invalid_inst_src;
            }
            Stage1ZirInst *sentinel;
            if (container_init_expr->type->data.inferred_array_type.sentinel != nullptr) {
                sentinel = astgen_node(ag, container_init_expr->type->data.inferred_array_type.sentinel, scope);
                if (sentinel == ag->codegen->invalid_inst_src)
                    return sentinel;
            } else {
                sentinel = nullptr;
            }

            Stage1ZirInst *elem_type = astgen_node(ag,
                    container_init_expr->type->data.inferred_array_type.child_type, scope);
            if (elem_type == ag->codegen->invalid_inst_src)
                return elem_type;
            size_t item_count = container_init_expr->entries.length;
            Stage1ZirInst *item_count_inst = ir_build_const_usize(ag, scope, node, item_count);
            container_type = ir_build_array_type(ag, scope, node, item_count_inst, sentinel, elem_type);
        } else {
            container_type = astgen_node(ag, container_init_expr->type, scope);
            if (container_type == ag->codegen->invalid_inst_src)
                return container_type;
        }

        result_loc_cast = ir_build_cast_result_loc(ag, container_type, parent_result_loc);
        child_result_loc = &result_loc_cast->base;
        init_array_type_source_node = container_type->source_node;
    } else {
        child_result_loc = parent_result_loc;
        if (parent_result_loc->source_instruction != nullptr) {
            init_array_type_source_node = parent_result_loc->source_instruction->source_node;
        } else {
            init_array_type_source_node = node;
        }
    }

    switch (kind) {
        case ContainerInitKindStruct: {
            Stage1ZirInst *container_ptr = ir_build_resolve_result(ag, scope, node, child_result_loc,
                    nullptr);

            size_t field_count = container_init_expr->entries.length;
            Stage1ZirInstContainerInitFieldsField *fields = heap::c_allocator.allocate<Stage1ZirInstContainerInitFieldsField>(field_count);
            for (size_t i = 0; i < field_count; i += 1) {
                AstNode *entry_node = container_init_expr->entries.at(i);
                assert(entry_node->type == NodeTypeStructValueField);

                Buf *name = entry_node->data.struct_val_field.name;
                AstNode *expr_node = entry_node->data.struct_val_field.expr;

                Stage1ZirInst *field_ptr = ir_build_field_ptr(ag, scope, entry_node, container_ptr, name, true);
                ResultLocInstruction *result_loc_inst = heap::c_allocator.create<ResultLocInstruction>();
                result_loc_inst->base.id = ResultLocIdInstruction;
                result_loc_inst->base.source_instruction = field_ptr;
                result_loc_inst->base.allow_write_through_const = true;
                ir_ref_instruction(field_ptr, ag->current_basic_block);
                ir_build_reset_result(ag, scope, expr_node, &result_loc_inst->base);

                Stage1ZirInst *expr_value = astgen_node_extra(ag, expr_node, scope, LValNone,
                        &result_loc_inst->base);
                if (expr_value == ag->codegen->invalid_inst_src)
                    return expr_value;

                fields[i].name = name;
                fields[i].source_node = entry_node;
                fields[i].result_loc = field_ptr;
            }
            Stage1ZirInst *result = ir_build_container_init_fields(ag, scope, node, field_count,
                    fields, container_ptr);

            if (result_loc_cast != nullptr) {
                result = ir_build_implicit_cast(ag, scope, node, result, result_loc_cast);
            }
            return ir_lval_wrap(ag, scope, result, lval, parent_result_loc);
        }
        case ContainerInitKindArray: {
            size_t item_count = container_init_expr->entries.length;

            Stage1ZirInst *container_ptr = ir_build_resolve_result(ag, scope, node, child_result_loc,
                    nullptr);

            Stage1ZirInst **result_locs = heap::c_allocator.allocate<Stage1ZirInst *>(item_count);
            for (size_t i = 0; i < item_count; i += 1) {
                AstNode *expr_node = container_init_expr->entries.at(i);

                Stage1ZirInst *elem_index = ir_build_const_usize(ag, scope, expr_node, i);
                Stage1ZirInst *elem_ptr = ir_build_elem_ptr(ag, scope, expr_node, container_ptr,
                        elem_index, false, PtrLenSingle, init_array_type_source_node);
                ResultLocInstruction *result_loc_inst = heap::c_allocator.create<ResultLocInstruction>();
                result_loc_inst->base.id = ResultLocIdInstruction;
                result_loc_inst->base.source_instruction = elem_ptr;
                result_loc_inst->base.allow_write_through_const = true;
                ir_ref_instruction(elem_ptr, ag->current_basic_block);
                ir_build_reset_result(ag, scope, expr_node, &result_loc_inst->base);

                Stage1ZirInst *expr_value = astgen_node_extra(ag, expr_node, scope, LValNone,
                        &result_loc_inst->base);
                if (expr_value == ag->codegen->invalid_inst_src)
                    return expr_value;

                result_locs[i] = elem_ptr;
            }
            Stage1ZirInst *result = ir_build_container_init_list(ag, scope, node, item_count,
                    result_locs, container_ptr, init_array_type_source_node);
            if (result_loc_cast != nullptr) {
                result = ir_build_implicit_cast(ag, scope, node, result, result_loc_cast);
            }
            return ir_lval_wrap(ag, scope, result, lval, parent_result_loc);
        }
    }
    zig_unreachable();
}

static ResultLocVar *ir_build_var_result_loc(Stage1AstGen *ag, Stage1ZirInst *alloca, ZigVar *var) {
    ResultLocVar *result_loc_var = heap::c_allocator.create<ResultLocVar>();
    result_loc_var->base.id = ResultLocIdVar;
    result_loc_var->base.source_instruction = alloca;
    result_loc_var->base.allow_write_through_const = true;
    result_loc_var->var = var;

    ir_build_reset_result(ag, alloca->scope, alloca->source_node, &result_loc_var->base);

    return result_loc_var;
}

static ResultLocCast *ir_build_cast_result_loc(Stage1AstGen *ag, Stage1ZirInst *dest_type,
        ResultLoc *parent_result_loc)
{
    ResultLocCast *result_loc_cast = heap::c_allocator.create<ResultLocCast>();
    result_loc_cast->base.id = ResultLocIdCast;
    result_loc_cast->base.source_instruction = dest_type;
    result_loc_cast->base.allow_write_through_const = parent_result_loc->allow_write_through_const;
    ir_ref_instruction(dest_type, ag->current_basic_block);
    result_loc_cast->parent = parent_result_loc;

    ir_build_reset_result(ag, dest_type->scope, dest_type->source_node, &result_loc_cast->base);

    return result_loc_cast;
}

static void build_decl_var_and_init(Stage1AstGen *ag, Scope *scope, AstNode *source_node, ZigVar *var,
        Stage1ZirInst *init, const char *name_hint, Stage1ZirInst *is_comptime)
{
    Stage1ZirInst *alloca = ir_build_alloca_src(ag, scope, source_node, nullptr, name_hint, is_comptime);
    ResultLocVar *var_result_loc = ir_build_var_result_loc(ag, alloca, var);
    ir_build_end_expr(ag, scope, source_node, init, &var_result_loc->base);
    ir_build_var_decl_src(ag, scope, source_node, var, nullptr, alloca);
}

static Stage1ZirInst *astgen_var_decl(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeVariableDeclaration);

    AstNodeVariableDeclaration *variable_declaration = &node->data.variable_declaration;

    if (buf_eql_str(variable_declaration->symbol, "_")) {
        add_node_error(ag->codegen, node, buf_sprintf("`_` is not a declarable symbol"));
        return ag->codegen->invalid_inst_src;
    }

    // Used for the type expr and the align expr
    Scope *comptime_scope = create_comptime_scope(ag->codegen, node, scope);

    Stage1ZirInst *type_instruction;
    if (variable_declaration->type != nullptr) {
        type_instruction = astgen_node(ag, variable_declaration->type, comptime_scope);
        if (type_instruction == ag->codegen->invalid_inst_src)
            return type_instruction;
    } else {
        type_instruction = nullptr;
    }

    bool is_shadowable = false;
    bool is_const = variable_declaration->is_const;
    bool is_extern = variable_declaration->is_extern;

    bool is_comptime_scalar = ir_should_inline(ag->exec, scope) || variable_declaration->is_comptime;
    Stage1ZirInst *is_comptime = ir_build_const_bool(ag, scope, node, is_comptime_scalar);
    ZigVar *var = ir_create_var(ag, node, scope, variable_declaration->symbol,
        is_const, is_const, is_shadowable, is_comptime);
    // we detect Stage1ZirInstDeclVar in gen_block to make sure the next node
    // is inside var->child_scope

    if (!is_extern && !variable_declaration->expr) {
        var->var_type = ag->codegen->builtin_types.entry_invalid;
        add_node_error(ag->codegen, node, buf_sprintf("variables must be initialized"));
        return ag->codegen->invalid_inst_src;
    }

    Stage1ZirInst *align_value = nullptr;
    if (variable_declaration->align_expr != nullptr) {
        align_value = astgen_node(ag, variable_declaration->align_expr, comptime_scope);
        if (align_value == ag->codegen->invalid_inst_src)
            return align_value;
    }

    if (variable_declaration->section_expr != nullptr) {
        add_node_error(ag->codegen, variable_declaration->section_expr,
            buf_sprintf("cannot set section of local variable '%s'", buf_ptr(variable_declaration->symbol)));
    }

    // Parser should ensure that this never happens
    assert(variable_declaration->threadlocal_tok == 0);

    Stage1ZirInst *alloca = ir_build_alloca_src(ag, scope, node, align_value,
            buf_ptr(variable_declaration->symbol), is_comptime);

    // Create a result location for the initialization expression.
    ResultLocVar *result_loc_var = ir_build_var_result_loc(ag, alloca, var);
    ResultLoc *init_result_loc;
    ResultLocCast *result_loc_cast;
    if (type_instruction != nullptr) {
        result_loc_cast = ir_build_cast_result_loc(ag, type_instruction, &result_loc_var->base);
        init_result_loc = &result_loc_cast->base;
    } else {
        result_loc_cast = nullptr;
        init_result_loc = &result_loc_var->base;
    }

    Scope *init_scope = is_comptime_scalar ?
        create_comptime_scope(ag->codegen, variable_declaration->expr, scope) : scope;

    // Temporarily set the name of the Stage1Zir to the VariableDeclaration
    // so that the struct or enum from the init expression inherits the name.
    Buf *old_exec_name = ag->exec->name;
    ag->exec->name = variable_declaration->symbol;
    Stage1ZirInst *init_value = astgen_node_extra(ag, variable_declaration->expr, init_scope,
            LValNone, init_result_loc);
    ag->exec->name = old_exec_name;

    if (init_value == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    if (result_loc_cast != nullptr) {
        Stage1ZirInst *implicit_cast = ir_build_implicit_cast(ag, scope, init_value->source_node,
                init_value, result_loc_cast);
        ir_build_end_expr(ag, scope, node, implicit_cast, &result_loc_var->base);
    }

    return ir_build_var_decl_src(ag, scope, node, var, align_value, alloca);
}

static Stage1ZirInst *astgen_while_expr(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeWhileExpr);

    AstNode *continue_expr_node = node->data.while_expr.continue_expr;
    AstNode *else_node = node->data.while_expr.else_node;

    Stage1ZirBasicBlock *cond_block = ir_create_basic_block(ag, scope, "WhileCond");
    Stage1ZirBasicBlock *body_block = ir_create_basic_block(ag, scope, "WhileBody");
    Stage1ZirBasicBlock *continue_block = continue_expr_node ?
        ir_create_basic_block(ag, scope, "WhileContinue") : cond_block;
    Stage1ZirBasicBlock *end_block = ir_create_basic_block(ag, scope, "WhileEnd");
    Stage1ZirBasicBlock *else_block = else_node ?
        ir_create_basic_block(ag, scope, "WhileElse") : end_block;

    Stage1ZirInst *is_comptime = ir_build_const_bool(ag, scope, node,
        ir_should_inline(ag->exec, scope) || node->data.while_expr.is_inline);
    ir_build_br(ag, scope, node, cond_block, is_comptime);

    Scope *subexpr_scope = create_runtime_scope(ag->codegen, node, scope, is_comptime);
    Buf *var_symbol = node->data.while_expr.var_symbol;
    Buf *err_symbol = node->data.while_expr.err_symbol;
    if (err_symbol != nullptr) {
        ir_set_cursor_at_end_and_append_block(ag, cond_block);

        Scope *payload_scope;
        AstNode *symbol_node = node; // TODO make more accurate
        ZigVar *payload_var;
        if (var_symbol) {
            // TODO make it an error to write to payload variable
            payload_var = ir_create_var(ag, symbol_node, subexpr_scope, var_symbol,
                    true, false, false, is_comptime);
            payload_scope = payload_var->child_scope;
        } else {
            payload_scope = subexpr_scope;
        }
        ScopeExpr *spill_scope = create_expr_scope(ag->codegen, node, payload_scope);
        Stage1ZirInst *err_val_ptr = astgen_node_extra(ag, node->data.while_expr.condition, subexpr_scope,
                LValPtr, nullptr);
        if (err_val_ptr == ag->codegen->invalid_inst_src)
            return err_val_ptr;
        Stage1ZirInst *is_err = ir_build_test_err_src(ag, scope, node->data.while_expr.condition, err_val_ptr,
                true, false);
        Stage1ZirBasicBlock *after_cond_block = ag->current_basic_block;
        Stage1ZirInst *void_else_result = else_node ? nullptr : ir_build_const_void(ag, scope, node);
        Stage1ZirInst *cond_br_inst;
        if (!instr_is_unreachable(is_err)) {
            cond_br_inst = ir_build_cond_br(ag, scope, node->data.while_expr.condition, is_err,
                        else_block, body_block, is_comptime);
        } else {
            // for the purposes of the source instruction to ir_build_result_peers
            cond_br_inst = ag->current_basic_block->instruction_list.last();
        }

        ResultLocPeerParent *peer_parent = ir_build_result_peers(ag, cond_br_inst, end_block, result_loc,
                is_comptime);

        ir_set_cursor_at_end_and_append_block(ag, body_block);
        if (var_symbol) {
            Stage1ZirInst *payload_ptr = ir_build_unwrap_err_payload_src(ag, &spill_scope->base, symbol_node,
                    err_val_ptr, false, false);
            Stage1ZirInst *var_value = node->data.while_expr.var_is_ptr ?
                payload_ptr : ir_build_load_ptr(ag, &spill_scope->base, symbol_node, payload_ptr);
            build_decl_var_and_init(ag, payload_scope, symbol_node, payload_var, var_value, buf_ptr(var_symbol), is_comptime);
        }

        ZigList<Stage1ZirInst *> incoming_values = {0};
        ZigList<Stage1ZirBasicBlock *> incoming_blocks = {0};

        if (is_duplicate_label(ag->codegen, payload_scope, node, node->data.while_expr.name))
            return ag->codegen->invalid_inst_src;

        ScopeLoop *loop_scope = create_loop_scope(ag->codegen, node, payload_scope);
        loop_scope->break_block = end_block;
        loop_scope->continue_block = continue_block;
        loop_scope->is_comptime = is_comptime;
        loop_scope->incoming_blocks = &incoming_blocks;
        loop_scope->incoming_values = &incoming_values;
        loop_scope->lval = lval;
        loop_scope->peer_parent = peer_parent;
        loop_scope->spill_scope = spill_scope;

        // Note the body block of the loop is not the place that lval and result_loc are used -
        // it's actually in break statements, handled similarly to return statements.
        // That is why we set those values in loop_scope above and not in this astgen_node call.
        Stage1ZirInst *body_result = astgen_node(ag, node->data.while_expr.body, &loop_scope->base);
        if (body_result == ag->codegen->invalid_inst_src)
            return body_result;

        if (loop_scope->name != nullptr && loop_scope->name_used == false) {
            add_node_error(ag->codegen, node, buf_sprintf("unused while label"));
        }

        if (!instr_is_unreachable(body_result)) {
            ir_build_check_statement_is_void(ag, payload_scope, node->data.while_expr.body, body_result);
            ir_build_br(ag, payload_scope, node, continue_block, is_comptime);
        }

        if (continue_expr_node) {
            ir_set_cursor_at_end_and_append_block(ag, continue_block);
            Stage1ZirInst *expr_result = astgen_node(ag, continue_expr_node, payload_scope);
            if (expr_result == ag->codegen->invalid_inst_src)
                return expr_result;
            if (!instr_is_unreachable(expr_result)) {
                ir_build_check_statement_is_void(ag, payload_scope, continue_expr_node, expr_result);
                ir_build_br(ag, payload_scope, node, cond_block, is_comptime);
            }
        }

        ir_set_cursor_at_end_and_append_block(ag, else_block);
        assert(else_node != nullptr);

        // TODO make it an error to write to error variable
        AstNode *err_symbol_node = else_node; // TODO make more accurate
        ZigVar *err_var = ir_create_var(ag, err_symbol_node, scope, err_symbol,
                true, false, false, is_comptime);
        Scope *err_scope = err_var->child_scope;
        Stage1ZirInst *err_ptr = ir_build_unwrap_err_code_src(ag, err_scope, err_symbol_node, err_val_ptr);
        Stage1ZirInst *err_value = ir_build_load_ptr(ag, err_scope, err_symbol_node, err_ptr);
        build_decl_var_and_init(ag, err_scope, err_symbol_node, err_var, err_value, buf_ptr(err_symbol), is_comptime);

        if (peer_parent->peers.length != 0) {
            peer_parent->peers.last()->next_bb = else_block;
        }
        ResultLocPeer *peer_result = create_peer_result(peer_parent);
        peer_parent->peers.append(peer_result);
        Stage1ZirInst *else_result = astgen_node_extra(ag, else_node, err_scope, lval, &peer_result->base);
        if (else_result == ag->codegen->invalid_inst_src)
            return else_result;
        if (!instr_is_unreachable(else_result))
            ir_build_br(ag, scope, node, end_block, is_comptime);
        Stage1ZirBasicBlock *after_else_block = ag->current_basic_block;
        ir_set_cursor_at_end_and_append_block(ag, end_block);
        if (else_result) {
            incoming_blocks.append(after_else_block);
            incoming_values.append(else_result);
        } else {
            incoming_blocks.append(after_cond_block);
            incoming_values.append(void_else_result);
        }
        if (peer_parent->peers.length != 0) {
            peer_parent->peers.last()->next_bb = end_block;
        }

        Stage1ZirInst *phi = ir_build_phi(ag, scope, node, incoming_blocks.length,
                incoming_blocks.items, incoming_values.items, peer_parent);
        return ir_expr_wrap(ag, scope, phi, result_loc);
    } else if (var_symbol != nullptr) {
        ir_set_cursor_at_end_and_append_block(ag, cond_block);
        Scope *subexpr_scope = create_runtime_scope(ag->codegen, node, scope, is_comptime);
        // TODO make it an error to write to payload variable
        AstNode *symbol_node = node; // TODO make more accurate

        ZigVar *payload_var = ir_create_var(ag, symbol_node, subexpr_scope, var_symbol,
                true, false, false, is_comptime);
        Scope *child_scope = payload_var->child_scope;
        ScopeExpr *spill_scope = create_expr_scope(ag->codegen, node, child_scope);
        Stage1ZirInst *maybe_val_ptr = astgen_node_extra(ag, node->data.while_expr.condition, subexpr_scope,
                LValPtr, nullptr);
        if (maybe_val_ptr == ag->codegen->invalid_inst_src)
            return maybe_val_ptr;
        Stage1ZirInst *maybe_val = ir_build_load_ptr(ag, scope, node->data.while_expr.condition, maybe_val_ptr);
        Stage1ZirInst *is_non_null = ir_build_test_non_null_src(ag, scope, node->data.while_expr.condition, maybe_val);
        Stage1ZirBasicBlock *after_cond_block = ag->current_basic_block;
        Stage1ZirInst *void_else_result = else_node ? nullptr : ir_build_const_void(ag, scope, node);
        Stage1ZirInst *cond_br_inst;
        if (!instr_is_unreachable(is_non_null)) {
            cond_br_inst = ir_build_cond_br(ag, scope, node->data.while_expr.condition, is_non_null,
                        body_block, else_block, is_comptime);
        } else {
            // for the purposes of the source instruction to ir_build_result_peers
            cond_br_inst = ag->current_basic_block->instruction_list.last();
        }

        ResultLocPeerParent *peer_parent = ir_build_result_peers(ag, cond_br_inst, end_block, result_loc,
                is_comptime);

        ir_set_cursor_at_end_and_append_block(ag, body_block);
        Stage1ZirInst *payload_ptr = ir_build_optional_unwrap_ptr(ag, &spill_scope->base, symbol_node, maybe_val_ptr, false);
        Stage1ZirInst *var_value = node->data.while_expr.var_is_ptr ?
            payload_ptr : ir_build_load_ptr(ag, &spill_scope->base, symbol_node, payload_ptr);
        build_decl_var_and_init(ag, child_scope, symbol_node, payload_var, var_value, buf_ptr(var_symbol), is_comptime);

        ZigList<Stage1ZirInst *> incoming_values = {0};
        ZigList<Stage1ZirBasicBlock *> incoming_blocks = {0};

        if (is_duplicate_label(ag->codegen, child_scope, node, node->data.while_expr.name))
            return ag->codegen->invalid_inst_src;

        ScopeLoop *loop_scope = create_loop_scope(ag->codegen, node, child_scope);
        loop_scope->break_block = end_block;
        loop_scope->continue_block = continue_block;
        loop_scope->is_comptime = is_comptime;
        loop_scope->incoming_blocks = &incoming_blocks;
        loop_scope->incoming_values = &incoming_values;
        loop_scope->lval = lval;
        loop_scope->peer_parent = peer_parent;
        loop_scope->spill_scope = spill_scope;

        // Note the body block of the loop is not the place that lval and result_loc are used -
        // it's actually in break statements, handled similarly to return statements.
        // That is why we set those values in loop_scope above and not in this astgen_node call.
        Stage1ZirInst *body_result = astgen_node(ag, node->data.while_expr.body, &loop_scope->base);
        if (body_result == ag->codegen->invalid_inst_src)
            return body_result;

        if (loop_scope->name != nullptr && loop_scope->name_used == false) {
            add_node_error(ag->codegen, node, buf_sprintf("unused while label"));
        }

        if (!instr_is_unreachable(body_result)) {
            ir_build_check_statement_is_void(ag, child_scope, node->data.while_expr.body, body_result);
            ir_build_br(ag, child_scope, node, continue_block, is_comptime);
        }

        if (continue_expr_node) {
            ir_set_cursor_at_end_and_append_block(ag, continue_block);
            Stage1ZirInst *expr_result = astgen_node(ag, continue_expr_node, child_scope);
            if (expr_result == ag->codegen->invalid_inst_src)
                return expr_result;
            if (!instr_is_unreachable(expr_result)) {
                ir_build_check_statement_is_void(ag, child_scope, continue_expr_node, expr_result);
                ir_build_br(ag, child_scope, node, cond_block, is_comptime);
            }
        }

        Stage1ZirInst *else_result = nullptr;
        if (else_node) {
            ir_set_cursor_at_end_and_append_block(ag, else_block);

            if (peer_parent->peers.length != 0) {
                peer_parent->peers.last()->next_bb = else_block;
            }
            ResultLocPeer *peer_result = create_peer_result(peer_parent);
            peer_parent->peers.append(peer_result);
            else_result = astgen_node_extra(ag, else_node, scope, lval, &peer_result->base);
            if (else_result == ag->codegen->invalid_inst_src)
                return else_result;
            if (!instr_is_unreachable(else_result))
                ir_build_br(ag, scope, node, end_block, is_comptime);
        }
        Stage1ZirBasicBlock *after_else_block = ag->current_basic_block;
        ir_set_cursor_at_end_and_append_block(ag, end_block);
        if (else_result) {
            incoming_blocks.append(after_else_block);
            incoming_values.append(else_result);
        } else {
            incoming_blocks.append(after_cond_block);
            incoming_values.append(void_else_result);
        }
        if (peer_parent->peers.length != 0) {
            peer_parent->peers.last()->next_bb = end_block;
        }

        Stage1ZirInst *phi = ir_build_phi(ag, scope, node, incoming_blocks.length,
                incoming_blocks.items, incoming_values.items, peer_parent);
        return ir_expr_wrap(ag, scope, phi, result_loc);
    } else {
        ir_set_cursor_at_end_and_append_block(ag, cond_block);
        Stage1ZirInst *cond_val = astgen_node(ag, node->data.while_expr.condition, scope);
        if (cond_val == ag->codegen->invalid_inst_src)
            return cond_val;
        Stage1ZirBasicBlock *after_cond_block = ag->current_basic_block;
        Stage1ZirInst *void_else_result = else_node ? nullptr : ir_build_const_void(ag, scope, node);
        Stage1ZirInst *cond_br_inst;
        if (!instr_is_unreachable(cond_val)) {
            cond_br_inst = ir_build_cond_br(ag, scope, node->data.while_expr.condition, cond_val,
                        body_block, else_block, is_comptime);
        } else {
            // for the purposes of the source instruction to ir_build_result_peers
            cond_br_inst = ag->current_basic_block->instruction_list.last();
        }

        ResultLocPeerParent *peer_parent = ir_build_result_peers(ag, cond_br_inst, end_block, result_loc,
                is_comptime);
        ir_set_cursor_at_end_and_append_block(ag, body_block);

        ZigList<Stage1ZirInst *> incoming_values = {0};
        ZigList<Stage1ZirBasicBlock *> incoming_blocks = {0};

        Scope *subexpr_scope = create_runtime_scope(ag->codegen, node, scope, is_comptime);

        if (is_duplicate_label(ag->codegen, subexpr_scope, node, node->data.while_expr.name))
            return ag->codegen->invalid_inst_src;

        ScopeLoop *loop_scope = create_loop_scope(ag->codegen, node, subexpr_scope);
        loop_scope->break_block = end_block;
        loop_scope->continue_block = continue_block;
        loop_scope->is_comptime = is_comptime;
        loop_scope->incoming_blocks = &incoming_blocks;
        loop_scope->incoming_values = &incoming_values;
        loop_scope->lval = lval;
        loop_scope->peer_parent = peer_parent;

        // Note the body block of the loop is not the place that lval and result_loc are used -
        // it's actually in break statements, handled similarly to return statements.
        // That is why we set those values in loop_scope above and not in this astgen_node call.
        Stage1ZirInst *body_result = astgen_node(ag, node->data.while_expr.body, &loop_scope->base);
        if (body_result == ag->codegen->invalid_inst_src)
            return body_result;

        if (loop_scope->name != nullptr && loop_scope->name_used == false) {
            add_node_error(ag->codegen, node, buf_sprintf("unused while label"));
        }

        if (!instr_is_unreachable(body_result)) {
            ir_build_check_statement_is_void(ag, scope, node->data.while_expr.body, body_result);
            ir_build_br(ag, scope, node, continue_block, is_comptime);
        }

        if (continue_expr_node) {
            ir_set_cursor_at_end_and_append_block(ag, continue_block);
            Stage1ZirInst *expr_result = astgen_node(ag, continue_expr_node, subexpr_scope);
            if (expr_result == ag->codegen->invalid_inst_src)
                return expr_result;
            if (!instr_is_unreachable(expr_result)) {
                ir_build_check_statement_is_void(ag, scope, continue_expr_node, expr_result);
                ir_build_br(ag, scope, node, cond_block, is_comptime);
            }
        }

        Stage1ZirInst *else_result = nullptr;
        if (else_node) {
            ir_set_cursor_at_end_and_append_block(ag, else_block);

            if (peer_parent->peers.length != 0) {
                peer_parent->peers.last()->next_bb = else_block;
            }
            ResultLocPeer *peer_result = create_peer_result(peer_parent);
            peer_parent->peers.append(peer_result);

            else_result = astgen_node_extra(ag, else_node, subexpr_scope, lval, &peer_result->base);
            if (else_result == ag->codegen->invalid_inst_src)
                return else_result;
            if (!instr_is_unreachable(else_result))
                ir_build_br(ag, scope, node, end_block, is_comptime);
        }
        Stage1ZirBasicBlock *after_else_block = ag->current_basic_block;
        ir_set_cursor_at_end_and_append_block(ag, end_block);
        if (else_result) {
            incoming_blocks.append(after_else_block);
            incoming_values.append(else_result);
        } else {
            incoming_blocks.append(after_cond_block);
            incoming_values.append(void_else_result);
        }
        if (peer_parent->peers.length != 0) {
            peer_parent->peers.last()->next_bb = end_block;
        }

        Stage1ZirInst *phi = ir_build_phi(ag, scope, node, incoming_blocks.length,
                incoming_blocks.items, incoming_values.items, peer_parent);
        return ir_expr_wrap(ag, scope, phi, result_loc);
    }
}

static Stage1ZirInst *astgen_for_expr(Stage1AstGen *ag, Scope *parent_scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeForExpr);

    AstNode *array_node = node->data.for_expr.array_expr;
    AstNode *elem_node = node->data.for_expr.elem_node;
    AstNode *index_node = node->data.for_expr.index_node;
    AstNode *body_node = node->data.for_expr.body;
    AstNode *else_node = node->data.for_expr.else_node;

    if (!elem_node) {
        add_node_error(ag->codegen, node, buf_sprintf("for loop expression missing element parameter"));
        return ag->codegen->invalid_inst_src;
    }
    assert(elem_node->type == NodeTypeIdentifier);

    ScopeExpr *spill_scope = create_expr_scope(ag->codegen, node, parent_scope);

    Stage1ZirInst *array_val_ptr = astgen_node_extra(ag, array_node, &spill_scope->base, LValPtr, nullptr);
    if (array_val_ptr == ag->codegen->invalid_inst_src)
        return array_val_ptr;

    Stage1ZirInst *is_comptime = ir_build_const_bool(ag, parent_scope, node,
        ir_should_inline(ag->exec, parent_scope) || node->data.for_expr.is_inline);

    AstNode *index_var_source_node;
    ZigVar *index_var;
    const char *index_var_name;
    if (index_node) {
        index_var_source_node = index_node;
        Buf *index_var_name_buf = node_identifier_buf(index_node);
        index_var = ir_create_var(ag, index_node, parent_scope, index_var_name_buf, true, false, false, is_comptime);
        index_var_name = buf_ptr(index_var_name_buf);
    } else {
        index_var_source_node = node;
        index_var = ir_create_var(ag, node, parent_scope, nullptr, true, false, true, is_comptime);
        index_var_name = "i";
    }

    Stage1ZirInst *zero = ir_build_const_usize(ag, parent_scope, node, 0);
    build_decl_var_and_init(ag, parent_scope, index_var_source_node, index_var, zero, index_var_name, is_comptime);
    parent_scope = index_var->child_scope;

    Stage1ZirInst *one = ir_build_const_usize(ag, parent_scope, node, 1);
    Stage1ZirInst *index_ptr = ir_build_var_ptr(ag, parent_scope, node, index_var);


    Stage1ZirBasicBlock *cond_block = ir_create_basic_block(ag, parent_scope, "ForCond");
    Stage1ZirBasicBlock *body_block = ir_create_basic_block(ag, parent_scope, "ForBody");
    Stage1ZirBasicBlock *end_block = ir_create_basic_block(ag, parent_scope, "ForEnd");
    Stage1ZirBasicBlock *else_block = else_node ? ir_create_basic_block(ag, parent_scope, "ForElse") : end_block;
    Stage1ZirBasicBlock *continue_block = ir_create_basic_block(ag, parent_scope, "ForContinue");

    Buf *len_field_name = buf_create_from_str("len");
    Stage1ZirInst *len_ref = ir_build_field_ptr(ag, parent_scope, node, array_val_ptr, len_field_name, false);
    Stage1ZirInst *len_val = ir_build_load_ptr(ag, &spill_scope->base, node, len_ref);
    ir_build_br(ag, parent_scope, node, cond_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, cond_block);
    Stage1ZirInst *index_val = ir_build_load_ptr(ag, &spill_scope->base, node, index_ptr);
    Stage1ZirInst *cond = ir_build_bin_op(ag, parent_scope, node, IrBinOpCmpLessThan, index_val, len_val, false);
    Stage1ZirBasicBlock *after_cond_block = ag->current_basic_block;
    Stage1ZirInst *void_else_value = else_node ? nullptr : ir_build_const_void(ag, parent_scope, node);
    Stage1ZirInst *cond_br_inst = ir_build_cond_br(ag, parent_scope, node, cond,
                body_block, else_block, is_comptime);

    ResultLocPeerParent *peer_parent = ir_build_result_peers(ag, cond_br_inst, end_block, result_loc, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, body_block);
    Stage1ZirInst *elem_ptr = ir_build_elem_ptr(ag, &spill_scope->base, node, array_val_ptr, index_val,
            false, PtrLenSingle, nullptr);
    // TODO make it an error to write to element variable or i variable.
    Buf *elem_var_name = node_identifier_buf(elem_node);
    ZigVar *elem_var = ir_create_var(ag, elem_node, parent_scope, elem_var_name, true, false, false, is_comptime);
    Scope *child_scope = elem_var->child_scope;

    Stage1ZirInst *elem_value = node->data.for_expr.elem_is_ptr ?
        elem_ptr : ir_build_load_ptr(ag, &spill_scope->base, elem_node, elem_ptr);
    build_decl_var_and_init(ag, parent_scope, elem_node, elem_var, elem_value, buf_ptr(elem_var_name), is_comptime);

    if (is_duplicate_label(ag->codegen, child_scope, node, node->data.for_expr.name))
        return ag->codegen->invalid_inst_src;

    ZigList<Stage1ZirInst *> incoming_values = {0};
    ZigList<Stage1ZirBasicBlock *> incoming_blocks = {0};
    ScopeLoop *loop_scope = create_loop_scope(ag->codegen, node, child_scope);
    loop_scope->break_block = end_block;
    loop_scope->continue_block = continue_block;
    loop_scope->is_comptime = is_comptime;
    loop_scope->incoming_blocks = &incoming_blocks;
    loop_scope->incoming_values = &incoming_values;
    loop_scope->lval = LValNone;
    loop_scope->peer_parent = peer_parent;
    loop_scope->spill_scope = spill_scope;

    // Note the body block of the loop is not the place that lval and result_loc are used -
    // it's actually in break statements, handled similarly to return statements.
    // That is why we set those values in loop_scope above and not in this astgen_node call.
    Stage1ZirInst *body_result = astgen_node(ag, body_node, &loop_scope->base);
    if (body_result == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    if (loop_scope->name != nullptr && loop_scope->name_used == false) {
        add_node_error(ag->codegen, node, buf_sprintf("unused for label"));
    }

    if (!instr_is_unreachable(body_result)) {
        ir_build_check_statement_is_void(ag, child_scope, node->data.for_expr.body, body_result);
        ir_build_br(ag, child_scope, node, continue_block, is_comptime);
    }

    ir_set_cursor_at_end_and_append_block(ag, continue_block);
    Stage1ZirInst *new_index_val = ir_build_bin_op(ag, child_scope, node, IrBinOpAdd, index_val, one, false);
    ir_build_store_ptr(ag, child_scope, node, index_ptr, new_index_val)->allow_write_through_const = true;
    ir_build_br(ag, child_scope, node, cond_block, is_comptime);

    Stage1ZirInst *else_result = nullptr;
    if (else_node) {
        ir_set_cursor_at_end_and_append_block(ag, else_block);

        if (peer_parent->peers.length != 0) {
            peer_parent->peers.last()->next_bb = else_block;
        }
        ResultLocPeer *peer_result = create_peer_result(peer_parent);
        peer_parent->peers.append(peer_result);
        else_result = astgen_node_extra(ag, else_node, parent_scope, LValNone, &peer_result->base);
        if (else_result == ag->codegen->invalid_inst_src)
            return else_result;
        if (!instr_is_unreachable(else_result))
            ir_build_br(ag, parent_scope, node, end_block, is_comptime);
    }
    Stage1ZirBasicBlock *after_else_block = ag->current_basic_block;
    ir_set_cursor_at_end_and_append_block(ag, end_block);

    if (else_result) {
        incoming_blocks.append(after_else_block);
        incoming_values.append(else_result);
    } else {
        incoming_blocks.append(after_cond_block);
        incoming_values.append(void_else_value);
    }
    if (peer_parent->peers.length != 0) {
        peer_parent->peers.last()->next_bb = end_block;
    }

    Stage1ZirInst *phi = ir_build_phi(ag, parent_scope, node, incoming_blocks.length,
            incoming_blocks.items, incoming_values.items, peer_parent);
    return ir_lval_wrap(ag, parent_scope, phi, lval, result_loc);
}

static Stage1ZirInst *astgen_bool_literal(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeBoolLiteral);
    return ir_build_const_bool(ag, scope, node, node->data.bool_literal.value);
}

static Stage1ZirInst *astgen_enum_literal(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeEnumLiteral);
    // Currently, stage1 runs astgen for every comptime function call,
    // resulting the allocation here wasting memory. As a workaround until
    // the code is adjusted to make astgen run only once per source node,
    // we memoize the result into the AST here.
    if (node->data.enum_literal.name == nullptr) {
        RootStruct *root_struct = node->owner->data.structure.root_struct;
        node->data.enum_literal.name = token_identifier_buf(root_struct, node->main_token + 1);
    }
    return ir_build_const_enum_literal(ag, scope, node, node->data.enum_literal.name);
}

static Stage1ZirInst *astgen_string_literal(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    Error err;
    assert(node->type == NodeTypeStringLiteral);

    RootStruct *root_struct = node->owner->data.structure.root_struct;
    const char *source = buf_ptr(root_struct->source_code);

    TokenId *token_ids = root_struct->token_ids;

    Buf *str = buf_alloc();
    if (token_ids[node->main_token] == TokenIdStringLiteral) {
        size_t byte_offset = root_struct->token_locs[node->main_token].offset;
        size_t bad_index;
        if ((err = source_string_literal_buf(source + byte_offset, str, &bad_index))) {
            add_token_error_offset(ag->codegen, node->owner, node->main_token,
                    buf_create_from_str("invalid string literal character"), bad_index);
        }
        src_assert(source[byte_offset] == '"', node);
        byte_offset += 1;
    } else if (token_ids[node->main_token] == TokenIdMultilineStringLiteralLine) {
        TokenIndex tok_index = node->main_token;
        bool first = true;
        for (;token_ids[tok_index] == TokenIdMultilineStringLiteralLine; tok_index += 1) {
            size_t byte_offset = root_struct->token_locs[tok_index].offset;
            size_t end = byte_offset;
            while (source[end] != 0 && source[end] != '\n') {
                end += 1;
            }
            if (!first) {
                buf_append_char(str, '\n');
            } else {
                first = false;
            }
            buf_append_mem(str, source + byte_offset + 2, end - byte_offset - 2);
        }
    } else {
        zig_unreachable();
    }

    return ir_build_const_str_lit(ag, scope, node, str);
}

static Stage1ZirInst *astgen_array_type(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeArrayType);

    AstNode *size_node = node->data.array_type.size;
    AstNode *child_type_node = node->data.array_type.child_type;
    bool is_const = node->data.array_type.is_const;
    bool is_volatile = node->data.array_type.is_volatile;
    bool is_allow_zero = node->data.array_type.allow_zero_token != 0;
    AstNode *sentinel_expr = node->data.array_type.sentinel;
    AstNode *align_expr = node->data.array_type.align_expr;

    Scope *comptime_scope = create_comptime_scope(ag->codegen, node, scope);

    Stage1ZirInst *sentinel;
    if (sentinel_expr != nullptr) {
        sentinel = astgen_node(ag, sentinel_expr, comptime_scope);
        if (sentinel == ag->codegen->invalid_inst_src)
            return sentinel;
    } else {
        sentinel = nullptr;
    }

    if (size_node) {
        if (is_const) {
            add_node_error(ag->codegen, node, buf_create_from_str("const qualifier invalid on array type"));
            return ag->codegen->invalid_inst_src;
        }
        if (is_volatile) {
            add_node_error(ag->codegen, node, buf_create_from_str("volatile qualifier invalid on array type"));
            return ag->codegen->invalid_inst_src;
        }
        if (is_allow_zero) {
            add_node_error(ag->codegen, node, buf_create_from_str("allowzero qualifier invalid on array type"));
            return ag->codegen->invalid_inst_src;
        }
        if (align_expr != nullptr) {
            add_node_error(ag->codegen, node, buf_create_from_str("align qualifier invalid on array type"));
            return ag->codegen->invalid_inst_src;
        }

        Stage1ZirInst *size_value = astgen_node(ag, size_node, comptime_scope);
        if (size_value == ag->codegen->invalid_inst_src)
            return size_value;

        Stage1ZirInst *child_type = astgen_node(ag, child_type_node, comptime_scope);
        if (child_type == ag->codegen->invalid_inst_src)
            return child_type;

        return ir_build_array_type(ag, scope, node, size_value, sentinel, child_type);
    } else {
        Stage1ZirInst *align_value;
        if (align_expr != nullptr) {
            align_value = astgen_node(ag, align_expr, comptime_scope);
            if (align_value == ag->codegen->invalid_inst_src)
                return align_value;
        } else {
            align_value = nullptr;
        }

        Stage1ZirInst *child_type = astgen_node(ag, child_type_node, comptime_scope);
        if (child_type == ag->codegen->invalid_inst_src)
            return child_type;

        return ir_build_slice_type(ag, scope, node, child_type, is_const, is_volatile, sentinel,
                align_value, is_allow_zero);
    }
}

static Stage1ZirInst *astgen_anyframe_type(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeAnyFrameType);

    AstNode *payload_type_node = node->data.anyframe_type.payload_type;
    Stage1ZirInst *payload_type_value = nullptr;

    if (payload_type_node != nullptr) {
        payload_type_value = astgen_node(ag, payload_type_node, scope);
        if (payload_type_value == ag->codegen->invalid_inst_src)
            return payload_type_value;

    }

    return ir_build_anyframe_type(ag, scope, node, payload_type_value);
}

static Stage1ZirInst *astgen_undefined_literal(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeUndefinedLiteral);
    return ir_build_const_undefined(ag, scope, node);
}

static Stage1ZirInst *astgen_asm_expr(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeAsmExpr);
    AstNodeAsmExpr *asm_expr = &node->data.asm_expr;

    Stage1ZirInst *asm_template = astgen_node(ag, asm_expr->asm_template, scope);
    if (asm_template == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    bool is_volatile = asm_expr->volatile_token != 0;
    bool in_fn_scope = (scope_fn_entry(scope) != nullptr);

    if (!in_fn_scope) {
        if (is_volatile) {
            add_token_error(ag->codegen, node->owner, asm_expr->volatile_token,
                    buf_sprintf("volatile is meaningless on global assembly"));
            return ag->codegen->invalid_inst_src;
        }

        if (asm_expr->output_list.length != 0 || asm_expr->input_list.length != 0 ||
            asm_expr->clobber_list.length != 0)
        {
            add_node_error(ag->codegen, node,
                buf_sprintf("global assembly cannot have inputs, outputs, or clobbers"));
            return ag->codegen->invalid_inst_src;
        }

        return ir_build_asm_src(ag, scope, node, asm_template, nullptr, nullptr,
                                nullptr, 0, is_volatile, true);
    }

    Stage1ZirInst **input_list = heap::c_allocator.allocate<Stage1ZirInst *>(asm_expr->input_list.length);
    Stage1ZirInst **output_types = heap::c_allocator.allocate<Stage1ZirInst *>(asm_expr->output_list.length);
    ZigVar **output_vars = heap::c_allocator.allocate<ZigVar *>(asm_expr->output_list.length);
    size_t return_count = 0;
    if (!is_volatile && asm_expr->output_list.length == 0) {
        add_node_error(ag->codegen, node,
                buf_sprintf("assembly expression with no output must be marked volatile"));
        return ag->codegen->invalid_inst_src;
    }
    for (size_t i = 0; i < asm_expr->output_list.length; i += 1) {
        AsmOutput *asm_output = asm_expr->output_list.at(i);
        if (asm_output->return_type) {
            return_count += 1;

            Stage1ZirInst *return_type = astgen_node(ag, asm_output->return_type, scope);
            if (return_type == ag->codegen->invalid_inst_src)
                return ag->codegen->invalid_inst_src;
            if (return_count > 1) {
                add_node_error(ag->codegen, node,
                        buf_sprintf("inline assembly allows up to one output value"));
                return ag->codegen->invalid_inst_src;
            }
            output_types[i] = return_type;
        } else {
            Buf *variable_name = asm_output->variable_name;
            // TODO there is some duplication here with astgen_identifier. I need to do a full audit of how
            // inline assembly works. https://github.com/ziglang/zig/issues/215
            ZigVar *var = find_variable(ag->codegen, scope, variable_name, nullptr);
            if (var) {
                output_vars[i] = var;
            } else {
                add_node_error(ag->codegen, node,
                        buf_sprintf("use of undeclared identifier '%s'", buf_ptr(variable_name)));
                return ag->codegen->invalid_inst_src;
            }
        }

        const char modifier = *buf_ptr(asm_output->constraint);
        if (modifier != '=') {
            add_node_error(ag->codegen, node,
                buf_sprintf("invalid modifier starting output constraint for '%s': '%c', only '=' is supported."
                    " Compiler TODO: see https://github.com/ziglang/zig/issues/215",
                    buf_ptr(asm_output->asm_symbolic_name), modifier));
            return ag->codegen->invalid_inst_src;
        }
    }
    for (size_t i = 0; i < asm_expr->input_list.length; i += 1) {
        AsmInput *asm_input = asm_expr->input_list.at(i);
        Stage1ZirInst *input_value = astgen_node(ag, asm_input->expr, scope);
        if (input_value == ag->codegen->invalid_inst_src)
            return ag->codegen->invalid_inst_src;

        input_list[i] = input_value;
    }

    return ir_build_asm_src(ag, scope, node, asm_template, input_list, output_types,
                            output_vars, return_count, is_volatile, false);
}

static Stage1ZirInst *astgen_if_optional_expr(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeIfOptional);

    Buf *var_symbol = node->data.test_expr.var_symbol;
    AstNode *expr_node = node->data.test_expr.target_node;
    AstNode *then_node = node->data.test_expr.then_node;
    AstNode *else_node = node->data.test_expr.else_node;
    bool var_is_ptr = node->data.test_expr.var_is_ptr;

    ScopeExpr *spill_scope = create_expr_scope(ag->codegen, expr_node, scope);
    spill_scope->spill_harder = true;

    Stage1ZirInst *maybe_val_ptr = astgen_node_extra(ag, expr_node, &spill_scope->base, LValPtr, nullptr);
    if (maybe_val_ptr == ag->codegen->invalid_inst_src)
        return maybe_val_ptr;

    Stage1ZirInst *maybe_val = ir_build_load_ptr(ag, scope, node, maybe_val_ptr);
    Stage1ZirInst *is_non_null = ir_build_test_non_null_src(ag, scope, node, maybe_val);

    Stage1ZirBasicBlock *then_block = ir_create_basic_block(ag, scope, "OptionalThen");
    Stage1ZirBasicBlock *else_block = ir_create_basic_block(ag, scope, "OptionalElse");
    Stage1ZirBasicBlock *endif_block = ir_create_basic_block(ag, scope, "OptionalEndIf");

    Stage1ZirInst *is_comptime;
    if (ir_should_inline(ag->exec, scope)) {
        is_comptime = ir_build_const_bool(ag, scope, node, true);
    } else {
        is_comptime = ir_build_test_comptime(ag, scope, node, is_non_null);
    }
    Stage1ZirInst *cond_br_inst = ir_build_cond_br(ag, scope, node, is_non_null,
            then_block, else_block, is_comptime);

    ResultLocPeerParent *peer_parent = ir_build_binary_result_peers(ag, cond_br_inst, else_block, endif_block,
            result_loc, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, then_block);

    Scope *subexpr_scope = create_runtime_scope(ag->codegen, node, &spill_scope->base, is_comptime);
    Scope *var_scope;
    if (var_symbol) {
        bool is_shadowable = false;
        bool is_const = true;
        ZigVar *var = ir_create_var(ag, node, subexpr_scope,
                var_symbol, is_const, is_const, is_shadowable, is_comptime);

        Stage1ZirInst *payload_ptr = ir_build_optional_unwrap_ptr(ag, subexpr_scope, node, maybe_val_ptr, false);
        Stage1ZirInst *var_value = var_is_ptr ?
            payload_ptr : ir_build_load_ptr(ag, &spill_scope->base, node, payload_ptr);
        build_decl_var_and_init(ag, subexpr_scope, node, var, var_value, buf_ptr(var_symbol), is_comptime);
        var_scope = var->child_scope;
    } else {
        var_scope = subexpr_scope;
    }
    Stage1ZirInst *then_expr_result = astgen_node_extra(ag, then_node, var_scope, lval,
            &peer_parent->peers.at(0)->base);
    if (then_expr_result == ag->codegen->invalid_inst_src)
        return then_expr_result;
    Stage1ZirBasicBlock *after_then_block = ag->current_basic_block;
    if (!instr_is_unreachable(then_expr_result))
        ir_build_br(ag, scope, node, endif_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, else_block);
    Stage1ZirInst *else_expr_result;
    if (else_node) {
        else_expr_result = astgen_node_extra(ag, else_node, subexpr_scope, lval, &peer_parent->peers.at(1)->base);
        if (else_expr_result == ag->codegen->invalid_inst_src)
            return else_expr_result;
    } else {
        else_expr_result = ir_build_const_void(ag, scope, node);
        ir_build_end_expr(ag, scope, node, else_expr_result, &peer_parent->peers.at(1)->base);
    }
    Stage1ZirBasicBlock *after_else_block = ag->current_basic_block;
    if (!instr_is_unreachable(else_expr_result))
        ir_build_br(ag, scope, node, endif_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, endif_block);
    Stage1ZirInst **incoming_values = heap::c_allocator.allocate<Stage1ZirInst *>(2);
    incoming_values[0] = then_expr_result;
    incoming_values[1] = else_expr_result;
    Stage1ZirBasicBlock **incoming_blocks = heap::c_allocator.allocate<Stage1ZirBasicBlock *>(2);
    incoming_blocks[0] = after_then_block;
    incoming_blocks[1] = after_else_block;

    Stage1ZirInst *phi = ir_build_phi(ag, scope, node, 2, incoming_blocks, incoming_values, peer_parent);
    return ir_expr_wrap(ag, scope, phi, result_loc);
}

static Stage1ZirInst *astgen_if_err_expr(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeIfErrorExpr);

    AstNode *target_node = node->data.if_err_expr.target_node;
    AstNode *then_node = node->data.if_err_expr.then_node;
    AstNode *else_node = node->data.if_err_expr.else_node;
    bool var_is_ptr = node->data.if_err_expr.var_is_ptr;
    bool var_is_const = true;
    Buf *var_symbol = node->data.if_err_expr.var_symbol;
    Buf *err_symbol = node->data.if_err_expr.err_symbol;

    Stage1ZirInst *err_val_ptr = astgen_node_extra(ag, target_node, scope, LValPtr, nullptr);
    if (err_val_ptr == ag->codegen->invalid_inst_src)
        return err_val_ptr;

    Stage1ZirInst *err_val = ir_build_load_ptr(ag, scope, node, err_val_ptr);
    Stage1ZirInst *is_err = ir_build_test_err_src(ag, scope, node, err_val_ptr, true, false);

    Stage1ZirBasicBlock *ok_block = ir_create_basic_block(ag, scope, "TryOk");
    Stage1ZirBasicBlock *else_block = ir_create_basic_block(ag, scope, "TryElse");
    Stage1ZirBasicBlock *endif_block = ir_create_basic_block(ag, scope, "TryEnd");

    bool force_comptime = ir_should_inline(ag->exec, scope);
    Stage1ZirInst *is_comptime = force_comptime ? ir_build_const_bool(ag, scope, node, true) : ir_build_test_comptime(ag, scope, node, is_err);
    Stage1ZirInst *cond_br_inst = ir_build_cond_br(ag, scope, node, is_err, else_block, ok_block, is_comptime);

    ResultLocPeerParent *peer_parent = ir_build_binary_result_peers(ag, cond_br_inst, else_block, endif_block,
            result_loc, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, ok_block);

    Scope *subexpr_scope = create_runtime_scope(ag->codegen, node, scope, is_comptime);
    Scope *var_scope;
    if (var_symbol) {
        bool is_shadowable = false;
        Stage1ZirInst *var_is_comptime = force_comptime ? ir_build_const_bool(ag, subexpr_scope, node, true) : ir_build_test_comptime(ag, subexpr_scope, node, err_val);
        ZigVar *var = ir_create_var(ag, node, subexpr_scope,
                var_symbol, var_is_const, var_is_const, is_shadowable, var_is_comptime);

        Stage1ZirInst *payload_ptr = ir_build_unwrap_err_payload_src(ag, subexpr_scope, node, err_val_ptr, false, false);
        Stage1ZirInst *var_value = var_is_ptr ?
            payload_ptr : ir_build_load_ptr(ag, subexpr_scope, node, payload_ptr);
        build_decl_var_and_init(ag, subexpr_scope, node, var, var_value, buf_ptr(var_symbol), var_is_comptime);
        var_scope = var->child_scope;
    } else {
        var_scope = subexpr_scope;
    }
    Stage1ZirInst *then_expr_result = astgen_node_extra(ag, then_node, var_scope, lval,
            &peer_parent->peers.at(0)->base);
    if (then_expr_result == ag->codegen->invalid_inst_src)
        return then_expr_result;
    Stage1ZirBasicBlock *after_then_block = ag->current_basic_block;
    if (!instr_is_unreachable(then_expr_result))
        ir_build_br(ag, scope, node, endif_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, else_block);

    Stage1ZirInst *else_expr_result;
    if (else_node) {
        Scope *err_var_scope;
        if (err_symbol) {
            bool is_shadowable = false;
            bool is_const = true;
            ZigVar *var = ir_create_var(ag, node, subexpr_scope,
                    err_symbol, is_const, is_const, is_shadowable, is_comptime);

            Stage1ZirInst *err_ptr = ir_build_unwrap_err_code_src(ag, subexpr_scope, node, err_val_ptr);
            Stage1ZirInst *err_value = ir_build_load_ptr(ag, subexpr_scope, node, err_ptr);
            build_decl_var_and_init(ag, subexpr_scope, node, var, err_value, buf_ptr(err_symbol), is_comptime);
            err_var_scope = var->child_scope;
        } else {
            err_var_scope = subexpr_scope;
        }
        else_expr_result = astgen_node_extra(ag, else_node, err_var_scope, lval, &peer_parent->peers.at(1)->base);
        if (else_expr_result == ag->codegen->invalid_inst_src)
            return else_expr_result;
    } else {
        else_expr_result = ir_build_const_void(ag, scope, node);
        ir_build_end_expr(ag, scope, node, else_expr_result, &peer_parent->peers.at(1)->base);
    }
    Stage1ZirBasicBlock *after_else_block = ag->current_basic_block;
    if (!instr_is_unreachable(else_expr_result))
        ir_build_br(ag, scope, node, endif_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, endif_block);
    Stage1ZirInst **incoming_values = heap::c_allocator.allocate<Stage1ZirInst *>(2);
    incoming_values[0] = then_expr_result;
    incoming_values[1] = else_expr_result;
    Stage1ZirBasicBlock **incoming_blocks = heap::c_allocator.allocate<Stage1ZirBasicBlock *>(2);
    incoming_blocks[0] = after_then_block;
    incoming_blocks[1] = after_else_block;

    Stage1ZirInst *phi = ir_build_phi(ag, scope, node, 2, incoming_blocks, incoming_values, peer_parent);
    return ir_expr_wrap(ag, scope, phi, result_loc);
}

static bool astgen_switch_prong_expr(Stage1AstGen *ag, Scope *scope, AstNode *switch_node, AstNode *prong_node,
        Stage1ZirBasicBlock *end_block, Stage1ZirInst *is_comptime, Stage1ZirInst *var_is_comptime,
        Stage1ZirInst *target_value_ptr, Stage1ZirInst **prong_values, size_t prong_values_len,
        ZigList<Stage1ZirBasicBlock *> *incoming_blocks, ZigList<Stage1ZirInst *> *incoming_values,
        Stage1ZirInstSwitchElseVar **out_switch_else_var, LVal lval, ResultLoc *result_loc)
{
    assert(switch_node->type == NodeTypeSwitchExpr);
    assert(prong_node->type == NodeTypeSwitchProng);

    AstNode *expr_node = prong_node->data.switch_prong.expr;
    AstNode *var_symbol_node = prong_node->data.switch_prong.var_symbol;
    Scope *child_scope;
    if (var_symbol_node) {
        assert(var_symbol_node->type == NodeTypeIdentifier);
        Buf *var_name = node_identifier_buf(var_symbol_node);
        bool var_is_ptr = prong_node->data.switch_prong.var_is_ptr;

        bool is_shadowable = false;
        bool is_const = true;
        ZigVar *var = ir_create_var(ag, var_symbol_node, scope,
                var_name, is_const, is_const, is_shadowable, var_is_comptime);
        child_scope = var->child_scope;
        Stage1ZirInst *var_value;
        if (out_switch_else_var != nullptr) {
            Stage1ZirInstSwitchElseVar *switch_else_var = ir_build_switch_else_var(ag, scope, var_symbol_node,
                    target_value_ptr);
            *out_switch_else_var = switch_else_var;
            Stage1ZirInst *payload_ptr = &switch_else_var->base;
            var_value = var_is_ptr ?
                payload_ptr : ir_build_load_ptr(ag, scope, var_symbol_node, payload_ptr);
        } else if (prong_values != nullptr) {
            Stage1ZirInst *payload_ptr = ir_build_switch_var(ag, scope, var_symbol_node, target_value_ptr,
                    prong_values, prong_values_len);
            var_value = var_is_ptr ?
                payload_ptr : ir_build_load_ptr(ag, scope, var_symbol_node, payload_ptr);
        } else {
            var_value = var_is_ptr ?
                target_value_ptr : ir_build_load_ptr(ag, scope, var_symbol_node, target_value_ptr);
        }
        build_decl_var_and_init(ag, scope, var_symbol_node, var, var_value, buf_ptr(var_name), var_is_comptime);
    } else {
        child_scope = scope;
    }

    Stage1ZirInst *expr_result = astgen_node_extra(ag, expr_node, child_scope, lval, result_loc);
    if (expr_result == ag->codegen->invalid_inst_src)
        return false;
    if (!instr_is_unreachable(expr_result))
        ir_build_br(ag, scope, switch_node, end_block, is_comptime);
    incoming_blocks->append(ag->current_basic_block);
    incoming_values->append(expr_result);
    return true;
}

static Stage1ZirInst *astgen_switch_expr(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeSwitchExpr);

    AstNode *target_node = node->data.switch_expr.expr;
    Stage1ZirInst *target_value_ptr = astgen_node_extra(ag, target_node, scope, LValPtr, nullptr);
    if (target_value_ptr == ag->codegen->invalid_inst_src)
        return target_value_ptr;
    Stage1ZirInst *target_value = ir_build_switch_target(ag, scope, node, target_value_ptr);

    Stage1ZirBasicBlock *else_block = ir_create_basic_block(ag, scope, "SwitchElse");
    Stage1ZirBasicBlock *end_block = ir_create_basic_block(ag, scope, "SwitchEnd");

    size_t prong_count = node->data.switch_expr.prongs.length;
    ZigList<Stage1ZirInstSwitchBrCase> cases = {0};

    Stage1ZirInst *is_comptime;
    Stage1ZirInst *var_is_comptime;
    if (ir_should_inline(ag->exec, scope)) {
        is_comptime = ir_build_const_bool(ag, scope, node, true);
        var_is_comptime = is_comptime;
    } else {
        is_comptime = ir_build_test_comptime(ag, scope, node, target_value);
        var_is_comptime = ir_build_test_comptime(ag, scope, node, target_value_ptr);
    }

    ZigList<Stage1ZirInst *> incoming_values = {0};
    ZigList<Stage1ZirBasicBlock *> incoming_blocks = {0};
    ZigList<Stage1ZirInstCheckSwitchProngsRange> check_ranges = {0};

    Stage1ZirInstSwitchElseVar *switch_else_var = nullptr;

    ResultLocPeerParent *peer_parent = heap::c_allocator.create<ResultLocPeerParent>();
    peer_parent->base.id = ResultLocIdPeerParent;
    peer_parent->base.allow_write_through_const = result_loc->allow_write_through_const;
    peer_parent->end_bb = end_block;
    peer_parent->is_comptime = is_comptime;
    peer_parent->parent = result_loc;

    ir_build_reset_result(ag, scope, node, &peer_parent->base);

    // First do the else and the ranges
    Scope *subexpr_scope = create_runtime_scope(ag->codegen, node, scope, is_comptime);
    Scope *comptime_scope = create_comptime_scope(ag->codegen, node, scope);
    AstNode *else_prong = nullptr;
    AstNode *underscore_prong = nullptr;
    for (size_t prong_i = 0; prong_i < prong_count; prong_i += 1) {
        AstNode *prong_node = node->data.switch_expr.prongs.at(prong_i);
        size_t prong_item_count = prong_node->data.switch_prong.items.length;
        if (prong_node->data.switch_prong.any_items_are_range) {
            ResultLocPeer *this_peer_result_loc = create_peer_result(peer_parent);

            Stage1ZirInst *ok_bit = nullptr;
            AstNode *last_item_node = nullptr;
            for (size_t item_i = 0; item_i < prong_item_count; item_i += 1) {
                AstNode *item_node = prong_node->data.switch_prong.items.at(item_i);
                last_item_node = item_node;
                if (item_node->type == NodeTypeSwitchRange) {
                    AstNode *start_node = item_node->data.switch_range.start;
                    AstNode *end_node = item_node->data.switch_range.end;

                    Stage1ZirInst *start_value = astgen_node(ag, start_node, comptime_scope);
                    if (start_value == ag->codegen->invalid_inst_src)
                        return ag->codegen->invalid_inst_src;

                    Stage1ZirInst *end_value = astgen_node(ag, end_node, comptime_scope);
                    if (end_value == ag->codegen->invalid_inst_src)
                        return ag->codegen->invalid_inst_src;

                    Stage1ZirInstCheckSwitchProngsRange *check_range = check_ranges.add_one();
                    check_range->start = start_value;
                    check_range->end = end_value;

                    Stage1ZirInst *lower_range_ok = ir_build_bin_op(ag, scope, item_node, IrBinOpCmpGreaterOrEq,
                            target_value, start_value, false);
                    Stage1ZirInst *upper_range_ok = ir_build_bin_op(ag, scope, item_node, IrBinOpCmpLessOrEq,
                            target_value, end_value, false);
                    Stage1ZirInst *both_ok = ir_build_bin_op(ag, scope, item_node, IrBinOpBoolAnd,
                            lower_range_ok, upper_range_ok, false);
                    if (ok_bit) {
                        ok_bit = ir_build_bin_op(ag, scope, item_node, IrBinOpBoolOr, both_ok, ok_bit, false);
                    } else {
                        ok_bit = both_ok;
                    }
                } else {
                    Stage1ZirInst *item_value = astgen_node(ag, item_node, comptime_scope);
                    if (item_value == ag->codegen->invalid_inst_src)
                        return ag->codegen->invalid_inst_src;

                    Stage1ZirInstCheckSwitchProngsRange *check_range = check_ranges.add_one();
                    check_range->start = item_value;
                    check_range->end = item_value;

                    Stage1ZirInst *cmp_ok = ir_build_bin_op(ag, scope, item_node, IrBinOpCmpEq,
                            item_value, target_value, false);
                    if (ok_bit) {
                        ok_bit = ir_build_bin_op(ag, scope, item_node, IrBinOpBoolOr, cmp_ok, ok_bit, false);
                    } else {
                        ok_bit = cmp_ok;
                    }
                }
            }

            Stage1ZirBasicBlock *range_block_yes = ir_create_basic_block(ag, scope, "SwitchRangeYes");
            Stage1ZirBasicBlock *range_block_no = ir_create_basic_block(ag, scope, "SwitchRangeNo");

            assert(ok_bit);
            assert(last_item_node);
            Stage1ZirInst *br_inst = ir_build_cond_br(ag, scope, last_item_node, ok_bit,
                        range_block_yes, range_block_no, is_comptime);
            if (peer_parent->base.source_instruction == nullptr) {
                peer_parent->base.source_instruction = br_inst;
            }

            if (peer_parent->peers.length > 0) {
                peer_parent->peers.last()->next_bb = range_block_yes;
            }
            peer_parent->peers.append(this_peer_result_loc);
            ir_set_cursor_at_end_and_append_block(ag, range_block_yes);
            if (!astgen_switch_prong_expr(ag, subexpr_scope, node, prong_node, end_block,
                is_comptime, var_is_comptime, target_value_ptr, nullptr, 0,
                &incoming_blocks, &incoming_values, nullptr, LValNone, &this_peer_result_loc->base))
            {
                return ag->codegen->invalid_inst_src;
            }

            ir_set_cursor_at_end_and_append_block(ag, range_block_no);
        } else {
            if (prong_item_count == 0) {
                if (else_prong) {
                    ErrorMsg *msg = add_node_error(ag->codegen, prong_node,
                            buf_sprintf("multiple else prongs in switch expression"));
                    add_error_note(ag->codegen, msg, else_prong,
                            buf_sprintf("previous else prong here"));
                    return ag->codegen->invalid_inst_src;
                }
                else_prong = prong_node;
            } else if (prong_item_count == 1 &&
                    prong_node->data.switch_prong.items.at(0)->type == NodeTypeIdentifier &&
                    buf_eql_str(node_identifier_buf(prong_node->data.switch_prong.items.at(0)), "_")) {
                if (underscore_prong) {
                    ErrorMsg *msg = add_node_error(ag->codegen, prong_node,
                            buf_sprintf("multiple '_' prongs in switch expression"));
                    add_error_note(ag->codegen, msg, underscore_prong,
                            buf_sprintf("previous '_' prong here"));
                    return ag->codegen->invalid_inst_src;
                }
                underscore_prong = prong_node;
            } else {
                continue;
            }
           if (underscore_prong && else_prong) {
                ErrorMsg *msg = add_node_error(ag->codegen, prong_node,
                        buf_sprintf("else and '_' prong in switch expression"));
                if (underscore_prong == prong_node)
                    add_error_note(ag->codegen, msg, else_prong,
                            buf_sprintf("else prong here"));
                else
                    add_error_note(ag->codegen, msg, underscore_prong,
                            buf_sprintf("'_' prong here"));
                return ag->codegen->invalid_inst_src;
            }
            ResultLocPeer *this_peer_result_loc = create_peer_result(peer_parent);

            Stage1ZirBasicBlock *prev_block = ag->current_basic_block;
            if (peer_parent->peers.length > 0) {
                peer_parent->peers.last()->next_bb = else_block;
            }
            peer_parent->peers.append(this_peer_result_loc);
            ir_set_cursor_at_end_and_append_block(ag, else_block);
            if (!astgen_switch_prong_expr(ag, subexpr_scope, node, prong_node, end_block,
                is_comptime, var_is_comptime, target_value_ptr, nullptr, 0, &incoming_blocks, &incoming_values,
                &switch_else_var, LValNone, &this_peer_result_loc->base))
            {
                return ag->codegen->invalid_inst_src;
            }
            ir_set_cursor_at_end(ag, prev_block);
        }
    }

    // next do the non-else non-ranges
    for (size_t prong_i = 0; prong_i < prong_count; prong_i += 1) {
        AstNode *prong_node = node->data.switch_expr.prongs.at(prong_i);
        size_t prong_item_count = prong_node->data.switch_prong.items.length;
        if (prong_item_count == 0)
            continue;
        if (prong_node->data.switch_prong.any_items_are_range)
            continue;
        if (underscore_prong == prong_node)
            continue;

        ResultLocPeer *this_peer_result_loc = create_peer_result(peer_parent);

        Stage1ZirBasicBlock *prong_block = ir_create_basic_block(ag, scope, "SwitchProng");
        Stage1ZirInst **items = heap::c_allocator.allocate<Stage1ZirInst *>(prong_item_count);

        for (size_t item_i = 0; item_i < prong_item_count; item_i += 1) {
            AstNode *item_node = prong_node->data.switch_prong.items.at(item_i);
            assert(item_node->type != NodeTypeSwitchRange);

            Stage1ZirInst *item_value = astgen_node(ag, item_node, comptime_scope);
            if (item_value == ag->codegen->invalid_inst_src)
                return ag->codegen->invalid_inst_src;

            Stage1ZirInstCheckSwitchProngsRange *check_range = check_ranges.add_one();
            check_range->start = item_value;
            check_range->end = item_value;

            Stage1ZirInstSwitchBrCase *this_case = cases.add_one();
            this_case->value = item_value;
            this_case->block = prong_block;

            items[item_i] = item_value;
        }

        Stage1ZirBasicBlock *prev_block = ag->current_basic_block;
        if (peer_parent->peers.length > 0) {
            peer_parent->peers.last()->next_bb = prong_block;
        }
        peer_parent->peers.append(this_peer_result_loc);
        ir_set_cursor_at_end_and_append_block(ag, prong_block);
        if (!astgen_switch_prong_expr(ag, subexpr_scope, node, prong_node, end_block,
            is_comptime, var_is_comptime, target_value_ptr, items, prong_item_count,
            &incoming_blocks, &incoming_values, nullptr, LValNone, &this_peer_result_loc->base))
        {
            return ag->codegen->invalid_inst_src;
        }

        ir_set_cursor_at_end(ag, prev_block);

    }

    Stage1ZirInst *switch_prongs_void = ir_build_check_switch_prongs(ag, scope, node, target_value,
            check_ranges.items, check_ranges.length, else_prong, underscore_prong != nullptr);

    Stage1ZirInst *br_instruction;
    if (cases.length == 0) {
        br_instruction = ir_build_br(ag, scope, node, else_block, is_comptime);
    } else {
        Stage1ZirInstSwitchBr *switch_br = ir_build_switch_br_src(ag, scope, node, target_value, else_block,
                cases.length, cases.items, is_comptime, switch_prongs_void);
        if (switch_else_var != nullptr) {
            switch_else_var->switch_br = switch_br;
        }
        br_instruction = &switch_br->base;
    }
    if (peer_parent->base.source_instruction == nullptr) {
        peer_parent->base.source_instruction = br_instruction;
    }
    for (size_t i = 0; i < peer_parent->peers.length; i += 1) {
        peer_parent->peers.at(i)->base.source_instruction = peer_parent->base.source_instruction;
    }

    if (!else_prong && !underscore_prong) {
        if (peer_parent->peers.length != 0) {
            peer_parent->peers.last()->next_bb = else_block;
        }
        ir_set_cursor_at_end_and_append_block(ag, else_block);
        ir_build_unreachable(ag, scope, node);
    } else {
        if (peer_parent->peers.length != 0) {
            peer_parent->peers.last()->next_bb = end_block;
        }
    }

    ir_set_cursor_at_end_and_append_block(ag, end_block);
    assert(incoming_blocks.length == incoming_values.length);
    Stage1ZirInst *result_instruction;
    if (incoming_blocks.length == 0) {
        result_instruction = ir_build_const_void(ag, scope, node);
    } else {
        result_instruction = ir_build_phi(ag, scope, node, incoming_blocks.length,
                incoming_blocks.items, incoming_values.items, peer_parent);
    }
    return ir_lval_wrap(ag, scope, result_instruction, lval, result_loc);
}

static Stage1ZirInst *astgen_comptime(Stage1AstGen *ag, Scope *parent_scope, AstNode *node, LVal lval) {
    assert(node->type == NodeTypeCompTime);

    Scope *child_scope = create_comptime_scope(ag->codegen, node, parent_scope);
    // purposefully pass null for result_loc and let EndExpr handle it
    return astgen_node_extra(ag, node->data.comptime_expr.expr, child_scope, lval, nullptr);
}

static Stage1ZirInst *astgen_nosuspend(Stage1AstGen *ag, Scope *parent_scope, AstNode *node, LVal lval) {
    assert(node->type == NodeTypeNoSuspend);

    Scope *child_scope = create_nosuspend_scope(ag->codegen, node, parent_scope);
    // purposefully pass null for result_loc and let EndExpr handle it
    return astgen_node_extra(ag, node->data.nosuspend_expr.expr, child_scope, lval, nullptr);
}

static Stage1ZirInst *astgen_return_from_block(Stage1AstGen *ag, Scope *break_scope, AstNode *node, ScopeBlock *block_scope) {
    Stage1ZirInst *is_comptime;
    if (ir_should_inline(ag->exec, break_scope)) {
        is_comptime = ir_build_const_bool(ag, break_scope, node, true);
    } else {
        is_comptime = block_scope->is_comptime;
    }

    Stage1ZirInst *result_value;
    if (node->data.break_expr.expr) {
        ResultLocPeer *peer_result = create_peer_result(block_scope->peer_parent);
        block_scope->peer_parent->peers.append(peer_result);

        result_value = astgen_node_extra(ag, node->data.break_expr.expr, break_scope, block_scope->lval,
                &peer_result->base);
        if (result_value == ag->codegen->invalid_inst_src)
            return ag->codegen->invalid_inst_src;
    } else {
        result_value = ir_build_const_void(ag, break_scope, node);
    }

    Stage1ZirBasicBlock *dest_block = block_scope->end_block;
    if (!astgen_defers_for_block(ag, break_scope, dest_block->scope, nullptr, nullptr))
        return ag->codegen->invalid_inst_src;

    block_scope->incoming_blocks->append(ag->current_basic_block);
    block_scope->incoming_values->append(result_value);
    return ir_build_br(ag, break_scope, node, dest_block, is_comptime);
}

static Stage1ZirInst *astgen_break(Stage1AstGen *ag, Scope *break_scope, AstNode *node) {
    assert(node->type == NodeTypeBreak);

    // Search up the scope. We'll find one of these things first:
    // * function definition scope or global scope => error, break outside loop
    // * defer expression scope => error, cannot break out of defer expression
    // * loop scope => OK
    // * (if it's a labeled break) labeled block => OK

    Scope *search_scope = break_scope;
    ScopeLoop *loop_scope;
    for (;;) {
        if (search_scope == nullptr || search_scope->id == ScopeIdFnDef) {
            if (node->data.break_expr.name != nullptr) {
                add_node_error(ag->codegen, node, buf_sprintf("label not found: '%s'", buf_ptr(node->data.break_expr.name)));
                return ag->codegen->invalid_inst_src;
            } else {
                add_node_error(ag->codegen, node, buf_sprintf("break expression outside loop"));
                return ag->codegen->invalid_inst_src;
            }
        } else if (search_scope->id == ScopeIdDeferExpr) {
            add_node_error(ag->codegen, node, buf_sprintf("cannot break out of defer expression"));
            return ag->codegen->invalid_inst_src;
        } else if (search_scope->id == ScopeIdLoop) {
            ScopeLoop *this_loop_scope = (ScopeLoop *)search_scope;
            if (node->data.break_expr.name == nullptr ||
                (this_loop_scope->name != nullptr && buf_eql_buf(node->data.break_expr.name, this_loop_scope->name)))
            {
                this_loop_scope->name_used = true;
                loop_scope = this_loop_scope;
                break;
            }
        } else if (search_scope->id == ScopeIdBlock) {
            ScopeBlock *this_block_scope = (ScopeBlock *)search_scope;
            if (node->data.break_expr.name != nullptr &&
                (this_block_scope->name != nullptr && buf_eql_buf(node->data.break_expr.name, this_block_scope->name)))
            {
                assert(this_block_scope->end_block != nullptr);
                this_block_scope->name_used = true;
                return astgen_return_from_block(ag, break_scope, node, this_block_scope);
            }
        } else if (search_scope->id == ScopeIdSuspend) {
            add_node_error(ag->codegen, node, buf_sprintf("cannot break out of suspend block"));
            return ag->codegen->invalid_inst_src;
        }
        search_scope = search_scope->parent;
    }

    Stage1ZirInst *is_comptime;
    if (ir_should_inline(ag->exec, break_scope)) {
        is_comptime = ir_build_const_bool(ag, break_scope, node, true);
    } else {
        is_comptime = loop_scope->is_comptime;
    }

    Stage1ZirInst *result_value;
    if (node->data.break_expr.expr) {
        ResultLocPeer *peer_result = create_peer_result(loop_scope->peer_parent);
        loop_scope->peer_parent->peers.append(peer_result);

        result_value = astgen_node_extra(ag, node->data.break_expr.expr, break_scope,
                loop_scope->lval, &peer_result->base);
        if (result_value == ag->codegen->invalid_inst_src)
            return ag->codegen->invalid_inst_src;
    } else {
        result_value = ir_build_const_void(ag, break_scope, node);
    }

    Stage1ZirBasicBlock *dest_block = loop_scope->break_block;
    if (!astgen_defers_for_block(ag, break_scope, dest_block->scope, nullptr, nullptr))
        return ag->codegen->invalid_inst_src;

    loop_scope->incoming_blocks->append(ag->current_basic_block);
    loop_scope->incoming_values->append(result_value);
    return ir_build_br(ag, break_scope, node, dest_block, is_comptime);
}

static Stage1ZirInst *astgen_continue(Stage1AstGen *ag, Scope *continue_scope, AstNode *node) {
    assert(node->type == NodeTypeContinue);

    // Search up the scope. We'll find one of these things first:
    // * function definition scope or global scope => error, break outside loop
    // * defer expression scope => error, cannot break out of defer expression
    // * loop scope => OK

    ZigList<ScopeRuntime *> runtime_scopes = {};

    Scope *search_scope = continue_scope;
    ScopeLoop *loop_scope;
    for (;;) {
        if (search_scope == nullptr || search_scope->id == ScopeIdFnDef) {
            if (node->data.continue_expr.name != nullptr) {
                add_node_error(ag->codegen, node, buf_sprintf("labeled loop not found: '%s'", buf_ptr(node->data.continue_expr.name)));
                return ag->codegen->invalid_inst_src;
            } else {
                add_node_error(ag->codegen, node, buf_sprintf("continue expression outside loop"));
                return ag->codegen->invalid_inst_src;
            }
        } else if (search_scope->id == ScopeIdDeferExpr) {
            add_node_error(ag->codegen, node, buf_sprintf("cannot continue out of defer expression"));
            return ag->codegen->invalid_inst_src;
        } else if (search_scope->id == ScopeIdLoop) {
            ScopeLoop *this_loop_scope = (ScopeLoop *)search_scope;
            if (node->data.continue_expr.name == nullptr ||
                (this_loop_scope->name != nullptr && buf_eql_buf(node->data.continue_expr.name, this_loop_scope->name)))
            {
                this_loop_scope->name_used = true;
                loop_scope = this_loop_scope;
                break;
            }
        } else if (search_scope->id == ScopeIdRuntime) {
            ScopeRuntime *scope_runtime = (ScopeRuntime *)search_scope;
            runtime_scopes.append(scope_runtime);
        }
        search_scope = search_scope->parent;
    }

    Stage1ZirInst *is_comptime;
    if (ir_should_inline(ag->exec, continue_scope)) {
        is_comptime = ir_build_const_bool(ag, continue_scope, node, true);
    } else {
        is_comptime = loop_scope->is_comptime;
    }

    for (size_t i = 0; i < runtime_scopes.length; i += 1) {
        ScopeRuntime *scope_runtime = runtime_scopes.at(i);
        ir_build_check_runtime_scope(ag, continue_scope, node, scope_runtime->is_comptime, is_comptime);
    }
    runtime_scopes.deinit();

    Stage1ZirBasicBlock *dest_block = loop_scope->continue_block;
    if (!astgen_defers_for_block(ag, continue_scope, dest_block->scope, nullptr, nullptr))
        return ag->codegen->invalid_inst_src;
    return ir_build_br(ag, continue_scope, node, dest_block, is_comptime);
}

static Stage1ZirInst *astgen_error_type(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeErrorType);
    return ir_build_const_type(ag, scope, node, ag->codegen->builtin_types.entry_global_error_set);
}

static Stage1ZirInst *astgen_defer(Stage1AstGen *ag, Scope *parent_scope, AstNode *node) {
    assert(node->type == NodeTypeDefer);

    ScopeDefer *defer_child_scope = create_defer_scope(ag->codegen, node, parent_scope);
    node->data.defer.child_scope = &defer_child_scope->base;

    ScopeDeferExpr *defer_expr_scope = create_defer_expr_scope(ag->codegen, node, parent_scope);
    node->data.defer.expr_scope = &defer_expr_scope->base;

    return ir_build_const_void(ag, parent_scope, node);
}

static Stage1ZirInst *astgen_slice(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval, ResultLoc *result_loc) {
    assert(node->type == NodeTypeSliceExpr);

    AstNodeSliceExpr *slice_expr = &node->data.slice_expr;
    AstNode *array_node = slice_expr->array_ref_expr;
    AstNode *start_node = slice_expr->start;
    AstNode *end_node = slice_expr->end;
    AstNode *sentinel_node = slice_expr->sentinel;

    Stage1ZirInst *ptr_value = astgen_node_extra(ag, array_node, scope, LValPtr, nullptr);
    if (ptr_value == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *start_value = astgen_node(ag, start_node, scope);
    if (start_value == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *end_value;
    if (end_node) {
        end_value = astgen_node(ag, end_node, scope);
        if (end_value == ag->codegen->invalid_inst_src)
            return ag->codegen->invalid_inst_src;
    } else {
        end_value = nullptr;
    }

    Stage1ZirInst *sentinel_value;
    if (sentinel_node) {
        sentinel_value = astgen_node(ag, sentinel_node, scope);
        if (sentinel_value == ag->codegen->invalid_inst_src)
            return ag->codegen->invalid_inst_src;
    } else {
        sentinel_value = nullptr;
    }

    Stage1ZirInst *slice = ir_build_slice_src(ag, scope, node, ptr_value, start_value, end_value,
            sentinel_value, true, result_loc);
    return ir_lval_wrap(ag, scope, slice, lval, result_loc);
}

static Stage1ZirInst *astgen_catch(Stage1AstGen *ag, Scope *parent_scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeCatchExpr);

    AstNode *op1_node = node->data.unwrap_err_expr.op1;
    AstNode *op2_node = node->data.unwrap_err_expr.op2;
    AstNode *var_node = node->data.unwrap_err_expr.symbol;

    if (op2_node->type == NodeTypeUnreachable) {
        if (var_node != nullptr) {
            assert(var_node->type == NodeTypeIdentifier);
            Buf *var_name = node_identifier_buf(var_node);
            add_node_error(ag->codegen, var_node, buf_sprintf("unused variable: '%s'", buf_ptr(var_name)));
            return ag->codegen->invalid_inst_src;
        }
        return astgen_catch_unreachable(ag, parent_scope, node, op1_node, lval, result_loc);
    }


    ScopeExpr *spill_scope = create_expr_scope(ag->codegen, op1_node, parent_scope);
    spill_scope->spill_harder = true;

    Stage1ZirInst *err_union_ptr = astgen_node_extra(ag, op1_node, &spill_scope->base, LValPtr, nullptr);
    if (err_union_ptr == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *is_err = ir_build_test_err_src(ag, parent_scope, node, err_union_ptr, true, false);

    Stage1ZirInst *is_comptime;
    if (ir_should_inline(ag->exec, parent_scope)) {
        is_comptime = ir_build_const_bool(ag, parent_scope, node, true);
    } else {
        is_comptime = ir_build_test_comptime(ag, parent_scope, node, is_err);
    }

    Stage1ZirBasicBlock *ok_block = ir_create_basic_block(ag, parent_scope, "UnwrapErrOk");
    Stage1ZirBasicBlock *err_block = ir_create_basic_block(ag, parent_scope, "UnwrapErrError");
    Stage1ZirBasicBlock *end_block = ir_create_basic_block(ag, parent_scope, "UnwrapErrEnd");
    Stage1ZirInst *cond_br_inst = ir_build_cond_br(ag, parent_scope, node, is_err, err_block, ok_block, is_comptime);

    ResultLocPeerParent *peer_parent = ir_build_binary_result_peers(ag, cond_br_inst, ok_block, end_block, result_loc,
            is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, err_block);
    Scope *subexpr_scope = create_runtime_scope(ag->codegen, node, &spill_scope->base, is_comptime);
    Scope *err_scope;
    if (var_node) {
        assert(var_node->type == NodeTypeIdentifier);
        Buf *var_name = node_identifier_buf(var_node);
        bool is_const = true;
        bool is_shadowable = false;
        ZigVar *var = ir_create_var(ag, node, subexpr_scope, var_name,
            is_const, is_const, is_shadowable, is_comptime);
        err_scope = var->child_scope;
        Stage1ZirInst *err_ptr = ir_build_unwrap_err_code_src(ag, err_scope, node, err_union_ptr);
        Stage1ZirInst *err_value = ir_build_load_ptr(ag, err_scope, var_node, err_ptr);
        build_decl_var_and_init(ag, err_scope, var_node, var, err_value, buf_ptr(var_name), is_comptime);
    } else {
        err_scope = subexpr_scope;
    }
    Stage1ZirInst *err_result = astgen_node_extra(ag, op2_node, err_scope, LValNone, &peer_parent->peers.at(0)->base);
    if (err_result == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;
    Stage1ZirBasicBlock *after_err_block = ag->current_basic_block;
    if (!instr_is_unreachable(err_result))
        ir_build_br(ag, parent_scope, node, end_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, ok_block);
    Stage1ZirInst *unwrapped_ptr = ir_build_unwrap_err_payload_src(ag, parent_scope, node, err_union_ptr, false, false);
    Stage1ZirInst *unwrapped_payload = ir_build_load_ptr(ag, parent_scope, node, unwrapped_ptr);
    ir_build_end_expr(ag, parent_scope, node, unwrapped_payload, &peer_parent->peers.at(1)->base);
    Stage1ZirBasicBlock *after_ok_block = ag->current_basic_block;
    ir_build_br(ag, parent_scope, node, end_block, is_comptime);

    ir_set_cursor_at_end_and_append_block(ag, end_block);
    Stage1ZirInst **incoming_values = heap::c_allocator.allocate<Stage1ZirInst *>(2);
    incoming_values[0] = err_result;
    incoming_values[1] = unwrapped_payload;
    Stage1ZirBasicBlock **incoming_blocks = heap::c_allocator.allocate<Stage1ZirBasicBlock *>(2);
    incoming_blocks[0] = after_err_block;
    incoming_blocks[1] = after_ok_block;
    Stage1ZirInst *phi = ir_build_phi(ag, parent_scope, node, 2, incoming_blocks, incoming_values, peer_parent);
    return ir_lval_wrap(ag, parent_scope, phi, lval, result_loc);
}

static bool render_instance_name_recursive(CodeGen *codegen, Buf *name, Scope *outer_scope, Scope *inner_scope) {
    if (inner_scope == nullptr || inner_scope == outer_scope) return false;
    bool need_comma = render_instance_name_recursive(codegen, name, outer_scope, inner_scope->parent);
    if (inner_scope->id != ScopeIdVarDecl)
        return need_comma;

    ScopeVarDecl *var_scope = (ScopeVarDecl *)inner_scope;
    if (need_comma)
        buf_append_char(name, ',');
    // TODO: const ptr reinterpret here to make the var type agree with the value?
    render_const_value(codegen, name, var_scope->var->const_value);
    return true;
}

Buf *get_anon_type_name(CodeGen *codegen, Stage1Zir *exec, const char *kind_name,
        Scope *scope, AstNode *source_node, Buf *out_bare_name)
{
    if (exec != nullptr && exec->name) {
        ZigType *import = get_scope_import(scope);
        Buf *namespace_name = buf_alloc();
        append_namespace_qualification(codegen, namespace_name, import);
        buf_append_buf(namespace_name, exec->name);
        buf_init_from_buf(out_bare_name, exec->name);
        return namespace_name;
    } else if (exec != nullptr && exec->name_fn != nullptr) {
        Buf *name = buf_alloc();
        buf_append_buf(name, &exec->name_fn->symbol_name);
        buf_appendf(name, "(");
        render_instance_name_recursive(codegen, name, &exec->name_fn->fndef_scope->base, exec->begin_scope);
        buf_appendf(name, ")");
        buf_init_from_buf(out_bare_name, name);
        return name;
    } else {
        ZigType *import = get_scope_import(scope);
        Buf *namespace_name = buf_alloc();
        append_namespace_qualification(codegen, namespace_name, import);
        RootStruct *root_struct = source_node->owner->data.structure.root_struct;
        TokenLoc tok_loc = root_struct->token_locs[source_node->main_token];
        buf_appendf(namespace_name, "%s:%u:%u", kind_name,
                tok_loc.line + 1, tok_loc.column + 1);
        buf_init_from_buf(out_bare_name, namespace_name);
        return namespace_name;
    }
}

static Stage1ZirInst *astgen_container_decl(Stage1AstGen *ag, Scope *parent_scope, AstNode *node) {
    assert(node->type == NodeTypeContainerDecl);

    ContainerKind kind = node->data.container_decl.kind;
    Buf *bare_name = buf_alloc();
    Buf *name = get_anon_type_name(ag->codegen, ag->exec, container_string(kind), parent_scope, node, bare_name);

    ContainerLayout layout = node->data.container_decl.layout;
    ZigType *container_type = get_partial_container_type(ag->codegen, parent_scope,
            kind, node, buf_ptr(name), bare_name, layout);
    ScopeDecls *child_scope = get_container_scope(container_type);

    for (size_t i = 0; i < node->data.container_decl.decls.length; i += 1) {
        AstNode *child_node = node->data.container_decl.decls.at(i);
        scan_decls(ag->codegen, child_scope, child_node);
    }

    TldContainer *tld_container = heap::c_allocator.create<TldContainer>();
    init_tld(&tld_container->base, TldIdContainer, bare_name, VisibModPub, node, parent_scope);
    tld_container->type_entry = container_type;
    tld_container->decls_scope = child_scope;
    ag->codegen->resolve_queue.append(&tld_container->base);

    // Add this to the list to mark as invalid if analyzing this exec fails.
    ag->exec->tld_list.append(&tld_container->base);

    return ir_build_const_type(ag, parent_scope, node, container_type);
}

static Stage1ZirInst *astgen_err_set_decl(Stage1AstGen *ag, Scope *parent_scope, AstNode *node) {
    assert(node->type == NodeTypeErrorSetDecl);

    uint32_t err_count = node->data.err_set_decl.decls.length;

    Buf bare_name = BUF_INIT;
    Buf *type_name = get_anon_type_name(ag->codegen, ag->exec, "error", parent_scope, node, &bare_name);
    ZigType *err_set_type = new_type_table_entry(ZigTypeIdErrorSet);
    buf_init_from_buf(&err_set_type->name, type_name);
    err_set_type->data.error_set.err_count = err_count;
    err_set_type->size_in_bits = ag->codegen->builtin_types.entry_global_error_set->size_in_bits;
    err_set_type->abi_align = ag->codegen->builtin_types.entry_global_error_set->abi_align;
    err_set_type->abi_size = ag->codegen->builtin_types.entry_global_error_set->abi_size;
    err_set_type->data.error_set.errors = heap::c_allocator.allocate<ErrorTableEntry *>(err_count);

    size_t errors_count = ag->codegen->errors_by_index.length + err_count;
    ErrorTableEntry **errors = heap::c_allocator.allocate<ErrorTableEntry *>(errors_count);

    for (uint32_t i = 0; i < err_count; i += 1) {
        AstNode *field_node = node->data.err_set_decl.decls.at(i);
        AstNode *symbol_node = ast_field_to_symbol_node(field_node);
        Buf *err_name = node_identifier_buf(symbol_node);
        ErrorTableEntry *err = heap::c_allocator.create<ErrorTableEntry>();
        err->decl_node = field_node;
        buf_init_from_buf(&err->name, err_name);

        auto existing_entry = ag->codegen->error_table.put_unique(err_name, err);
        if (existing_entry) {
            err->value = existing_entry->value->value;
        } else {
            size_t error_value_count = ag->codegen->errors_by_index.length;
            assert((uint32_t)error_value_count < (((uint32_t)1) << (uint32_t)ag->codegen->err_tag_type->data.integral.bit_count));
            err->value = error_value_count;
            ag->codegen->errors_by_index.append(err);
        }
        err_set_type->data.error_set.errors[i] = err;

        ErrorTableEntry *prev_err = errors[err->value];
        if (prev_err != nullptr) {
            ErrorMsg *msg = add_node_error(ag->codegen, ast_field_to_symbol_node(err->decl_node),
                    buf_sprintf("duplicate error: '%s'", buf_ptr(&err->name)));
            add_error_note(ag->codegen, msg, ast_field_to_symbol_node(prev_err->decl_node),
                    buf_sprintf("other error here"));
            return ag->codegen->invalid_inst_src;
        }
        errors[err->value] = err;
    }
    heap::c_allocator.deallocate(errors, errors_count);
    return ir_build_const_type(ag, parent_scope, node, err_set_type);
}

static Stage1ZirInst *astgen_fn_proto(Stage1AstGen *ag, Scope *parent_scope, AstNode *node) {
    assert(node->type == NodeTypeFnProto);

    size_t param_count = node->data.fn_proto.params.length;
    Stage1ZirInst **param_types = heap::c_allocator.allocate<Stage1ZirInst*>(param_count);

    bool is_var_args = false;
    for (size_t i = 0; i < param_count; i += 1) {
        AstNode *param_node = node->data.fn_proto.params.at(i);
        if (param_node->data.param_decl.is_var_args) {
            is_var_args = true;
            break;
        }
        if (param_node->data.param_decl.anytype_token == 0) {
            AstNode *type_node = param_node->data.param_decl.type;
            Stage1ZirInst *type_value = astgen_node(ag, type_node, parent_scope);
            if (type_value == ag->codegen->invalid_inst_src)
                return ag->codegen->invalid_inst_src;
            param_types[i] = type_value;
        } else {
            param_types[i] = nullptr;
        }
    }

    Stage1ZirInst *align_value = nullptr;
    if (node->data.fn_proto.align_expr != nullptr) {
        align_value = astgen_node(ag, node->data.fn_proto.align_expr, parent_scope);
        if (align_value == ag->codegen->invalid_inst_src)
            return ag->codegen->invalid_inst_src;
    }

    Stage1ZirInst *callconv_value = nullptr;
    if (node->data.fn_proto.callconv_expr != nullptr) {
        callconv_value = astgen_node(ag, node->data.fn_proto.callconv_expr, parent_scope);
        if (callconv_value == ag->codegen->invalid_inst_src)
            return ag->codegen->invalid_inst_src;
    }

    Stage1ZirInst *return_type;
    if (node->data.fn_proto.return_type == nullptr) {
        return_type = ir_build_const_type(ag, parent_scope, node, ag->codegen->builtin_types.entry_void);
    } else {
        return_type = astgen_node(ag, node->data.fn_proto.return_type, parent_scope);
        if (return_type == ag->codegen->invalid_inst_src)
            return ag->codegen->invalid_inst_src;
    }

    return ir_build_fn_proto(ag, parent_scope, node, param_types, align_value, callconv_value, return_type, is_var_args);
}

static Stage1ZirInst *astgen_resume(Stage1AstGen *ag, Scope *scope, AstNode *node) {
    assert(node->type == NodeTypeResume);

    Stage1ZirInst *target_inst = astgen_node_extra(ag, node->data.resume_expr.expr, scope, LValPtr, nullptr);
    if (target_inst == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    return ir_build_resume_src(ag, scope, node, target_inst);
}

static Stage1ZirInst *astgen_await_expr(Stage1AstGen *ag, Scope *scope, AstNode *node, LVal lval,
        ResultLoc *result_loc)
{
    assert(node->type == NodeTypeAwaitExpr);

    bool is_nosuspend = get_scope_nosuspend(scope) != nullptr;

    AstNode *expr_node = node->data.await_expr.expr;
    if (expr_node->type == NodeTypeFnCallExpr && expr_node->data.fn_call_expr.modifier == CallModifierBuiltin) {
        AstNode *fn_ref_expr = expr_node->data.fn_call_expr.fn_ref_expr;
        Buf *name = node_identifier_buf(fn_ref_expr);
        auto entry = ag->codegen->builtin_fn_table.maybe_get(name);
        if (entry != nullptr) {
            BuiltinFnEntry *builtin_fn = entry->value;
            if (builtin_fn->id == BuiltinFnIdAsyncCall) {
                return astgen_async_call(ag, scope, node, expr_node, lval, result_loc);
            }
        }
    }

    if (!ag->fn) {
        add_node_error(ag->codegen, node, buf_sprintf("await outside function definition"));
        return ag->codegen->invalid_inst_src;
    }
    ScopeSuspend *existing_suspend_scope = get_scope_suspend(scope);
    if (existing_suspend_scope) {
        if (!existing_suspend_scope->reported_err) {
            ErrorMsg *msg = add_node_error(ag->codegen, node, buf_sprintf("cannot await inside suspend block"));
            add_error_note(ag->codegen, msg, existing_suspend_scope->base.source_node, buf_sprintf("suspend block here"));
            existing_suspend_scope->reported_err = true;
        }
        return ag->codegen->invalid_inst_src;
    }

    Stage1ZirInst *target_inst = astgen_node_extra(ag, expr_node, scope, LValPtr, nullptr);
    if (target_inst == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;

    Stage1ZirInst *await_inst = ir_build_await_src(ag, scope, node, target_inst, result_loc, is_nosuspend);
    return ir_lval_wrap(ag, scope, await_inst, lval, result_loc);
}

static Stage1ZirInst *astgen_suspend(Stage1AstGen *ag, Scope *parent_scope, AstNode *node) {
    assert(node->type == NodeTypeSuspend);

    if (!ag->fn) {
        add_node_error(ag->codegen, node, buf_sprintf("suspend outside function definition"));
        return ag->codegen->invalid_inst_src;
    }
    if (get_scope_nosuspend(parent_scope) != nullptr) {
        add_node_error(ag->codegen, node, buf_sprintf("suspend in nosuspend scope"));
        return ag->codegen->invalid_inst_src;
    }

    ScopeSuspend *existing_suspend_scope = get_scope_suspend(parent_scope);
    if (existing_suspend_scope) {
        if (!existing_suspend_scope->reported_err) {
            ErrorMsg *msg = add_node_error(ag->codegen, node, buf_sprintf("cannot suspend inside suspend block"));
            add_error_note(ag->codegen, msg, existing_suspend_scope->base.source_node, buf_sprintf("other suspend block here"));
            existing_suspend_scope->reported_err = true;
        }
        return ag->codegen->invalid_inst_src;
    }

    Stage1ZirInstSuspendBegin *begin = ir_build_suspend_begin_src(ag, parent_scope, node);
    ScopeSuspend *suspend_scope = create_suspend_scope(ag->codegen, node, parent_scope);
    Scope *child_scope = &suspend_scope->base;
    Stage1ZirInst *susp_res = astgen_node(ag, node->data.suspend.block, child_scope);
    if (susp_res == ag->codegen->invalid_inst_src)
        return ag->codegen->invalid_inst_src;
    ir_build_check_statement_is_void(ag, child_scope, node->data.suspend.block, susp_res);

    return ir_build_suspend_finish_src(ag, parent_scope, node, begin);
}

static Stage1ZirInst *astgen_node_raw(Stage1AstGen *ag, AstNode *node, Scope *scope,
        LVal lval, ResultLoc *result_loc)
{
    assert(scope);
    switch (node->type) {
        case NodeTypeStructValueField:
        case NodeTypeParamDecl:
        case NodeTypeUsingNamespace:
        case NodeTypeSwitchProng:
        case NodeTypeSwitchRange:
        case NodeTypeStructField:
        case NodeTypeErrorSetField:
        case NodeTypeFnDef:
        case NodeTypeTestDecl:
            zig_unreachable();
        case NodeTypeBlock:
            return astgen_block(ag, scope, node, lval, result_loc);
        case NodeTypeGroupedExpr:
            return astgen_node_raw(ag, node->data.grouped_expr, scope, lval, result_loc);
        case NodeTypeBinOpExpr:
            return astgen_bin_op(ag, scope, node, lval, result_loc);
        case NodeTypeIntLiteral:
            return ir_lval_wrap(ag, scope, astgen_int_lit(ag, scope, node), lval, result_loc);
        case NodeTypeFloatLiteral:
            return ir_lval_wrap(ag, scope, astgen_float_lit(ag, scope, node), lval, result_loc);
        case NodeTypeCharLiteral:
            return ir_lval_wrap(ag, scope, astgen_char_lit(ag, scope, node), lval, result_loc);
        case NodeTypeIdentifier:
            return astgen_identifier(ag, scope, node, lval, result_loc);
        case NodeTypeFnCallExpr:
            return astgen_fn_call(ag, scope, node, lval, result_loc);
        case NodeTypeIfBoolExpr:
            return astgen_if_bool_expr(ag, scope, node, lval, result_loc);
        case NodeTypePrefixOpExpr:
            return astgen_prefix_op_expr(ag, scope, node, lval, result_loc);
        case NodeTypeContainerInitExpr:
            return astgen_container_init_expr(ag, scope, node, lval, result_loc);
        case NodeTypeVariableDeclaration:
            return astgen_var_decl(ag, scope, node);
        case NodeTypeWhileExpr:
            return astgen_while_expr(ag, scope, node, lval, result_loc);
        case NodeTypeForExpr:
            return astgen_for_expr(ag, scope, node, lval, result_loc);
        case NodeTypeArrayAccessExpr:
            return astgen_array_access(ag, scope, node, lval, result_loc);
        case NodeTypeReturnExpr:
            return astgen_return(ag, scope, node, lval, result_loc);
        case NodeTypeFieldAccessExpr:
            {
                Stage1ZirInst *ptr_instruction = astgen_field_access(ag, scope, node);
                if (ptr_instruction == ag->codegen->invalid_inst_src)
                    return ptr_instruction;
                if (lval == LValPtr || lval == LValAssign)
                    return ptr_instruction;

                Stage1ZirInst *load_ptr = ir_build_load_ptr(ag, scope, node, ptr_instruction);
                return ir_expr_wrap(ag, scope, load_ptr, result_loc);
            }
        case NodeTypePtrDeref: {
            AstNode *expr_node = node->data.ptr_deref_expr.target;

            LVal child_lval = lval;
            if (child_lval == LValAssign)
                child_lval = LValPtr;

            Stage1ZirInst *value = astgen_node_extra(ag, expr_node, scope, child_lval, nullptr);
            if (value == ag->codegen->invalid_inst_src)
                return value;

            // We essentially just converted any lvalue from &(x.*) to (&x).*;
            // this inhibits checking that x is a pointer later, so we directly
            // record whether the pointer check is needed
            Stage1ZirInst *un_op = ir_build_un_op_lval(ag, scope, node, IrUnOpDereference, value, lval, result_loc);
            return ir_expr_wrap(ag, scope, un_op, result_loc);
        }
        case NodeTypeUnwrapOptional: {
            AstNode *expr_node = node->data.unwrap_optional.expr;

            Stage1ZirInst *maybe_ptr = astgen_node_extra(ag, expr_node, scope, LValPtr, nullptr);
            if (maybe_ptr == ag->codegen->invalid_inst_src)
                return ag->codegen->invalid_inst_src;

            Stage1ZirInst *unwrapped_ptr = ir_build_optional_unwrap_ptr(ag, scope, node, maybe_ptr, true );
            if (lval == LValPtr || lval == LValAssign)
                return unwrapped_ptr;

            Stage1ZirInst *load_ptr = ir_build_load_ptr(ag, scope, node, unwrapped_ptr);
            return ir_expr_wrap(ag, scope, load_ptr, result_loc);
        }
        case NodeTypeBoolLiteral:
            return ir_lval_wrap(ag, scope, astgen_bool_literal(ag, scope, node), lval, result_loc);
        case NodeTypeArrayType:
            return ir_lval_wrap(ag, scope, astgen_array_type(ag, scope, node), lval, result_loc);
        case NodeTypePointerType:
            return ir_lval_wrap(ag, scope, astgen_pointer_type(ag, scope, node), lval, result_loc);
        case NodeTypeAnyFrameType:
            return ir_lval_wrap(ag, scope, astgen_anyframe_type(ag, scope, node), lval, result_loc);
        case NodeTypeStringLiteral:
            return ir_lval_wrap(ag, scope, astgen_string_literal(ag, scope, node), lval, result_loc);
        case NodeTypeUndefinedLiteral:
            return ir_lval_wrap(ag, scope, astgen_undefined_literal(ag, scope, node), lval, result_loc);
        case NodeTypeAsmExpr:
            return ir_lval_wrap(ag, scope, astgen_asm_expr(ag, scope, node), lval, result_loc);
        case NodeTypeNullLiteral:
            return ir_lval_wrap(ag, scope, astgen_null_literal(ag, scope, node), lval, result_loc);
        case NodeTypeIfErrorExpr:
            return astgen_if_err_expr(ag, scope, node, lval, result_loc);
        case NodeTypeIfOptional:
            return astgen_if_optional_expr(ag, scope, node, lval, result_loc);
        case NodeTypeSwitchExpr:
            return astgen_switch_expr(ag, scope, node, lval, result_loc);
        case NodeTypeCompTime:
            return ir_expr_wrap(ag, scope, astgen_comptime(ag, scope, node, lval), result_loc);
        case NodeTypeNoSuspend:
            return ir_expr_wrap(ag, scope, astgen_nosuspend(ag, scope, node, lval), result_loc);
        case NodeTypeErrorType:
            return ir_lval_wrap(ag, scope, astgen_error_type(ag, scope, node), lval, result_loc);
        case NodeTypeBreak:
            return ir_lval_wrap(ag, scope, astgen_break(ag, scope, node), lval, result_loc);
        case NodeTypeContinue:
            return ir_lval_wrap(ag, scope, astgen_continue(ag, scope, node), lval, result_loc);
        case NodeTypeUnreachable:
            return ir_build_unreachable(ag, scope, node);
        case NodeTypeDefer:
            return ir_lval_wrap(ag, scope, astgen_defer(ag, scope, node), lval, result_loc);
        case NodeTypeSliceExpr:
            return astgen_slice(ag, scope, node, lval, result_loc);
        case NodeTypeCatchExpr:
            return astgen_catch(ag, scope, node, lval, result_loc);
        case NodeTypeContainerDecl:
            return ir_lval_wrap(ag, scope, astgen_container_decl(ag, scope, node), lval, result_loc);
        case NodeTypeFnProto:
            return ir_lval_wrap(ag, scope, astgen_fn_proto(ag, scope, node), lval, result_loc);
        case NodeTypeErrorSetDecl:
            return ir_lval_wrap(ag, scope, astgen_err_set_decl(ag, scope, node), lval, result_loc);
        case NodeTypeResume:
            return ir_lval_wrap(ag, scope, astgen_resume(ag, scope, node), lval, result_loc);
        case NodeTypeAwaitExpr:
            return astgen_await_expr(ag, scope, node, lval, result_loc);
        case NodeTypeSuspend:
            return ir_lval_wrap(ag, scope, astgen_suspend(ag, scope, node), lval, result_loc);
        case NodeTypeEnumLiteral:
            return ir_lval_wrap(ag, scope, astgen_enum_literal(ag, scope, node), lval, result_loc);
        case NodeTypeInferredArrayType:
            add_node_error(ag->codegen, node,
                buf_sprintf("inferred array size invalid here"));
            return ag->codegen->invalid_inst_src;
        case NodeTypeAnyTypeField:
            return ir_lval_wrap(ag, scope,
                    ir_build_const_type(ag, scope, node, ag->codegen->builtin_types.entry_anytype), lval, result_loc);
    }
    zig_unreachable();
}

ResultLoc *no_result_loc(void) {
    ResultLocNone *result_loc_none = heap::c_allocator.create<ResultLocNone>();
    result_loc_none->base.id = ResultLocIdNone;
    return &result_loc_none->base;
}

static Stage1ZirInst *astgen_node_extra(Stage1AstGen *ag, AstNode *node, Scope *scope, LVal lval,
        ResultLoc *result_loc)
{
    if (lval == LValAssign) {
        switch (node->type) {
            case NodeTypeStructValueField:
            case NodeTypeParamDecl:
            case NodeTypeUsingNamespace:
            case NodeTypeSwitchProng:
            case NodeTypeSwitchRange:
            case NodeTypeStructField:
            case NodeTypeErrorSetField:
            case NodeTypeFnDef:
            case NodeTypeTestDecl:
                zig_unreachable();

            // cannot be assigned to
            case NodeTypeBlock:
            case NodeTypeGroupedExpr:
            case NodeTypeBinOpExpr:
            case NodeTypeIntLiteral:
            case NodeTypeFloatLiteral:
            case NodeTypeCharLiteral:
            case NodeTypeIfBoolExpr:
            case NodeTypeContainerInitExpr:
            case NodeTypeVariableDeclaration:
            case NodeTypeWhileExpr:
            case NodeTypeForExpr:
            case NodeTypeReturnExpr:
            case NodeTypeBoolLiteral:
            case NodeTypeArrayType:
            case NodeTypePointerType:
            case NodeTypeAnyFrameType:
            case NodeTypeStringLiteral:
            case NodeTypeUndefinedLiteral:
            case NodeTypeAsmExpr:
            case NodeTypeNullLiteral:
            case NodeTypeIfErrorExpr:
            case NodeTypeIfOptional:
            case NodeTypeSwitchExpr:
            case NodeTypeCompTime:
            case NodeTypeNoSuspend:
            case NodeTypeErrorType:
            case NodeTypeBreak:
            case NodeTypeContinue:
            case NodeTypeUnreachable:
            case NodeTypeDefer:
            case NodeTypeSliceExpr:
            case NodeTypeCatchExpr:
            case NodeTypeContainerDecl:
            case NodeTypeFnProto:
            case NodeTypeErrorSetDecl:
            case NodeTypeResume:
            case NodeTypeAwaitExpr:
            case NodeTypeSuspend:
            case NodeTypeEnumLiteral:
            case NodeTypeInferredArrayType:
            case NodeTypeAnyTypeField:
            case NodeTypePrefixOpExpr:
                add_node_error(ag->codegen, node,
                    buf_sprintf("invalid left-hand side to assignment"));
                return ag->codegen->invalid_inst_src;

            // @field can be assigned to
            case NodeTypeFnCallExpr:
                if (node->data.fn_call_expr.modifier == CallModifierBuiltin) {
                    AstNode *fn_ref_expr = node->data.fn_call_expr.fn_ref_expr;
                    Buf *name = node_identifier_buf(fn_ref_expr);
                    auto entry = ag->codegen->builtin_fn_table.maybe_get(name);

                    if (!entry) {
                        add_node_error(ag->codegen, node,
                                buf_sprintf("invalid builtin function: '%s'", buf_ptr(name)));
                        return ag->codegen->invalid_inst_src;
                    }

                    if (entry->value->id == BuiltinFnIdField) {
                        break;
                    }
                }
                add_node_error(ag->codegen, node,
                    buf_sprintf("invalid left-hand side to assignment"));
                return ag->codegen->invalid_inst_src;


            // can be assigned to
            case NodeTypeUnwrapOptional:
            case NodeTypePtrDeref:
            case NodeTypeFieldAccessExpr:
            case NodeTypeArrayAccessExpr:
            case NodeTypeIdentifier:
                break;
        }
    }
    if (result_loc == nullptr) {
        // Create a result location indicating there is none - but if one gets created
        // it will be properly distributed.
        result_loc = no_result_loc();
        ir_build_reset_result(ag, scope, node, result_loc);
    }
    Scope *child_scope;
    if (ag->exec->is_inline ||
        (ag->fn != nullptr && ag->fn->child_scope == scope))
    {
        child_scope = scope;
    } else {
        child_scope = &create_expr_scope(ag->codegen, node, scope)->base;
    }
    Stage1ZirInst *result = astgen_node_raw(ag, node, child_scope, lval, result_loc);
    if (result == ag->codegen->invalid_inst_src) {
        if (ag->exec->first_err_trace_msg == nullptr) {
            ag->exec->first_err_trace_msg = ag->codegen->trace_err;
        }
    }
    return result;
}

static Stage1ZirInst *astgen_node(Stage1AstGen *ag, AstNode *node, Scope *scope) {
    return astgen_node_extra(ag, node, scope, LValNone, nullptr);
}

bool stage1_astgen(CodeGen *codegen, AstNode *node, Scope *scope, Stage1Zir *stage1_zir,
        ZigFn *fn, bool in_c_import_scope)
{
    assert(node->owner);

    Stage1AstGen ir_builder = {0};
    Stage1AstGen *ag = &ir_builder;

    ag->codegen = codegen;
    ag->fn = fn;
    ag->in_c_import_scope = in_c_import_scope;
    ag->exec = stage1_zir;
    ag->main_block_node = node;

    Stage1ZirBasicBlock *entry_block = ir_create_basic_block(ag, scope, "Entry");
    ir_set_cursor_at_end_and_append_block(ag, entry_block);
    // Entry block gets a reference because we enter it to begin.
    ir_ref_bb(ag->current_basic_block);

    Stage1ZirInst *result = astgen_node_extra(ag, node, scope, LValNone, nullptr);

    if (result == ag->codegen->invalid_inst_src)
        return false;

    if (ag->exec->first_err_trace_msg != nullptr) {
        codegen->trace_err = ag->exec->first_err_trace_msg;
        return false;
    }

    if (!instr_is_unreachable(result)) {
        ir_build_add_implicit_return_type(ag, scope, result->source_node, result, nullptr);
        // no need for save_err_ret_addr because this cannot return error
        ResultLocReturn *result_loc_ret = heap::c_allocator.create<ResultLocReturn>();
        result_loc_ret->base.id = ResultLocIdReturn;
        ir_build_reset_result(ag, scope, node, &result_loc_ret->base);
        ir_build_end_expr(ag, scope, node, result, &result_loc_ret->base);
        ir_build_return_src(ag, scope, result->source_node, result);
    }

    return true;
}

bool stage1_astgen_fn(CodeGen *codegen, ZigFn *fn) {
    assert(fn != nullptr);
    assert(fn->child_scope != nullptr);
    return stage1_astgen(codegen, fn->body_node, fn->child_scope, fn->stage1_zir, fn, false);
}

void invalidate_exec(Stage1Zir *exec, ErrorMsg *msg) {
    if (exec->first_err_trace_msg != nullptr)
        return;

    exec->first_err_trace_msg = msg;

    for (size_t i = 0; i < exec->tld_list.length; i += 1) {
        exec->tld_list.items[i]->resolution = TldResolutionInvalid;
    }
}

AstNode *ast_field_to_symbol_node(AstNode *err_set_field_node) {
    if (err_set_field_node->type == NodeTypeIdentifier) {
        return err_set_field_node;
    } else if (err_set_field_node->type == NodeTypeErrorSetField) {
        assert(err_set_field_node->data.err_set_field.field_name->type == NodeTypeIdentifier);
        return err_set_field_node->data.err_set_field.field_name;
    } else {
        return err_set_field_node;
    }
}

void ir_add_call_stack_errors_gen(CodeGen *codegen, Stage1Air *exec, ErrorMsg *err_msg, int limit) {
    if (!exec || !exec->source_node || limit < 0) return;
    add_error_note(codegen, err_msg, exec->source_node, buf_sprintf("called from here"));

    ir_add_call_stack_errors_gen(codegen, exec->parent_exec, err_msg, limit - 1);
}

void Stage1ZirInst::src() {
    Stage1ZirInst *inst = this;
    if (inst->source_node != nullptr) {
        inst->source_node->src();
    } else {
        fprintf(stderr, "(null source node)\n");
    }
}

