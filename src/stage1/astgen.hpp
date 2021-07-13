/*
 * Copyright (c) 2021 Andrew Kelley
 *
 * This file is part of zig, which is MIT licensed.
 * See http://opensource.org/licenses/MIT
 */

#ifndef ZIG_ASTGEN_HPP
#define ZIG_ASTGEN_HPP

#include "all_types.hpp"

bool stage1_astgen(CodeGen *g, AstNode *node, Scope *scope, Stage1Zir *stage1_zir,
        ZigFn *fn, bool in_c_import_scope);
bool stage1_astgen_fn(CodeGen *g, ZigFn *fn_entry);

bool ir_inst_src_has_side_effects(Stage1ZirInst *inst);

ZigVar *create_local_var(CodeGen *codegen, AstNode *node, Scope *parent_scope,
        Buf *name, bool src_is_const, bool gen_is_const, bool is_shadowable, Stage1ZirInst *is_comptime,
        bool skip_name_check);

ResultLoc *no_result_loc(void);

void invalidate_exec(Stage1Zir *exec, ErrorMsg *msg);

AstNode *ast_field_to_symbol_node(AstNode *err_set_field_node);
void ir_add_call_stack_errors_gen(CodeGen *codegen, Stage1Air *exec, ErrorMsg *err_msg,
        int limit);

void destroy_instruction_src(Stage1ZirInst *inst);

bool ir_should_inline(Stage1Zir *exec, Scope *scope);
Buf *get_anon_type_name(CodeGen *codegen, Stage1Zir *exec, const char *kind_name,
        Scope *scope, AstNode *source_node, Buf *out_bare_name, ResultLoc *result_loc);

#endif
