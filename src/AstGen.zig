//! Ingests an AST and produces ZIR code.
const AstGen = @This();

const std = @import("std");
const ast = std.zig.ast;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const Zir = @import("Zir.zig");
const trace = @import("tracy.zig").trace;
const BuiltinFn = @import("BuiltinFn.zig");

gpa: *Allocator,
tree: *const ast.Tree,
instructions: std.MultiArrayList(Zir.Inst) = .{},
extra: ArrayListUnmanaged(u32) = .{},
string_bytes: ArrayListUnmanaged(u8) = .{},
/// Tracks the current byte offset within the source file.
/// Used to populate line deltas in the ZIR. AstGen maintains
/// this "cursor" throughout the entire AST lowering process in order
/// to avoid starting over the line/column scan for every declaration, which
/// would be O(N^2).
source_offset: u32 = 0,
/// Tracks the current line of `source_offset`.
source_line: u32 = 0,
/// Tracks the current column of `source_offset`.
source_column: u32 = 0,
/// Used for temporary allocations; freed after AstGen is complete.
/// The resulting ZIR code has no references to anything in this arena.
arena: *Allocator,
string_table: std.StringHashMapUnmanaged(u32) = .{},
compile_errors: ArrayListUnmanaged(Zir.Inst.CompileErrors.Item) = .{},
/// The topmost block of the current function.
fn_block: ?*GenZir = null,
/// Maps string table indexes to the first `@import` ZIR instruction
/// that uses this string as the operand.
imports: std.AutoArrayHashMapUnmanaged(u32, Zir.Inst.Index) = .{},

const InnerError = error{ OutOfMemory, AnalysisFail };

fn addExtra(astgen: *AstGen, extra: anytype) Allocator.Error!u32 {
    const fields = std.meta.fields(@TypeOf(extra));
    try astgen.extra.ensureCapacity(astgen.gpa, astgen.extra.items.len + fields.len);
    return addExtraAssumeCapacity(astgen, extra);
}

fn addExtraAssumeCapacity(astgen: *AstGen, extra: anytype) u32 {
    const fields = std.meta.fields(@TypeOf(extra));
    const result = @intCast(u32, astgen.extra.items.len);
    inline for (fields) |field| {
        astgen.extra.appendAssumeCapacity(switch (field.field_type) {
            u32 => @field(extra, field.name),
            Zir.Inst.Ref => @enumToInt(@field(extra, field.name)),
            i32 => @bitCast(u32, @field(extra, field.name)),
            else => @compileError("bad field type"),
        });
    }
    return result;
}

fn appendRefs(astgen: *AstGen, refs: []const Zir.Inst.Ref) !void {
    const coerced = @bitCast([]const u32, refs);
    return astgen.extra.appendSlice(astgen.gpa, coerced);
}

fn appendRefsAssumeCapacity(astgen: *AstGen, refs: []const Zir.Inst.Ref) void {
    const coerced = @bitCast([]const u32, refs);
    astgen.extra.appendSliceAssumeCapacity(coerced);
}

pub fn generate(gpa: *Allocator, tree: ast.Tree) Allocator.Error!Zir {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var astgen: AstGen = .{
        .gpa = gpa,
        .arena = &arena.allocator,
        .tree = &tree,
    };
    defer astgen.deinit(gpa);

    // String table indexes 0 and 1 are reserved for special meaning.
    try astgen.string_bytes.appendSlice(gpa, &[_]u8{ 0, 0 });

    // We expect at least as many ZIR instructions and extra data items
    // as AST nodes.
    try astgen.instructions.ensureTotalCapacity(gpa, tree.nodes.len);

    // First few indexes of extra are reserved and set at the end.
    const reserved_count = @typeInfo(Zir.ExtraIndex).Enum.fields.len;
    try astgen.extra.ensureTotalCapacity(gpa, tree.nodes.len + reserved_count);
    astgen.extra.items.len += reserved_count;

    var top_scope: Scope.Top = .{};

    var gen_scope: GenZir = .{
        .force_comptime = true,
        .in_defer = false,
        .parent = &top_scope.base,
        .anon_name_strategy = .parent,
        .decl_node_index = 0,
        .decl_line = 0,
        .astgen = &astgen,
    };
    defer gen_scope.instructions.deinit(gpa);

    const container_decl: ast.full.ContainerDecl = .{
        .layout_token = null,
        .ast = .{
            .main_token = undefined,
            .enum_token = null,
            .members = tree.rootDecls(),
            .arg = 0,
        },
    };
    if (AstGen.structDeclInner(
        &gen_scope,
        &gen_scope.base,
        0,
        container_decl,
        .Auto,
    )) |struct_decl_ref| {
        astgen.extra.items[@enumToInt(Zir.ExtraIndex.main_struct)] = @enumToInt(struct_decl_ref);
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AnalysisFail => {}, // Handled via compile_errors below.
    }

    const err_index = @enumToInt(Zir.ExtraIndex.compile_errors);
    if (astgen.compile_errors.items.len == 0) {
        astgen.extra.items[err_index] = 0;
    } else {
        try astgen.extra.ensureCapacity(gpa, astgen.extra.items.len +
            1 + astgen.compile_errors.items.len *
            @typeInfo(Zir.Inst.CompileErrors.Item).Struct.fields.len);

        astgen.extra.items[err_index] = astgen.addExtraAssumeCapacity(Zir.Inst.CompileErrors{
            .items_len = @intCast(u32, astgen.compile_errors.items.len),
        });

        for (astgen.compile_errors.items) |item| {
            _ = astgen.addExtraAssumeCapacity(item);
        }
    }

    const imports_index = @enumToInt(Zir.ExtraIndex.imports);
    if (astgen.imports.count() == 0) {
        astgen.extra.items[imports_index] = 0;
    } else {
        try astgen.extra.ensureCapacity(gpa, astgen.extra.items.len +
            @typeInfo(Zir.Inst.Imports).Struct.fields.len + astgen.imports.count());

        astgen.extra.items[imports_index] = astgen.addExtraAssumeCapacity(Zir.Inst.Imports{
            .imports_len = @intCast(u32, astgen.imports.count()),
        });
        astgen.extra.appendSliceAssumeCapacity(astgen.imports.values());
    }

    return Zir{
        .instructions = astgen.instructions.toOwnedSlice(),
        .string_bytes = astgen.string_bytes.toOwnedSlice(gpa),
        .extra = astgen.extra.toOwnedSlice(gpa),
    };
}

pub fn deinit(astgen: *AstGen, gpa: *Allocator) void {
    astgen.instructions.deinit(gpa);
    astgen.extra.deinit(gpa);
    astgen.string_table.deinit(gpa);
    astgen.string_bytes.deinit(gpa);
    astgen.compile_errors.deinit(gpa);
    astgen.imports.deinit(gpa);
}

pub const ResultLoc = union(enum) {
    /// The expression is the right-hand side of assignment to `_`. Only the side-effects of the
    /// expression should be generated. The result instruction from the expression must
    /// be ignored.
    discard,
    /// The expression has an inferred type, and it will be evaluated as an rvalue.
    none,
    /// The expression must generate a pointer rather than a value. For example, the left hand side
    /// of an assignment uses this kind of result location.
    ref,
    /// The callee will accept a ref, but it is not necessary, and the `ResultLoc`
    /// may be treated as `none` instead.
    none_or_ref,
    /// The expression will be coerced into this type, but it will be evaluated as an rvalue.
    ty: Zir.Inst.Ref,
    /// The expression must store its result into this typed pointer. The result instruction
    /// from the expression must be ignored.
    ptr: Zir.Inst.Ref,
    /// The expression must store its result into this allocation, which has an inferred type.
    /// The result instruction from the expression must be ignored.
    /// Always an instruction with tag `alloc_inferred`.
    inferred_ptr: Zir.Inst.Ref,
    /// There is a pointer for the expression to store its result into, however, its type
    /// is inferred based on peer type resolution for a `Zir.Inst.Block`.
    /// The result instruction from the expression must be ignored.
    block_ptr: *GenZir,

    pub const Strategy = struct {
        elide_store_to_block_ptr_instructions: bool,
        tag: Tag,

        pub const Tag = enum {
            /// Both branches will use break_void; result location is used to communicate the
            /// result instruction.
            break_void,
            /// Use break statements to pass the block result value, and call rvalue() at
            /// the end depending on rl. Also elide the store_to_block_ptr instructions
            /// depending on rl.
            break_operand,
        };
    };

    fn strategy(rl: ResultLoc, block_scope: *GenZir) Strategy {
        switch (rl) {
            // In this branch there will not be any store_to_block_ptr instructions.
            .discard, .none, .none_or_ref, .ty, .ref => return .{
                .tag = .break_operand,
                .elide_store_to_block_ptr_instructions = false,
            },
            // The pointer got passed through to the sub-expressions, so we will use
            // break_void here.
            // In this branch there will not be any store_to_block_ptr instructions.
            .ptr => return .{
                .tag = .break_void,
                .elide_store_to_block_ptr_instructions = false,
            },
            .inferred_ptr, .block_ptr => {
                if (block_scope.rvalue_rl_count == block_scope.break_count) {
                    // Neither prong of the if consumed the result location, so we can
                    // use break instructions to create an rvalue.
                    return .{
                        .tag = .break_operand,
                        .elide_store_to_block_ptr_instructions = true,
                    };
                } else {
                    // Allow the store_to_block_ptr instructions to remain so that
                    // semantic analysis can turn them into bitcasts.
                    return .{
                        .tag = .break_void,
                        .elide_store_to_block_ptr_instructions = false,
                    };
                }
            },
        }
    }
};

pub const align_rl: ResultLoc = .{ .ty = .u16_type };
pub const bool_rl: ResultLoc = .{ .ty = .bool_type };

fn typeExpr(gz: *GenZir, scope: *Scope, type_node: ast.Node.Index) InnerError!Zir.Inst.Ref {
    const prev_force_comptime = gz.force_comptime;
    gz.force_comptime = true;
    defer gz.force_comptime = prev_force_comptime;

    return expr(gz, scope, .{ .ty = .type_type }, type_node);
}

/// Same as `expr` but fails with a compile error if the result type is `noreturn`.
fn reachableExpr(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    src_node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const result_inst = try expr(gz, scope, rl, node);
    if (gz.refIsNoReturn(result_inst)) {
        return gz.astgen.failNodeNotes(src_node, "unreachable code", .{}, &[_]u32{
            try gz.astgen.errNoteNode(node, "control flow is diverted here", .{}),
        });
    }
    return result_inst;
}

fn lvalExpr(gz: *GenZir, scope: *Scope, node: ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);
    switch (node_tags[node]) {
        .root => unreachable,
        .@"usingnamespace" => unreachable,
        .test_decl => unreachable,
        .global_var_decl => unreachable,
        .local_var_decl => unreachable,
        .simple_var_decl => unreachable,
        .aligned_var_decl => unreachable,
        .switch_case => unreachable,
        .switch_case_one => unreachable,
        .container_field_init => unreachable,
        .container_field_align => unreachable,
        .container_field => unreachable,
        .asm_output => unreachable,
        .asm_input => unreachable,

        .assign,
        .assign_bit_and,
        .assign_bit_or,
        .assign_bit_shift_left,
        .assign_bit_shift_right,
        .assign_bit_xor,
        .assign_div,
        .assign_sub,
        .assign_sub_wrap,
        .assign_mod,
        .assign_add,
        .assign_add_wrap,
        .assign_mul,
        .assign_mul_wrap,
        .add,
        .add_wrap,
        .sub,
        .sub_wrap,
        .mul,
        .mul_wrap,
        .div,
        .mod,
        .bit_and,
        .bit_or,
        .bit_shift_left,
        .bit_shift_right,
        .bit_xor,
        .bang_equal,
        .equal_equal,
        .greater_than,
        .greater_or_equal,
        .less_than,
        .less_or_equal,
        .array_cat,
        .array_mult,
        .bool_and,
        .bool_or,
        .@"asm",
        .asm_simple,
        .string_literal,
        .integer_literal,
        .call,
        .call_comma,
        .async_call,
        .async_call_comma,
        .call_one,
        .call_one_comma,
        .async_call_one,
        .async_call_one_comma,
        .unreachable_literal,
        .@"return",
        .@"if",
        .if_simple,
        .@"while",
        .while_simple,
        .while_cont,
        .bool_not,
        .address_of,
        .float_literal,
        .undefined_literal,
        .true_literal,
        .false_literal,
        .null_literal,
        .optional_type,
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        .@"break",
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        .array_type,
        .array_type_sentinel,
        .enum_literal,
        .multiline_string_literal,
        .char_literal,
        .@"defer",
        .@"errdefer",
        .@"catch",
        .error_union,
        .merge_error_sets,
        .switch_range,
        .@"await",
        .bit_not,
        .negation,
        .negation_wrap,
        .@"resume",
        .@"try",
        .slice,
        .slice_open,
        .slice_sentinel,
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        .@"switch",
        .switch_comma,
        .@"for",
        .for_simple,
        .@"suspend",
        .@"continue",
        .@"anytype",
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        .fn_decl,
        .anyframe_type,
        .anyframe_literal,
        .error_set_decl,
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .@"comptime",
        .@"nosuspend",
        .error_value,
        => return astgen.failNode(node, "invalid left-hand side to assignment", .{}),

        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const builtin_token = main_tokens[node];
            const builtin_name = tree.tokenSlice(builtin_token);
            // If the builtin is an invalid name, we don't cause an error here; instead
            // let it pass, and the error will be "invalid builtin function" later.
            if (BuiltinFn.list.get(builtin_name)) |info| {
                if (!info.allows_lvalue) {
                    return astgen.failNode(node, "invalid left-hand side to assignment", .{});
                }
            }
        },

        // These can be assigned to.
        .unwrap_optional,
        .deref,
        .field_access,
        .array_access,
        .identifier,
        .grouped_expression,
        .@"orelse",
        => {},
    }
    return expr(gz, scope, .ref, node);
}

/// Turn Zig AST into untyped ZIR istructions.
/// When `rl` is discard, ptr, inferred_ptr, or inferred_ptr, the
/// result instruction can be used to inspect whether it is isNoReturn() but that is it,
/// it must otherwise not be used.
fn expr(gz: *GenZir, scope: *Scope, rl: ResultLoc, node: ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);
    const node_datas = tree.nodes.items(.data);
    const node_tags = tree.nodes.items(.tag);

    switch (node_tags[node]) {
        .root => unreachable, // Top-level declaration.
        .@"usingnamespace" => unreachable, // Top-level declaration.
        .test_decl => unreachable, // Top-level declaration.
        .container_field_init => unreachable, // Top-level declaration.
        .container_field_align => unreachable, // Top-level declaration.
        .container_field => unreachable, // Top-level declaration.
        .fn_decl => unreachable, // Top-level declaration.

        .global_var_decl => unreachable, // Handled in `blockExpr`.
        .local_var_decl => unreachable, // Handled in `blockExpr`.
        .simple_var_decl => unreachable, // Handled in `blockExpr`.
        .aligned_var_decl => unreachable, // Handled in `blockExpr`.
        .@"defer" => unreachable, // Handled in `blockExpr`.
        .@"errdefer" => unreachable, // Handled in `blockExpr`.

        .switch_case => unreachable, // Handled in `switchExpr`.
        .switch_case_one => unreachable, // Handled in `switchExpr`.
        .switch_range => unreachable, // Handled in `switchExpr`.

        .asm_output => unreachable, // Handled in `asmExpr`.
        .asm_input => unreachable, // Handled in `asmExpr`.

        .@"anytype" => unreachable, // Handled in `containerDecl`.

        .assign => {
            try assign(gz, scope, node);
            return rvalue(gz, rl, .void_value, node);
        },

        .assign_bit_shift_left => {
            try assignShift(gz, scope, node, .shl);
            return rvalue(gz, rl, .void_value, node);
        },
        .assign_bit_shift_right => {
            try assignShift(gz, scope, node, .shr);
            return rvalue(gz, rl, .void_value, node);
        },

        .assign_bit_and => {
            try assignOp(gz, scope, node, .bit_and);
            return rvalue(gz, rl, .void_value, node);
        },
        .assign_bit_or => {
            try assignOp(gz, scope, node, .bit_or);
            return rvalue(gz, rl, .void_value, node);
        },
        .assign_bit_xor => {
            try assignOp(gz, scope, node, .xor);
            return rvalue(gz, rl, .void_value, node);
        },
        .assign_div => {
            try assignOp(gz, scope, node, .div);
            return rvalue(gz, rl, .void_value, node);
        },
        .assign_sub => {
            try assignOp(gz, scope, node, .sub);
            return rvalue(gz, rl, .void_value, node);
        },
        .assign_sub_wrap => {
            try assignOp(gz, scope, node, .subwrap);
            return rvalue(gz, rl, .void_value, node);
        },
        .assign_mod => {
            try assignOp(gz, scope, node, .mod_rem);
            return rvalue(gz, rl, .void_value, node);
        },
        .assign_add => {
            try assignOp(gz, scope, node, .add);
            return rvalue(gz, rl, .void_value, node);
        },
        .assign_add_wrap => {
            try assignOp(gz, scope, node, .addwrap);
            return rvalue(gz, rl, .void_value, node);
        },
        .assign_mul => {
            try assignOp(gz, scope, node, .mul);
            return rvalue(gz, rl, .void_value, node);
        },
        .assign_mul_wrap => {
            try assignOp(gz, scope, node, .mulwrap);
            return rvalue(gz, rl, .void_value, node);
        },

        // zig fmt: off
        .bit_shift_left  => return shiftOp(gz, scope, rl, node, node_datas[node].lhs, node_datas[node].rhs, .shl),
        .bit_shift_right => return shiftOp(gz, scope, rl, node, node_datas[node].lhs, node_datas[node].rhs, .shr),

        .add      => return simpleBinOp(gz, scope, rl, node, .add),
        .add_wrap => return simpleBinOp(gz, scope, rl, node, .addwrap),
        .sub      => return simpleBinOp(gz, scope, rl, node, .sub),
        .sub_wrap => return simpleBinOp(gz, scope, rl, node, .subwrap),
        .mul      => return simpleBinOp(gz, scope, rl, node, .mul),
        .mul_wrap => return simpleBinOp(gz, scope, rl, node, .mulwrap),
        .div      => return simpleBinOp(gz, scope, rl, node, .div),
        .mod      => return simpleBinOp(gz, scope, rl, node, .mod_rem),
        .bit_and  => {
            const current_ampersand_token = main_tokens[node];
            if (token_tags[current_ampersand_token + 1] == .ampersand) {
                const token_starts = tree.tokens.items(.start);
                const current_token_offset = token_starts[current_ampersand_token];
                const next_token_offset = token_starts[current_ampersand_token + 1];
                if (current_token_offset + 1 == next_token_offset) {
                    return astgen.failTok(
                        current_ampersand_token,
                        "`&&` is invalid; note that `and` is boolean AND",
                        .{},
                    );
                }
            }

            return simpleBinOp(gz, scope, rl, node, .bit_and);
        },
        .bit_or   => return simpleBinOp(gz, scope, rl, node, .bit_or),
        .bit_xor  => return simpleBinOp(gz, scope, rl, node, .xor),

        .bang_equal       => return simpleBinOp(gz, scope, rl, node, .cmp_neq),
        .equal_equal      => return simpleBinOp(gz, scope, rl, node, .cmp_eq),
        .greater_than     => return simpleBinOp(gz, scope, rl, node, .cmp_gt),
        .greater_or_equal => return simpleBinOp(gz, scope, rl, node, .cmp_gte),
        .less_than        => return simpleBinOp(gz, scope, rl, node, .cmp_lt),
        .less_or_equal    => return simpleBinOp(gz, scope, rl, node, .cmp_lte),

        .array_cat        => return simpleBinOp(gz, scope, rl, node, .array_cat),
        .array_mult       => return simpleBinOp(gz, scope, rl, node, .array_mul),

        .error_union      => return simpleBinOp(gz, scope, rl, node, .error_union_type),
        .merge_error_sets => return simpleBinOp(gz, scope, rl, node, .merge_error_sets),

        .bool_and => return boolBinOp(gz, scope, rl, node, .bool_br_and),
        .bool_or  => return boolBinOp(gz, scope, rl, node, .bool_br_or),

        .bool_not => return boolNot(gz, scope, rl, node),
        .bit_not  => return bitNot(gz, scope, rl, node),

        .negation      => return negation(gz, scope, rl, node, .negate),
        .negation_wrap => return negation(gz, scope, rl, node, .negate_wrap),

        .identifier => return identifier(gz, scope, rl, node),

        .asm_simple => return asmExpr(gz, scope, rl, node, tree.asmSimple(node)),
        .@"asm"     => return asmExpr(gz, scope, rl, node, tree.asmFull(node)),

        .string_literal           => return stringLiteral(gz, rl, node),
        .multiline_string_literal => return multilineStringLiteral(gz, rl, node),

        .integer_literal => return integerLiteral(gz, rl, node),
        // zig fmt: on

        .builtin_call_two, .builtin_call_two_comma => {
            if (node_datas[node].lhs == 0) {
                const params = [_]ast.Node.Index{};
                return builtinCall(gz, scope, rl, node, &params);
            } else if (node_datas[node].rhs == 0) {
                const params = [_]ast.Node.Index{node_datas[node].lhs};
                return builtinCall(gz, scope, rl, node, &params);
            } else {
                const params = [_]ast.Node.Index{ node_datas[node].lhs, node_datas[node].rhs };
                return builtinCall(gz, scope, rl, node, &params);
            }
        },
        .builtin_call, .builtin_call_comma => {
            const params = tree.extra_data[node_datas[node].lhs..node_datas[node].rhs];
            return builtinCall(gz, scope, rl, node, params);
        },

        .call_one, .call_one_comma, .async_call_one, .async_call_one_comma => {
            var params: [1]ast.Node.Index = undefined;
            return callExpr(gz, scope, rl, node, tree.callOne(&params, node));
        },
        .call, .call_comma, .async_call, .async_call_comma => {
            return callExpr(gz, scope, rl, node, tree.callFull(node));
        },

        .unreachable_literal => {
            _ = try gz.addAsIndex(.{
                .tag = .@"unreachable",
                .data = .{ .@"unreachable" = .{
                    .safety = true,
                    .src_node = gz.nodeIndexToRelative(node),
                } },
            });
            return Zir.Inst.Ref.unreachable_value;
        },
        .@"return" => return ret(gz, scope, node),
        .field_access => return fieldAccess(gz, scope, rl, node),
        .float_literal => return floatLiteral(gz, rl, node),

        .if_simple => return ifExpr(gz, scope, rl, node, tree.ifSimple(node)),
        .@"if" => return ifExpr(gz, scope, rl, node, tree.ifFull(node)),

        .while_simple => return whileExpr(gz, scope, rl, node, tree.whileSimple(node)),
        .while_cont => return whileExpr(gz, scope, rl, node, tree.whileCont(node)),
        .@"while" => return whileExpr(gz, scope, rl, node, tree.whileFull(node)),

        .for_simple => return forExpr(gz, scope, rl, node, tree.forSimple(node)),
        .@"for" => return forExpr(gz, scope, rl, node, tree.forFull(node)),

        .slice_open => {
            const lhs = try expr(gz, scope, .ref, node_datas[node].lhs);
            const start = try expr(gz, scope, .{ .ty = .usize_type }, node_datas[node].rhs);
            const result = try gz.addPlNode(.slice_start, node, Zir.Inst.SliceStart{
                .lhs = lhs,
                .start = start,
            });
            return rvalue(gz, rl, result, node);
        },
        .slice => {
            const lhs = try expr(gz, scope, .ref, node_datas[node].lhs);
            const extra = tree.extraData(node_datas[node].rhs, ast.Node.Slice);
            const start = try expr(gz, scope, .{ .ty = .usize_type }, extra.start);
            const end = try expr(gz, scope, .{ .ty = .usize_type }, extra.end);
            const result = try gz.addPlNode(.slice_end, node, Zir.Inst.SliceEnd{
                .lhs = lhs,
                .start = start,
                .end = end,
            });
            return rvalue(gz, rl, result, node);
        },
        .slice_sentinel => {
            const lhs = try expr(gz, scope, .ref, node_datas[node].lhs);
            const extra = tree.extraData(node_datas[node].rhs, ast.Node.SliceSentinel);
            const start = try expr(gz, scope, .{ .ty = .usize_type }, extra.start);
            const end = if (extra.end != 0) try expr(gz, scope, .{ .ty = .usize_type }, extra.end) else .none;
            const sentinel = try expr(gz, scope, .{ .ty = .usize_type }, extra.sentinel);
            const result = try gz.addPlNode(.slice_sentinel, node, Zir.Inst.SliceSentinel{
                .lhs = lhs,
                .start = start,
                .end = end,
                .sentinel = sentinel,
            });
            return rvalue(gz, rl, result, node);
        },

        .deref => {
            const lhs = try expr(gz, scope, .none, node_datas[node].lhs);
            switch (rl) {
                .ref, .none_or_ref => return lhs,
                else => {
                    const result = try gz.addUnNode(.load, lhs, node);
                    return rvalue(gz, rl, result, node);
                },
            }
        },
        .address_of => {
            const result = try expr(gz, scope, .ref, node_datas[node].lhs);
            return rvalue(gz, rl, result, node);
        },
        .undefined_literal => return rvalue(gz, rl, .undef, node),
        .true_literal => return rvalue(gz, rl, .bool_true, node),
        .false_literal => return rvalue(gz, rl, .bool_false, node),
        .null_literal => return rvalue(gz, rl, .null_value, node),
        .optional_type => {
            const operand = try typeExpr(gz, scope, node_datas[node].lhs);
            const result = try gz.addUnNode(.optional_type, operand, node);
            return rvalue(gz, rl, result, node);
        },
        .unwrap_optional => switch (rl) {
            .ref => return gz.addUnNode(
                .optional_payload_safe_ptr,
                try expr(gz, scope, .ref, node_datas[node].lhs),
                node,
            ),
            else => return rvalue(gz, rl, try gz.addUnNode(
                .optional_payload_safe,
                try expr(gz, scope, .none, node_datas[node].lhs),
                node,
            ), node),
        },
        .block_two, .block_two_semicolon => {
            const statements = [2]ast.Node.Index{ node_datas[node].lhs, node_datas[node].rhs };
            if (node_datas[node].lhs == 0) {
                return blockExpr(gz, scope, rl, node, statements[0..0]);
            } else if (node_datas[node].rhs == 0) {
                return blockExpr(gz, scope, rl, node, statements[0..1]);
            } else {
                return blockExpr(gz, scope, rl, node, statements[0..2]);
            }
        },
        .block, .block_semicolon => {
            const statements = tree.extra_data[node_datas[node].lhs..node_datas[node].rhs];
            return blockExpr(gz, scope, rl, node, statements);
        },
        .enum_literal => return simpleStrTok(gz, rl, main_tokens[node], node, .enum_literal),
        .error_value => return simpleStrTok(gz, rl, node_datas[node].rhs, node, .error_value),
        .anyframe_literal => return rvalue(gz, rl, .anyframe_type, node),
        .anyframe_type => {
            const return_type = try typeExpr(gz, scope, node_datas[node].rhs);
            const result = try gz.addUnNode(.anyframe_type, return_type, node);
            return rvalue(gz, rl, result, node);
        },
        .@"catch" => {
            const catch_token = main_tokens[node];
            const payload_token: ?ast.TokenIndex = if (token_tags[catch_token + 1] == .pipe)
                catch_token + 2
            else
                null;
            switch (rl) {
                .ref => return orelseCatchExpr(
                    gz,
                    scope,
                    rl,
                    node,
                    node_datas[node].lhs,
                    .is_non_err_ptr,
                    .err_union_payload_unsafe_ptr,
                    .err_union_code_ptr,
                    node_datas[node].rhs,
                    payload_token,
                ),
                else => return orelseCatchExpr(
                    gz,
                    scope,
                    rl,
                    node,
                    node_datas[node].lhs,
                    .is_non_err,
                    .err_union_payload_unsafe,
                    .err_union_code,
                    node_datas[node].rhs,
                    payload_token,
                ),
            }
        },
        .@"orelse" => switch (rl) {
            .ref => return orelseCatchExpr(
                gz,
                scope,
                rl,
                node,
                node_datas[node].lhs,
                .is_non_null_ptr,
                .optional_payload_unsafe_ptr,
                undefined,
                node_datas[node].rhs,
                null,
            ),
            else => return orelseCatchExpr(
                gz,
                scope,
                rl,
                node,
                node_datas[node].lhs,
                .is_non_null,
                .optional_payload_unsafe,
                undefined,
                node_datas[node].rhs,
                null,
            ),
        },

        .ptr_type_aligned => return ptrType(gz, scope, rl, node, tree.ptrTypeAligned(node)),
        .ptr_type_sentinel => return ptrType(gz, scope, rl, node, tree.ptrTypeSentinel(node)),
        .ptr_type => return ptrType(gz, scope, rl, node, tree.ptrType(node)),
        .ptr_type_bit_range => return ptrType(gz, scope, rl, node, tree.ptrTypeBitRange(node)),

        .container_decl,
        .container_decl_trailing,
        => return containerDecl(gz, scope, rl, node, tree.containerDecl(node)),
        .container_decl_two, .container_decl_two_trailing => {
            var buffer: [2]ast.Node.Index = undefined;
            return containerDecl(gz, scope, rl, node, tree.containerDeclTwo(&buffer, node));
        },
        .container_decl_arg,
        .container_decl_arg_trailing,
        => return containerDecl(gz, scope, rl, node, tree.containerDeclArg(node)),

        .tagged_union,
        .tagged_union_trailing,
        => return containerDecl(gz, scope, rl, node, tree.taggedUnion(node)),
        .tagged_union_two, .tagged_union_two_trailing => {
            var buffer: [2]ast.Node.Index = undefined;
            return containerDecl(gz, scope, rl, node, tree.taggedUnionTwo(&buffer, node));
        },
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => return containerDecl(gz, scope, rl, node, tree.taggedUnionEnumTag(node)),

        .@"break" => return breakExpr(gz, scope, node),
        .@"continue" => return continueExpr(gz, scope, node),
        .grouped_expression => return expr(gz, scope, rl, node_datas[node].lhs),
        .array_type => return arrayType(gz, scope, rl, node),
        .array_type_sentinel => return arrayTypeSentinel(gz, scope, rl, node),
        .char_literal => return charLiteral(gz, rl, node),
        .error_set_decl => return errorSetDecl(gz, rl, node),
        .array_access => return arrayAccess(gz, scope, rl, node),
        .@"comptime" => return comptimeExprAst(gz, scope, rl, node),
        .@"switch", .switch_comma => return switchExpr(gz, scope, rl, node),

        .@"nosuspend" => return nosuspendExpr(gz, scope, rl, node),
        .@"suspend" => return suspendExpr(gz, scope, node),
        .@"await" => return awaitExpr(gz, scope, rl, node),
        .@"resume" => return resumeExpr(gz, scope, rl, node),

        .@"try" => return tryExpr(gz, scope, rl, node, node_datas[node].lhs),

        .array_init_one, .array_init_one_comma => {
            var elements: [1]ast.Node.Index = undefined;
            return arrayInitExpr(gz, scope, rl, node, tree.arrayInitOne(&elements, node));
        },
        .array_init_dot_two, .array_init_dot_two_comma => {
            var elements: [2]ast.Node.Index = undefined;
            return arrayInitExpr(gz, scope, rl, node, tree.arrayInitDotTwo(&elements, node));
        },
        .array_init_dot,
        .array_init_dot_comma,
        => return arrayInitExpr(gz, scope, rl, node, tree.arrayInitDot(node)),
        .array_init,
        .array_init_comma,
        => return arrayInitExpr(gz, scope, rl, node, tree.arrayInit(node)),

        .struct_init_one, .struct_init_one_comma => {
            var fields: [1]ast.Node.Index = undefined;
            return structInitExpr(gz, scope, rl, node, tree.structInitOne(&fields, node));
        },
        .struct_init_dot_two, .struct_init_dot_two_comma => {
            var fields: [2]ast.Node.Index = undefined;
            return structInitExpr(gz, scope, rl, node, tree.structInitDotTwo(&fields, node));
        },
        .struct_init_dot,
        .struct_init_dot_comma,
        => return structInitExpr(gz, scope, rl, node, tree.structInitDot(node)),
        .struct_init,
        .struct_init_comma,
        => return structInitExpr(gz, scope, rl, node, tree.structInit(node)),

        .fn_proto_simple => {
            var params: [1]ast.Node.Index = undefined;
            return fnProtoExpr(gz, scope, rl, tree.fnProtoSimple(&params, node));
        },
        .fn_proto_multi => {
            return fnProtoExpr(gz, scope, rl, tree.fnProtoMulti(node));
        },
        .fn_proto_one => {
            var params: [1]ast.Node.Index = undefined;
            return fnProtoExpr(gz, scope, rl, tree.fnProtoOne(&params, node));
        },
        .fn_proto => {
            return fnProtoExpr(gz, scope, rl, tree.fnProto(node));
        },
    }
}

fn nosuspendExpr(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const body_node = node_datas[node].lhs;
    assert(body_node != 0);
    if (gz.nosuspend_node != 0) {
        return astgen.failNodeNotes(node, "redundant nosuspend block", .{}, &[_]u32{
            try astgen.errNoteNode(gz.nosuspend_node, "other nosuspend block here", .{}),
        });
    }
    gz.nosuspend_node = node;
    const result = try expr(gz, scope, rl, body_node);
    gz.nosuspend_node = 0;
    return rvalue(gz, rl, result, node);
}

fn suspendExpr(
    gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const body_node = node_datas[node].lhs;

    if (gz.nosuspend_node != 0) {
        return astgen.failNodeNotes(node, "suspend inside nosuspend block", .{}, &[_]u32{
            try astgen.errNoteNode(gz.nosuspend_node, "nosuspend block here", .{}),
        });
    }
    if (gz.suspend_node != 0) {
        return astgen.failNodeNotes(node, "cannot suspend inside suspend block", .{}, &[_]u32{
            try astgen.errNoteNode(gz.suspend_node, "other suspend block here", .{}),
        });
    }
    assert(body_node != 0);

    const suspend_inst = try gz.addBlock(.suspend_block, node);
    try gz.instructions.append(gpa, suspend_inst);

    var suspend_scope = gz.makeSubBlock(scope);
    suspend_scope.suspend_node = node;
    defer suspend_scope.instructions.deinit(gpa);

    const body_result = try expr(&suspend_scope, &suspend_scope.base, .none, body_node);
    if (!gz.refIsNoReturn(body_result)) {
        _ = try suspend_scope.addBreak(.break_inline, suspend_inst, .void_value);
    }
    try suspend_scope.setBlockBody(suspend_inst);

    return indexToRef(suspend_inst);
}

fn awaitExpr(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const rhs_node = node_datas[node].lhs;

    if (gz.suspend_node != 0) {
        return astgen.failNodeNotes(node, "cannot await inside suspend block", .{}, &[_]u32{
            try astgen.errNoteNode(gz.suspend_node, "suspend block here", .{}),
        });
    }
    const operand = try expr(gz, scope, .none, rhs_node);
    const tag: Zir.Inst.Tag = if (gz.nosuspend_node != 0) .await_nosuspend else .@"await";
    const result = try gz.addUnNode(tag, operand, node);
    return rvalue(gz, rl, result, node);
}

fn resumeExpr(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const rhs_node = node_datas[node].lhs;
    const operand = try expr(gz, scope, .none, rhs_node);
    const result = try gz.addUnNode(.@"resume", operand, node);
    return rvalue(gz, rl, result, node);
}

fn fnProtoExpr(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    fn_proto: ast.full.FnProto,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const token_tags = tree.tokens.items(.tag);

    const is_extern = blk: {
        const maybe_extern_token = fn_proto.extern_export_inline_token orelse break :blk false;
        break :blk token_tags[maybe_extern_token] == .keyword_extern;
    };
    assert(!is_extern);

    // The AST params array does not contain anytype and ... parameters.
    // We must iterate to count how many param types to allocate.
    const param_count = blk: {
        var count: usize = 0;
        var it = fn_proto.iterate(tree.*);
        while (it.next()) |param| {
            if (param.anytype_ellipsis3) |token| switch (token_tags[token]) {
                .ellipsis3 => break,
                .keyword_anytype => {},
                else => unreachable,
            };
            count += 1;
        }
        break :blk count;
    };
    const param_types = try gpa.alloc(Zir.Inst.Ref, param_count);
    defer gpa.free(param_types);

    var is_var_args = false;
    {
        var param_type_i: usize = 0;
        var it = fn_proto.iterate(tree.*);
        while (it.next()) |param| : (param_type_i += 1) {
            if (param.anytype_ellipsis3) |token| {
                switch (token_tags[token]) {
                    .keyword_anytype => {
                        param_types[param_type_i] = .none;
                        continue;
                    },
                    .ellipsis3 => {
                        is_var_args = true;
                        break;
                    },
                    else => unreachable,
                }
            }
            const param_type_node = param.type_expr;
            assert(param_type_node != 0);
            param_types[param_type_i] =
                try expr(gz, scope, .{ .ty = .type_type }, param_type_node);
        }
        assert(param_type_i == param_count);
    }

    const align_inst: Zir.Inst.Ref = if (fn_proto.ast.align_expr == 0) .none else inst: {
        break :inst try expr(gz, scope, align_rl, fn_proto.ast.align_expr);
    };
    if (fn_proto.ast.section_expr != 0) {
        return astgen.failNode(fn_proto.ast.section_expr, "linksection not allowed on function prototypes", .{});
    }

    const maybe_bang = tree.firstToken(fn_proto.ast.return_type) - 1;
    const is_inferred_error = token_tags[maybe_bang] == .bang;
    if (is_inferred_error) {
        return astgen.failTok(maybe_bang, "function prototype may not have inferred error set", .{});
    }
    const return_type_inst = try AstGen.expr(
        gz,
        scope,
        .{ .ty = .type_type },
        fn_proto.ast.return_type,
    );

    const cc: Zir.Inst.Ref = if (fn_proto.ast.callconv_expr != 0)
        try AstGen.expr(
            gz,
            scope,
            .{ .ty = .calling_convention_type },
            fn_proto.ast.callconv_expr,
        )
    else
        Zir.Inst.Ref.none;

    const result = try gz.addFunc(.{
        .src_node = fn_proto.ast.proto_node,
        .ret_ty = return_type_inst,
        .param_types = param_types,
        .body = &[0]Zir.Inst.Index{},
        .cc = cc,
        .align_inst = align_inst,
        .lib_name = 0,
        .is_var_args = is_var_args,
        .is_inferred_error = false,
        .is_test = false,
        .is_extern = false,
    });
    return rvalue(gz, rl, result, fn_proto.ast.proto_node);
}

fn arrayInitExpr(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    array_init: ast.full.ArrayInit,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);

    assert(array_init.ast.elements.len != 0); // Otherwise it would be struct init.

    const types: struct {
        array: Zir.Inst.Ref,
        elem: Zir.Inst.Ref,
    } = inst: {
        if (array_init.ast.type_expr == 0) break :inst .{
            .array = .none,
            .elem = .none,
        };

        infer: {
            const array_type: ast.full.ArrayType = switch (node_tags[array_init.ast.type_expr]) {
                .array_type => tree.arrayType(array_init.ast.type_expr),
                .array_type_sentinel => tree.arrayTypeSentinel(array_init.ast.type_expr),
                else => break :infer,
            };
            // This intentionally does not support `@"_"` syntax.
            if (node_tags[array_type.ast.elem_count] == .identifier and
                mem.eql(u8, tree.tokenSlice(main_tokens[array_type.ast.elem_count]), "_"))
            {
                const len_inst = try gz.addInt(array_init.ast.elements.len);
                const elem_type = try typeExpr(gz, scope, array_type.ast.elem_type);
                if (array_type.ast.sentinel == 0) {
                    const array_type_inst = try gz.addBin(.array_type, len_inst, elem_type);
                    break :inst .{
                        .array = array_type_inst,
                        .elem = elem_type,
                    };
                } else {
                    const sentinel = try comptimeExpr(gz, scope, .{ .ty = elem_type }, array_type.ast.sentinel);
                    const array_type_inst = try gz.addArrayTypeSentinel(len_inst, elem_type, sentinel);
                    break :inst .{
                        .array = array_type_inst,
                        .elem = elem_type,
                    };
                }
            }
        }
        const array_type_inst = try typeExpr(gz, scope, array_init.ast.type_expr);
        const elem_type = try gz.addUnNode(.elem_type, array_type_inst, array_init.ast.type_expr);
        break :inst .{
            .array = array_type_inst,
            .elem = elem_type,
        };
    };

    switch (rl) {
        .discard => {
            for (array_init.ast.elements) |elem_init| {
                _ = try expr(gz, scope, .discard, elem_init);
            }
            return Zir.Inst.Ref.void_value;
        },
        .ref => {
            if (types.array != .none) {
                return arrayInitExprRlTy(gz, scope, node, array_init.ast.elements, types.elem, .array_init_ref);
            } else {
                return arrayInitExprRlNone(gz, scope, node, array_init.ast.elements, .array_init_anon_ref);
            }
        },
        .none, .none_or_ref => {
            if (types.array != .none) {
                return arrayInitExprRlTy(gz, scope, node, array_init.ast.elements, types.elem, .array_init);
            } else {
                return arrayInitExprRlNone(gz, scope, node, array_init.ast.elements, .array_init_anon);
            }
        },
        .ty => |ty_inst| {
            if (types.array != .none) {
                const result = try arrayInitExprRlTy(gz, scope, node, array_init.ast.elements, types.elem, .array_init);
                return rvalue(gz, rl, result, node);
            } else {
                const elem_type = try gz.addUnNode(.elem_type, ty_inst, node);
                return arrayInitExprRlTy(gz, scope, node, array_init.ast.elements, elem_type, .array_init);
            }
        },
        .ptr, .inferred_ptr => |ptr_inst| {
            return arrayInitExprRlPtr(gz, scope, node, array_init.ast.elements, ptr_inst);
        },
        .block_ptr => |block_gz| {
            return arrayInitExprRlPtr(gz, scope, node, array_init.ast.elements, block_gz.rl_ptr);
        },
    }
}

fn arrayInitExprRlNone(
    gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
    elements: []const ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const elem_list = try gpa.alloc(Zir.Inst.Ref, elements.len);
    defer gpa.free(elem_list);

    for (elements) |elem_init, i| {
        elem_list[i] = try expr(gz, scope, .none, elem_init);
    }
    const init_inst = try gz.addPlNode(tag, node, Zir.Inst.MultiOp{
        .operands_len = @intCast(u32, elem_list.len),
    });
    try astgen.appendRefs(elem_list);
    return init_inst;
}

fn arrayInitExprRlTy(
    gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
    elements: []const ast.Node.Index,
    elem_ty_inst: Zir.Inst.Ref,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;

    const elem_list = try gpa.alloc(Zir.Inst.Ref, elements.len);
    defer gpa.free(elem_list);

    const elem_rl: ResultLoc = .{ .ty = elem_ty_inst };

    for (elements) |elem_init, i| {
        elem_list[i] = try expr(gz, scope, elem_rl, elem_init);
    }
    const init_inst = try gz.addPlNode(tag, node, Zir.Inst.MultiOp{
        .operands_len = @intCast(u32, elem_list.len),
    });
    try astgen.appendRefs(elem_list);
    return init_inst;
}

fn arrayInitExprRlPtr(
    gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
    elements: []const ast.Node.Index,
    result_ptr: Zir.Inst.Ref,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;

    const elem_ptr_list = try gpa.alloc(Zir.Inst.Index, elements.len);
    defer gpa.free(elem_ptr_list);

    for (elements) |elem_init, i| {
        const index_inst = try gz.addInt(i);
        const elem_ptr = try gz.addPlNode(.elem_ptr_node, elem_init, Zir.Inst.Bin{
            .lhs = result_ptr,
            .rhs = index_inst,
        });
        elem_ptr_list[i] = refToIndex(elem_ptr).?;
        _ = try expr(gz, scope, .{ .ptr = elem_ptr }, elem_init);
    }
    _ = try gz.addPlNode(.validate_array_init_ptr, node, Zir.Inst.Block{
        .body_len = @intCast(u32, elem_ptr_list.len),
    });
    try astgen.extra.appendSlice(gpa, elem_ptr_list);
    return .void_value;
}

fn structInitExpr(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    struct_init: ast.full.StructInit,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    if (struct_init.ast.type_expr == 0) {
        if (struct_init.ast.fields.len == 0) {
            return rvalue(gz, rl, .empty_struct, node);
        }
    } else array: {
        const node_tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);
        const array_type: ast.full.ArrayType = switch (node_tags[struct_init.ast.type_expr]) {
            .array_type => tree.arrayType(struct_init.ast.type_expr),
            .array_type_sentinel => tree.arrayTypeSentinel(struct_init.ast.type_expr),
            else => break :array,
        };
        const is_inferred_array_len = node_tags[array_type.ast.elem_count] == .identifier and
            // This intentionally does not support `@"_"` syntax.
            mem.eql(u8, tree.tokenSlice(main_tokens[array_type.ast.elem_count]), "_");
        if (struct_init.ast.fields.len == 0) {
            if (is_inferred_array_len) {
                const elem_type = try typeExpr(gz, scope, array_type.ast.elem_type);
                const array_type_inst = if (array_type.ast.sentinel == 0) blk: {
                    break :blk try gz.addBin(.array_type, .zero_usize, elem_type);
                } else blk: {
                    const sentinel = try comptimeExpr(gz, scope, .{ .ty = elem_type }, array_type.ast.sentinel);
                    break :blk try gz.addArrayTypeSentinel(.zero_usize, elem_type, sentinel);
                };
                const result = try gz.addUnNode(.struct_init_empty, array_type_inst, node);
                return rvalue(gz, rl, result, node);
            }
            const ty_inst = try typeExpr(gz, scope, struct_init.ast.type_expr);
            const result = try gz.addUnNode(.struct_init_empty, ty_inst, node);
            return rvalue(gz, rl, result, node);
        } else {
            return astgen.failNode(
                struct_init.ast.type_expr,
                "initializing array with struct syntax",
                .{},
            );
        }
    }

    switch (rl) {
        .discard => {
            if (struct_init.ast.type_expr != 0)
                _ = try typeExpr(gz, scope, struct_init.ast.type_expr);
            for (struct_init.ast.fields) |field_init| {
                _ = try expr(gz, scope, .discard, field_init);
            }
            return Zir.Inst.Ref.void_value;
        },
        .ref => {
            if (struct_init.ast.type_expr != 0) {
                const ty_inst = try typeExpr(gz, scope, struct_init.ast.type_expr);
                return structInitExprRlTy(gz, scope, node, struct_init, ty_inst, .struct_init_ref);
            } else {
                return structInitExprRlNone(gz, scope, node, struct_init, .struct_init_anon_ref);
            }
        },
        .none, .none_or_ref => {
            if (struct_init.ast.type_expr != 0) {
                const ty_inst = try typeExpr(gz, scope, struct_init.ast.type_expr);
                return structInitExprRlTy(gz, scope, node, struct_init, ty_inst, .struct_init);
            } else {
                return structInitExprRlNone(gz, scope, node, struct_init, .struct_init_anon);
            }
        },
        .ty => |ty_inst| {
            if (struct_init.ast.type_expr == 0) {
                return structInitExprRlTy(gz, scope, node, struct_init, ty_inst, .struct_init);
            }
            const inner_ty_inst = try typeExpr(gz, scope, struct_init.ast.type_expr);
            const result = try structInitExprRlTy(gz, scope, node, struct_init, inner_ty_inst, .struct_init);
            return rvalue(gz, rl, result, node);
        },
        .ptr, .inferred_ptr => |ptr_inst| return structInitExprRlPtr(gz, scope, node, struct_init, ptr_inst),
        .block_ptr => |block_gz| return structInitExprRlPtr(gz, scope, node, struct_init, block_gz.rl_ptr),
    }
}

fn structInitExprRlNone(
    gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
    struct_init: ast.full.StructInit,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;

    const fields_list = try gpa.alloc(Zir.Inst.StructInitAnon.Item, struct_init.ast.fields.len);
    defer gpa.free(fields_list);

    for (struct_init.ast.fields) |field_init, i| {
        const name_token = tree.firstToken(field_init) - 2;
        const str_index = try astgen.identAsString(name_token);

        fields_list[i] = .{
            .field_name = str_index,
            .init = try expr(gz, scope, .none, field_init),
        };
    }
    const init_inst = try gz.addPlNode(tag, node, Zir.Inst.StructInitAnon{
        .fields_len = @intCast(u32, fields_list.len),
    });
    try astgen.extra.ensureCapacity(gpa, astgen.extra.items.len +
        fields_list.len * @typeInfo(Zir.Inst.StructInitAnon.Item).Struct.fields.len);
    for (fields_list) |field| {
        _ = gz.astgen.addExtraAssumeCapacity(field);
    }
    return init_inst;
}

fn structInitExprRlPtr(
    gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
    struct_init: ast.full.StructInit,
    result_ptr: Zir.Inst.Ref,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;

    const field_ptr_list = try gpa.alloc(Zir.Inst.Index, struct_init.ast.fields.len);
    defer gpa.free(field_ptr_list);

    if (struct_init.ast.type_expr != 0)
        _ = try typeExpr(gz, scope, struct_init.ast.type_expr);

    for (struct_init.ast.fields) |field_init, i| {
        const name_token = tree.firstToken(field_init) - 2;
        const str_index = try astgen.identAsString(name_token);
        const field_ptr = try gz.addPlNode(.field_ptr, field_init, Zir.Inst.Field{
            .lhs = result_ptr,
            .field_name_start = str_index,
        });
        field_ptr_list[i] = refToIndex(field_ptr).?;
        _ = try expr(gz, scope, .{ .ptr = field_ptr }, field_init);
    }
    _ = try gz.addPlNode(.validate_struct_init_ptr, node, Zir.Inst.Block{
        .body_len = @intCast(u32, field_ptr_list.len),
    });
    try astgen.extra.appendSlice(gpa, field_ptr_list);
    return .void_value;
}

fn structInitExprRlTy(
    gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
    struct_init: ast.full.StructInit,
    ty_inst: Zir.Inst.Ref,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;

    const fields_list = try gpa.alloc(Zir.Inst.StructInit.Item, struct_init.ast.fields.len);
    defer gpa.free(fields_list);

    for (struct_init.ast.fields) |field_init, i| {
        const name_token = tree.firstToken(field_init) - 2;
        const str_index = try astgen.identAsString(name_token);

        const field_ty_inst = try gz.addPlNode(.field_type, field_init, Zir.Inst.FieldType{
            .container_type = ty_inst,
            .name_start = str_index,
        });
        fields_list[i] = .{
            .field_type = refToIndex(field_ty_inst).?,
            .init = try expr(gz, scope, .{ .ty = field_ty_inst }, field_init),
        };
    }
    const init_inst = try gz.addPlNode(tag, node, Zir.Inst.StructInit{
        .fields_len = @intCast(u32, fields_list.len),
    });
    try astgen.extra.ensureCapacity(gpa, astgen.extra.items.len +
        fields_list.len * @typeInfo(Zir.Inst.StructInit.Item).Struct.fields.len);
    for (fields_list) |field| {
        _ = gz.astgen.addExtraAssumeCapacity(field);
    }
    return init_inst;
}

/// This calls expr in a comptime scope, and is intended to be called as a helper function.
/// The one that corresponds to `comptime` expression syntax is `comptimeExprAst`.
fn comptimeExpr(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const prev_force_comptime = gz.force_comptime;
    gz.force_comptime = true;
    defer gz.force_comptime = prev_force_comptime;

    return expr(gz, scope, rl, node);
}

/// This one is for an actual `comptime` syntax, and will emit a compile error if
/// the scope already has `force_comptime=true`.
/// See `comptimeExpr` for the helper function for calling expr in a comptime scope.
fn comptimeExprAst(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    if (gz.force_comptime) {
        return astgen.failNode(node, "redundant comptime keyword in already comptime scope", .{});
    }
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const body_node = node_datas[node].lhs;
    gz.force_comptime = true;
    const result = try expr(gz, scope, rl, body_node);
    gz.force_comptime = false;
    return result;
}

fn breakExpr(parent_gz: *GenZir, parent_scope: *Scope, node: ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const break_label = node_datas[node].lhs;
    const rhs = node_datas[node].rhs;

    // Look for the label in the scope.
    var scope = parent_scope;
    while (true) {
        switch (scope.tag) {
            .gen_zir => {
                const block_gz = scope.cast(GenZir).?;

                const block_inst = blk: {
                    if (break_label != 0) {
                        if (block_gz.label) |*label| {
                            if (try astgen.tokenIdentEql(label.token, break_label)) {
                                label.used = true;
                                break :blk label.block_inst;
                            }
                        }
                    } else if (block_gz.break_block != 0) {
                        break :blk block_gz.break_block;
                    }
                    scope = block_gz.parent;
                    continue;
                };

                if (rhs == 0) {
                    _ = try parent_gz.addBreak(.@"break", block_inst, .void_value);
                    return Zir.Inst.Ref.unreachable_value;
                }
                block_gz.break_count += 1;
                const prev_rvalue_rl_count = block_gz.rvalue_rl_count;
                const operand = try expr(parent_gz, parent_scope, block_gz.break_result_loc, rhs);
                const have_store_to_block = block_gz.rvalue_rl_count != prev_rvalue_rl_count;

                const br = try parent_gz.addBreak(.@"break", block_inst, operand);

                if (block_gz.break_result_loc == .block_ptr) {
                    try block_gz.labeled_breaks.append(astgen.gpa, br);

                    if (have_store_to_block) {
                        const zir_tags = parent_gz.astgen.instructions.items(.tag);
                        const zir_datas = parent_gz.astgen.instructions.items(.data);
                        const store_inst = @intCast(u32, zir_tags.len - 2);
                        assert(zir_tags[store_inst] == .store_to_block_ptr);
                        assert(zir_datas[store_inst].bin.lhs == block_gz.rl_ptr);
                        try block_gz.labeled_store_to_block_ptr_list.append(astgen.gpa, store_inst);
                    }
                }
                return Zir.Inst.Ref.unreachable_value;
            },
            .local_val => scope = scope.cast(Scope.LocalVal).?.parent,
            .local_ptr => scope = scope.cast(Scope.LocalPtr).?.parent,
            .namespace => break,
            .defer_normal => {
                const defer_scope = scope.cast(Scope.Defer).?;
                scope = defer_scope.parent;
                const expr_node = node_datas[defer_scope.defer_node].rhs;
                _ = try unusedResultExpr(parent_gz, defer_scope.parent, expr_node);
            },
            .defer_error => scope = scope.cast(Scope.Defer).?.parent,
            .top => unreachable,
        }
    }
    if (break_label != 0) {
        const label_name = try astgen.identifierTokenString(break_label);
        return astgen.failTok(break_label, "label not found: '{s}'", .{label_name});
    } else {
        return astgen.failNode(node, "break expression outside loop", .{});
    }
}

fn continueExpr(parent_gz: *GenZir, parent_scope: *Scope, node: ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const break_label = node_datas[node].lhs;

    // Look for the label in the scope.
    var scope = parent_scope;
    while (true) {
        switch (scope.tag) {
            .gen_zir => {
                const gen_zir = scope.cast(GenZir).?;
                const continue_block = gen_zir.continue_block;
                if (continue_block == 0) {
                    scope = gen_zir.parent;
                    continue;
                }
                if (break_label != 0) blk: {
                    if (gen_zir.label) |*label| {
                        if (try astgen.tokenIdentEql(label.token, break_label)) {
                            label.used = true;
                            break :blk;
                        }
                    }
                    // found continue but either it has a different label, or no label
                    scope = gen_zir.parent;
                    continue;
                }

                // TODO emit a break_inline if the loop being continued is inline
                _ = try parent_gz.addBreak(.@"break", continue_block, .void_value);
                return Zir.Inst.Ref.unreachable_value;
            },
            .local_val => scope = scope.cast(Scope.LocalVal).?.parent,
            .local_ptr => scope = scope.cast(Scope.LocalPtr).?.parent,
            .defer_normal => {
                const defer_scope = scope.cast(Scope.Defer).?;
                scope = defer_scope.parent;
                const expr_node = node_datas[defer_scope.defer_node].rhs;
                _ = try unusedResultExpr(parent_gz, defer_scope.parent, expr_node);
            },
            .defer_error => scope = scope.cast(Scope.Defer).?.parent,
            .namespace => break,
            .top => unreachable,
        }
    }
    if (break_label != 0) {
        const label_name = try astgen.identifierTokenString(break_label);
        return astgen.failTok(break_label, "label not found: '{s}'", .{label_name});
    } else {
        return astgen.failNode(node, "continue expression outside loop", .{});
    }
}

fn blockExpr(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    block_node: ast.Node.Index,
    statements: []const ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const tracy = trace(@src());
    defer tracy.end();

    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);

    const lbrace = main_tokens[block_node];
    if (token_tags[lbrace - 1] == .colon and
        token_tags[lbrace - 2] == .identifier)
    {
        return labeledBlockExpr(gz, scope, rl, block_node, statements, .block);
    }

    try blockExprStmts(gz, scope, statements);
    return rvalue(gz, rl, .void_value, block_node);
}

fn checkLabelRedefinition(astgen: *AstGen, parent_scope: *Scope, label: ast.TokenIndex) !void {
    // Look for the label in the scope.
    var scope = parent_scope;
    while (true) {
        switch (scope.tag) {
            .gen_zir => {
                const gen_zir = scope.cast(GenZir).?;
                if (gen_zir.label) |prev_label| {
                    if (try astgen.tokenIdentEql(label, prev_label.token)) {
                        const label_name = try astgen.identifierTokenString(label);
                        return astgen.failTokNotes(label, "redefinition of label '{s}'", .{
                            label_name,
                        }, &[_]u32{
                            try astgen.errNoteTok(
                                prev_label.token,
                                "previous definition here",
                                .{},
                            ),
                        });
                    }
                }
                scope = gen_zir.parent;
            },
            .local_val => scope = scope.cast(Scope.LocalVal).?.parent,
            .local_ptr => scope = scope.cast(Scope.LocalPtr).?.parent,
            .defer_normal, .defer_error => scope = scope.cast(Scope.Defer).?.parent,
            .namespace => break,
            .top => unreachable,
        }
    }
}

fn labeledBlockExpr(
    gz: *GenZir,
    parent_scope: *Scope,
    rl: ResultLoc,
    block_node: ast.Node.Index,
    statements: []const ast.Node.Index,
    zir_tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const tracy = trace(@src());
    defer tracy.end();

    assert(zir_tag == .block);

    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);

    const lbrace = main_tokens[block_node];
    const label_token = lbrace - 2;
    assert(token_tags[label_token] == .identifier);

    try astgen.checkLabelRedefinition(parent_scope, label_token);

    // Reserve the Block ZIR instruction index so that we can put it into the GenZir struct
    // so that break statements can reference it.
    const block_inst = try gz.addBlock(zir_tag, block_node);
    try gz.instructions.append(astgen.gpa, block_inst);

    var block_scope = gz.makeSubBlock(parent_scope);
    block_scope.label = GenZir.Label{
        .token = label_token,
        .block_inst = block_inst,
    };
    block_scope.setBreakResultLoc(rl);
    defer block_scope.instructions.deinit(astgen.gpa);
    defer block_scope.labeled_breaks.deinit(astgen.gpa);
    defer block_scope.labeled_store_to_block_ptr_list.deinit(astgen.gpa);

    try blockExprStmts(&block_scope, &block_scope.base, statements);

    if (!block_scope.label.?.used) {
        return astgen.failTok(label_token, "unused block label", .{});
    }

    const zir_tags = gz.astgen.instructions.items(.tag);
    const zir_datas = gz.astgen.instructions.items(.data);

    const strat = rl.strategy(&block_scope);
    switch (strat.tag) {
        .break_void => {
            // The code took advantage of the result location as a pointer.
            // Turn the break instruction operands into void.
            for (block_scope.labeled_breaks.items) |br| {
                zir_datas[br].@"break".operand = .void_value;
            }
            try block_scope.setBlockBody(block_inst);

            return indexToRef(block_inst);
        },
        .break_operand => {
            // All break operands are values that did not use the result location pointer.
            if (strat.elide_store_to_block_ptr_instructions) {
                for (block_scope.labeled_store_to_block_ptr_list.items) |inst| {
                    // Mark as elided for removal below.
                    assert(zir_tags[inst] == .store_to_block_ptr);
                    zir_datas[inst].bin.lhs = .none;
                }
                try block_scope.setBlockBodyEliding(block_inst);
            } else {
                try block_scope.setBlockBody(block_inst);
            }
            const block_ref = indexToRef(block_inst);
            switch (rl) {
                .ref => return block_ref,
                else => return rvalue(gz, rl, block_ref, block_node),
            }
        },
    }
}

fn blockExprStmts(gz: *GenZir, parent_scope: *Scope, statements: []const ast.Node.Index) !void {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_tags = tree.nodes.items(.tag);

    var block_arena = std.heap.ArenaAllocator.init(gz.astgen.gpa);
    defer block_arena.deinit();

    var noreturn_src_node: ast.Node.Index = 0;
    var scope = parent_scope;
    for (statements) |statement| {
        if (noreturn_src_node != 0) {
            return astgen.failNodeNotes(
                statement,
                "unreachable code",
                .{},
                &[_]u32{
                    try astgen.errNoteNode(
                        noreturn_src_node,
                        "control flow is diverted here",
                        .{},
                    ),
                },
            );
        }
        switch (node_tags[statement]) {
            // zig fmt: off
            .global_var_decl  => scope = try varDecl(gz, scope, statement, &block_arena.allocator, tree.globalVarDecl(statement)),
            .local_var_decl   => scope = try varDecl(gz, scope, statement, &block_arena.allocator, tree.localVarDecl(statement)),
            .simple_var_decl  => scope = try varDecl(gz, scope, statement, &block_arena.allocator, tree.simpleVarDecl(statement)),
            .aligned_var_decl => scope = try varDecl(gz, scope, statement, &block_arena.allocator, tree.alignedVarDecl(statement)),

            .@"defer"    => scope = try makeDeferScope(scope, statement, &block_arena.allocator, .defer_normal),
            .@"errdefer" => scope = try makeDeferScope(scope, statement, &block_arena.allocator, .defer_error),

            .assign => try assign(gz, scope, statement),

            .assign_bit_shift_left  => try assignShift(gz, scope, statement, .shl),
            .assign_bit_shift_right => try assignShift(gz, scope, statement, .shr),

            .assign_bit_and  => try assignOp(gz, scope, statement, .bit_and),
            .assign_bit_or   => try assignOp(gz, scope, statement, .bit_or),
            .assign_bit_xor  => try assignOp(gz, scope, statement, .xor),
            .assign_div      => try assignOp(gz, scope, statement, .div),
            .assign_sub      => try assignOp(gz, scope, statement, .sub),
            .assign_sub_wrap => try assignOp(gz, scope, statement, .subwrap),
            .assign_mod      => try assignOp(gz, scope, statement, .mod_rem),
            .assign_add      => try assignOp(gz, scope, statement, .add),
            .assign_add_wrap => try assignOp(gz, scope, statement, .addwrap),
            .assign_mul      => try assignOp(gz, scope, statement, .mul),
            .assign_mul_wrap => try assignOp(gz, scope, statement, .mulwrap),

            else => noreturn_src_node = try unusedResultExpr(gz, scope, statement),
            // zig fmt: on
        }
    }

    try genDefers(gz, parent_scope, scope, .normal_only);
    try checkUsed(gz, parent_scope, scope);
}

/// Returns AST source node of the thing that is noreturn if the statement is definitely `noreturn`.
/// Otherwise returns 0.
fn unusedResultExpr(gz: *GenZir, scope: *Scope, statement: ast.Node.Index) InnerError!ast.Node.Index {
    try emitDbgNode(gz, statement);
    // We need to emit an error if the result is not `noreturn` or `void`, but
    // we want to avoid adding the ZIR instruction if possible for performance.
    const maybe_unused_result = try expr(gz, scope, .none, statement);
    var noreturn_src_node: ast.Node.Index = 0;
    const elide_check = if (refToIndex(maybe_unused_result)) |inst| b: {
        // Note that this array becomes invalid after appending more items to it
        // in the above while loop.
        const zir_tags = gz.astgen.instructions.items(.tag);
        switch (zir_tags[inst]) {
            // For some instructions, swap in a slightly different ZIR tag
            // so we can avoid a separate ensure_result_used instruction.
            .call_chkused => unreachable,
            .call => {
                zir_tags[inst] = .call_chkused;
                break :b true;
            },

            // ZIR instructions that might be a type other than `noreturn` or `void`.
            .add,
            .addwrap,
            .arg,
            .alloc,
            .alloc_mut,
            .alloc_comptime,
            .alloc_inferred,
            .alloc_inferred_mut,
            .alloc_inferred_comptime,
            .array_cat,
            .array_mul,
            .array_type,
            .array_type_sentinel,
            .vector_type,
            .elem_type,
            .indexable_ptr_len,
            .anyframe_type,
            .as,
            .as_node,
            .bit_and,
            .bitcast,
            .bitcast_result_ptr,
            .bit_or,
            .block,
            .block_inline,
            .suspend_block,
            .loop,
            .bool_br_and,
            .bool_br_or,
            .bool_not,
            .bool_and,
            .bool_or,
            .call_compile_time,
            .call_nosuspend,
            .call_async,
            .cmp_lt,
            .cmp_lte,
            .cmp_eq,
            .cmp_gte,
            .cmp_gt,
            .cmp_neq,
            .coerce_result_ptr,
            .decl_ref,
            .decl_val,
            .load,
            .div,
            .elem_ptr,
            .elem_val,
            .elem_ptr_node,
            .elem_val_node,
            .field_ptr,
            .field_val,
            .field_ptr_named,
            .field_val_named,
            .func,
            .func_inferred,
            .int,
            .int_big,
            .float,
            .float128,
            .int_type,
            .is_non_null,
            .is_non_null_ptr,
            .is_non_err,
            .is_non_err_ptr,
            .mod_rem,
            .mul,
            .mulwrap,
            .param_type,
            .ref,
            .shl,
            .shr,
            .str,
            .sub,
            .subwrap,
            .negate,
            .negate_wrap,
            .typeof,
            .typeof_elem,
            .xor,
            .optional_type,
            .optional_payload_safe,
            .optional_payload_unsafe,
            .optional_payload_safe_ptr,
            .optional_payload_unsafe_ptr,
            .err_union_payload_safe,
            .err_union_payload_unsafe,
            .err_union_payload_safe_ptr,
            .err_union_payload_unsafe_ptr,
            .err_union_code,
            .err_union_code_ptr,
            .ptr_type,
            .ptr_type_simple,
            .enum_literal,
            .merge_error_sets,
            .error_union_type,
            .bit_not,
            .error_value,
            .error_to_int,
            .int_to_error,
            .slice_start,
            .slice_end,
            .slice_sentinel,
            .import,
            .switch_block,
            .switch_block_multi,
            .switch_block_else,
            .switch_block_else_multi,
            .switch_block_under,
            .switch_block_under_multi,
            .switch_block_ref,
            .switch_block_ref_multi,
            .switch_block_ref_else,
            .switch_block_ref_else_multi,
            .switch_block_ref_under,
            .switch_block_ref_under_multi,
            .switch_capture,
            .switch_capture_ref,
            .switch_capture_multi,
            .switch_capture_multi_ref,
            .switch_capture_else,
            .switch_capture_else_ref,
            .struct_init_empty,
            .struct_init,
            .struct_init_ref,
            .struct_init_anon,
            .struct_init_anon_ref,
            .array_init,
            .array_init_anon,
            .array_init_ref,
            .array_init_anon_ref,
            .union_init_ptr,
            .field_type,
            .field_type_ref,
            .opaque_decl,
            .opaque_decl_anon,
            .opaque_decl_func,
            .error_set_decl,
            .error_set_decl_anon,
            .error_set_decl_func,
            .int_to_enum,
            .enum_to_int,
            .type_info,
            .size_of,
            .bit_size_of,
            .log2_int_type,
            .typeof_log2_int_type,
            .ptr_to_int,
            .align_of,
            .bool_to_int,
            .embed_file,
            .error_name,
            .sqrt,
            .sin,
            .cos,
            .exp,
            .exp2,
            .log,
            .log2,
            .log10,
            .fabs,
            .floor,
            .ceil,
            .trunc,
            .round,
            .tag_name,
            .reify,
            .type_name,
            .frame_type,
            .frame_size,
            .float_to_int,
            .int_to_float,
            .int_to_ptr,
            .float_cast,
            .int_cast,
            .err_set_cast,
            .ptr_cast,
            .truncate,
            .align_cast,
            .has_decl,
            .has_field,
            .clz,
            .ctz,
            .pop_count,
            .byte_swap,
            .bit_reverse,
            .div_exact,
            .div_floor,
            .div_trunc,
            .mod,
            .rem,
            .shl_exact,
            .shr_exact,
            .bit_offset_of,
            .offset_of,
            .cmpxchg_strong,
            .cmpxchg_weak,
            .splat,
            .reduce,
            .shuffle,
            .atomic_load,
            .atomic_rmw,
            .atomic_store,
            .mul_add,
            .builtin_call,
            .field_ptr_type,
            .field_parent_ptr,
            .memcpy,
            .memset,
            .builtin_async_call,
            .c_import,
            .@"resume",
            .@"await",
            .await_nosuspend,
            .ret_err_value_code,
            .extended,
            => break :b false,

            // ZIR instructions that are always `noreturn`.
            .@"break",
            .break_inline,
            .condbr,
            .condbr_inline,
            .compile_error,
            .ret_node,
            .ret_coerce,
            .ret_err_value,
            .@"unreachable",
            .repeat,
            .repeat_inline,
            .panic,
            => {
                noreturn_src_node = statement;
                break :b true;
            },

            // ZIR instructions that are always `void`.
            .breakpoint,
            .fence,
            .dbg_stmt,
            .ensure_result_used,
            .ensure_result_non_error,
            .@"export",
            .set_eval_branch_quota,
            .ensure_err_payload_void,
            .store,
            .store_node,
            .store_to_block_ptr,
            .store_to_inferred_ptr,
            .resolve_inferred_alloc,
            .validate_struct_init_ptr,
            .validate_array_init_ptr,
            .set_align_stack,
            .set_cold,
            .set_float_mode,
            .set_runtime_safety,
            => break :b true,
        }
    } else switch (maybe_unused_result) {
        .none => unreachable,

        .unreachable_value => b: {
            noreturn_src_node = statement;
            break :b true;
        },

        .void_value => true,

        else => false,
    };
    if (!elide_check) {
        _ = try gz.addUnNode(.ensure_result_used, maybe_unused_result, statement);
    }
    return noreturn_src_node;
}

fn countDefers(astgen: *AstGen, outer_scope: *Scope, inner_scope: *Scope) struct {
    have_any: bool,
    have_normal: bool,
    have_err: bool,
    need_err_code: bool,
} {
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);

    var have_normal = false;
    var have_err = false;
    var need_err_code = false;
    var scope = inner_scope;
    while (scope != outer_scope) {
        switch (scope.tag) {
            .gen_zir => scope = scope.cast(GenZir).?.parent,
            .local_val => scope = scope.cast(Scope.LocalVal).?.parent,
            .local_ptr => scope = scope.cast(Scope.LocalPtr).?.parent,
            .defer_normal => {
                const defer_scope = scope.cast(Scope.Defer).?;
                scope = defer_scope.parent;

                have_normal = true;
            },
            .defer_error => {
                const defer_scope = scope.cast(Scope.Defer).?;
                scope = defer_scope.parent;

                have_err = true;

                const have_err_payload = node_datas[defer_scope.defer_node].lhs != 0;
                need_err_code = need_err_code or have_err_payload;
            },
            .namespace => unreachable,
            .top => unreachable,
        }
    }
    return .{
        .have_any = have_normal or have_err,
        .have_normal = have_normal,
        .have_err = have_err,
        .need_err_code = need_err_code,
    };
}

const DefersToEmit = union(enum) {
    both: Zir.Inst.Ref, // err code
    both_sans_err,
    normal_only,
};

fn genDefers(
    gz: *GenZir,
    outer_scope: *Scope,
    inner_scope: *Scope,
    which_ones: DefersToEmit,
) InnerError!void {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);

    var scope = inner_scope;
    while (scope != outer_scope) {
        switch (scope.tag) {
            .gen_zir => scope = scope.cast(GenZir).?.parent,
            .local_val => scope = scope.cast(Scope.LocalVal).?.parent,
            .local_ptr => scope = scope.cast(Scope.LocalPtr).?.parent,
            .defer_normal => {
                const defer_scope = scope.cast(Scope.Defer).?;
                scope = defer_scope.parent;
                const expr_node = node_datas[defer_scope.defer_node].rhs;
                const prev_in_defer = gz.in_defer;
                gz.in_defer = true;
                defer gz.in_defer = prev_in_defer;
                _ = try unusedResultExpr(gz, defer_scope.parent, expr_node);
            },
            .defer_error => {
                const defer_scope = scope.cast(Scope.Defer).?;
                scope = defer_scope.parent;
                switch (which_ones) {
                    .both_sans_err => {
                        const expr_node = node_datas[defer_scope.defer_node].rhs;
                        const prev_in_defer = gz.in_defer;
                        gz.in_defer = true;
                        defer gz.in_defer = prev_in_defer;
                        _ = try unusedResultExpr(gz, defer_scope.parent, expr_node);
                    },
                    .both => |err_code| {
                        const expr_node = node_datas[defer_scope.defer_node].rhs;
                        const payload_token = node_datas[defer_scope.defer_node].lhs;
                        const prev_in_defer = gz.in_defer;
                        gz.in_defer = true;
                        defer gz.in_defer = prev_in_defer;
                        var local_val_scope: Scope.LocalVal = undefined;
                        const sub_scope = if (payload_token == 0) defer_scope.parent else blk: {
                            const ident_name = try astgen.identAsString(payload_token);
                            local_val_scope = .{
                                .parent = defer_scope.parent,
                                .gen_zir = gz,
                                .name = ident_name,
                                .inst = err_code,
                                .token_src = payload_token,
                                .id_cat = .@"capture",
                            };
                            break :blk &local_val_scope.base;
                        };
                        _ = try unusedResultExpr(gz, sub_scope, expr_node);
                    },
                    .normal_only => continue,
                }
            },
            .namespace => unreachable,
            .top => unreachable,
        }
    }
}

fn checkUsed(
    gz: *GenZir,
    outer_scope: *Scope,
    inner_scope: *Scope,
) InnerError!void {
    const astgen = gz.astgen;

    var scope = inner_scope;
    while (scope != outer_scope) {
        switch (scope.tag) {
            .gen_zir => scope = scope.cast(GenZir).?.parent,
            .local_val => {
                const s = scope.cast(Scope.LocalVal).?;
                if (!s.used) {
                    return astgen.failTok(s.token_src, "unused {s}", .{@tagName(s.id_cat)});
                }
                scope = s.parent;
            },
            .local_ptr => {
                const s = scope.cast(Scope.LocalPtr).?;
                if (!s.used) {
                    return astgen.failTok(s.token_src, "unused {s}", .{@tagName(s.id_cat)});
                }
                scope = s.parent;
            },
            .defer_normal, .defer_error => scope = scope.cast(Scope.Defer).?.parent,
            .namespace => unreachable,
            .top => unreachable,
        }
    }
}

fn makeDeferScope(
    scope: *Scope,
    node: ast.Node.Index,
    block_arena: *Allocator,
    scope_tag: Scope.Tag,
) InnerError!*Scope {
    const defer_scope = try block_arena.create(Scope.Defer);
    defer_scope.* = .{
        .base = .{ .tag = scope_tag },
        .parent = scope,
        .defer_node = node,
    };
    return &defer_scope.base;
}

fn varDecl(
    gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
    block_arena: *Allocator,
    var_decl: ast.full.VarDecl,
) InnerError!*Scope {
    try emitDbgNode(gz, node);
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const token_tags = tree.tokens.items(.tag);

    const name_token = var_decl.ast.mut_token + 1;
    const ident_name_raw = tree.tokenSlice(name_token);
    if (mem.eql(u8, ident_name_raw, "_")) {
        return astgen.failTok(name_token, "'_' used as an identifier without @\"_\" syntax", .{});
    }
    const ident_name = try astgen.identAsString(name_token);

    try astgen.detectLocalShadowing(scope, ident_name, name_token);

    if (var_decl.ast.init_node == 0) {
        return astgen.failNode(node, "variables must be initialized", .{});
    }

    const align_inst: Zir.Inst.Ref = if (var_decl.ast.align_node != 0)
        try expr(gz, scope, align_rl, var_decl.ast.align_node)
    else
        .none;

    switch (token_tags[var_decl.ast.mut_token]) {
        .keyword_const => {
            if (var_decl.comptime_token) |comptime_token| {
                return astgen.failTok(comptime_token, "'comptime const' is redundant; instead wrap the initialization expression with 'comptime'", .{});
            }

            // Depending on the type of AST the initialization expression is, we may need an lvalue
            // or an rvalue as a result location. If it is an rvalue, we can use the instruction as
            // the variable, no memory location needed.
            if (align_inst == .none and !nodeMayNeedMemoryLocation(tree, var_decl.ast.init_node)) {
                const result_loc: ResultLoc = if (var_decl.ast.type_node != 0) .{
                    .ty = try typeExpr(gz, scope, var_decl.ast.type_node),
                } else .none;
                const init_inst = try reachableExpr(gz, scope, result_loc, var_decl.ast.init_node, node);

                const sub_scope = try block_arena.create(Scope.LocalVal);
                sub_scope.* = .{
                    .parent = scope,
                    .gen_zir = gz,
                    .name = ident_name,
                    .inst = init_inst,
                    .token_src = name_token,
                    .id_cat = .@"local constant",
                };
                return &sub_scope.base;
            }

            // Detect whether the initialization expression actually uses the
            // result location pointer.
            var init_scope = gz.makeSubBlock(scope);
            defer init_scope.instructions.deinit(gpa);

            var resolve_inferred_alloc: Zir.Inst.Ref = .none;
            var opt_type_inst: Zir.Inst.Ref = .none;
            if (var_decl.ast.type_node != 0) {
                const type_inst = try typeExpr(gz, &init_scope.base, var_decl.ast.type_node);
                opt_type_inst = type_inst;
                if (align_inst == .none) {
                    init_scope.rl_ptr = try init_scope.addUnNode(.alloc, type_inst, node);
                } else {
                    init_scope.rl_ptr = try gz.addAllocExtended(.{
                        .node = node,
                        .type_inst = type_inst,
                        .align_inst = align_inst,
                        .is_const = true,
                        .is_comptime = false,
                    });
                }
                init_scope.rl_ty_inst = type_inst;
            } else {
                const alloc = if (align_inst == .none)
                    try init_scope.addNode(.alloc_inferred, node)
                else
                    try gz.addAllocExtended(.{
                        .node = node,
                        .type_inst = .none,
                        .align_inst = align_inst,
                        .is_const = true,
                        .is_comptime = false,
                    });
                resolve_inferred_alloc = alloc;
                init_scope.rl_ptr = alloc;
            }
            const init_result_loc: ResultLoc = .{ .block_ptr = &init_scope };
            const init_inst = try reachableExpr(&init_scope, &init_scope.base, init_result_loc, var_decl.ast.init_node, node);

            const zir_tags = astgen.instructions.items(.tag);
            const zir_datas = astgen.instructions.items(.data);

            const parent_zir = &gz.instructions;
            if (align_inst == .none and init_scope.rvalue_rl_count == 1) {
                // Result location pointer not used. We don't need an alloc for this
                // const local, and type inference becomes trivial.
                // Move the init_scope instructions into the parent scope, eliding
                // the alloc instruction and the store_to_block_ptr instruction.
                try parent_zir.ensureUnusedCapacity(gpa, init_scope.instructions.items.len);
                for (init_scope.instructions.items) |src_inst| {
                    if (indexToRef(src_inst) == init_scope.rl_ptr) continue;
                    if (zir_tags[src_inst] == .store_to_block_ptr) {
                        if (zir_datas[src_inst].bin.lhs == init_scope.rl_ptr) continue;
                    }
                    parent_zir.appendAssumeCapacity(src_inst);
                }

                const sub_scope = try block_arena.create(Scope.LocalVal);
                sub_scope.* = .{
                    .parent = scope,
                    .gen_zir = gz,
                    .name = ident_name,
                    .inst = init_inst,
                    .token_src = name_token,
                    .id_cat = .@"local constant",
                };
                return &sub_scope.base;
            }
            // The initialization expression took advantage of the result location
            // of the const local. In this case we will create an alloc and a LocalPtr for it.
            // Move the init_scope instructions into the parent scope, swapping
            // store_to_block_ptr for store_to_inferred_ptr.
            const expected_len = parent_zir.items.len + init_scope.instructions.items.len;
            try parent_zir.ensureCapacity(gpa, expected_len);
            for (init_scope.instructions.items) |src_inst| {
                if (zir_tags[src_inst] == .store_to_block_ptr) {
                    if (zir_datas[src_inst].bin.lhs == init_scope.rl_ptr) {
                        zir_tags[src_inst] = .store_to_inferred_ptr;
                    }
                }
                parent_zir.appendAssumeCapacity(src_inst);
            }
            assert(parent_zir.items.len == expected_len);
            if (resolve_inferred_alloc != .none) {
                _ = try gz.addUnNode(.resolve_inferred_alloc, resolve_inferred_alloc, node);
            }
            const sub_scope = try block_arena.create(Scope.LocalPtr);
            sub_scope.* = .{
                .parent = scope,
                .gen_zir = gz,
                .name = ident_name,
                .ptr = init_scope.rl_ptr,
                .token_src = name_token,
                .maybe_comptime = true,
                .id_cat = .@"local constant",
            };
            return &sub_scope.base;
        },
        .keyword_var => {
            const is_comptime = var_decl.comptime_token != null or gz.force_comptime;
            var resolve_inferred_alloc: Zir.Inst.Ref = .none;
            const var_data: struct {
                result_loc: ResultLoc,
                alloc: Zir.Inst.Ref,
            } = if (var_decl.ast.type_node != 0) a: {
                const type_inst = try typeExpr(gz, scope, var_decl.ast.type_node);
                const alloc = alloc: {
                    if (align_inst == .none) {
                        const tag: Zir.Inst.Tag = if (is_comptime) .alloc_comptime else .alloc_mut;
                        break :alloc try gz.addUnNode(tag, type_inst, node);
                    } else {
                        break :alloc try gz.addAllocExtended(.{
                            .node = node,
                            .type_inst = type_inst,
                            .align_inst = align_inst,
                            .is_const = false,
                            .is_comptime = is_comptime,
                        });
                    }
                };
                break :a .{ .alloc = alloc, .result_loc = .{ .ptr = alloc } };
            } else a: {
                const alloc = alloc: {
                    if (align_inst == .none) {
                        const tag: Zir.Inst.Tag = if (is_comptime) .alloc_inferred_comptime else .alloc_inferred_mut;
                        break :alloc try gz.addNode(tag, node);
                    } else {
                        break :alloc try gz.addAllocExtended(.{
                            .node = node,
                            .type_inst = .none,
                            .align_inst = align_inst,
                            .is_const = false,
                            .is_comptime = is_comptime,
                        });
                    }
                };
                resolve_inferred_alloc = alloc;
                break :a .{ .alloc = alloc, .result_loc = .{ .inferred_ptr = alloc } };
            };
            _ = try reachableExpr(gz, scope, var_data.result_loc, var_decl.ast.init_node, node);
            if (resolve_inferred_alloc != .none) {
                _ = try gz.addUnNode(.resolve_inferred_alloc, resolve_inferred_alloc, node);
            }
            const sub_scope = try block_arena.create(Scope.LocalPtr);
            sub_scope.* = .{
                .parent = scope,
                .gen_zir = gz,
                .name = ident_name,
                .ptr = var_data.alloc,
                .token_src = name_token,
                .maybe_comptime = is_comptime,
                .id_cat = .@"local variable",
            };
            return &sub_scope.base;
        },
        else => unreachable,
    }
}

fn emitDbgNode(gz: *GenZir, node: ast.Node.Index) !void {
    // The instruction emitted here is for debugging runtime code.
    // If the current block will be evaluated only during semantic analysis
    // then no dbg_stmt ZIR instruction is needed.
    if (gz.force_comptime) return;

    const astgen = gz.astgen;
    const tree = astgen.tree;
    const source = tree.source;
    const token_starts = tree.tokens.items(.start);
    const node_start = token_starts[tree.firstToken(node)];

    astgen.advanceSourceCursor(source, node_start);
    const line = @intCast(u32, astgen.source_line);
    const column = @intCast(u32, astgen.source_column);

    _ = try gz.add(.{ .tag = .dbg_stmt, .data = .{
        .dbg_stmt = .{
            .line = line,
            .column = column,
        },
    } });
}

fn assign(gz: *GenZir, scope: *Scope, infix_node: ast.Node.Index) InnerError!void {
    try emitDbgNode(gz, infix_node);
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const node_tags = tree.nodes.items(.tag);

    const lhs = node_datas[infix_node].lhs;
    const rhs = node_datas[infix_node].rhs;
    if (node_tags[lhs] == .identifier) {
        // This intentionally does not support `@"_"` syntax.
        const ident_name = tree.tokenSlice(main_tokens[lhs]);
        if (mem.eql(u8, ident_name, "_")) {
            _ = try expr(gz, scope, .discard, rhs);
            return;
        }
    }
    const lvalue = try lvalExpr(gz, scope, lhs);
    _ = try expr(gz, scope, .{ .ptr = lvalue }, rhs);
}

fn assignOp(
    gz: *GenZir,
    scope: *Scope,
    infix_node: ast.Node.Index,
    op_inst_tag: Zir.Inst.Tag,
) InnerError!void {
    try emitDbgNode(gz, infix_node);
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);

    const lhs_ptr = try lvalExpr(gz, scope, node_datas[infix_node].lhs);
    const lhs = try gz.addUnNode(.load, lhs_ptr, infix_node);
    const lhs_type = try gz.addUnNode(.typeof, lhs, infix_node);
    const rhs = try expr(gz, scope, .{ .ty = lhs_type }, node_datas[infix_node].rhs);

    const result = try gz.addPlNode(op_inst_tag, infix_node, Zir.Inst.Bin{
        .lhs = lhs,
        .rhs = rhs,
    });
    _ = try gz.addBin(.store, lhs_ptr, result);
}

fn assignShift(
    gz: *GenZir,
    scope: *Scope,
    infix_node: ast.Node.Index,
    op_inst_tag: Zir.Inst.Tag,
) InnerError!void {
    try emitDbgNode(gz, infix_node);
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);

    const lhs_ptr = try lvalExpr(gz, scope, node_datas[infix_node].lhs);
    const lhs = try gz.addUnNode(.load, lhs_ptr, infix_node);
    const rhs_type = try gz.addUnNode(.typeof_log2_int_type, lhs, infix_node);
    const rhs = try expr(gz, scope, .{ .ty = rhs_type }, node_datas[infix_node].rhs);

    const result = try gz.addPlNode(op_inst_tag, infix_node, Zir.Inst.Bin{
        .lhs = lhs,
        .rhs = rhs,
    });
    _ = try gz.addBin(.store, lhs_ptr, result);
}

fn boolNot(gz: *GenZir, scope: *Scope, rl: ResultLoc, node: ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);

    const operand = try expr(gz, scope, bool_rl, node_datas[node].lhs);
    const result = try gz.addUnNode(.bool_not, operand, node);
    return rvalue(gz, rl, result, node);
}

fn bitNot(gz: *GenZir, scope: *Scope, rl: ResultLoc, node: ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);

    const operand = try expr(gz, scope, .none, node_datas[node].lhs);
    const result = try gz.addUnNode(.bit_not, operand, node);
    return rvalue(gz, rl, result, node);
}

fn negation(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);

    const operand = try expr(gz, scope, .none, node_datas[node].lhs);
    const result = try gz.addUnNode(tag, operand, node);
    return rvalue(gz, rl, result, node);
}

fn ptrType(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    ptr_info: ast.full.PtrType,
) InnerError!Zir.Inst.Ref {
    const elem_type = try typeExpr(gz, scope, ptr_info.ast.child_type);

    const simple = ptr_info.ast.align_node == 0 and
        ptr_info.ast.sentinel == 0 and
        ptr_info.ast.bit_range_start == 0;

    if (simple) {
        const result = try gz.add(.{ .tag = .ptr_type_simple, .data = .{
            .ptr_type_simple = .{
                .is_allowzero = ptr_info.allowzero_token != null,
                .is_mutable = ptr_info.const_token == null,
                .is_volatile = ptr_info.volatile_token != null,
                .size = ptr_info.size,
                .elem_type = elem_type,
            },
        } });
        return rvalue(gz, rl, result, node);
    }

    var sentinel_ref: Zir.Inst.Ref = .none;
    var align_ref: Zir.Inst.Ref = .none;
    var bit_start_ref: Zir.Inst.Ref = .none;
    var bit_end_ref: Zir.Inst.Ref = .none;
    var trailing_count: u32 = 0;

    if (ptr_info.ast.sentinel != 0) {
        sentinel_ref = try expr(gz, scope, .{ .ty = elem_type }, ptr_info.ast.sentinel);
        trailing_count += 1;
    }
    if (ptr_info.ast.align_node != 0) {
        align_ref = try expr(gz, scope, align_rl, ptr_info.ast.align_node);
        trailing_count += 1;
    }
    if (ptr_info.ast.bit_range_start != 0) {
        assert(ptr_info.ast.bit_range_end != 0);
        bit_start_ref = try expr(gz, scope, .none, ptr_info.ast.bit_range_start);
        bit_end_ref = try expr(gz, scope, .none, ptr_info.ast.bit_range_end);
        trailing_count += 2;
    }

    const gpa = gz.astgen.gpa;
    try gz.instructions.ensureCapacity(gpa, gz.instructions.items.len + 1);
    try gz.astgen.instructions.ensureCapacity(gpa, gz.astgen.instructions.len + 1);
    try gz.astgen.extra.ensureCapacity(gpa, gz.astgen.extra.items.len +
        @typeInfo(Zir.Inst.PtrType).Struct.fields.len + trailing_count);

    const payload_index = gz.astgen.addExtraAssumeCapacity(Zir.Inst.PtrType{ .elem_type = elem_type });
    if (sentinel_ref != .none) {
        gz.astgen.extra.appendAssumeCapacity(@enumToInt(sentinel_ref));
    }
    if (align_ref != .none) {
        gz.astgen.extra.appendAssumeCapacity(@enumToInt(align_ref));
    }
    if (bit_start_ref != .none) {
        gz.astgen.extra.appendAssumeCapacity(@enumToInt(bit_start_ref));
        gz.astgen.extra.appendAssumeCapacity(@enumToInt(bit_end_ref));
    }

    const new_index = @intCast(Zir.Inst.Index, gz.astgen.instructions.len);
    const result = indexToRef(new_index);
    gz.astgen.instructions.appendAssumeCapacity(.{ .tag = .ptr_type, .data = .{
        .ptr_type = .{
            .flags = .{
                .is_allowzero = ptr_info.allowzero_token != null,
                .is_mutable = ptr_info.const_token == null,
                .is_volatile = ptr_info.volatile_token != null,
                .has_sentinel = sentinel_ref != .none,
                .has_align = align_ref != .none,
                .has_bit_range = bit_start_ref != .none,
            },
            .size = ptr_info.size,
            .payload_index = payload_index,
        },
    } });
    gz.instructions.appendAssumeCapacity(new_index);

    return rvalue(gz, rl, result, node);
}

fn arrayType(gz: *GenZir, scope: *Scope, rl: ResultLoc, node: ast.Node.Index) !Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const node_tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);

    const len_node = node_datas[node].lhs;
    if (node_tags[len_node] == .identifier and
        mem.eql(u8, tree.tokenSlice(main_tokens[len_node]), "_"))
    {
        return astgen.failNode(len_node, "unable to infer array size", .{});
    }
    const len = try expr(gz, scope, .{ .ty = .usize_type }, len_node);
    const elem_type = try typeExpr(gz, scope, node_datas[node].rhs);

    const result = try gz.addBin(.array_type, len, elem_type);
    return rvalue(gz, rl, result, node);
}

fn arrayTypeSentinel(gz: *GenZir, scope: *Scope, rl: ResultLoc, node: ast.Node.Index) !Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const node_tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);
    const extra = tree.extraData(node_datas[node].rhs, ast.Node.ArrayTypeSentinel);

    const len_node = node_datas[node].lhs;
    if (node_tags[len_node] == .identifier and
        mem.eql(u8, tree.tokenSlice(main_tokens[len_node]), "_"))
    {
        return astgen.failNode(len_node, "unable to infer array size", .{});
    }
    const len = try expr(gz, scope, .{ .ty = .usize_type }, len_node);
    const elem_type = try typeExpr(gz, scope, extra.elem_type);
    const sentinel = try expr(gz, scope, .{ .ty = elem_type }, extra.sentinel);

    const result = try gz.addArrayTypeSentinel(len, elem_type, sentinel);
    return rvalue(gz, rl, result, node);
}

const WipDecls = struct {
    decl_index: usize = 0,
    cur_bit_bag: u32 = 0,
    bit_bag: ArrayListUnmanaged(u32) = .{},
    payload: ArrayListUnmanaged(u32) = .{},

    const bits_per_field = 4;
    const fields_per_u32 = 32 / bits_per_field;

    fn next(
        wip_decls: *WipDecls,
        gpa: *Allocator,
        is_pub: bool,
        is_export: bool,
        has_align: bool,
        has_section: bool,
    ) Allocator.Error!void {
        if (wip_decls.decl_index % fields_per_u32 == 0 and wip_decls.decl_index != 0) {
            try wip_decls.bit_bag.append(gpa, wip_decls.cur_bit_bag);
            wip_decls.cur_bit_bag = 0;
        }
        wip_decls.cur_bit_bag = (wip_decls.cur_bit_bag >> bits_per_field) |
            (@as(u32, @boolToInt(is_pub)) << 28) |
            (@as(u32, @boolToInt(is_export)) << 29) |
            (@as(u32, @boolToInt(has_align)) << 30) |
            (@as(u32, @boolToInt(has_section)) << 31);
        wip_decls.decl_index += 1;
    }

    fn deinit(wip_decls: *WipDecls, gpa: *Allocator) void {
        wip_decls.bit_bag.deinit(gpa);
        wip_decls.payload.deinit(gpa);
    }
};

fn fnDecl(
    astgen: *AstGen,
    gz: *GenZir,
    scope: *Scope,
    wip_decls: *WipDecls,
    decl_node: ast.Node.Index,
    body_node: ast.Node.Index,
    fn_proto: ast.full.FnProto,
) InnerError!void {
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const token_tags = tree.tokens.items(.tag);

    const fn_name_token = fn_proto.name_token orelse {
        return astgen.failTok(fn_proto.ast.fn_token, "missing function name", .{});
    };
    const fn_name_str_index = try astgen.identAsString(fn_name_token);

    try astgen.declareNewName(scope, fn_name_str_index, decl_node);

    // We insert this at the beginning so that its instruction index marks the
    // start of the top level declaration.
    const block_inst = try gz.addBlock(.block_inline, fn_proto.ast.proto_node);

    var decl_gz: GenZir = .{
        .force_comptime = true,
        .in_defer = false,
        .decl_node_index = fn_proto.ast.proto_node,
        .decl_line = gz.calcLine(decl_node),
        .parent = scope,
        .astgen = astgen,
    };
    defer decl_gz.instructions.deinit(gpa);

    // TODO: support noinline
    const is_pub = fn_proto.visib_token != null;
    const is_export = blk: {
        const maybe_export_token = fn_proto.extern_export_inline_token orelse break :blk false;
        break :blk token_tags[maybe_export_token] == .keyword_export;
    };
    const is_extern = blk: {
        const maybe_extern_token = fn_proto.extern_export_inline_token orelse break :blk false;
        break :blk token_tags[maybe_extern_token] == .keyword_extern;
    };
    const has_inline_keyword = blk: {
        const maybe_inline_token = fn_proto.extern_export_inline_token orelse break :blk false;
        break :blk token_tags[maybe_inline_token] == .keyword_inline;
    };
    const align_inst: Zir.Inst.Ref = if (fn_proto.ast.align_expr == 0) .none else inst: {
        break :inst try expr(&decl_gz, &decl_gz.base, align_rl, fn_proto.ast.align_expr);
    };
    const section_inst: Zir.Inst.Ref = if (fn_proto.ast.section_expr == 0) .none else inst: {
        break :inst try comptimeExpr(&decl_gz, &decl_gz.base, .{ .ty = .const_slice_u8_type }, fn_proto.ast.section_expr);
    };

    try wip_decls.next(gpa, is_pub, is_export, align_inst != .none, section_inst != .none);

    // The AST params array does not contain anytype and ... parameters.
    // We must iterate to count how many param types to allocate.
    const param_count = blk: {
        var count: usize = 0;
        var it = fn_proto.iterate(tree.*);
        while (it.next()) |param| {
            if (param.anytype_ellipsis3) |token| switch (token_tags[token]) {
                .ellipsis3 => break,
                .keyword_anytype => {},
                else => unreachable,
            };
            count += 1;
        }
        break :blk count;
    };
    const param_types = try gpa.alloc(Zir.Inst.Ref, param_count);
    defer gpa.free(param_types);

    var is_var_args = false;
    {
        var param_type_i: usize = 0;
        var it = fn_proto.iterate(tree.*);
        while (it.next()) |param| : (param_type_i += 1) {
            if (param.anytype_ellipsis3) |token| {
                switch (token_tags[token]) {
                    .keyword_anytype => {
                        param_types[param_type_i] = .none;
                        continue;
                    },
                    .ellipsis3 => {
                        is_var_args = true;
                        break;
                    },
                    else => unreachable,
                }
            }
            const param_type_node = param.type_expr;
            assert(param_type_node != 0);
            param_types[param_type_i] =
                try expr(&decl_gz, &decl_gz.base, .{ .ty = .type_type }, param_type_node);
        }
        assert(param_type_i == param_count);
    }

    const lib_name: u32 = if (fn_proto.lib_name) |lib_name_token| blk: {
        const lib_name_str = try astgen.strLitAsString(lib_name_token);
        break :blk lib_name_str.index;
    } else 0;

    const maybe_bang = tree.firstToken(fn_proto.ast.return_type) - 1;
    const is_inferred_error = token_tags[maybe_bang] == .bang;

    const return_type_inst = try AstGen.expr(
        &decl_gz,
        &decl_gz.base,
        .{ .ty = .type_type },
        fn_proto.ast.return_type,
    );

    const cc: Zir.Inst.Ref = blk: {
        if (fn_proto.ast.callconv_expr != 0) {
            if (has_inline_keyword) {
                return astgen.failNode(
                    fn_proto.ast.callconv_expr,
                    "explicit callconv incompatible with inline keyword",
                    .{},
                );
            }
            break :blk try AstGen.expr(
                &decl_gz,
                &decl_gz.base,
                .{ .ty = .calling_convention_type },
                fn_proto.ast.callconv_expr,
            );
        } else if (is_extern) {
            // note: https://github.com/ziglang/zig/issues/5269
            break :blk .calling_convention_c;
        } else if (has_inline_keyword) {
            break :blk .calling_convention_inline;
        } else {
            break :blk .none;
        }
    };

    const func_inst: Zir.Inst.Ref = if (body_node == 0) func: {
        if (!is_extern) {
            return astgen.failTok(fn_proto.ast.fn_token, "non-extern function has no body", .{});
        }
        if (is_inferred_error) {
            return astgen.failTok(maybe_bang, "function prototype may not have inferred error set", .{});
        }
        break :func try decl_gz.addFunc(.{
            .src_node = decl_node,
            .ret_ty = return_type_inst,
            .param_types = param_types,
            .body = &[0]Zir.Inst.Index{},
            .cc = cc,
            .align_inst = .none, // passed in the per-decl data
            .lib_name = lib_name,
            .is_var_args = is_var_args,
            .is_inferred_error = false,
            .is_test = false,
            .is_extern = true,
        });
    } else func: {
        if (is_var_args) {
            return astgen.failTok(fn_proto.ast.fn_token, "non-extern function is variadic", .{});
        }

        var fn_gz: GenZir = .{
            .force_comptime = false,
            .in_defer = false,
            .decl_node_index = fn_proto.ast.proto_node,
            .decl_line = decl_gz.decl_line,
            .parent = &decl_gz.base,
            .astgen = astgen,
        };
        defer fn_gz.instructions.deinit(gpa);

        const prev_fn_block = astgen.fn_block;
        astgen.fn_block = &fn_gz;
        defer astgen.fn_block = prev_fn_block;

        // Iterate over the parameters. We put the param names as the first N
        // items inside `extra` so that debug info later can refer to the parameter names
        // even while the respective source code is unloaded.
        try astgen.extra.ensureUnusedCapacity(gpa, param_count);

        {
            var params_scope = &fn_gz.base;
            var i: usize = 0;
            var it = fn_proto.iterate(tree.*);
            while (it.next()) |param| : (i += 1) {
                const name_token = param.name_token orelse {
                    if (param.anytype_ellipsis3) |tok| {
                        return astgen.failTok(tok, "missing parameter name", .{});
                    } else {
                        return astgen.failNode(param.type_expr, "missing parameter name", .{});
                    }
                };
                if (param.type_expr != 0)
                    _ = try typeExpr(&fn_gz, params_scope, param.type_expr);
                if (mem.eql(u8, "_", tree.tokenSlice(name_token)))
                    continue;
                const param_name = try astgen.identAsString(name_token);
                // Create an arg instruction. This is needed to emit a semantic analysis
                // error for shadowing decls.
                try astgen.detectLocalShadowing(params_scope, param_name, name_token);
                const arg_inst = try fn_gz.addStrTok(.arg, param_name, name_token);
                const sub_scope = try astgen.arena.create(Scope.LocalVal);
                sub_scope.* = .{
                    .parent = params_scope,
                    .gen_zir = &fn_gz,
                    .name = param_name,
                    .inst = arg_inst,
                    .token_src = name_token,
                    .id_cat = .@"function parameter",
                };
                params_scope = &sub_scope.base;

                // Additionally put the param name into `string_bytes` and reference it with
                // `extra` so that we have access to the data in codegen, for debug info.
                const str_index = try astgen.identAsString(name_token);
                try astgen.extra.append(astgen.gpa, str_index);
            }
            _ = try typeExpr(&fn_gz, params_scope, fn_proto.ast.return_type);

            _ = try expr(&fn_gz, params_scope, .none, body_node);
            try checkUsed(gz, &fn_gz.base, params_scope);
        }

        const need_implicit_ret = blk: {
            if (fn_gz.instructions.items.len == 0)
                break :blk true;
            const last = fn_gz.instructions.items[fn_gz.instructions.items.len - 1];
            const zir_tags = astgen.instructions.items(.tag);
            break :blk !zir_tags[last].isNoReturn();
        };
        if (need_implicit_ret) {
            // Since we are adding the return instruction here, we must handle the coercion.
            // We do this by using the `ret_coerce` instruction.
            _ = try fn_gz.addUnTok(.ret_coerce, .void_value, tree.lastToken(body_node));
        }

        break :func try decl_gz.addFunc(.{
            .src_node = decl_node,
            .ret_ty = return_type_inst,
            .param_types = param_types,
            .body = fn_gz.instructions.items,
            .cc = cc,
            .align_inst = .none, // passed in the per-decl data
            .lib_name = lib_name,
            .is_var_args = is_var_args,
            .is_inferred_error = is_inferred_error,
            .is_test = false,
            .is_extern = false,
        });
    };

    // We add this at the end so that its instruction index marks the end range
    // of the top level declaration.
    _ = try decl_gz.addBreak(.break_inline, block_inst, func_inst);
    try decl_gz.setBlockBody(block_inst);

    try wip_decls.payload.ensureUnusedCapacity(gpa, 9);
    {
        const contents_hash = std.zig.hashSrc(tree.getNodeSource(decl_node));
        const casted = @bitCast([4]u32, contents_hash);
        wip_decls.payload.appendSliceAssumeCapacity(&casted);
    }
    {
        const line_delta = decl_gz.decl_line - gz.decl_line;
        wip_decls.payload.appendAssumeCapacity(line_delta);
    }
    wip_decls.payload.appendAssumeCapacity(fn_name_str_index);
    wip_decls.payload.appendAssumeCapacity(block_inst);
    if (align_inst != .none) {
        wip_decls.payload.appendAssumeCapacity(@enumToInt(align_inst));
    }
    if (section_inst != .none) {
        wip_decls.payload.appendAssumeCapacity(@enumToInt(section_inst));
    }
}

fn globalVarDecl(
    astgen: *AstGen,
    gz: *GenZir,
    scope: *Scope,
    wip_decls: *WipDecls,
    node: ast.Node.Index,
    var_decl: ast.full.VarDecl,
) InnerError!void {
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const token_tags = tree.tokens.items(.tag);

    const is_mutable = token_tags[var_decl.ast.mut_token] == .keyword_var;
    // We do this at the beginning so that the instruction index marks the range start
    // of the top level declaration.
    const block_inst = try gz.addBlock(.block_inline, node);

    const name_token = var_decl.ast.mut_token + 1;
    const name_str_index = try astgen.identAsString(name_token);

    try astgen.declareNewName(scope, name_str_index, node);

    var block_scope: GenZir = .{
        .parent = scope,
        .decl_node_index = node,
        .decl_line = gz.calcLine(node),
        .astgen = astgen,
        .force_comptime = true,
        .in_defer = false,
        .anon_name_strategy = .parent,
    };
    defer block_scope.instructions.deinit(gpa);

    const is_pub = var_decl.visib_token != null;
    const is_export = blk: {
        const maybe_export_token = var_decl.extern_export_token orelse break :blk false;
        break :blk token_tags[maybe_export_token] == .keyword_export;
    };
    const is_extern = blk: {
        const maybe_extern_token = var_decl.extern_export_token orelse break :blk false;
        break :blk token_tags[maybe_extern_token] == .keyword_extern;
    };
    const align_inst: Zir.Inst.Ref = if (var_decl.ast.align_node == 0) .none else inst: {
        break :inst try expr(&block_scope, &block_scope.base, align_rl, var_decl.ast.align_node);
    };
    const section_inst: Zir.Inst.Ref = if (var_decl.ast.section_node == 0) .none else inst: {
        break :inst try comptimeExpr(&block_scope, &block_scope.base, .{ .ty = .const_slice_u8_type }, var_decl.ast.section_node);
    };
    try wip_decls.next(gpa, is_pub, is_export, align_inst != .none, section_inst != .none);

    const is_threadlocal = if (var_decl.threadlocal_token) |tok| blk: {
        if (!is_mutable) {
            return astgen.failTok(tok, "threadlocal variable cannot be constant", .{});
        }
        break :blk true;
    } else false;

    const lib_name: u32 = if (var_decl.lib_name) |lib_name_token| blk: {
        const lib_name_str = try astgen.strLitAsString(lib_name_token);
        break :blk lib_name_str.index;
    } else 0;

    assert(var_decl.comptime_token == null); // handled by parser

    const var_inst: Zir.Inst.Ref = if (var_decl.ast.init_node != 0) vi: {
        if (is_extern) {
            return astgen.failNode(
                var_decl.ast.init_node,
                "extern variables have no initializers",
                .{},
            );
        }

        const type_inst: Zir.Inst.Ref = if (var_decl.ast.type_node != 0)
            try expr(
                &block_scope,
                &block_scope.base,
                .{ .ty = .type_type },
                var_decl.ast.type_node,
            )
        else
            .none;

        const init_inst = try expr(
            &block_scope,
            &block_scope.base,
            if (type_inst != .none) .{ .ty = type_inst } else .none,
            var_decl.ast.init_node,
        );

        if (is_mutable) {
            const var_inst = try block_scope.addVar(.{
                .var_type = type_inst,
                .lib_name = 0,
                .align_inst = .none, // passed via the decls data
                .init = init_inst,
                .is_extern = false,
                .is_threadlocal = is_threadlocal,
            });
            break :vi var_inst;
        } else {
            break :vi init_inst;
        }
    } else if (!is_extern) {
        return astgen.failNode(node, "variables must be initialized", .{});
    } else if (var_decl.ast.type_node != 0) vi: {
        // Extern variable which has an explicit type.
        const type_inst = try typeExpr(&block_scope, &block_scope.base, var_decl.ast.type_node);

        const var_inst = try block_scope.addVar(.{
            .var_type = type_inst,
            .lib_name = lib_name,
            .align_inst = .none, // passed via the decls data
            .init = .none,
            .is_extern = true,
            .is_threadlocal = is_threadlocal,
        });
        break :vi var_inst;
    } else {
        return astgen.failNode(node, "unable to infer variable type", .{});
    };
    // We do this at the end so that the instruction index marks the end
    // range of a top level declaration.
    _ = try block_scope.addBreak(.break_inline, block_inst, var_inst);
    try block_scope.setBlockBody(block_inst);

    try wip_decls.payload.ensureUnusedCapacity(gpa, 9);
    {
        const contents_hash = std.zig.hashSrc(tree.getNodeSource(node));
        const casted = @bitCast([4]u32, contents_hash);
        wip_decls.payload.appendSliceAssumeCapacity(&casted);
    }
    {
        const line_delta = block_scope.decl_line - gz.decl_line;
        wip_decls.payload.appendAssumeCapacity(line_delta);
    }
    wip_decls.payload.appendAssumeCapacity(name_str_index);
    wip_decls.payload.appendAssumeCapacity(block_inst);
    if (align_inst != .none) {
        wip_decls.payload.appendAssumeCapacity(@enumToInt(align_inst));
    }
    if (section_inst != .none) {
        wip_decls.payload.appendAssumeCapacity(@enumToInt(section_inst));
    }
}

fn comptimeDecl(
    astgen: *AstGen,
    gz: *GenZir,
    scope: *Scope,
    wip_decls: *WipDecls,
    node: ast.Node.Index,
) InnerError!void {
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const body_node = node_datas[node].lhs;

    // Up top so the ZIR instruction index marks the start range of this
    // top-level declaration.
    const block_inst = try gz.addBlock(.block_inline, node);
    try wip_decls.next(gpa, false, false, false, false);

    var decl_block: GenZir = .{
        .force_comptime = true,
        .in_defer = false,
        .decl_node_index = node,
        .decl_line = gz.calcLine(node),
        .parent = scope,
        .astgen = astgen,
    };
    defer decl_block.instructions.deinit(gpa);

    const block_result = try expr(&decl_block, &decl_block.base, .none, body_node);
    if (decl_block.instructions.items.len == 0 or !decl_block.refIsNoReturn(block_result)) {
        _ = try decl_block.addBreak(.break_inline, block_inst, .void_value);
    }
    try decl_block.setBlockBody(block_inst);

    try wip_decls.payload.ensureUnusedCapacity(gpa, 7);
    {
        const contents_hash = std.zig.hashSrc(tree.getNodeSource(node));
        const casted = @bitCast([4]u32, contents_hash);
        wip_decls.payload.appendSliceAssumeCapacity(&casted);
    }
    {
        const line_delta = decl_block.decl_line - gz.decl_line;
        wip_decls.payload.appendAssumeCapacity(line_delta);
    }
    wip_decls.payload.appendAssumeCapacity(0);
    wip_decls.payload.appendAssumeCapacity(block_inst);
}

fn usingnamespaceDecl(
    astgen: *AstGen,
    gz: *GenZir,
    scope: *Scope,
    wip_decls: *WipDecls,
    node: ast.Node.Index,
) InnerError!void {
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);

    const type_expr = node_datas[node].lhs;
    const is_pub = blk: {
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);
        const main_token = main_tokens[node];
        break :blk (main_token > 0 and token_tags[main_token - 1] == .keyword_pub);
    };
    // Up top so the ZIR instruction index marks the start range of this
    // top-level declaration.
    const block_inst = try gz.addBlock(.block_inline, node);
    try wip_decls.next(gpa, is_pub, true, false, false);

    var decl_block: GenZir = .{
        .force_comptime = true,
        .in_defer = false,
        .decl_node_index = node,
        .decl_line = gz.calcLine(node),
        .parent = scope,
        .astgen = astgen,
    };
    defer decl_block.instructions.deinit(gpa);

    const namespace_inst = try typeExpr(&decl_block, &decl_block.base, type_expr);
    _ = try decl_block.addBreak(.break_inline, block_inst, namespace_inst);
    try decl_block.setBlockBody(block_inst);

    try wip_decls.payload.ensureUnusedCapacity(gpa, 7);
    {
        const contents_hash = std.zig.hashSrc(tree.getNodeSource(node));
        const casted = @bitCast([4]u32, contents_hash);
        wip_decls.payload.appendSliceAssumeCapacity(&casted);
    }
    {
        const line_delta = decl_block.decl_line - gz.decl_line;
        wip_decls.payload.appendAssumeCapacity(line_delta);
    }
    wip_decls.payload.appendAssumeCapacity(0);
    wip_decls.payload.appendAssumeCapacity(block_inst);
}

fn testDecl(
    astgen: *AstGen,
    gz: *GenZir,
    scope: *Scope,
    wip_decls: *WipDecls,
    node: ast.Node.Index,
) InnerError!void {
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const body_node = node_datas[node].rhs;

    // Up top so the ZIR instruction index marks the start range of this
    // top-level declaration.
    const block_inst = try gz.addBlock(.block_inline, node);

    try wip_decls.next(gpa, false, false, false, false);

    var decl_block: GenZir = .{
        .force_comptime = true,
        .in_defer = false,
        .decl_node_index = node,
        .decl_line = gz.calcLine(node),
        .parent = scope,
        .astgen = astgen,
    };
    defer decl_block.instructions.deinit(gpa);

    const test_name: u32 = blk: {
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);
        const test_token = main_tokens[node];
        const str_lit_token = test_token + 1;
        if (token_tags[str_lit_token] == .string_literal) {
            break :blk try astgen.testNameString(str_lit_token);
        }
        // String table index 1 has a special meaning here of test decl with no name.
        break :blk 1;
    };

    var fn_block: GenZir = .{
        .force_comptime = false,
        .in_defer = false,
        .decl_node_index = node,
        .decl_line = decl_block.decl_line,
        .parent = &decl_block.base,
        .astgen = astgen,
    };
    defer fn_block.instructions.deinit(gpa);

    const prev_fn_block = astgen.fn_block;
    astgen.fn_block = &fn_block;
    defer astgen.fn_block = prev_fn_block;

    const block_result = try expr(&fn_block, &fn_block.base, .none, body_node);
    if (fn_block.instructions.items.len == 0 or !fn_block.refIsNoReturn(block_result)) {
        // Since we are adding the return instruction here, we must handle the coercion.
        // We do this by using the `ret_coerce` instruction.
        _ = try fn_block.addUnTok(.ret_coerce, .void_value, tree.lastToken(body_node));
    }

    const func_inst = try decl_block.addFunc(.{
        .src_node = node,
        .ret_ty = .void_type,
        .param_types = &[0]Zir.Inst.Ref{},
        .body = fn_block.instructions.items,
        .cc = .none,
        .align_inst = .none,
        .lib_name = 0,
        .is_var_args = false,
        .is_inferred_error = true,
        .is_test = true,
        .is_extern = false,
    });

    _ = try decl_block.addBreak(.break_inline, block_inst, func_inst);
    try decl_block.setBlockBody(block_inst);

    try wip_decls.payload.ensureUnusedCapacity(gpa, 7);
    {
        const contents_hash = std.zig.hashSrc(tree.getNodeSource(node));
        const casted = @bitCast([4]u32, contents_hash);
        wip_decls.payload.appendSliceAssumeCapacity(&casted);
    }
    {
        const line_delta = decl_block.decl_line - gz.decl_line;
        wip_decls.payload.appendAssumeCapacity(line_delta);
    }
    wip_decls.payload.appendAssumeCapacity(test_name);
    wip_decls.payload.appendAssumeCapacity(block_inst);
}

fn structDeclInner(
    gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
    container_decl: ast.full.ContainerDecl,
    layout: std.builtin.TypeInfo.ContainerLayout,
) InnerError!Zir.Inst.Ref {
    if (container_decl.ast.members.len == 0) {
        const decl_inst = try gz.reserveInstructionIndex();
        try gz.setStruct(decl_inst, .{
            .src_node = node,
            .layout = layout,
            .fields_len = 0,
            .body_len = 0,
            .decls_len = 0,
        });
        return indexToRef(decl_inst);
    }

    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const node_tags = tree.nodes.items(.tag);
    const node_datas = tree.nodes.items(.data);

    // The struct_decl instruction introduces a scope in which the decls of the struct
    // are in scope, so that field types, alignments, and default value expressions
    // can refer to decls within the struct itself.
    var block_scope: GenZir = .{
        .parent = scope,
        .decl_node_index = node,
        .decl_line = gz.calcLine(node),
        .astgen = astgen,
        .force_comptime = true,
        .in_defer = false,
    };
    defer block_scope.instructions.deinit(gpa);

    var namespace: Scope.Namespace = .{ .parent = scope };
    defer namespace.decls.deinit(gpa);

    var wip_decls: WipDecls = .{};
    defer wip_decls.deinit(gpa);

    // We don't know which members are fields until we iterate, so cannot do
    // an accurate ensureCapacity yet.
    var fields_data = ArrayListUnmanaged(u32){};
    defer fields_data.deinit(gpa);

    const bits_per_field = 4;
    const fields_per_u32 = 32 / bits_per_field;
    // We only need this if there are greater than fields_per_u32 fields.
    var bit_bag = ArrayListUnmanaged(u32){};
    defer bit_bag.deinit(gpa);

    var cur_bit_bag: u32 = 0;
    var field_index: usize = 0;
    for (container_decl.ast.members) |member_node| {
        const member = switch (node_tags[member_node]) {
            .container_field_init => tree.containerFieldInit(member_node),
            .container_field_align => tree.containerFieldAlign(member_node),
            .container_field => tree.containerField(member_node),

            .fn_decl => {
                const fn_proto = node_datas[member_node].lhs;
                const body = node_datas[member_node].rhs;
                switch (node_tags[fn_proto]) {
                    .fn_proto_simple => {
                        var params: [1]ast.Node.Index = undefined;
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoSimple(&params, fn_proto)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto_multi => {
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoMulti(fn_proto)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto_one => {
                        var params: [1]ast.Node.Index = undefined;
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoOne(&params, fn_proto)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto => {
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProto(fn_proto)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    else => unreachable,
                }
            },
            .fn_proto_simple => {
                var params: [1]ast.Node.Index = undefined;
                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoSimple(&params, member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .fn_proto_multi => {
                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoMulti(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .fn_proto_one => {
                var params: [1]ast.Node.Index = undefined;
                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoOne(&params, member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .fn_proto => {
                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProto(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },

            .global_var_decl => {
                astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.globalVarDecl(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .local_var_decl => {
                astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.localVarDecl(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .simple_var_decl => {
                astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.simpleVarDecl(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .aligned_var_decl => {
                astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.alignedVarDecl(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },

            .@"comptime" => {
                astgen.comptimeDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .@"usingnamespace" => {
                astgen.usingnamespaceDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .test_decl => {
                astgen.testDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            else => unreachable,
        };
        if (field_index % fields_per_u32 == 0 and field_index != 0) {
            try bit_bag.append(gpa, cur_bit_bag);
            cur_bit_bag = 0;
        }
        try fields_data.ensureUnusedCapacity(gpa, 4);

        const field_name = try astgen.identAsString(member.ast.name_token);
        fields_data.appendAssumeCapacity(field_name);

        if (member.ast.type_expr == 0) {
            return astgen.failTok(member.ast.name_token, "struct field missing type", .{});
        }

        const field_type: Zir.Inst.Ref = if (node_tags[member.ast.type_expr] == .@"anytype")
            .none
        else
            try typeExpr(&block_scope, &block_scope.base, member.ast.type_expr);
        fields_data.appendAssumeCapacity(@enumToInt(field_type));

        const have_align = member.ast.align_expr != 0;
        const have_value = member.ast.value_expr != 0;
        const is_comptime = member.comptime_token != null;
        const unused = false;
        cur_bit_bag = (cur_bit_bag >> bits_per_field) |
            (@as(u32, @boolToInt(have_align)) << 28) |
            (@as(u32, @boolToInt(have_value)) << 29) |
            (@as(u32, @boolToInt(is_comptime)) << 30) |
            (@as(u32, @boolToInt(unused)) << 31);

        if (have_align) {
            const align_inst = try expr(&block_scope, &block_scope.base, align_rl, member.ast.align_expr);
            fields_data.appendAssumeCapacity(@enumToInt(align_inst));
        }
        if (have_value) {
            const rl: ResultLoc = if (field_type == .none) .none else .{ .ty = field_type };

            const default_inst = try expr(&block_scope, &block_scope.base, rl, member.ast.value_expr);
            fields_data.appendAssumeCapacity(@enumToInt(default_inst));
        } else if (member.comptime_token) |comptime_token| {
            return astgen.failTok(comptime_token, "comptime field without default initialization value", .{});
        }

        field_index += 1;
    }
    {
        const empty_slot_count = fields_per_u32 - (field_index % fields_per_u32);
        if (empty_slot_count < fields_per_u32) {
            cur_bit_bag >>= @intCast(u5, empty_slot_count * bits_per_field);
        }
    }
    {
        const empty_slot_count = WipDecls.fields_per_u32 - (wip_decls.decl_index % WipDecls.fields_per_u32);
        if (empty_slot_count < WipDecls.fields_per_u32) {
            wip_decls.cur_bit_bag >>= @intCast(u5, empty_slot_count * WipDecls.bits_per_field);
        }
    }

    const decl_inst = try gz.reserveInstructionIndex();
    if (block_scope.instructions.items.len != 0) {
        _ = try block_scope.addBreak(.break_inline, decl_inst, .void_value);
    }

    try gz.setStruct(decl_inst, .{
        .src_node = node,
        .layout = layout,
        .body_len = @intCast(u32, block_scope.instructions.items.len),
        .fields_len = @intCast(u32, field_index),
        .decls_len = @intCast(u32, wip_decls.decl_index),
    });

    try astgen.extra.ensureUnusedCapacity(gpa, bit_bag.items.len +
        @boolToInt(field_index != 0) + fields_data.items.len +
        block_scope.instructions.items.len +
        wip_decls.bit_bag.items.len + @boolToInt(wip_decls.decl_index != 0) +
        wip_decls.payload.items.len);
    astgen.extra.appendSliceAssumeCapacity(wip_decls.bit_bag.items); // Likely empty.
    if (wip_decls.decl_index != 0) {
        astgen.extra.appendAssumeCapacity(wip_decls.cur_bit_bag);
    }
    astgen.extra.appendSliceAssumeCapacity(wip_decls.payload.items);

    astgen.extra.appendSliceAssumeCapacity(block_scope.instructions.items);

    astgen.extra.appendSliceAssumeCapacity(bit_bag.items); // Likely empty.
    if (field_index != 0) {
        astgen.extra.appendAssumeCapacity(cur_bit_bag);
    }
    astgen.extra.appendSliceAssumeCapacity(fields_data.items);

    return indexToRef(decl_inst);
}

fn unionDeclInner(
    gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
    members: []const ast.Node.Index,
    layout: std.builtin.TypeInfo.ContainerLayout,
    arg_inst: Zir.Inst.Ref,
    have_auto_enum: bool,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const node_tags = tree.nodes.items(.tag);
    const node_datas = tree.nodes.items(.data);

    // The union_decl instruction introduces a scope in which the decls of the union
    // are in scope, so that field types, alignments, and default value expressions
    // can refer to decls within the union itself.
    var block_scope: GenZir = .{
        .parent = scope,
        .decl_node_index = node,
        .decl_line = gz.calcLine(node),
        .astgen = astgen,
        .force_comptime = true,
        .in_defer = false,
    };
    defer block_scope.instructions.deinit(gpa);

    var namespace: Scope.Namespace = .{ .parent = scope };
    defer namespace.decls.deinit(gpa);

    var wip_decls: WipDecls = .{};
    defer wip_decls.deinit(gpa);

    // We don't know which members are fields until we iterate, so cannot do
    // an accurate ensureCapacity yet.
    var fields_data = ArrayListUnmanaged(u32){};
    defer fields_data.deinit(gpa);

    const bits_per_field = 4;
    const fields_per_u32 = 32 / bits_per_field;
    // We only need this if there are greater than fields_per_u32 fields.
    var bit_bag = ArrayListUnmanaged(u32){};
    defer bit_bag.deinit(gpa);

    var cur_bit_bag: u32 = 0;
    var field_index: usize = 0;
    for (members) |member_node| {
        const member = switch (node_tags[member_node]) {
            .container_field_init => tree.containerFieldInit(member_node),
            .container_field_align => tree.containerFieldAlign(member_node),
            .container_field => tree.containerField(member_node),

            .fn_decl => {
                const fn_proto = node_datas[member_node].lhs;
                const body = node_datas[member_node].rhs;
                switch (node_tags[fn_proto]) {
                    .fn_proto_simple => {
                        var params: [1]ast.Node.Index = undefined;
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoSimple(&params, fn_proto)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto_multi => {
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoMulti(fn_proto)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto_one => {
                        var params: [1]ast.Node.Index = undefined;
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoOne(&params, fn_proto)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto => {
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProto(fn_proto)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    else => unreachable,
                }
            },
            .fn_proto_simple => {
                var params: [1]ast.Node.Index = undefined;
                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoSimple(&params, member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .fn_proto_multi => {
                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoMulti(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .fn_proto_one => {
                var params: [1]ast.Node.Index = undefined;
                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoOne(&params, member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .fn_proto => {
                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProto(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },

            .global_var_decl => {
                astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.globalVarDecl(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .local_var_decl => {
                astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.localVarDecl(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .simple_var_decl => {
                astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.simpleVarDecl(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .aligned_var_decl => {
                astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.alignedVarDecl(member_node)) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },

            .@"comptime" => {
                astgen.comptimeDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .@"usingnamespace" => {
                astgen.usingnamespaceDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            .test_decl => {
                astgen.testDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.AnalysisFail => {},
                };
                continue;
            },
            else => unreachable,
        };
        if (field_index % fields_per_u32 == 0 and field_index != 0) {
            try bit_bag.append(gpa, cur_bit_bag);
            cur_bit_bag = 0;
        }
        if (member.comptime_token) |comptime_token| {
            return astgen.failTok(comptime_token, "union fields cannot be marked comptime", .{});
        }
        try fields_data.ensureUnusedCapacity(gpa, if (node_tags[member.ast.type_expr] != .@"anytype") 4 else 3);

        const field_name = try astgen.identAsString(member.ast.name_token);
        fields_data.appendAssumeCapacity(field_name);

        const have_type = member.ast.type_expr != 0;
        const have_align = member.ast.align_expr != 0;
        const have_value = member.ast.value_expr != 0;
        const unused = false;
        cur_bit_bag = (cur_bit_bag >> bits_per_field) |
            (@as(u32, @boolToInt(have_type)) << 28) |
            (@as(u32, @boolToInt(have_align)) << 29) |
            (@as(u32, @boolToInt(have_value)) << 30) |
            (@as(u32, @boolToInt(unused)) << 31);

        if (have_type and node_tags[member.ast.type_expr] != .@"anytype") {
            const field_type = try typeExpr(&block_scope, &block_scope.base, member.ast.type_expr);
            fields_data.appendAssumeCapacity(@enumToInt(field_type));
        }
        if (have_align) {
            const align_inst = try expr(&block_scope, &block_scope.base, .{ .ty = .u32_type }, member.ast.align_expr);
            fields_data.appendAssumeCapacity(@enumToInt(align_inst));
        }
        if (have_value) {
            if (arg_inst == .none) {
                return astgen.failNodeNotes(
                    node,
                    "explicitly valued tagged union missing integer tag type",
                    .{},
                    &[_]u32{
                        try astgen.errNoteNode(
                            member.ast.value_expr,
                            "tag value specified here",
                            .{},
                        ),
                    },
                );
            }
            const tag_value = try expr(&block_scope, &block_scope.base, .{ .ty = arg_inst }, member.ast.value_expr);
            fields_data.appendAssumeCapacity(@enumToInt(tag_value));
        }

        field_index += 1;
    }
    if (field_index == 0) {
        return astgen.failNode(node, "union declarations must have at least one tag", .{});
    }
    {
        const empty_slot_count = fields_per_u32 - (field_index % fields_per_u32);
        if (empty_slot_count < fields_per_u32) {
            cur_bit_bag >>= @intCast(u5, empty_slot_count * bits_per_field);
        }
    }
    {
        const empty_slot_count = WipDecls.fields_per_u32 - (wip_decls.decl_index % WipDecls.fields_per_u32);
        if (empty_slot_count < WipDecls.fields_per_u32) {
            wip_decls.cur_bit_bag >>= @intCast(u5, empty_slot_count * WipDecls.bits_per_field);
        }
    }

    const decl_inst = try gz.reserveInstructionIndex();
    if (block_scope.instructions.items.len != 0) {
        _ = try block_scope.addBreak(.break_inline, decl_inst, .void_value);
    }

    try gz.setUnion(decl_inst, .{
        .src_node = node,
        .layout = layout,
        .tag_type = arg_inst,
        .body_len = @intCast(u32, block_scope.instructions.items.len),
        .fields_len = @intCast(u32, field_index),
        .decls_len = @intCast(u32, wip_decls.decl_index),
        .auto_enum_tag = have_auto_enum,
    });

    try astgen.extra.ensureUnusedCapacity(gpa, bit_bag.items.len +
        1 + fields_data.items.len +
        block_scope.instructions.items.len +
        wip_decls.bit_bag.items.len + @boolToInt(wip_decls.decl_index != 0) +
        wip_decls.payload.items.len);
    astgen.extra.appendSliceAssumeCapacity(wip_decls.bit_bag.items); // Likely empty.
    if (wip_decls.decl_index != 0) {
        astgen.extra.appendAssumeCapacity(wip_decls.cur_bit_bag);
    }
    astgen.extra.appendSliceAssumeCapacity(wip_decls.payload.items);

    astgen.extra.appendSliceAssumeCapacity(block_scope.instructions.items);

    astgen.extra.appendSliceAssumeCapacity(bit_bag.items); // Likely empty.
    astgen.extra.appendAssumeCapacity(cur_bit_bag);
    astgen.extra.appendSliceAssumeCapacity(fields_data.items);

    return indexToRef(decl_inst);
}

fn containerDecl(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    container_decl: ast.full.ContainerDecl,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const token_tags = tree.tokens.items(.tag);
    const node_tags = tree.nodes.items(.tag);
    const node_datas = tree.nodes.items(.data);

    const prev_fn_block = astgen.fn_block;
    astgen.fn_block = null;
    defer astgen.fn_block = prev_fn_block;

    // We must not create any types until Sema. Here the goal is only to generate
    // ZIR for all the field types, alignments, and default value expressions.

    const arg_inst: Zir.Inst.Ref = if (container_decl.ast.arg != 0)
        try comptimeExpr(gz, scope, .{ .ty = .type_type }, container_decl.ast.arg)
    else
        .none;

    switch (token_tags[container_decl.ast.main_token]) {
        .keyword_struct => {
            const layout = if (container_decl.layout_token) |t| switch (token_tags[t]) {
                .keyword_packed => std.builtin.TypeInfo.ContainerLayout.Packed,
                .keyword_extern => std.builtin.TypeInfo.ContainerLayout.Extern,
                else => unreachable,
            } else std.builtin.TypeInfo.ContainerLayout.Auto;

            assert(arg_inst == .none);

            const result = try structDeclInner(gz, scope, node, container_decl, layout);
            return rvalue(gz, rl, result, node);
        },
        .keyword_union => {
            const layout = if (container_decl.layout_token) |t| switch (token_tags[t]) {
                .keyword_packed => std.builtin.TypeInfo.ContainerLayout.Packed,
                .keyword_extern => std.builtin.TypeInfo.ContainerLayout.Extern,
                else => unreachable,
            } else std.builtin.TypeInfo.ContainerLayout.Auto;

            const have_auto_enum = container_decl.ast.enum_token != null;

            const result = try unionDeclInner(gz, scope, node, container_decl.ast.members, layout, arg_inst, have_auto_enum);
            return rvalue(gz, rl, result, node);
        },
        .keyword_enum => {
            if (container_decl.layout_token) |t| {
                return astgen.failTok(t, "enums do not support 'packed' or 'extern'; instead provide an explicit integer tag type", .{});
            }
            // Count total fields as well as how many have explicitly provided tag values.
            const counts = blk: {
                var values: usize = 0;
                var total_fields: usize = 0;
                var decls: usize = 0;
                var nonexhaustive_node: ast.Node.Index = 0;
                for (container_decl.ast.members) |member_node| {
                    const member = switch (node_tags[member_node]) {
                        .container_field_init => tree.containerFieldInit(member_node),
                        .container_field_align => tree.containerFieldAlign(member_node),
                        .container_field => tree.containerField(member_node),
                        else => {
                            decls += 1;
                            continue;
                        },
                    };
                    if (member.comptime_token) |comptime_token| {
                        return astgen.failTok(comptime_token, "enum fields cannot be marked comptime", .{});
                    }
                    if (member.ast.type_expr != 0) {
                        return astgen.failNodeNotes(
                            member.ast.type_expr,
                            "enum fields do not have types",
                            .{},
                            &[_]u32{
                                try astgen.errNoteNode(
                                    node,
                                    "consider 'union(enum)' here to make it a tagged union",
                                    .{},
                                ),
                            },
                        );
                    }
                    // Alignment expressions in enums are caught by the parser.
                    assert(member.ast.align_expr == 0);

                    const name_token = member.ast.name_token;
                    if (mem.eql(u8, tree.tokenSlice(name_token), "_")) {
                        if (nonexhaustive_node != 0) {
                            return astgen.failNodeNotes(
                                member_node,
                                "redundant non-exhaustive enum mark",
                                .{},
                                &[_]u32{
                                    try astgen.errNoteNode(
                                        nonexhaustive_node,
                                        "other mark here",
                                        .{},
                                    ),
                                },
                            );
                        }
                        nonexhaustive_node = member_node;
                        if (member.ast.value_expr != 0) {
                            return astgen.failNode(member.ast.value_expr, "'_' is used to mark an enum as non-exhaustive and cannot be assigned a value", .{});
                        }
                        continue;
                    }
                    total_fields += 1;
                    if (member.ast.value_expr != 0) {
                        if (arg_inst == .none) {
                            return astgen.failNode(member.ast.value_expr, "value assigned to enum tag with inferred tag type", .{});
                        }
                        values += 1;
                    }
                }
                break :blk .{
                    .total_fields = total_fields,
                    .values = values,
                    .decls = decls,
                    .nonexhaustive_node = nonexhaustive_node,
                };
            };
            if (counts.total_fields == 0 and counts.nonexhaustive_node == 0) {
                // One can construct an enum with no tags, and it functions the same as `noreturn`. But
                // this is only useful for generic code; when explicitly using `enum {}` syntax, there
                // must be at least one tag.
                return astgen.failNode(node, "enum declarations must have at least one tag", .{});
            }
            if (counts.nonexhaustive_node != 0 and arg_inst == .none) {
                return astgen.failNodeNotes(
                    node,
                    "non-exhaustive enum missing integer tag type",
                    .{},
                    &[_]u32{
                        try astgen.errNoteNode(
                            counts.nonexhaustive_node,
                            "marked non-exhaustive here",
                            .{},
                        ),
                    },
                );
            }
            // In this case we must generate ZIR code for the tag values, similar to
            // how structs are handled above.
            const nonexhaustive = counts.nonexhaustive_node != 0;

            // The enum_decl instruction introduces a scope in which the decls of the enum
            // are in scope, so that tag values can refer to decls within the enum itself.
            var block_scope: GenZir = .{
                .parent = scope,
                .decl_node_index = node,
                .decl_line = gz.calcLine(node),
                .astgen = astgen,
                .force_comptime = true,
                .in_defer = false,
            };
            defer block_scope.instructions.deinit(gpa);

            var namespace: Scope.Namespace = .{ .parent = scope };
            defer namespace.decls.deinit(gpa);

            var wip_decls: WipDecls = .{};
            defer wip_decls.deinit(gpa);

            var fields_data = ArrayListUnmanaged(u32){};
            defer fields_data.deinit(gpa);

            try fields_data.ensureCapacity(gpa, counts.total_fields + counts.values);

            // We only need this if there are greater than 32 fields.
            var bit_bag = ArrayListUnmanaged(u32){};
            defer bit_bag.deinit(gpa);

            var cur_bit_bag: u32 = 0;
            var field_index: usize = 0;
            for (container_decl.ast.members) |member_node| {
                if (member_node == counts.nonexhaustive_node)
                    continue;
                const member = switch (node_tags[member_node]) {
                    .container_field_init => tree.containerFieldInit(member_node),
                    .container_field_align => tree.containerFieldAlign(member_node),
                    .container_field => tree.containerField(member_node),

                    .fn_decl => {
                        const fn_proto = node_datas[member_node].lhs;
                        const body = node_datas[member_node].rhs;
                        switch (node_tags[fn_proto]) {
                            .fn_proto_simple => {
                                var params: [1]ast.Node.Index = undefined;
                                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoSimple(&params, fn_proto)) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    error.AnalysisFail => {},
                                };
                                continue;
                            },
                            .fn_proto_multi => {
                                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoMulti(fn_proto)) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    error.AnalysisFail => {},
                                };
                                continue;
                            },
                            .fn_proto_one => {
                                var params: [1]ast.Node.Index = undefined;
                                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoOne(&params, fn_proto)) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    error.AnalysisFail => {},
                                };
                                continue;
                            },
                            .fn_proto => {
                                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProto(fn_proto)) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    error.AnalysisFail => {},
                                };
                                continue;
                            },
                            else => unreachable,
                        }
                    },
                    .fn_proto_simple => {
                        var params: [1]ast.Node.Index = undefined;
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoSimple(&params, member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto_multi => {
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoMulti(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto_one => {
                        var params: [1]ast.Node.Index = undefined;
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoOne(&params, member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto => {
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProto(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },

                    .global_var_decl => {
                        astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.globalVarDecl(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .local_var_decl => {
                        astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.localVarDecl(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .simple_var_decl => {
                        astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.simpleVarDecl(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .aligned_var_decl => {
                        astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.alignedVarDecl(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },

                    .@"comptime" => {
                        astgen.comptimeDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .@"usingnamespace" => {
                        astgen.usingnamespaceDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .test_decl => {
                        astgen.testDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    else => unreachable,
                };
                if (field_index % 32 == 0 and field_index != 0) {
                    try bit_bag.append(gpa, cur_bit_bag);
                    cur_bit_bag = 0;
                }
                assert(member.comptime_token == null);
                assert(member.ast.type_expr == 0);
                assert(member.ast.align_expr == 0);

                const field_name = try astgen.identAsString(member.ast.name_token);
                fields_data.appendAssumeCapacity(field_name);

                const have_value = member.ast.value_expr != 0;
                cur_bit_bag = (cur_bit_bag >> 1) |
                    (@as(u32, @boolToInt(have_value)) << 31);

                if (have_value) {
                    if (arg_inst == .none) {
                        return astgen.failNodeNotes(
                            node,
                            "explicitly valued enum missing integer tag type",
                            .{},
                            &[_]u32{
                                try astgen.errNoteNode(
                                    member.ast.value_expr,
                                    "tag value specified here",
                                    .{},
                                ),
                            },
                        );
                    }
                    const tag_value_inst = try expr(&block_scope, &block_scope.base, .{ .ty = arg_inst }, member.ast.value_expr);
                    fields_data.appendAssumeCapacity(@enumToInt(tag_value_inst));
                }

                field_index += 1;
            }
            {
                const empty_slot_count = 32 - (field_index % 32);
                if (empty_slot_count < 32) {
                    cur_bit_bag >>= @intCast(u5, empty_slot_count);
                }
            }
            {
                const empty_slot_count = WipDecls.fields_per_u32 - (wip_decls.decl_index % WipDecls.fields_per_u32);
                if (empty_slot_count < WipDecls.fields_per_u32) {
                    wip_decls.cur_bit_bag >>= @intCast(u5, empty_slot_count * WipDecls.bits_per_field);
                }
            }

            const decl_inst = try gz.reserveInstructionIndex();
            if (block_scope.instructions.items.len != 0) {
                _ = try block_scope.addBreak(.break_inline, decl_inst, .void_value);
            }

            try gz.setEnum(decl_inst, .{
                .src_node = node,
                .nonexhaustive = nonexhaustive,
                .tag_type = arg_inst,
                .body_len = @intCast(u32, block_scope.instructions.items.len),
                .fields_len = @intCast(u32, field_index),
                .decls_len = @intCast(u32, wip_decls.decl_index),
            });

            try astgen.extra.ensureUnusedCapacity(gpa, bit_bag.items.len +
                1 + fields_data.items.len +
                block_scope.instructions.items.len +
                wip_decls.bit_bag.items.len + @boolToInt(wip_decls.decl_index != 0) +
                wip_decls.payload.items.len);
            astgen.extra.appendSliceAssumeCapacity(wip_decls.bit_bag.items); // Likely empty.
            if (wip_decls.decl_index != 0) {
                astgen.extra.appendAssumeCapacity(wip_decls.cur_bit_bag);
            }
            astgen.extra.appendSliceAssumeCapacity(wip_decls.payload.items);

            astgen.extra.appendSliceAssumeCapacity(block_scope.instructions.items);
            astgen.extra.appendSliceAssumeCapacity(bit_bag.items); // Likely empty.
            astgen.extra.appendAssumeCapacity(cur_bit_bag);
            astgen.extra.appendSliceAssumeCapacity(fields_data.items);

            return rvalue(gz, rl, indexToRef(decl_inst), node);
        },
        .keyword_opaque => {
            var namespace: Scope.Namespace = .{ .parent = scope };
            defer namespace.decls.deinit(gpa);

            var wip_decls: WipDecls = .{};
            defer wip_decls.deinit(gpa);

            for (container_decl.ast.members) |member_node| {
                switch (node_tags[member_node]) {
                    .container_field_init, .container_field_align, .container_field => {},

                    .fn_decl => {
                        const fn_proto = node_datas[member_node].lhs;
                        const body = node_datas[member_node].rhs;
                        switch (node_tags[fn_proto]) {
                            .fn_proto_simple => {
                                var params: [1]ast.Node.Index = undefined;
                                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoSimple(&params, fn_proto)) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    error.AnalysisFail => {},
                                };
                                continue;
                            },
                            .fn_proto_multi => {
                                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoMulti(fn_proto)) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    error.AnalysisFail => {},
                                };
                                continue;
                            },
                            .fn_proto_one => {
                                var params: [1]ast.Node.Index = undefined;
                                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProtoOne(&params, fn_proto)) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    error.AnalysisFail => {},
                                };
                                continue;
                            },
                            .fn_proto => {
                                astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, body, tree.fnProto(fn_proto)) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    error.AnalysisFail => {},
                                };
                                continue;
                            },
                            else => unreachable,
                        }
                    },
                    .fn_proto_simple => {
                        var params: [1]ast.Node.Index = undefined;
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoSimple(&params, member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto_multi => {
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoMulti(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto_one => {
                        var params: [1]ast.Node.Index = undefined;
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProtoOne(&params, member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .fn_proto => {
                        astgen.fnDecl(gz, &namespace.base, &wip_decls, member_node, 0, tree.fnProto(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },

                    .global_var_decl => {
                        astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.globalVarDecl(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .local_var_decl => {
                        astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.localVarDecl(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .simple_var_decl => {
                        astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.simpleVarDecl(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .aligned_var_decl => {
                        astgen.globalVarDecl(gz, &namespace.base, &wip_decls, member_node, tree.alignedVarDecl(member_node)) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },

                    .@"comptime" => {
                        astgen.comptimeDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .@"usingnamespace" => {
                        astgen.usingnamespaceDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    .test_decl => {
                        astgen.testDecl(gz, &namespace.base, &wip_decls, member_node) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.AnalysisFail => {},
                        };
                        continue;
                    },
                    else => unreachable,
                }
            }
            {
                const empty_slot_count = WipDecls.fields_per_u32 - (wip_decls.decl_index % WipDecls.fields_per_u32);
                if (empty_slot_count < WipDecls.fields_per_u32) {
                    wip_decls.cur_bit_bag >>= @intCast(u5, empty_slot_count * WipDecls.bits_per_field);
                }
            }
            const tag: Zir.Inst.Tag = switch (gz.anon_name_strategy) {
                .parent => .opaque_decl,
                .anon => .opaque_decl_anon,
                .func => .opaque_decl_func,
            };
            const decl_inst = try gz.addBlock(tag, node);
            try gz.instructions.append(gpa, decl_inst);

            try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.OpaqueDecl).Struct.fields.len +
                wip_decls.bit_bag.items.len + @boolToInt(wip_decls.decl_index != 0) +
                wip_decls.payload.items.len);
            const zir_datas = astgen.instructions.items(.data);
            zir_datas[decl_inst].pl_node.payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.OpaqueDecl{
                .decls_len = @intCast(u32, wip_decls.decl_index),
            });
            astgen.extra.appendSliceAssumeCapacity(wip_decls.bit_bag.items); // Likely empty.
            if (wip_decls.decl_index != 0) {
                astgen.extra.appendAssumeCapacity(wip_decls.cur_bit_bag);
            }
            astgen.extra.appendSliceAssumeCapacity(wip_decls.payload.items);

            return rvalue(gz, rl, indexToRef(decl_inst), node);
        },
        else => unreachable,
    }
}

fn errorSetDecl(gz: *GenZir, rl: ResultLoc, node: ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);

    var field_names: std.ArrayListUnmanaged(u32) = .{};
    defer field_names.deinit(gpa);

    {
        const error_token = main_tokens[node];
        var tok_i = error_token + 2;
        var field_i: usize = 0;
        while (true) : (tok_i += 1) {
            switch (token_tags[tok_i]) {
                .doc_comment, .comma => {},
                .identifier => {
                    const str_index = try astgen.identAsString(tok_i);
                    try field_names.append(gpa, str_index);
                    field_i += 1;
                },
                .r_brace => break,
                else => unreachable,
            }
        }
    }

    const result = try gz.addPlNode(.error_set_decl, node, Zir.Inst.ErrorSetDecl{
        .fields_len = @intCast(u32, field_names.items.len),
    });
    try astgen.extra.appendSlice(gpa, field_names.items);
    return rvalue(gz, rl, result, node);
}

fn tryExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    operand_node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;

    const fn_block = astgen.fn_block orelse {
        return astgen.failNode(node, "'try' outside function scope", .{});
    };

    if (parent_gz.in_defer) return astgen.failNode(node, "'try' not allowed inside defer expression", .{});

    var block_scope = parent_gz.makeSubBlock(scope);
    block_scope.setBreakResultLoc(rl);
    defer block_scope.instructions.deinit(astgen.gpa);

    const operand_rl: ResultLoc = switch (block_scope.break_result_loc) {
        .ref => .ref,
        else => .none,
    };
    const err_ops = switch (rl) {
        // zig fmt: off
        .ref => [3]Zir.Inst.Tag{ .is_non_err_ptr, .err_union_code_ptr, .err_union_payload_unsafe_ptr },
        else => [3]Zir.Inst.Tag{ .is_non_err,     .err_union_code,     .err_union_payload_unsafe },
        // zig fmt: on
    };
    // This could be a pointer or value depending on the `operand_rl` parameter.
    // We cannot use `block_scope.break_result_loc` because that has the bare
    // type, whereas this expression has the optional type. Later we make
    // up for this fact by calling rvalue on the else branch.
    const operand = try expr(&block_scope, &block_scope.base, operand_rl, operand_node);
    const cond = try block_scope.addUnNode(err_ops[0], operand, node);
    const condbr = try block_scope.addCondBr(.condbr, node);

    const block = try parent_gz.addBlock(.block, node);
    try parent_gz.instructions.append(astgen.gpa, block);
    try block_scope.setBlockBody(block);

    var then_scope = parent_gz.makeSubBlock(scope);
    defer then_scope.instructions.deinit(astgen.gpa);

    block_scope.break_count += 1;
    // This could be a pointer or value depending on `err_ops[2]`.
    const unwrapped_payload = try then_scope.addUnNode(err_ops[2], operand, node);
    const then_result = switch (rl) {
        .ref => unwrapped_payload,
        else => try rvalue(&then_scope, block_scope.break_result_loc, unwrapped_payload, node),
    };

    var else_scope = parent_gz.makeSubBlock(scope);
    defer else_scope.instructions.deinit(astgen.gpa);

    const err_code = try else_scope.addUnNode(err_ops[1], operand, node);
    try genDefers(&else_scope, &fn_block.base, scope, .{ .both = err_code });
    const else_result = try else_scope.addUnNode(.ret_node, err_code, node);

    return finishThenElseBlock(
        parent_gz,
        rl,
        node,
        &block_scope,
        &then_scope,
        &else_scope,
        condbr,
        cond,
        then_result,
        else_result,
        block,
        block,
        .@"break",
    );
}

fn orelseCatchExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    lhs: ast.Node.Index,
    cond_op: Zir.Inst.Tag,
    unwrap_op: Zir.Inst.Tag,
    unwrap_code_op: Zir.Inst.Tag,
    rhs: ast.Node.Index,
    payload_token: ?ast.TokenIndex,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const tree = astgen.tree;

    var block_scope = parent_gz.makeSubBlock(scope);
    block_scope.setBreakResultLoc(rl);
    defer block_scope.instructions.deinit(astgen.gpa);

    const operand_rl: ResultLoc = switch (block_scope.break_result_loc) {
        .ref => .ref,
        else => .none,
    };
    block_scope.break_count += 1;
    // This could be a pointer or value depending on the `operand_rl` parameter.
    // We cannot use `block_scope.break_result_loc` because that has the bare
    // type, whereas this expression has the optional type. Later we make
    // up for this fact by calling rvalue on the else branch.
    const operand = try expr(&block_scope, &block_scope.base, operand_rl, lhs);
    const cond = try block_scope.addUnNode(cond_op, operand, node);
    const condbr = try block_scope.addCondBr(.condbr, node);

    const block = try parent_gz.addBlock(.block, node);
    try parent_gz.instructions.append(astgen.gpa, block);
    try block_scope.setBlockBody(block);

    var then_scope = parent_gz.makeSubBlock(scope);
    defer then_scope.instructions.deinit(astgen.gpa);

    // This could be a pointer or value depending on `unwrap_op`.
    const unwrapped_payload = try then_scope.addUnNode(unwrap_op, operand, node);
    const then_result = switch (rl) {
        .ref => unwrapped_payload,
        else => try rvalue(&then_scope, block_scope.break_result_loc, unwrapped_payload, node),
    };

    var else_scope = parent_gz.makeSubBlock(scope);
    defer else_scope.instructions.deinit(astgen.gpa);

    var err_val_scope: Scope.LocalVal = undefined;
    const else_sub_scope = blk: {
        const payload = payload_token orelse break :blk &else_scope.base;
        if (mem.eql(u8, tree.tokenSlice(payload), "_")) {
            return astgen.failTok(payload, "discard of error capture; omit it instead", .{});
        }
        const err_name = try astgen.identAsString(payload);
        err_val_scope = .{
            .parent = &else_scope.base,
            .gen_zir = &else_scope,
            .name = err_name,
            .inst = try else_scope.addUnNode(unwrap_code_op, operand, node),
            .token_src = payload,
            .id_cat = .@"capture",
        };
        break :blk &err_val_scope.base;
    };

    block_scope.break_count += 1;
    const else_result = try expr(&else_scope, else_sub_scope, block_scope.break_result_loc, rhs);
    try checkUsed(parent_gz, &else_scope.base, else_sub_scope);

    // We hold off on the break instructions as well as copying the then/else
    // instructions into place until we know whether to keep store_to_block_ptr
    // instructions or not.

    return finishThenElseBlock(
        parent_gz,
        rl,
        node,
        &block_scope,
        &then_scope,
        &else_scope,
        condbr,
        cond,
        then_result,
        else_result,
        block,
        block,
        .@"break",
    );
}

fn finishThenElseBlock(
    parent_gz: *GenZir,
    rl: ResultLoc,
    node: ast.Node.Index,
    block_scope: *GenZir,
    then_scope: *GenZir,
    else_scope: *GenZir,
    condbr: Zir.Inst.Index,
    cond: Zir.Inst.Ref,
    then_result: Zir.Inst.Ref,
    else_result: Zir.Inst.Ref,
    main_block: Zir.Inst.Index,
    then_break_block: Zir.Inst.Index,
    break_tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    // We now have enough information to decide whether the result instruction should
    // be communicated via result location pointer or break instructions.
    const strat = rl.strategy(block_scope);
    switch (strat.tag) {
        .break_void => {
            if (!parent_gz.refIsNoReturn(then_result)) {
                _ = try then_scope.addBreak(break_tag, then_break_block, .void_value);
            }
            const elide_else = if (else_result != .none) parent_gz.refIsNoReturn(else_result) else false;
            if (!elide_else) {
                _ = try else_scope.addBreak(break_tag, main_block, .void_value);
            }
            assert(!strat.elide_store_to_block_ptr_instructions);
            try setCondBrPayload(condbr, cond, then_scope, else_scope);
            return indexToRef(main_block);
        },
        .break_operand => {
            if (!parent_gz.refIsNoReturn(then_result)) {
                _ = try then_scope.addBreak(break_tag, then_break_block, then_result);
            }
            if (else_result != .none) {
                if (!parent_gz.refIsNoReturn(else_result)) {
                    _ = try else_scope.addBreak(break_tag, main_block, else_result);
                }
            } else {
                _ = try else_scope.addBreak(break_tag, main_block, .void_value);
            }
            if (strat.elide_store_to_block_ptr_instructions) {
                try setCondBrPayloadElideBlockStorePtr(condbr, cond, then_scope, else_scope, block_scope.rl_ptr);
            } else {
                try setCondBrPayload(condbr, cond, then_scope, else_scope);
            }
            const block_ref = indexToRef(main_block);
            switch (rl) {
                .ref => return block_ref,
                else => return rvalue(parent_gz, rl, block_ref, node),
            }
        },
    }
}

/// Return whether the identifier names of two tokens are equal. Resolves @""
/// tokens without allocating.
/// OK in theory it could do it without allocating. This implementation
/// allocates when the @"" form is used.
fn tokenIdentEql(astgen: *AstGen, token1: ast.TokenIndex, token2: ast.TokenIndex) !bool {
    const ident_name_1 = try astgen.identifierTokenString(token1);
    const ident_name_2 = try astgen.identifierTokenString(token2);
    return mem.eql(u8, ident_name_1, ident_name_2);
}

fn fieldAccess(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);
    const node_datas = tree.nodes.items(.data);

    const object_node = node_datas[node].lhs;
    const dot_token = main_tokens[node];
    const field_ident = dot_token + 1;
    const str_index = try astgen.identAsString(field_ident);
    switch (rl) {
        .ref => return gz.addPlNode(.field_ptr, node, Zir.Inst.Field{
            .lhs = try expr(gz, scope, .ref, object_node),
            .field_name_start = str_index,
        }),
        else => return rvalue(gz, rl, try gz.addPlNode(.field_val, node, Zir.Inst.Field{
            .lhs = try expr(gz, scope, .none_or_ref, object_node),
            .field_name_start = str_index,
        }), node),
    }
}

fn arrayAccess(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    switch (rl) {
        .ref => return gz.addBin(
            .elem_ptr,
            try expr(gz, scope, .ref, node_datas[node].lhs),
            try expr(gz, scope, .{ .ty = .usize_type }, node_datas[node].rhs),
        ),
        else => return rvalue(gz, rl, try gz.addBin(
            .elem_val,
            try expr(gz, scope, .none_or_ref, node_datas[node].lhs),
            try expr(gz, scope, .{ .ty = .usize_type }, node_datas[node].rhs),
        ), node),
    }
}

fn simpleBinOp(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    op_inst_tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);

    const result = try gz.addPlNode(op_inst_tag, node, Zir.Inst.Bin{
        .lhs = try expr(gz, scope, .none, node_datas[node].lhs),
        .rhs = try expr(gz, scope, .none, node_datas[node].rhs),
    });
    return rvalue(gz, rl, result, node);
}

fn simpleStrTok(
    gz: *GenZir,
    rl: ResultLoc,
    ident_token: ast.TokenIndex,
    node: ast.Node.Index,
    op_inst_tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const str_index = try astgen.identAsString(ident_token);
    const result = try gz.addStrTok(op_inst_tag, str_index, ident_token);
    return rvalue(gz, rl, result, node);
}

fn boolBinOp(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    zir_tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);

    const lhs = try expr(gz, scope, bool_rl, node_datas[node].lhs);
    const bool_br = try gz.addBoolBr(zir_tag, lhs);

    var rhs_scope = gz.makeSubBlock(scope);
    defer rhs_scope.instructions.deinit(gz.astgen.gpa);
    const rhs = try expr(&rhs_scope, &rhs_scope.base, bool_rl, node_datas[node].rhs);
    if (!gz.refIsNoReturn(rhs)) {
        _ = try rhs_scope.addBreak(.break_inline, bool_br, rhs);
    }
    try rhs_scope.setBoolBrBody(bool_br);

    const block_ref = indexToRef(bool_br);
    return rvalue(gz, rl, block_ref, node);
}

fn ifExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    if_full: ast.full.If,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const tree = astgen.tree;
    const token_tags = tree.tokens.items(.tag);

    var block_scope = parent_gz.makeSubBlock(scope);
    block_scope.setBreakResultLoc(rl);
    defer block_scope.instructions.deinit(astgen.gpa);

    const payload_is_ref = if (if_full.payload_token) |payload_token|
        token_tags[payload_token] == .asterisk
    else
        false;

    const cond: struct {
        inst: Zir.Inst.Ref,
        bool_bit: Zir.Inst.Ref,
    } = c: {
        if (if_full.error_token) |_| {
            const cond_rl: ResultLoc = if (payload_is_ref) .ref else .none;
            const err_union = try expr(&block_scope, &block_scope.base, cond_rl, if_full.ast.cond_expr);
            const tag: Zir.Inst.Tag = if (payload_is_ref) .is_non_err_ptr else .is_non_err;
            break :c .{
                .inst = err_union,
                .bool_bit = try block_scope.addUnNode(tag, err_union, node),
            };
        } else if (if_full.payload_token) |_| {
            const cond_rl: ResultLoc = if (payload_is_ref) .ref else .none;
            const optional = try expr(&block_scope, &block_scope.base, cond_rl, if_full.ast.cond_expr);
            const tag: Zir.Inst.Tag = if (payload_is_ref) .is_non_null_ptr else .is_non_null;
            break :c .{
                .inst = optional,
                .bool_bit = try block_scope.addUnNode(tag, optional, node),
            };
        } else {
            const cond = try expr(&block_scope, &block_scope.base, bool_rl, if_full.ast.cond_expr);
            break :c .{
                .inst = cond,
                .bool_bit = cond,
            };
        }
    };

    const condbr = try block_scope.addCondBr(.condbr, node);

    const block = try parent_gz.addBlock(.block, node);
    try parent_gz.instructions.append(astgen.gpa, block);
    try block_scope.setBlockBody(block);

    var then_scope = parent_gz.makeSubBlock(scope);
    defer then_scope.instructions.deinit(astgen.gpa);

    var payload_val_scope: Scope.LocalVal = undefined;

    const then_sub_scope = s: {
        if (if_full.error_token != null) {
            if (if_full.payload_token) |payload_token| {
                const tag: Zir.Inst.Tag = if (payload_is_ref)
                    .err_union_payload_unsafe_ptr
                else
                    .err_union_payload_unsafe;
                const payload_inst = try then_scope.addUnNode(tag, cond.inst, node);
                const token_name_index = payload_token + @boolToInt(payload_is_ref);
                const ident_name = try astgen.identAsString(token_name_index);
                const token_name_str = tree.tokenSlice(token_name_index);
                if (mem.eql(u8, "_", token_name_str))
                    break :s &then_scope.base;
                payload_val_scope = .{
                    .parent = &then_scope.base,
                    .gen_zir = &then_scope,
                    .name = ident_name,
                    .inst = payload_inst,
                    .token_src = payload_token,
                    .id_cat = .@"capture",
                };
                break :s &payload_val_scope.base;
            } else {
                break :s &then_scope.base;
            }
        } else if (if_full.payload_token) |payload_token| {
            const ident_token = if (payload_is_ref) payload_token + 1 else payload_token;
            const tag: Zir.Inst.Tag = if (payload_is_ref)
                .optional_payload_unsafe_ptr
            else
                .optional_payload_unsafe;
            if (mem.eql(u8, "_", tree.tokenSlice(ident_token)))
                break :s &then_scope.base;
            const payload_inst = try then_scope.addUnNode(tag, cond.inst, node);
            const ident_name = try astgen.identAsString(ident_token);
            payload_val_scope = .{
                .parent = &then_scope.base,
                .gen_zir = &then_scope,
                .name = ident_name,
                .inst = payload_inst,
                .token_src = ident_token,
                .id_cat = .@"capture",
            };
            break :s &payload_val_scope.base;
        } else {
            break :s &then_scope.base;
        }
    };

    block_scope.break_count += 1;
    const then_result = try expr(&then_scope, then_sub_scope, block_scope.break_result_loc, if_full.ast.then_expr);
    try checkUsed(parent_gz, &then_scope.base, then_sub_scope);
    // We hold off on the break instructions as well as copying the then/else
    // instructions into place until we know whether to keep store_to_block_ptr
    // instructions or not.

    var else_scope = parent_gz.makeSubBlock(scope);
    defer else_scope.instructions.deinit(astgen.gpa);

    const else_node = if_full.ast.else_expr;
    const else_info: struct {
        src: ast.Node.Index,
        result: Zir.Inst.Ref,
    } = if (else_node != 0) blk: {
        block_scope.break_count += 1;
        const sub_scope = s: {
            if (if_full.error_token) |error_token| {
                const tag: Zir.Inst.Tag = if (payload_is_ref)
                    .err_union_code_ptr
                else
                    .err_union_code;
                const payload_inst = try else_scope.addUnNode(tag, cond.inst, node);
                const ident_name = try astgen.identAsString(error_token);
                const error_token_str = tree.tokenSlice(error_token);
                if (mem.eql(u8, "_", error_token_str))
                    break :s &else_scope.base;
                payload_val_scope = .{
                    .parent = &else_scope.base,
                    .gen_zir = &else_scope,
                    .name = ident_name,
                    .inst = payload_inst,
                    .token_src = error_token,
                    .id_cat = .@"capture",
                };
                break :s &payload_val_scope.base;
            } else {
                break :s &else_scope.base;
            }
        };
        const e = try expr(&else_scope, sub_scope, block_scope.break_result_loc, else_node);
        try checkUsed(parent_gz, &else_scope.base, sub_scope);
        break :blk .{
            .src = else_node,
            .result = e,
        };
    } else .{
        .src = if_full.ast.then_expr,
        .result = .none,
    };

    return finishThenElseBlock(
        parent_gz,
        rl,
        node,
        &block_scope,
        &then_scope,
        &else_scope,
        condbr,
        cond.bool_bit,
        then_result,
        else_info.result,
        block,
        block,
        .@"break",
    );
}

fn setCondBrPayload(
    condbr: Zir.Inst.Index,
    cond: Zir.Inst.Ref,
    then_scope: *GenZir,
    else_scope: *GenZir,
) !void {
    const astgen = then_scope.astgen;

    try astgen.extra.ensureCapacity(astgen.gpa, astgen.extra.items.len +
        @typeInfo(Zir.Inst.CondBr).Struct.fields.len +
        then_scope.instructions.items.len + else_scope.instructions.items.len);

    const zir_datas = astgen.instructions.items(.data);
    zir_datas[condbr].pl_node.payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.CondBr{
        .condition = cond,
        .then_body_len = @intCast(u32, then_scope.instructions.items.len),
        .else_body_len = @intCast(u32, else_scope.instructions.items.len),
    });
    astgen.extra.appendSliceAssumeCapacity(then_scope.instructions.items);
    astgen.extra.appendSliceAssumeCapacity(else_scope.instructions.items);
}

fn setCondBrPayloadElideBlockStorePtr(
    condbr: Zir.Inst.Index,
    cond: Zir.Inst.Ref,
    then_scope: *GenZir,
    else_scope: *GenZir,
    block_ptr: Zir.Inst.Ref,
) !void {
    const astgen = then_scope.astgen;

    try astgen.extra.ensureUnusedCapacity(astgen.gpa, @typeInfo(Zir.Inst.CondBr).Struct.fields.len +
        then_scope.instructions.items.len + else_scope.instructions.items.len);

    const zir_tags = astgen.instructions.items(.tag);
    const zir_datas = astgen.instructions.items(.data);

    const condbr_pl = astgen.addExtraAssumeCapacity(Zir.Inst.CondBr{
        .condition = cond,
        .then_body_len = @intCast(u32, then_scope.instructions.items.len),
        .else_body_len = @intCast(u32, else_scope.instructions.items.len),
    });
    zir_datas[condbr].pl_node.payload_index = condbr_pl;
    const then_body_len_index = condbr_pl + 1;
    const else_body_len_index = condbr_pl + 2;

    for (then_scope.instructions.items) |src_inst| {
        if (zir_tags[src_inst] == .store_to_block_ptr) {
            if (zir_datas[src_inst].bin.lhs == block_ptr) {
                astgen.extra.items[then_body_len_index] -= 1;
                continue;
            }
        }
        astgen.extra.appendAssumeCapacity(src_inst);
    }
    for (else_scope.instructions.items) |src_inst| {
        if (zir_tags[src_inst] == .store_to_block_ptr) {
            if (zir_datas[src_inst].bin.lhs == block_ptr) {
                astgen.extra.items[else_body_len_index] -= 1;
                continue;
            }
        }
        astgen.extra.appendAssumeCapacity(src_inst);
    }
}

fn whileExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    while_full: ast.full.While,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const tree = astgen.tree;
    const token_tags = tree.tokens.items(.tag);

    if (while_full.label_token) |label_token| {
        try astgen.checkLabelRedefinition(scope, label_token);
    }

    const is_inline = parent_gz.force_comptime or while_full.inline_token != null;
    const loop_tag: Zir.Inst.Tag = if (is_inline) .block_inline else .loop;
    const loop_block = try parent_gz.addBlock(loop_tag, node);
    try parent_gz.instructions.append(astgen.gpa, loop_block);

    var loop_scope = parent_gz.makeSubBlock(scope);
    loop_scope.setBreakResultLoc(rl);
    defer loop_scope.instructions.deinit(astgen.gpa);
    defer loop_scope.labeled_breaks.deinit(astgen.gpa);
    defer loop_scope.labeled_store_to_block_ptr_list.deinit(astgen.gpa);

    var continue_scope = parent_gz.makeSubBlock(&loop_scope.base);
    defer continue_scope.instructions.deinit(astgen.gpa);

    const payload_is_ref = if (while_full.payload_token) |payload_token|
        token_tags[payload_token] == .asterisk
    else
        false;

    const cond: struct {
        inst: Zir.Inst.Ref,
        bool_bit: Zir.Inst.Ref,
    } = c: {
        if (while_full.error_token) |_| {
            const cond_rl: ResultLoc = if (payload_is_ref) .ref else .none;
            const err_union = try expr(&continue_scope, &continue_scope.base, cond_rl, while_full.ast.cond_expr);
            const tag: Zir.Inst.Tag = if (payload_is_ref) .is_non_err_ptr else .is_non_err;
            break :c .{
                .inst = err_union,
                .bool_bit = try continue_scope.addUnNode(tag, err_union, node),
            };
        } else if (while_full.payload_token) |_| {
            const cond_rl: ResultLoc = if (payload_is_ref) .ref else .none;
            const optional = try expr(&continue_scope, &continue_scope.base, cond_rl, while_full.ast.cond_expr);
            const tag: Zir.Inst.Tag = if (payload_is_ref) .is_non_null_ptr else .is_non_null;
            break :c .{
                .inst = optional,
                .bool_bit = try continue_scope.addUnNode(tag, optional, node),
            };
        } else {
            const cond = try expr(&continue_scope, &continue_scope.base, bool_rl, while_full.ast.cond_expr);
            break :c .{
                .inst = cond,
                .bool_bit = cond,
            };
        }
    };

    const condbr_tag: Zir.Inst.Tag = if (is_inline) .condbr_inline else .condbr;
    const condbr = try continue_scope.addCondBr(condbr_tag, node);
    const block_tag: Zir.Inst.Tag = if (is_inline) .block_inline else .block;
    const cond_block = try loop_scope.addBlock(block_tag, node);
    try loop_scope.instructions.append(astgen.gpa, cond_block);
    try continue_scope.setBlockBody(cond_block);

    var then_scope = parent_gz.makeSubBlock(&continue_scope.base);
    defer then_scope.instructions.deinit(astgen.gpa);

    var payload_val_scope: Scope.LocalVal = undefined;

    const then_sub_scope = s: {
        if (while_full.error_token != null) {
            if (while_full.payload_token) |payload_token| {
                const tag: Zir.Inst.Tag = if (payload_is_ref)
                    .err_union_payload_unsafe_ptr
                else
                    .err_union_payload_unsafe;
                const payload_inst = try then_scope.addUnNode(tag, cond.inst, node);
                const ident_token = if (payload_is_ref) payload_token + 1 else payload_token;
                if (mem.eql(u8, "_", tree.tokenSlice(ident_token)))
                    break :s &then_scope.base;
                const ident_name = try astgen.identAsString(payload_token + @boolToInt(payload_is_ref));
                payload_val_scope = .{
                    .parent = &then_scope.base,
                    .gen_zir = &then_scope,
                    .name = ident_name,
                    .inst = payload_inst,
                    .token_src = payload_token,
                    .id_cat = .@"capture",
                };
                break :s &payload_val_scope.base;
            } else {
                break :s &then_scope.base;
            }
        } else if (while_full.payload_token) |payload_token| {
            const ident_token = if (payload_is_ref) payload_token + 1 else payload_token;
            const tag: Zir.Inst.Tag = if (payload_is_ref)
                .optional_payload_unsafe_ptr
            else
                .optional_payload_unsafe;
            const payload_inst = try then_scope.addUnNode(tag, cond.inst, node);
            const ident_name = try astgen.identAsString(ident_token);
            if (mem.eql(u8, "_", tree.tokenSlice(ident_token)))
                break :s &then_scope.base;
            payload_val_scope = .{
                .parent = &then_scope.base,
                .gen_zir = &then_scope,
                .name = ident_name,
                .inst = payload_inst,
                .token_src = ident_token,
                .id_cat = .@"capture",
            };
            break :s &payload_val_scope.base;
        } else {
            break :s &then_scope.base;
        }
    };

    // This code could be improved to avoid emitting the continue expr when there
    // are no jumps to it. This happens when the last statement of a while body is noreturn
    // and there are no `continue` statements.
    // Tracking issue: https://github.com/ziglang/zig/issues/9185
    if (while_full.ast.cont_expr != 0) {
        _ = try expr(&loop_scope, then_sub_scope, .{ .ty = .void_type }, while_full.ast.cont_expr);
    }
    const repeat_tag: Zir.Inst.Tag = if (is_inline) .repeat_inline else .repeat;
    _ = try loop_scope.addNode(repeat_tag, node);

    try loop_scope.setBlockBody(loop_block);
    loop_scope.break_block = loop_block;
    loop_scope.continue_block = cond_block;
    if (while_full.label_token) |label_token| {
        loop_scope.label = @as(?GenZir.Label, GenZir.Label{
            .token = label_token,
            .block_inst = loop_block,
        });
    }

    loop_scope.break_count += 1;
    const then_result = try expr(&then_scope, then_sub_scope, loop_scope.break_result_loc, while_full.ast.then_expr);
    try checkUsed(parent_gz, &then_scope.base, then_sub_scope);

    var else_scope = parent_gz.makeSubBlock(&continue_scope.base);
    defer else_scope.instructions.deinit(astgen.gpa);

    const else_node = while_full.ast.else_expr;
    const else_info: struct {
        src: ast.Node.Index,
        result: Zir.Inst.Ref,
    } = if (else_node != 0) blk: {
        loop_scope.break_count += 1;
        const sub_scope = s: {
            if (while_full.error_token) |error_token| {
                const tag: Zir.Inst.Tag = if (payload_is_ref)
                    .err_union_code_ptr
                else
                    .err_union_code;
                const payload_inst = try else_scope.addUnNode(tag, cond.inst, node);
                const ident_name = try astgen.identAsString(error_token);
                if (mem.eql(u8, tree.tokenSlice(error_token), "_"))
                    break :s &else_scope.base;
                payload_val_scope = .{
                    .parent = &else_scope.base,
                    .gen_zir = &else_scope,
                    .name = ident_name,
                    .inst = payload_inst,
                    .token_src = error_token,
                    .id_cat = .@"capture",
                };
                break :s &payload_val_scope.base;
            } else {
                break :s &else_scope.base;
            }
        };
        const e = try expr(&else_scope, sub_scope, loop_scope.break_result_loc, else_node);
        try checkUsed(parent_gz, &else_scope.base, sub_scope);
        break :blk .{
            .src = else_node,
            .result = e,
        };
    } else .{
        .src = while_full.ast.then_expr,
        .result = .none,
    };

    if (loop_scope.label) |some| {
        if (!some.used) {
            return astgen.failTok(some.token, "unused while loop label", .{});
        }
    }
    const break_tag: Zir.Inst.Tag = if (is_inline) .break_inline else .@"break";
    return finishThenElseBlock(
        parent_gz,
        rl,
        node,
        &loop_scope,
        &then_scope,
        &else_scope,
        condbr,
        cond.bool_bit,
        then_result,
        else_info.result,
        loop_block,
        cond_block,
        break_tag,
    );
}

fn forExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    for_full: ast.full.While,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;

    if (for_full.label_token) |label_token| {
        try astgen.checkLabelRedefinition(scope, label_token);
    }
    // Set up variables and constants.
    const is_inline = parent_gz.force_comptime or for_full.inline_token != null;
    const tree = astgen.tree;
    const token_tags = tree.tokens.items(.tag);

    const array_ptr = try expr(parent_gz, scope, .ref, for_full.ast.cond_expr);
    const len = try parent_gz.addUnNode(.indexable_ptr_len, array_ptr, for_full.ast.cond_expr);

    const index_ptr = blk: {
        const index_ptr = try parent_gz.addUnNode(.alloc, .usize_type, node);
        // initialize to zero
        _ = try parent_gz.addBin(.store, index_ptr, .zero_usize);
        break :blk index_ptr;
    };

    const loop_tag: Zir.Inst.Tag = if (is_inline) .block_inline else .loop;
    const loop_block = try parent_gz.addBlock(loop_tag, node);
    try parent_gz.instructions.append(astgen.gpa, loop_block);

    var loop_scope = parent_gz.makeSubBlock(scope);
    loop_scope.setBreakResultLoc(rl);
    defer loop_scope.instructions.deinit(astgen.gpa);
    defer loop_scope.labeled_breaks.deinit(astgen.gpa);
    defer loop_scope.labeled_store_to_block_ptr_list.deinit(astgen.gpa);

    var cond_scope = parent_gz.makeSubBlock(&loop_scope.base);
    defer cond_scope.instructions.deinit(astgen.gpa);

    // check condition i < array_expr.len
    const index = try cond_scope.addUnNode(.load, index_ptr, for_full.ast.cond_expr);
    const cond = try cond_scope.addPlNode(.cmp_lt, for_full.ast.cond_expr, Zir.Inst.Bin{
        .lhs = index,
        .rhs = len,
    });

    const condbr_tag: Zir.Inst.Tag = if (is_inline) .condbr_inline else .condbr;
    const condbr = try cond_scope.addCondBr(condbr_tag, node);
    const block_tag: Zir.Inst.Tag = if (is_inline) .block_inline else .block;
    const cond_block = try loop_scope.addBlock(block_tag, node);
    try loop_scope.instructions.append(astgen.gpa, cond_block);
    try cond_scope.setBlockBody(cond_block);

    // Increment the index variable.
    const index_2 = try loop_scope.addUnNode(.load, index_ptr, for_full.ast.cond_expr);
    const index_plus_one = try loop_scope.addPlNode(.add, node, Zir.Inst.Bin{
        .lhs = index_2,
        .rhs = .one_usize,
    });
    _ = try loop_scope.addBin(.store, index_ptr, index_plus_one);
    const repeat_tag: Zir.Inst.Tag = if (is_inline) .repeat_inline else .repeat;
    _ = try loop_scope.addNode(repeat_tag, node);

    try loop_scope.setBlockBody(loop_block);
    loop_scope.break_block = loop_block;
    loop_scope.continue_block = cond_block;
    if (for_full.label_token) |label_token| {
        loop_scope.label = @as(?GenZir.Label, GenZir.Label{
            .token = label_token,
            .block_inst = loop_block,
        });
    }

    var then_scope = parent_gz.makeSubBlock(&cond_scope.base);
    defer then_scope.instructions.deinit(astgen.gpa);

    var payload_val_scope: Scope.LocalVal = undefined;
    var index_scope: Scope.LocalPtr = undefined;
    const then_sub_scope = blk: {
        const payload_token = for_full.payload_token.?;
        const ident = if (token_tags[payload_token] == .asterisk)
            payload_token + 1
        else
            payload_token;
        const is_ptr = ident != payload_token;
        const value_name = tree.tokenSlice(ident);
        var payload_sub_scope: *Scope = undefined;
        if (!mem.eql(u8, value_name, "_")) {
            const name_str_index = try astgen.identAsString(ident);
            const tag: Zir.Inst.Tag = if (is_ptr) .elem_ptr else .elem_val;
            const payload_inst = try then_scope.addBin(tag, array_ptr, index);
            payload_val_scope = .{
                .parent = &then_scope.base,
                .gen_zir = &then_scope,
                .name = name_str_index,
                .inst = payload_inst,
                .token_src = ident,
                .id_cat = .@"capture",
            };
            payload_sub_scope = &payload_val_scope.base;
        } else if (is_ptr) {
            return astgen.failTok(payload_token, "pointer modifier invalid on discard", .{});
        } else {
            payload_sub_scope = &then_scope.base;
        }

        const index_token = if (token_tags[ident + 1] == .comma)
            ident + 2
        else
            break :blk payload_sub_scope;
        if (mem.eql(u8, tree.tokenSlice(index_token), "_")) {
            return astgen.failTok(index_token, "discard of index capture; omit it instead", .{});
        }
        const index_name = try astgen.identAsString(index_token);
        index_scope = .{
            .parent = payload_sub_scope,
            .gen_zir = &then_scope,
            .name = index_name,
            .ptr = index_ptr,
            .token_src = index_token,
            .maybe_comptime = is_inline,
            .id_cat = .@"loop index capture",
        };
        break :blk &index_scope.base;
    };

    loop_scope.break_count += 1;
    const then_result = try expr(&then_scope, then_sub_scope, loop_scope.break_result_loc, for_full.ast.then_expr);
    try checkUsed(parent_gz, &then_scope.base, then_sub_scope);

    var else_scope = parent_gz.makeSubBlock(&cond_scope.base);
    defer else_scope.instructions.deinit(astgen.gpa);

    const else_node = for_full.ast.else_expr;
    const else_info: struct {
        src: ast.Node.Index,
        result: Zir.Inst.Ref,
    } = if (else_node != 0) blk: {
        loop_scope.break_count += 1;
        const sub_scope = &else_scope.base;
        break :blk .{
            .src = else_node,
            .result = try expr(&else_scope, sub_scope, loop_scope.break_result_loc, else_node),
        };
    } else .{
        .src = for_full.ast.then_expr,
        .result = .none,
    };

    if (loop_scope.label) |some| {
        if (!some.used) {
            return astgen.failTok(some.token, "unused for loop label", .{});
        }
    }
    const break_tag: Zir.Inst.Tag = if (is_inline) .break_inline else .@"break";
    return finishThenElseBlock(
        parent_gz,
        rl,
        node,
        &loop_scope,
        &then_scope,
        &else_scope,
        condbr,
        cond,
        then_result,
        else_info.result,
        loop_block,
        cond_block,
        break_tag,
    );
}

fn switchExpr(
    parent_gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    switch_node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = parent_gz.astgen;
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const node_tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);
    const operand_node = node_datas[switch_node].lhs;
    const extra = tree.extraData(node_datas[switch_node].rhs, ast.Node.SubRange);
    const case_nodes = tree.extra_data[extra.start..extra.end];

    // We perform two passes over the AST. This first pass is to collect information
    // for the following variables, make note of the special prong AST node index,
    // and bail out with a compile error if there are multiple special prongs present.
    var any_payload_is_ref = false;
    var scalar_cases_len: u32 = 0;
    var multi_cases_len: u32 = 0;
    var special_prong: Zir.SpecialProng = .none;
    var special_node: ast.Node.Index = 0;
    var else_src: ?ast.TokenIndex = null;
    var underscore_src: ?ast.TokenIndex = null;
    for (case_nodes) |case_node| {
        const case = switch (node_tags[case_node]) {
            .switch_case_one => tree.switchCaseOne(case_node),
            .switch_case => tree.switchCase(case_node),
            else => unreachable,
        };
        if (case.payload_token) |payload_token| {
            if (token_tags[payload_token] == .asterisk) {
                any_payload_is_ref = true;
            }
        }
        // Check for else/`_` prong.
        if (case.ast.values.len == 0) {
            const case_src = case.ast.arrow_token - 1;
            if (else_src) |src| {
                return astgen.failTokNotes(
                    case_src,
                    "multiple else prongs in switch expression",
                    .{},
                    &[_]u32{
                        try astgen.errNoteTok(
                            src,
                            "previous else prong here",
                            .{},
                        ),
                    },
                );
            } else if (underscore_src) |some_underscore| {
                return astgen.failNodeNotes(
                    switch_node,
                    "else and '_' prong in switch expression",
                    .{},
                    &[_]u32{
                        try astgen.errNoteTok(
                            case_src,
                            "else prong here",
                            .{},
                        ),
                        try astgen.errNoteTok(
                            some_underscore,
                            "'_' prong here",
                            .{},
                        ),
                    },
                );
            }
            special_node = case_node;
            special_prong = .@"else";
            else_src = case_src;
            continue;
        } else if (case.ast.values.len == 1 and
            node_tags[case.ast.values[0]] == .identifier and
            mem.eql(u8, tree.tokenSlice(main_tokens[case.ast.values[0]]), "_"))
        {
            const case_src = case.ast.arrow_token - 1;
            if (underscore_src) |src| {
                return astgen.failTokNotes(
                    case_src,
                    "multiple '_' prongs in switch expression",
                    .{},
                    &[_]u32{
                        try astgen.errNoteTok(
                            src,
                            "previous '_' prong here",
                            .{},
                        ),
                    },
                );
            } else if (else_src) |some_else| {
                return astgen.failNodeNotes(
                    switch_node,
                    "else and '_' prong in switch expression",
                    .{},
                    &[_]u32{
                        try astgen.errNoteTok(
                            some_else,
                            "else prong here",
                            .{},
                        ),
                        try astgen.errNoteTok(
                            case_src,
                            "'_' prong here",
                            .{},
                        ),
                    },
                );
            }
            special_node = case_node;
            special_prong = .under;
            underscore_src = case_src;
            continue;
        }

        if (case.ast.values.len == 1 and node_tags[case.ast.values[0]] != .switch_range) {
            scalar_cases_len += 1;
        } else {
            multi_cases_len += 1;
        }
    }

    const operand_rl: ResultLoc = if (any_payload_is_ref) .ref else .none;
    const operand = try expr(parent_gz, scope, operand_rl, operand_node);
    // We need the type of the operand to use as the result location for all the prong items.
    const typeof_tag: Zir.Inst.Tag = if (any_payload_is_ref) .typeof_elem else .typeof;
    const operand_ty_inst = try parent_gz.addUnNode(typeof_tag, operand, operand_node);
    const item_rl: ResultLoc = .{ .ty = operand_ty_inst };

    // Contains the data that goes into the `extra` array for the SwitchBlock/SwitchBlockMulti.
    // This is the header as well as the optional else prong body, as well as all the
    // scalar cases.
    // At the end we will memcpy this into place.
    var scalar_cases_payload = ArrayListUnmanaged(u32){};
    defer scalar_cases_payload.deinit(gpa);
    // Same deal, but this is only the `extra` data for the multi cases.
    var multi_cases_payload = ArrayListUnmanaged(u32){};
    defer multi_cases_payload.deinit(gpa);

    var block_scope = parent_gz.makeSubBlock(scope);
    block_scope.setBreakResultLoc(rl);
    defer block_scope.instructions.deinit(gpa);

    // This gets added to the parent block later, after the item expressions.
    const switch_block = try parent_gz.addBlock(undefined, switch_node);

    // We re-use this same scope for all cases, including the special prong, if any.
    var case_scope = parent_gz.makeSubBlock(&block_scope.base);
    defer case_scope.instructions.deinit(gpa);

    // Do the else/`_` first because it goes first in the payload.
    var capture_val_scope: Scope.LocalVal = undefined;
    if (special_node != 0) {
        const case = switch (node_tags[special_node]) {
            .switch_case_one => tree.switchCaseOne(special_node),
            .switch_case => tree.switchCase(special_node),
            else => unreachable,
        };
        const sub_scope = blk: {
            const payload_token = case.payload_token orelse break :blk &case_scope.base;
            const ident = if (token_tags[payload_token] == .asterisk)
                payload_token + 1
            else
                payload_token;
            const is_ptr = ident != payload_token;
            if (mem.eql(u8, tree.tokenSlice(ident), "_")) {
                if (is_ptr) {
                    return astgen.failTok(payload_token, "pointer modifier invalid on discard", .{});
                }
                break :blk &case_scope.base;
            }
            const capture_tag: Zir.Inst.Tag = if (is_ptr)
                .switch_capture_else_ref
            else
                .switch_capture_else;
            const capture = try case_scope.add(.{
                .tag = capture_tag,
                .data = .{ .switch_capture = .{
                    .switch_inst = switch_block,
                    .prong_index = undefined,
                } },
            });
            const capture_name = try astgen.identAsString(payload_token);
            capture_val_scope = .{
                .parent = &case_scope.base,
                .gen_zir = &case_scope,
                .name = capture_name,
                .inst = capture,
                .token_src = payload_token,
                .id_cat = .@"capture",
            };
            break :blk &capture_val_scope.base;
        };
        const case_result = try expr(&case_scope, sub_scope, block_scope.break_result_loc, case.ast.target_expr);
        try checkUsed(parent_gz, &case_scope.base, sub_scope);
        if (!parent_gz.refIsNoReturn(case_result)) {
            block_scope.break_count += 1;
            _ = try case_scope.addBreak(.@"break", switch_block, case_result);
        }
        // Documentation for this: `Zir.Inst.SwitchBlock` and `Zir.Inst.SwitchBlockMulti`.
        try scalar_cases_payload.ensureCapacity(gpa, scalar_cases_payload.items.len +
            3 + // operand, scalar_cases_len, else body len
            @boolToInt(multi_cases_len != 0) +
            case_scope.instructions.items.len);
        scalar_cases_payload.appendAssumeCapacity(@enumToInt(operand));
        scalar_cases_payload.appendAssumeCapacity(scalar_cases_len);
        if (multi_cases_len != 0) {
            scalar_cases_payload.appendAssumeCapacity(multi_cases_len);
        }
        scalar_cases_payload.appendAssumeCapacity(@intCast(u32, case_scope.instructions.items.len));
        scalar_cases_payload.appendSliceAssumeCapacity(case_scope.instructions.items);
    } else {
        // Documentation for this: `Zir.Inst.SwitchBlock` and `Zir.Inst.SwitchBlockMulti`.
        try scalar_cases_payload.ensureCapacity(gpa, scalar_cases_payload.items.len +
            2 + // operand, scalar_cases_len
            @boolToInt(multi_cases_len != 0));
        scalar_cases_payload.appendAssumeCapacity(@enumToInt(operand));
        scalar_cases_payload.appendAssumeCapacity(scalar_cases_len);
        if (multi_cases_len != 0) {
            scalar_cases_payload.appendAssumeCapacity(multi_cases_len);
        }
    }

    // In this pass we generate all the item and prong expressions except the special case.
    var multi_case_index: u32 = 0;
    var scalar_case_index: u32 = 0;
    for (case_nodes) |case_node| {
        if (case_node == special_node)
            continue;
        const case = switch (node_tags[case_node]) {
            .switch_case_one => tree.switchCaseOne(case_node),
            .switch_case => tree.switchCase(case_node),
            else => unreachable,
        };

        // Reset the scope.
        case_scope.instructions.shrinkRetainingCapacity(0);

        const is_multi_case = case.ast.values.len != 1 or
            node_tags[case.ast.values[0]] == .switch_range;

        const sub_scope = blk: {
            const payload_token = case.payload_token orelse break :blk &case_scope.base;
            const ident = if (token_tags[payload_token] == .asterisk)
                payload_token + 1
            else
                payload_token;
            const is_ptr = ident != payload_token;
            if (mem.eql(u8, tree.tokenSlice(ident), "_")) {
                if (is_ptr) {
                    return astgen.failTok(payload_token, "pointer modifier invalid on discard", .{});
                }
                break :blk &case_scope.base;
            }
            const is_multi_case_bits: u2 = @boolToInt(is_multi_case);
            const is_ptr_bits: u2 = @boolToInt(is_ptr);
            const capture_tag: Zir.Inst.Tag = switch ((is_multi_case_bits << 1) | is_ptr_bits) {
                0b00 => .switch_capture,
                0b01 => .switch_capture_ref,
                0b10 => .switch_capture_multi,
                0b11 => .switch_capture_multi_ref,
            };
            const capture_index = if (is_multi_case) ci: {
                multi_case_index += 1;
                break :ci multi_case_index - 1;
            } else ci: {
                scalar_case_index += 1;
                break :ci scalar_case_index - 1;
            };
            const capture = try case_scope.add(.{
                .tag = capture_tag,
                .data = .{ .switch_capture = .{
                    .switch_inst = switch_block,
                    .prong_index = capture_index,
                } },
            });
            const capture_name = try astgen.identAsString(ident);
            capture_val_scope = .{
                .parent = &case_scope.base,
                .gen_zir = &case_scope,
                .name = capture_name,
                .inst = capture,
                .token_src = payload_token,
                .id_cat = .@"capture",
            };
            break :blk &capture_val_scope.base;
        };

        if (is_multi_case) {
            // items_len, ranges_len, body_len
            const header_index = multi_cases_payload.items.len;
            try multi_cases_payload.resize(gpa, multi_cases_payload.items.len + 3);

            // items
            var items_len: u32 = 0;
            for (case.ast.values) |item_node| {
                if (node_tags[item_node] == .switch_range) continue;
                items_len += 1;

                const item_inst = try comptimeExpr(parent_gz, scope, item_rl, item_node);
                try multi_cases_payload.append(gpa, @enumToInt(item_inst));
            }

            // ranges
            var ranges_len: u32 = 0;
            for (case.ast.values) |range| {
                if (node_tags[range] != .switch_range) continue;
                ranges_len += 1;

                const first = try comptimeExpr(parent_gz, scope, item_rl, node_datas[range].lhs);
                const last = try comptimeExpr(parent_gz, scope, item_rl, node_datas[range].rhs);
                try multi_cases_payload.appendSlice(gpa, &[_]u32{
                    @enumToInt(first), @enumToInt(last),
                });
            }

            const case_result = try expr(&case_scope, sub_scope, block_scope.break_result_loc, case.ast.target_expr);
            try checkUsed(parent_gz, &case_scope.base, sub_scope);
            if (!parent_gz.refIsNoReturn(case_result)) {
                block_scope.break_count += 1;
                _ = try case_scope.addBreak(.@"break", switch_block, case_result);
            }

            multi_cases_payload.items[header_index + 0] = items_len;
            multi_cases_payload.items[header_index + 1] = ranges_len;
            multi_cases_payload.items[header_index + 2] = @intCast(u32, case_scope.instructions.items.len);
            try multi_cases_payload.appendSlice(gpa, case_scope.instructions.items);
        } else {
            const item_node = case.ast.values[0];
            const item_inst = try comptimeExpr(parent_gz, scope, item_rl, item_node);
            const case_result = try expr(&case_scope, sub_scope, block_scope.break_result_loc, case.ast.target_expr);
            try checkUsed(parent_gz, &case_scope.base, sub_scope);
            if (!parent_gz.refIsNoReturn(case_result)) {
                block_scope.break_count += 1;
                _ = try case_scope.addBreak(.@"break", switch_block, case_result);
            }
            try scalar_cases_payload.ensureCapacity(gpa, scalar_cases_payload.items.len +
                2 + case_scope.instructions.items.len);
            scalar_cases_payload.appendAssumeCapacity(@enumToInt(item_inst));
            scalar_cases_payload.appendAssumeCapacity(@intCast(u32, case_scope.instructions.items.len));
            scalar_cases_payload.appendSliceAssumeCapacity(case_scope.instructions.items);
        }
    }
    // Now that the item expressions are generated we can add this.
    try parent_gz.instructions.append(gpa, switch_block);

    const ref_bit: u4 = @boolToInt(any_payload_is_ref);
    const multi_bit: u4 = @boolToInt(multi_cases_len != 0);
    const special_prong_bits: u4 = @enumToInt(special_prong);
    comptime {
        assert(@enumToInt(Zir.SpecialProng.none) == 0b00);
        assert(@enumToInt(Zir.SpecialProng.@"else") == 0b01);
        assert(@enumToInt(Zir.SpecialProng.under) == 0b10);
    }
    const zir_tags = astgen.instructions.items(.tag);
    zir_tags[switch_block] = switch ((ref_bit << 3) | (special_prong_bits << 1) | multi_bit) {
        0b0_00_0 => .switch_block,
        0b0_00_1 => .switch_block_multi,
        0b0_01_0 => .switch_block_else,
        0b0_01_1 => .switch_block_else_multi,
        0b0_10_0 => .switch_block_under,
        0b0_10_1 => .switch_block_under_multi,
        0b1_00_0 => .switch_block_ref,
        0b1_00_1 => .switch_block_ref_multi,
        0b1_01_0 => .switch_block_ref_else,
        0b1_01_1 => .switch_block_ref_else_multi,
        0b1_10_0 => .switch_block_ref_under,
        0b1_10_1 => .switch_block_ref_under_multi,
        else => unreachable,
    };
    const payload_index = astgen.extra.items.len;
    const zir_datas = astgen.instructions.items(.data);
    zir_datas[switch_block].pl_node.payload_index = @intCast(u32, payload_index);
    try astgen.extra.ensureCapacity(gpa, astgen.extra.items.len +
        scalar_cases_payload.items.len + multi_cases_payload.items.len);
    const strat = rl.strategy(&block_scope);
    switch (strat.tag) {
        .break_operand => {
            // Switch expressions return `true` for `nodeMayNeedMemoryLocation` thus
            // `elide_store_to_block_ptr_instructions` will either be true,
            // or all prongs are noreturn.
            if (!strat.elide_store_to_block_ptr_instructions) {
                astgen.extra.appendSliceAssumeCapacity(scalar_cases_payload.items);
                astgen.extra.appendSliceAssumeCapacity(multi_cases_payload.items);
                return indexToRef(switch_block);
            }

            // There will necessarily be a store_to_block_ptr for
            // all prongs, except for prongs that ended with a noreturn instruction.
            // Elide all the `store_to_block_ptr` instructions.

            // The break instructions need to have their operands coerced if the
            // switch's result location is a `ty`. In this case we overwrite the
            // `store_to_block_ptr` instruction with an `as` instruction and repurpose
            // it as the break operand.

            var extra_index: usize = 0;
            extra_index += 2;
            extra_index += @boolToInt(multi_cases_len != 0);
            if (special_prong != .none) special_prong: {
                const body_len_index = extra_index;
                const body_len = scalar_cases_payload.items[extra_index];
                extra_index += 1;
                if (body_len < 2) {
                    extra_index += body_len;
                    astgen.extra.appendSliceAssumeCapacity(scalar_cases_payload.items[0..extra_index]);
                    break :special_prong;
                }
                extra_index += body_len - 2;
                const store_inst = scalar_cases_payload.items[extra_index];
                if (zir_tags[store_inst] != .store_to_block_ptr or
                    zir_datas[store_inst].bin.lhs != block_scope.rl_ptr)
                {
                    extra_index += 2;
                    astgen.extra.appendSliceAssumeCapacity(scalar_cases_payload.items[0..extra_index]);
                    break :special_prong;
                }
                assert(zir_datas[store_inst].bin.lhs == block_scope.rl_ptr);
                if (block_scope.rl_ty_inst != .none) {
                    extra_index += 1;
                    const break_inst = scalar_cases_payload.items[extra_index];
                    extra_index += 1;
                    astgen.extra.appendSliceAssumeCapacity(scalar_cases_payload.items[0..extra_index]);
                    zir_tags[store_inst] = .as;
                    zir_datas[store_inst].bin = .{
                        .lhs = block_scope.rl_ty_inst,
                        .rhs = zir_datas[break_inst].@"break".operand,
                    };
                    zir_datas[break_inst].@"break".operand = indexToRef(store_inst);
                } else {
                    scalar_cases_payload.items[body_len_index] -= 1;
                    astgen.extra.appendSliceAssumeCapacity(scalar_cases_payload.items[0..extra_index]);
                    extra_index += 1;
                    astgen.extra.appendAssumeCapacity(scalar_cases_payload.items[extra_index]);
                    extra_index += 1;
                }
            } else {
                astgen.extra.appendSliceAssumeCapacity(scalar_cases_payload.items[0..extra_index]);
            }
            var scalar_i: u32 = 0;
            while (scalar_i < scalar_cases_len) : (scalar_i += 1) {
                const start_index = extra_index;
                extra_index += 1;
                const body_len_index = extra_index;
                const body_len = scalar_cases_payload.items[extra_index];
                extra_index += 1;
                if (body_len < 2) {
                    extra_index += body_len;
                    astgen.extra.appendSliceAssumeCapacity(scalar_cases_payload.items[start_index..extra_index]);
                    continue;
                }
                extra_index += body_len - 2;
                const store_inst = scalar_cases_payload.items[extra_index];
                if (zir_tags[store_inst] != .store_to_block_ptr or
                    zir_datas[store_inst].bin.lhs != block_scope.rl_ptr)
                {
                    extra_index += 2;
                    astgen.extra.appendSliceAssumeCapacity(scalar_cases_payload.items[start_index..extra_index]);
                    continue;
                }
                if (block_scope.rl_ty_inst != .none) {
                    extra_index += 1;
                    const break_inst = scalar_cases_payload.items[extra_index];
                    extra_index += 1;
                    astgen.extra.appendSliceAssumeCapacity(scalar_cases_payload.items[start_index..extra_index]);
                    zir_tags[store_inst] = .as;
                    zir_datas[store_inst].bin = .{
                        .lhs = block_scope.rl_ty_inst,
                        .rhs = zir_datas[break_inst].@"break".operand,
                    };
                    zir_datas[break_inst].@"break".operand = indexToRef(store_inst);
                } else {
                    scalar_cases_payload.items[body_len_index] -= 1;
                    astgen.extra.appendSliceAssumeCapacity(scalar_cases_payload.items[start_index..extra_index]);
                    extra_index += 1;
                    astgen.extra.appendAssumeCapacity(scalar_cases_payload.items[extra_index]);
                    extra_index += 1;
                }
            }
            extra_index = 0;
            var multi_i: u32 = 0;
            while (multi_i < multi_cases_len) : (multi_i += 1) {
                const start_index = extra_index;
                const items_len = multi_cases_payload.items[extra_index];
                extra_index += 1;
                const ranges_len = multi_cases_payload.items[extra_index];
                extra_index += 1;
                const body_len_index = extra_index;
                const body_len = multi_cases_payload.items[extra_index];
                extra_index += 1;
                extra_index += items_len;
                extra_index += 2 * ranges_len;
                if (body_len < 2) {
                    extra_index += body_len;
                    astgen.extra.appendSliceAssumeCapacity(multi_cases_payload.items[start_index..extra_index]);
                    continue;
                }
                extra_index += body_len - 2;
                const store_inst = multi_cases_payload.items[extra_index];
                if (zir_tags[store_inst] != .store_to_block_ptr or
                    zir_datas[store_inst].bin.lhs != block_scope.rl_ptr)
                {
                    extra_index += 2;
                    astgen.extra.appendSliceAssumeCapacity(multi_cases_payload.items[start_index..extra_index]);
                    continue;
                }
                if (block_scope.rl_ty_inst != .none) {
                    extra_index += 1;
                    const break_inst = multi_cases_payload.items[extra_index];
                    extra_index += 1;
                    astgen.extra.appendSliceAssumeCapacity(multi_cases_payload.items[start_index..extra_index]);
                    zir_tags[store_inst] = .as;
                    zir_datas[store_inst].bin = .{
                        .lhs = block_scope.rl_ty_inst,
                        .rhs = zir_datas[break_inst].@"break".operand,
                    };
                    zir_datas[break_inst].@"break".operand = indexToRef(store_inst);
                } else {
                    assert(zir_datas[store_inst].bin.lhs == block_scope.rl_ptr);
                    multi_cases_payload.items[body_len_index] -= 1;
                    astgen.extra.appendSliceAssumeCapacity(multi_cases_payload.items[start_index..extra_index]);
                    extra_index += 1;
                    astgen.extra.appendAssumeCapacity(multi_cases_payload.items[extra_index]);
                    extra_index += 1;
                }
            }

            const block_ref = indexToRef(switch_block);
            switch (rl) {
                .ref => return block_ref,
                else => return rvalue(parent_gz, rl, block_ref, switch_node),
            }
        },
        .break_void => {
            assert(!strat.elide_store_to_block_ptr_instructions);
            astgen.extra.appendSliceAssumeCapacity(scalar_cases_payload.items);
            astgen.extra.appendSliceAssumeCapacity(multi_cases_payload.items);
            // Modify all the terminating instruction tags to become `break` variants.
            var extra_index: usize = payload_index;
            extra_index += 2;
            extra_index += @boolToInt(multi_cases_len != 0);
            if (special_prong != .none) {
                const body_len = astgen.extra.items[extra_index];
                extra_index += 1;
                const body = astgen.extra.items[extra_index..][0..body_len];
                extra_index += body_len;
                const last = body[body.len - 1];
                if (zir_tags[last] == .@"break" and
                    zir_datas[last].@"break".block_inst == switch_block)
                {
                    zir_datas[last].@"break".operand = .void_value;
                }
            }
            var scalar_i: u32 = 0;
            while (scalar_i < scalar_cases_len) : (scalar_i += 1) {
                extra_index += 1;
                const body_len = astgen.extra.items[extra_index];
                extra_index += 1;
                const body = astgen.extra.items[extra_index..][0..body_len];
                extra_index += body_len;
                const last = body[body.len - 1];
                if (zir_tags[last] == .@"break" and
                    zir_datas[last].@"break".block_inst == switch_block)
                {
                    zir_datas[last].@"break".operand = .void_value;
                }
            }
            var multi_i: u32 = 0;
            while (multi_i < multi_cases_len) : (multi_i += 1) {
                const items_len = astgen.extra.items[extra_index];
                extra_index += 1;
                const ranges_len = astgen.extra.items[extra_index];
                extra_index += 1;
                const body_len = astgen.extra.items[extra_index];
                extra_index += 1;
                extra_index += items_len;
                extra_index += 2 * ranges_len;
                const body = astgen.extra.items[extra_index..][0..body_len];
                extra_index += body_len;
                const last = body[body.len - 1];
                if (zir_tags[last] == .@"break" and
                    zir_datas[last].@"break".block_inst == switch_block)
                {
                    zir_datas[last].@"break".operand = .void_value;
                }
            }

            return indexToRef(switch_block);
        },
    }
}

fn ret(gz: *GenZir, scope: *Scope, node: ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);
    const node_tags = tree.nodes.items(.tag);

    if (astgen.fn_block == null) {
        return astgen.failNode(node, "'return' outside function scope", .{});
    }

    if (gz.in_defer) return astgen.failNode(node, "cannot return from defer expression", .{});

    const defer_outer = &astgen.fn_block.?.base;

    const operand_node = node_datas[node].lhs;
    if (operand_node == 0) {
        // Returning a void value; skip error defers.
        try genDefers(gz, defer_outer, scope, .normal_only);
        _ = try gz.addUnNode(.ret_node, .void_value, node);
        return Zir.Inst.Ref.unreachable_value;
    }

    if (node_tags[operand_node] == .error_value) {
        // Hot path for `return error.Foo`. This bypasses result location logic as well as logic
        // for detecting whether to add something to the function's inferred error set.
        const ident_token = node_datas[operand_node].rhs;
        const err_name_str_index = try astgen.identAsString(ident_token);
        const defer_counts = countDefers(astgen, defer_outer, scope);
        if (!defer_counts.need_err_code) {
            try genDefers(gz, defer_outer, scope, .both_sans_err);
            _ = try gz.addStrTok(.ret_err_value, err_name_str_index, ident_token);
            return Zir.Inst.Ref.unreachable_value;
        }
        const err_code = try gz.addStrTok(.ret_err_value_code, err_name_str_index, ident_token);
        try genDefers(gz, defer_outer, scope, .{ .both = err_code });
        _ = try gz.addUnNode(.ret_node, err_code, node);
        return Zir.Inst.Ref.unreachable_value;
    }

    const rl: ResultLoc = if (nodeMayNeedMemoryLocation(tree, operand_node)) .{
        .ptr = try gz.addNodeExtended(.ret_ptr, node),
    } else .{
        .ty = try gz.addNodeExtended(.ret_type, node),
    };
    const operand = try expr(gz, scope, rl, operand_node);

    switch (nodeMayEvalToError(tree, operand_node)) {
        .never => {
            // Returning a value that cannot be an error; skip error defers.
            try genDefers(gz, defer_outer, scope, .normal_only);
            _ = try gz.addUnNode(.ret_node, operand, node);
            return Zir.Inst.Ref.unreachable_value;
        },
        .always => {
            // Value is always an error. Emit both error defers and regular defers.
            const err_code = try gz.addUnNode(.err_union_code, operand, node);
            try genDefers(gz, defer_outer, scope, .{ .both = err_code });
            _ = try gz.addUnNode(.ret_node, operand, node);
            return Zir.Inst.Ref.unreachable_value;
        },
        .maybe => {
            const defer_counts = countDefers(astgen, defer_outer, scope);
            if (!defer_counts.have_err) {
                // Only regular defers; no branch needed.
                try genDefers(gz, defer_outer, scope, .normal_only);
                _ = try gz.addUnNode(.ret_node, operand, node);
                return Zir.Inst.Ref.unreachable_value;
            }

            // Emit conditional branch for generating errdefers.
            const is_non_err = try gz.addUnNode(.is_non_err, operand, node);
            const condbr = try gz.addCondBr(.condbr, node);

            var then_scope = gz.makeSubBlock(scope);
            defer then_scope.instructions.deinit(astgen.gpa);

            try genDefers(&then_scope, defer_outer, scope, .normal_only);
            _ = try then_scope.addUnNode(.ret_node, operand, node);

            var else_scope = gz.makeSubBlock(scope);
            defer else_scope.instructions.deinit(astgen.gpa);

            const which_ones: DefersToEmit = if (!defer_counts.need_err_code) .both_sans_err else .{
                .both = try else_scope.addUnNode(.err_union_code, operand, node),
            };
            try genDefers(&else_scope, defer_outer, scope, which_ones);
            _ = try else_scope.addUnNode(.ret_node, operand, node);

            try setCondBrPayload(condbr, is_non_err, &then_scope, &else_scope);

            return Zir.Inst.Ref.unreachable_value;
        },
    }
}

fn identifier(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    ident: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const tracy = trace(@src());
    defer tracy.end();

    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);

    const ident_token = main_tokens[ident];
    const ident_name_raw = tree.tokenSlice(ident_token);
    if (mem.eql(u8, ident_name_raw, "_")) {
        return astgen.failNode(ident, "'_' used as an identifier without @\"_\" syntax", .{});
    }
    const ident_name = try astgen.identifierTokenString(ident_token);

    if (simple_types.get(ident_name)) |zir_const_ref| {
        return rvalue(gz, rl, zir_const_ref, ident);
    }

    if (ident_name.len >= 2) integer: {
        const first_c = ident_name[0];
        if (first_c == 'i' or first_c == 'u') {
            const signedness: std.builtin.Signedness = switch (first_c == 'i') {
                true => .signed,
                false => .unsigned,
            };
            const bit_count = std.fmt.parseInt(u16, ident_name[1..], 10) catch |err| switch (err) {
                error.Overflow => return astgen.failNode(
                    ident,
                    "primitive integer type '{s}' exceeds maximum bit width of 65535",
                    .{ident_name},
                ),
                error.InvalidCharacter => break :integer,
            };
            const result = try gz.add(.{
                .tag = .int_type,
                .data = .{ .int_type = .{
                    .src_node = gz.nodeIndexToRelative(ident),
                    .signedness = signedness,
                    .bit_count = bit_count,
                } },
            });
            return rvalue(gz, rl, result, ident);
        }
    }

    // Local variables, including function parameters.
    const name_str_index = try astgen.identAsString(ident_token);
    {
        var s = scope;
        var found_already: ?ast.Node.Index = null; // we have found a decl with the same name already
        var hit_namespace = false;
        while (true) switch (s.tag) {
            .local_val => {
                const local_val = s.cast(Scope.LocalVal).?;

                if (local_val.name == name_str_index) {
                    local_val.used = true;
                    // Captures of non-locals need to be emitted as decl_val or decl_ref.
                    // This *might* be capturable depending on if it is comptime known.
                    if (!hit_namespace) {
                        return rvalue(gz, rl, local_val.inst, ident);
                    }
                }
                s = local_val.parent;
            },
            .local_ptr => {
                const local_ptr = s.cast(Scope.LocalPtr).?;
                if (local_ptr.name == name_str_index) {
                    local_ptr.used = true;
                    if (hit_namespace) {
                        if (local_ptr.maybe_comptime)
                            break
                        else
                            return astgen.failNodeNotes(ident, "'{s}' not accessible from inner function", .{ident_name}, &.{
                                try astgen.errNoteTok(local_ptr.token_src, "declared here", .{}),
                                // TODO add crossed function definition here note.
                                // Maybe add a note to the error about it being because of the var,
                                // maybe recommend copying it into a const variable. -SpexGuy
                            });
                    }
                    switch (rl) {
                        .ref, .none_or_ref => return local_ptr.ptr,
                        else => {
                            const loaded = try gz.addUnNode(.load, local_ptr.ptr, ident);
                            return rvalue(gz, rl, loaded, ident);
                        },
                    }
                }
                s = local_ptr.parent;
            },
            .gen_zir => s = s.cast(GenZir).?.parent,
            .defer_normal, .defer_error => s = s.cast(Scope.Defer).?.parent,
            // look for ambiguous references to decls
            .namespace => {
                const ns = s.cast(Scope.Namespace).?;
                if (ns.decls.get(name_str_index)) |i| {
                    if (found_already) |f|
                        return astgen.failNodeNotes(ident, "ambiguous reference", .{}, &.{
                            try astgen.errNoteNode(i, "declared here", .{}),
                            try astgen.errNoteNode(f, "also declared here", .{}),
                        })
                    else
                        found_already = i;
                }
                hit_namespace = true;
                s = ns.parent;
            },
            .top => break,
        };
    }

    // We can't look up Decls until Sema because the same ZIR code is supposed to be
    // used for multiple generic instantiations, and this may refer to a different Decl
    // depending on the scope, determined by the generic instantiation.
    switch (rl) {
        .ref, .none_or_ref => return gz.addStrTok(.decl_ref, name_str_index, ident_token),
        else => {
            const result = try gz.addStrTok(.decl_val, name_str_index, ident_token);
            return rvalue(gz, rl, result, ident);
        },
    }
}

fn stringLiteral(
    gz: *GenZir,
    rl: ResultLoc,
    node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);
    const str_lit_token = main_tokens[node];
    const str = try astgen.strLitAsString(str_lit_token);
    const result = try gz.add(.{
        .tag = .str,
        .data = .{ .str = .{
            .start = str.index,
            .len = str.len,
        } },
    });
    return rvalue(gz, rl, result, node);
}

fn multilineStringLiteral(
    gz: *GenZir,
    rl: ResultLoc,
    node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const node_datas = tree.nodes.items(.data);

    const start = node_datas[node].lhs;
    const end = node_datas[node].rhs;

    const gpa = gz.astgen.gpa;
    const string_bytes = &gz.astgen.string_bytes;
    const str_index = string_bytes.items.len;

    // First line: do not append a newline.
    var tok_i = start;
    {
        const slice = tree.tokenSlice(tok_i);
        const line_bytes = slice[2 .. slice.len - 1];
        try string_bytes.appendSlice(gpa, line_bytes);
        tok_i += 1;
    }
    // Following lines: each line prepends a newline.
    while (tok_i <= end) : (tok_i += 1) {
        const slice = tree.tokenSlice(tok_i);
        const line_bytes = slice[2 .. slice.len - 1];
        try string_bytes.ensureCapacity(gpa, string_bytes.items.len + line_bytes.len + 1);
        string_bytes.appendAssumeCapacity('\n');
        string_bytes.appendSliceAssumeCapacity(line_bytes);
    }
    const result = try gz.add(.{
        .tag = .str,
        .data = .{ .str = .{
            .start = @intCast(u32, str_index),
            .len = @intCast(u32, string_bytes.items.len - str_index),
        } },
    });
    return rvalue(gz, rl, result, node);
}

fn charLiteral(gz: *GenZir, rl: ResultLoc, node: ast.Node.Index) !Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);
    const main_token = main_tokens[node];
    const slice = tree.tokenSlice(main_token);

    switch (std.zig.parseCharLiteral(slice)) {
        .success => |codepoint| {
            const result = try gz.addInt(codepoint);
            return rvalue(gz, rl, result, node);
        },
        .invalid_escape_character => |bad_index| {
            return astgen.failOff(
                main_token,
                @intCast(u32, bad_index),
                "invalid escape character: '{c}'",
                .{slice[bad_index]},
            );
        },
        .expected_hex_digit => |bad_index| {
            return astgen.failOff(
                main_token,
                @intCast(u32, bad_index),
                "expected hex digit, found '{c}'",
                .{slice[bad_index]},
            );
        },
        .empty_unicode_escape_sequence => |bad_index| {
            return astgen.failOff(
                main_token,
                @intCast(u32, bad_index),
                "empty unicode escape sequence",
                .{},
            );
        },
        .expected_hex_digit_or_rbrace => |bad_index| {
            return astgen.failOff(
                main_token,
                @intCast(u32, bad_index),
                "expected hex digit or '}}', found '{c}'",
                .{slice[bad_index]},
            );
        },
        .unicode_escape_overflow => |bad_index| {
            return astgen.failOff(
                main_token,
                @intCast(u32, bad_index),
                "unicode escape too large to be a valid codepoint",
                .{},
            );
        },
        .expected_lbrace => |bad_index| {
            return astgen.failOff(
                main_token,
                @intCast(u32, bad_index),
                "expected '{{', found '{c}",
                .{slice[bad_index]},
            );
        },
        .expected_end => |bad_index| {
            return astgen.failOff(
                main_token,
                @intCast(u32, bad_index),
                "expected ending single quote ('), found '{c}",
                .{slice[bad_index]},
            );
        },
        .invalid_character => |bad_index| {
            return astgen.failOff(
                main_token,
                @intCast(u32, bad_index),
                "invalid byte in character literal: '{c}'",
                .{slice[bad_index]},
            );
        },
    }
}

fn integerLiteral(gz: *GenZir, rl: ResultLoc, node: ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);
    const int_token = main_tokens[node];
    const prefixed_bytes = tree.tokenSlice(int_token);
    if (std.fmt.parseInt(u64, prefixed_bytes, 0)) |small_int| {
        const result: Zir.Inst.Ref = switch (small_int) {
            0 => .zero,
            1 => .one,
            else => try gz.addInt(small_int),
        };
        return rvalue(gz, rl, result, node);
    } else |err| switch (err) {
        error.InvalidCharacter => unreachable, // Caught by the parser.
        error.Overflow => {},
    }

    var base: u8 = 10;
    var non_prefixed: []const u8 = prefixed_bytes;
    if (mem.startsWith(u8, prefixed_bytes, "0x")) {
        base = 16;
        non_prefixed = prefixed_bytes[2..];
    } else if (mem.startsWith(u8, prefixed_bytes, "0o")) {
        base = 8;
        non_prefixed = prefixed_bytes[2..];
    } else if (mem.startsWith(u8, prefixed_bytes, "0b")) {
        base = 2;
        non_prefixed = prefixed_bytes[2..];
    }

    const gpa = astgen.gpa;
    var big_int = try std.math.big.int.Managed.init(gpa);
    defer big_int.deinit();
    big_int.setString(base, non_prefixed) catch |err| switch (err) {
        error.InvalidCharacter => unreachable, // caught by parser
        error.InvalidBase => unreachable, // we only pass 16, 8, 2, see above
        error.OutOfMemory => return error.OutOfMemory,
    };

    const limbs = big_int.limbs[0..big_int.len()];
    assert(big_int.isPositive());
    const result = try gz.addIntBig(limbs);
    return rvalue(gz, rl, result, node);
}

fn floatLiteral(gz: *GenZir, rl: ResultLoc, node: ast.Node.Index) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);

    const main_token = main_tokens[node];
    const bytes = tree.tokenSlice(main_token);
    const float_number: f128 = if (bytes.len > 2 and bytes[1] == 'x') hex: {
        assert(bytes[0] == '0'); // validated by tokenizer
        break :hex std.fmt.parseHexFloat(f128, bytes) catch |err| switch (err) {
            error.InvalidCharacter => unreachable, // validated by tokenizer
            error.Overflow => return astgen.failNode(node, "number literal cannot be represented in a 128-bit floating point", .{}),
        };
    } else std.fmt.parseFloat(f128, bytes) catch |err| switch (err) {
        error.InvalidCharacter => unreachable, // validated by tokenizer
    };
    // If the value fits into a f32 without losing any precision, store it that way.
    @setFloatMode(.Strict);
    const smaller_float = @floatCast(f32, float_number);
    const bigger_again: f128 = smaller_float;
    if (bigger_again == float_number) {
        const result = try gz.addFloat(smaller_float, node);
        return rvalue(gz, rl, result, node);
    }
    // We need to use 128 bits. Break the float into 4 u32 values so we can
    // put it into the `extra` array.
    const int_bits = @bitCast(u128, float_number);
    const result = try gz.addPlNode(.float128, node, Zir.Inst.Float128{
        .piece0 = @truncate(u32, int_bits),
        .piece1 = @truncate(u32, int_bits >> 32),
        .piece2 = @truncate(u32, int_bits >> 64),
        .piece3 = @truncate(u32, int_bits >> 96),
    });
    return rvalue(gz, rl, result, node);
}

fn asmExpr(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    full: ast.full.Asm,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);
    const node_datas = tree.nodes.items(.data);
    const token_tags = tree.tokens.items(.tag);

    const asm_source = try comptimeExpr(gz, scope, .{ .ty = .const_slice_u8_type }, full.ast.template);

    // See https://github.com/ziglang/zig/issues/215 and related issues discussing
    // possible inline assembly improvements. Until then here is status quo AstGen
    // for assembly syntax. It's used by std lib crypto aesni.zig.
    const is_container_asm = astgen.fn_block == null;
    if (is_container_asm) {
        if (full.volatile_token) |t|
            return astgen.failTok(t, "volatile is meaningless on global assembly", .{});
        if (full.outputs.len != 0 or full.inputs.len != 0 or full.first_clobber != null)
            return astgen.failNode(node, "global assembly cannot have inputs, outputs, or clobbers", .{});
    } else {
        if (full.outputs.len == 0 and full.volatile_token == null) {
            return astgen.failNode(node, "assembly expression with no output must be marked volatile", .{});
        }
    }
    if (full.outputs.len > 32) {
        return astgen.failNode(full.outputs[32], "too many asm outputs", .{});
    }
    var outputs_buffer: [32]Zir.Inst.Asm.Output = undefined;
    const outputs = outputs_buffer[0..full.outputs.len];

    var output_type_bits: u32 = 0;

    for (full.outputs) |output_node, i| {
        const symbolic_name = main_tokens[output_node];
        const name = try astgen.identAsString(symbolic_name);
        const constraint_token = symbolic_name + 2;
        const constraint = (try astgen.strLitAsString(constraint_token)).index;
        const has_arrow = token_tags[symbolic_name + 4] == .arrow;
        if (has_arrow) {
            output_type_bits |= @as(u32, 1) << @intCast(u5, i);
            const out_type_node = node_datas[output_node].lhs;
            const out_type_inst = try typeExpr(gz, scope, out_type_node);
            outputs[i] = .{
                .name = name,
                .constraint = constraint,
                .operand = out_type_inst,
            };
        } else {
            const ident_token = symbolic_name + 4;
            const str_index = try astgen.identAsString(ident_token);
            // TODO this needs extra code for local variables. Have a look at #215 and related
            // issues and decide how to handle outputs. Do we want this to be identifiers?
            // Or maybe we want to force this to be expressions with a pointer type.
            // Until that is figured out this is only hooked up for referencing Decls.
            // TODO we have put this as an identifier lookup just so that we don't get
            // unused vars for outputs. We need to check if this is correct in the future ^^
            // so we just put in this simple lookup. This is a workaround.
            {
                var s = scope;
                while (true) switch (s.tag) {
                    .local_val => {
                        const local_val = s.cast(Scope.LocalVal).?;
                        if (local_val.name == str_index) {
                            local_val.used = true;
                            break;
                        }
                        s = local_val.parent;
                    },
                    .local_ptr => {
                        const local_ptr = s.cast(Scope.LocalPtr).?;
                        if (local_ptr.name == str_index) {
                            local_ptr.used = true;
                            break;
                        }
                        s = local_ptr.parent;
                    },
                    .gen_zir => s = s.cast(GenZir).?.parent,
                    .defer_normal, .defer_error => s = s.cast(Scope.Defer).?.parent,
                    .namespace, .top => break,
                };
            }
            const operand = try gz.addStrTok(.decl_ref, str_index, ident_token);
            outputs[i] = .{
                .name = name,
                .constraint = constraint,
                .operand = operand,
            };
        }
    }

    if (full.inputs.len > 32) {
        return astgen.failNode(full.inputs[32], "too many asm inputs", .{});
    }
    var inputs_buffer: [32]Zir.Inst.Asm.Input = undefined;
    const inputs = inputs_buffer[0..full.inputs.len];

    for (full.inputs) |input_node, i| {
        const symbolic_name = main_tokens[input_node];
        const name = try astgen.identAsString(symbolic_name);
        const constraint_token = symbolic_name + 2;
        const constraint = (try astgen.strLitAsString(constraint_token)).index;
        const operand = try expr(gz, scope, .{ .ty = .usize_type }, node_datas[input_node].lhs);
        inputs[i] = .{
            .name = name,
            .constraint = constraint,
            .operand = operand,
        };
    }

    var clobbers_buffer: [32]u32 = undefined;
    var clobber_i: usize = 0;
    if (full.first_clobber) |first_clobber| clobbers: {
        // asm ("foo" ::: "a", "b")
        // asm ("foo" ::: "a", "b",)
        var tok_i = first_clobber;
        while (true) : (tok_i += 1) {
            if (clobber_i >= clobbers_buffer.len) {
                return astgen.failTok(tok_i, "too many asm clobbers", .{});
            }
            clobbers_buffer[clobber_i] = (try astgen.strLitAsString(tok_i)).index;
            clobber_i += 1;
            tok_i += 1;
            switch (token_tags[tok_i]) {
                .r_paren => break :clobbers,
                .comma => {
                    if (token_tags[tok_i + 1] == .r_paren) {
                        break :clobbers;
                    } else {
                        continue;
                    }
                },
                else => unreachable,
            }
        }
    }

    const result = try gz.addAsm(.{
        .node = node,
        .asm_source = asm_source,
        .is_volatile = full.volatile_token != null,
        .output_type_bits = output_type_bits,
        .outputs = outputs,
        .inputs = inputs,
        .clobbers = clobbers_buffer[0..clobber_i],
    });
    return rvalue(gz, rl, result, node);
}

fn as(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    lhs: ast.Node.Index,
    rhs: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const dest_type = try typeExpr(gz, scope, lhs);
    switch (rl) {
        .none, .none_or_ref, .discard, .ref, .ty => {
            const result = try reachableExpr(gz, scope, .{ .ty = dest_type }, rhs, node);
            return rvalue(gz, rl, result, node);
        },
        .ptr, .inferred_ptr => |result_ptr| {
            return asRlPtr(gz, scope, rl, node, result_ptr, rhs, dest_type);
        },
        .block_ptr => |block_scope| {
            return asRlPtr(gz, scope, rl, node, block_scope.rl_ptr, rhs, dest_type);
        },
    }
}

fn unionInit(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    params: []const ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const union_type = try typeExpr(gz, scope, params[0]);
    const field_name = try comptimeExpr(gz, scope, .{ .ty = .const_slice_u8_type }, params[1]);
    switch (rl) {
        .none, .none_or_ref, .discard, .ref, .ty, .inferred_ptr => {
            _ = try gz.addPlNode(.field_type_ref, params[1], Zir.Inst.FieldTypeRef{
                .container_type = union_type,
                .field_name = field_name,
            });
            const result = try expr(gz, scope, .{ .ty = union_type }, params[2]);
            return rvalue(gz, rl, result, node);
        },
        .ptr => |result_ptr| {
            return unionInitRlPtr(gz, scope, node, result_ptr, params[2], union_type, field_name);
        },
        .block_ptr => |block_scope| {
            return unionInitRlPtr(gz, scope, node, block_scope.rl_ptr, params[2], union_type, field_name);
        },
    }
}

fn unionInitRlPtr(
    parent_gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
    result_ptr: Zir.Inst.Ref,
    expr_node: ast.Node.Index,
    union_type: Zir.Inst.Ref,
    field_name: Zir.Inst.Ref,
) InnerError!Zir.Inst.Ref {
    const union_init_ptr = try parent_gz.addPlNode(.union_init_ptr, node, Zir.Inst.UnionInitPtr{
        .result_ptr = result_ptr,
        .union_type = union_type,
        .field_name = field_name,
    });
    // TODO check if we need to do the elision like below in asRlPtr
    return expr(parent_gz, scope, .{ .ptr = union_init_ptr }, expr_node);
}

fn asRlPtr(
    parent_gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    src_node: ast.Node.Index,
    result_ptr: Zir.Inst.Ref,
    operand_node: ast.Node.Index,
    dest_type: Zir.Inst.Ref,
) InnerError!Zir.Inst.Ref {
    // Detect whether this expr() call goes into rvalue() to store the result into the
    // result location. If it does, elide the coerce_result_ptr instruction
    // as well as the store instruction, instead passing the result as an rvalue.
    const astgen = parent_gz.astgen;

    var as_scope = parent_gz.makeSubBlock(scope);
    defer as_scope.instructions.deinit(astgen.gpa);

    as_scope.rl_ptr = try as_scope.addBin(.coerce_result_ptr, dest_type, result_ptr);
    const result = try reachableExpr(&as_scope, &as_scope.base, .{ .block_ptr = &as_scope }, operand_node, src_node);
    const parent_zir = &parent_gz.instructions;
    if (as_scope.rvalue_rl_count == 1) {
        // Busted! This expression didn't actually need a pointer.
        const zir_tags = astgen.instructions.items(.tag);
        const zir_datas = astgen.instructions.items(.data);
        try parent_zir.ensureUnusedCapacity(astgen.gpa, as_scope.instructions.items.len);
        for (as_scope.instructions.items) |src_inst| {
            if (indexToRef(src_inst) == as_scope.rl_ptr) continue;
            if (zir_tags[src_inst] == .store_to_block_ptr) {
                if (zir_datas[src_inst].bin.lhs == as_scope.rl_ptr) continue;
            }
            parent_zir.appendAssumeCapacity(src_inst);
        }
        const casted_result = try parent_gz.addBin(.as, dest_type, result);
        return rvalue(parent_gz, rl, casted_result, operand_node);
    } else {
        try parent_zir.appendSlice(astgen.gpa, as_scope.instructions.items);
        return result;
    }
}

fn bitCast(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    lhs: ast.Node.Index,
    rhs: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const dest_type = try typeExpr(gz, scope, lhs);
    switch (rl) {
        .none, .none_or_ref, .discard, .ty => {
            const operand = try expr(gz, scope, .none, rhs);
            const result = try gz.addPlNode(.bitcast, node, Zir.Inst.Bin{
                .lhs = dest_type,
                .rhs = operand,
            });
            return rvalue(gz, rl, result, node);
        },
        .ref => {
            return astgen.failNode(node, "cannot take address of `@bitCast` result", .{});
        },
        .ptr, .inferred_ptr => |result_ptr| {
            return bitCastRlPtr(gz, scope, node, dest_type, result_ptr, rhs);
        },
        .block_ptr => |block| {
            return bitCastRlPtr(gz, scope, node, dest_type, block.rl_ptr, rhs);
        },
    }
}

fn bitCastRlPtr(
    gz: *GenZir,
    scope: *Scope,
    node: ast.Node.Index,
    dest_type: Zir.Inst.Ref,
    result_ptr: Zir.Inst.Ref,
    rhs: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const casted_result_ptr = try gz.addPlNode(.bitcast_result_ptr, node, Zir.Inst.Bin{
        .lhs = dest_type,
        .rhs = result_ptr,
    });
    return expr(gz, scope, .{ .ptr = casted_result_ptr }, rhs);
}

fn typeOf(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    params: []const ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    if (params.len < 1) {
        return gz.astgen.failNode(node, "expected at least 1 argument, found 0", .{});
    }
    if (params.len == 1) {
        const expr_result = try reachableExpr(gz, scope, .none, params[0], node);
        const result = try gz.addUnNode(.typeof, expr_result, node);
        return rvalue(gz, rl, result, node);
    }
    const arena = gz.astgen.arena;
    var items = try arena.alloc(Zir.Inst.Ref, params.len);
    for (params) |param, param_i| {
        items[param_i] = try reachableExpr(gz, scope, .none, param, node);
    }

    const result = try gz.addExtendedMultiOp(.typeof_peer, node, items);
    return rvalue(gz, rl, result, node);
}

fn builtinCall(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    params: []const ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const tree = astgen.tree;
    const main_tokens = tree.nodes.items(.main_token);

    const builtin_token = main_tokens[node];
    const builtin_name = tree.tokenSlice(builtin_token);

    // We handle the different builtins manually because they have different semantics depending
    // on the function. For example, `@as` and others participate in result location semantics,
    // and `@cImport` creates a special scope that collects a .c source code text buffer.
    // Also, some builtins have a variable number of parameters.

    const info = BuiltinFn.list.get(builtin_name) orelse {
        return astgen.failNode(node, "invalid builtin function: '{s}'", .{
            builtin_name,
        });
    };
    if (info.param_count) |expected| {
        if (expected != params.len) {
            const s = if (expected == 1) "" else "s";
            return astgen.failNode(node, "expected {d} argument{s}, found {d}", .{
                expected, s, params.len,
            });
        }
    }

    // zig fmt: off
    switch (info.tag) {
        .import => {
            const node_tags = tree.nodes.items(.tag);
            const operand_node = params[0];

            if (node_tags[operand_node] != .string_literal) {
                // Spec reference: https://github.com/ziglang/zig/issues/2206
                return astgen.failNode(operand_node, "@import operand must be a string literal", .{});
            }
            const str_lit_token = main_tokens[operand_node];
            const str = try astgen.strLitAsString(str_lit_token);
            const result = try gz.addStrTok(.import, str.index, str_lit_token);
            if (refToIndex(result)) |import_inst_index| {
                const gop = try astgen.imports.getOrPut(astgen.gpa, str.index);
                if (!gop.found_existing) {
                    gop.value_ptr.* = import_inst_index;
                }
            }
            return rvalue(gz, rl, result, node);
        },
        .compile_log => {
            const arg_refs = try astgen.gpa.alloc(Zir.Inst.Ref, params.len);
            defer astgen.gpa.free(arg_refs);

            for (params) |param, i| arg_refs[i] = try expr(gz, scope, .none, param);

            const result = try gz.addExtendedMultiOp(.compile_log, node, arg_refs);
            return rvalue(gz, rl, result, node);
        },
        .field => {
            const field_name = try comptimeExpr(gz, scope, .{ .ty = .const_slice_u8_type }, params[1]);
            if (rl == .ref) {
                return gz.addPlNode(.field_ptr_named, node, Zir.Inst.FieldNamed{
                    .lhs = try expr(gz, scope, .ref, params[0]),
                    .field_name = field_name,
                });
            }
            const result = try gz.addPlNode(.field_val_named, node, Zir.Inst.FieldNamed{
                .lhs = try expr(gz, scope, .none, params[0]),
                .field_name = field_name,
            });
            return rvalue(gz, rl, result, node);
        },
        .as         => return as(       gz, scope, rl, node, params[0], params[1]),
        .bit_cast   => return bitCast(  gz, scope, rl, node, params[0], params[1]),
        .TypeOf     => return typeOf(   gz, scope, rl, node, params),
        .union_init => return unionInit(gz, scope, rl, node, params),
        .c_import   => return cImport(  gz, scope, rl, node, params[0]),

        .@"export" => {
            const node_tags = tree.nodes.items(.tag);
            const node_datas = tree.nodes.items(.data);
            // This function causes a Decl to be exported. The first parameter is not an expression,
            // but an identifier of the Decl to be exported.
            var namespace: Zir.Inst.Ref = .none;
            var decl_name: u32 = 0;
            switch (node_tags[params[0]]) {
                .identifier => {
                    const ident_token = main_tokens[params[0]];
                    decl_name = try astgen.identAsString(ident_token);
                    {
                        var s = scope;
                        while (true) switch (s.tag) {
                            .local_val => {
                                const local_val = s.cast(Scope.LocalVal).?;
                                if (local_val.name == decl_name) {
                                    local_val.used = true;
                                    break;
                                }
                                s = local_val.parent;
                            },
                            .local_ptr => {
                                const local_ptr = s.cast(Scope.LocalPtr).?;
                                if (local_ptr.name == decl_name) {
                                    if (!local_ptr.maybe_comptime)
                                        return astgen.failNode(params[0], "unable to export runtime-known value", .{});
                                    local_ptr.used = true;
                                    break;
                                }
                                s = local_ptr.parent;
                            },
                            .gen_zir => s = s.cast(GenZir).?.parent,
                            .defer_normal, .defer_error => s = s.cast(Scope.Defer).?.parent,
                            .namespace, .top => break,
                        };
                    }
                },
                .field_access => {
                    const namespace_node = node_datas[params[0]].lhs;
                    namespace = try typeExpr(gz, scope, namespace_node);
                    const dot_token = main_tokens[params[0]];
                    const field_ident = dot_token + 1;
                    decl_name = try astgen.identAsString(field_ident);
                },
                else => return astgen.failNode(
                    params[0], "symbol to export must identify a declaration", .{},
                ),
            }
            const options = try comptimeExpr(gz, scope, .{ .ty = .export_options_type }, params[1]);
            _ = try gz.addPlNode(.@"export", node, Zir.Inst.Export{
                .namespace = namespace,
                .decl_name = decl_name,
                .options = options,
            });
            return rvalue(gz, rl, .void_value, node);
        },
        .@"extern" => {
            const type_inst = try typeExpr(gz, scope, params[0]);
            const options = try comptimeExpr(gz, scope, .{ .ty = .extern_options_type }, params[1]);
            const result = try gz.addExtendedPayload(.builtin_extern, Zir.Inst.BinNode{
                .node = gz.nodeIndexToRelative(node),
                .lhs = type_inst,
                .rhs = options,
            });
            return rvalue(gz, rl, result, node);
        },

        .breakpoint => return simpleNoOpVoid(gz, rl, node, .breakpoint),
        .fence      => return simpleNoOpVoid(gz, rl, node, .fence),

        .This               => return rvalue(gz, rl, try gz.addNodeExtended(.this,               node), node),
        .return_address     => return rvalue(gz, rl, try gz.addNodeExtended(.ret_addr,           node), node),
        .src                => return rvalue(gz, rl, try gz.addNodeExtended(.builtin_src,        node), node),
        .error_return_trace => return rvalue(gz, rl, try gz.addNodeExtended(.error_return_trace, node), node),
        .frame              => return rvalue(gz, rl, try gz.addNodeExtended(.frame,              node), node),
        .frame_address      => return rvalue(gz, rl, try gz.addNodeExtended(.frame_address,      node), node),

        .type_info   => return simpleUnOpType(gz, scope, rl, node, params[0], .type_info),
        .size_of     => return simpleUnOpType(gz, scope, rl, node, params[0], .size_of),
        .bit_size_of => return simpleUnOpType(gz, scope, rl, node, params[0], .bit_size_of),
        .align_of    => return simpleUnOpType(gz, scope, rl, node, params[0], .align_of),

        .ptr_to_int            => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .ptr_to_int),
        .error_to_int          => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .error_to_int),
        .int_to_error          => return simpleUnOp(gz, scope, rl, node, .{ .ty = .u16_type },            params[0], .int_to_error),
        .compile_error         => return simpleUnOp(gz, scope, rl, node, .{ .ty = .const_slice_u8_type }, params[0], .compile_error),
        .set_eval_branch_quota => return simpleUnOp(gz, scope, rl, node, .{ .ty = .u32_type },            params[0], .set_eval_branch_quota),
        .enum_to_int           => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .enum_to_int),
        .bool_to_int           => return simpleUnOp(gz, scope, rl, node, bool_rl,                         params[0], .bool_to_int),
        .embed_file            => return simpleUnOp(gz, scope, rl, node, .{ .ty = .const_slice_u8_type }, params[0], .embed_file),
        .error_name            => return simpleUnOp(gz, scope, rl, node, .{ .ty = .anyerror_type },       params[0], .error_name),
        .panic                 => return simpleUnOp(gz, scope, rl, node, .{ .ty = .const_slice_u8_type }, params[0], .panic),
        .set_align_stack       => return simpleUnOp(gz, scope, rl, node, align_rl,                        params[0], .set_align_stack),
        .set_cold              => return simpleUnOp(gz, scope, rl, node, bool_rl,                         params[0], .set_cold),
        .set_float_mode        => return simpleUnOp(gz, scope, rl, node, .{ .ty = .float_mode_type },     params[0], .set_float_mode),
        .set_runtime_safety    => return simpleUnOp(gz, scope, rl, node, bool_rl,                         params[0], .set_runtime_safety),
        .sqrt                  => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .sqrt),
        .sin                   => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .sin),
        .cos                   => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .cos),
        .exp                   => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .exp),
        .exp2                  => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .exp2),
        .log                   => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .log),
        .log2                  => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .log2),
        .log10                 => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .log10),
        .fabs                  => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .fabs),
        .floor                 => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .floor),
        .ceil                  => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .ceil),
        .trunc                 => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .trunc),
        .round                 => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .round),
        .tag_name              => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .tag_name),
        .Type                  => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .reify),
        .type_name             => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .type_name),
        .Frame                 => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .frame_type),
        .frame_size            => return simpleUnOp(gz, scope, rl, node, .none,                           params[0], .frame_size),

        .float_to_int => return typeCast(gz, scope, rl, node, params[0], params[1], .float_to_int),
        .int_to_float => return typeCast(gz, scope, rl, node, params[0], params[1], .int_to_float),
        .int_to_ptr   => return typeCast(gz, scope, rl, node, params[0], params[1], .int_to_ptr),
        .int_to_enum  => return typeCast(gz, scope, rl, node, params[0], params[1], .int_to_enum),
        .float_cast   => return typeCast(gz, scope, rl, node, params[0], params[1], .float_cast),
        .int_cast     => return typeCast(gz, scope, rl, node, params[0], params[1], .int_cast),
        .err_set_cast => return typeCast(gz, scope, rl, node, params[0], params[1], .err_set_cast),
        .ptr_cast     => return typeCast(gz, scope, rl, node, params[0], params[1], .ptr_cast),
        .truncate     => return typeCast(gz, scope, rl, node, params[0], params[1], .truncate),
        .align_cast => {
            const dest_align = try comptimeExpr(gz, scope, align_rl, params[0]);
            const rhs = try expr(gz, scope, .none, params[1]);
            const result = try gz.addPlNode(.align_cast, node, Zir.Inst.Bin{
                .lhs = dest_align,
                .rhs = rhs,
            });
            return rvalue(gz, rl, result, node);
        },

        .has_decl  => return hasDeclOrField(gz, scope, rl, node, params[0], params[1], .has_decl),
        .has_field => return hasDeclOrField(gz, scope, rl, node, params[0], params[1], .has_field),

        .clz         => return bitBuiltin(gz, scope, rl, node, params[0], params[1], .clz),
        .ctz         => return bitBuiltin(gz, scope, rl, node, params[0], params[1], .ctz),
        .pop_count   => return bitBuiltin(gz, scope, rl, node, params[0], params[1], .pop_count),
        .byte_swap   => return bitBuiltin(gz, scope, rl, node, params[0], params[1], .byte_swap),
        .bit_reverse => return bitBuiltin(gz, scope, rl, node, params[0], params[1], .bit_reverse),

        .div_exact => return divBuiltin(gz, scope, rl, node, params[0], params[1], .div_exact),
        .div_floor => return divBuiltin(gz, scope, rl, node, params[0], params[1], .div_floor),
        .div_trunc => return divBuiltin(gz, scope, rl, node, params[0], params[1], .div_trunc),
        .mod       => return divBuiltin(gz, scope, rl, node, params[0], params[1], .mod),
        .rem       => return divBuiltin(gz, scope, rl, node, params[0], params[1], .rem),

        .shl_exact => return shiftOp(gz, scope, rl, node, params[0], params[1], .shl_exact),
        .shr_exact => return shiftOp(gz, scope, rl, node, params[0], params[1], .shr_exact),

        .bit_offset_of  => return offsetOf(gz, scope, rl, node, params[0], params[1], .bit_offset_of),
        .offset_of => return offsetOf(gz, scope, rl, node, params[0], params[1], .offset_of),

        .c_undef   => return simpleCBuiltin(gz, scope, rl, node, params[0], .c_undef),
        .c_include => return simpleCBuiltin(gz, scope, rl, node, params[0], .c_include),

        .cmpxchg_strong => return cmpxchg(gz, scope, rl, node, params, .cmpxchg_strong),
        .cmpxchg_weak   => return cmpxchg(gz, scope, rl, node, params, .cmpxchg_weak),

        .wasm_memory_size => {
            const operand = try expr(gz, scope, .{ .ty = .u32_type }, params[0]);
            const result = try gz.addExtendedPayload(.wasm_memory_size, Zir.Inst.UnNode{
                .node = gz.nodeIndexToRelative(node),
                .operand = operand,
            });
            return rvalue(gz, rl, result, node);
        },
        .wasm_memory_grow => {
            const index_arg = try expr(gz, scope, .{ .ty = .u32_type }, params[0]);
            const delta_arg = try expr(gz, scope, .{ .ty = .u32_type }, params[1]);
            const result = try gz.addExtendedPayload(.wasm_memory_grow, Zir.Inst.BinNode{
                .node = gz.nodeIndexToRelative(node),
                .lhs = index_arg,
                .rhs = delta_arg,
            });
            return rvalue(gz, rl, result, node);
        },
        .c_define => {
            const name = try comptimeExpr(gz, scope, .{ .ty = .const_slice_u8_type }, params[0]);
            const value = try comptimeExpr(gz, scope, .none, params[1]);
            const result = try gz.addExtendedPayload(.c_define, Zir.Inst.BinNode{
                .node = gz.nodeIndexToRelative(node),
                .lhs = name,
                .rhs = value,
            });
            return rvalue(gz, rl, result, node);
        },

        .splat => {
            const len = try expr(gz, scope, .{ .ty = .u32_type }, params[0]);
            const scalar = try expr(gz, scope, .none, params[1]);
            const result = try gz.addPlNode(.splat, node, Zir.Inst.Bin{
                .lhs = len,
                .rhs = scalar,
            });
            return rvalue(gz, rl, result, node);
        },
        .reduce => {
            const op = try expr(gz, scope, .{ .ty = .reduce_op_type }, params[0]);
            const scalar = try expr(gz, scope, .none, params[1]);
            const result = try gz.addPlNode(.reduce, node, Zir.Inst.Bin{
                .lhs = op,
                .rhs = scalar,
            });
            return rvalue(gz, rl, result, node);
        },

        .add_with_overflow => return overflowArithmetic(gz, scope, rl, node, params, .add_with_overflow),
        .sub_with_overflow => return overflowArithmetic(gz, scope, rl, node, params, .sub_with_overflow),
        .mul_with_overflow => return overflowArithmetic(gz, scope, rl, node, params, .mul_with_overflow),
        .shl_with_overflow => {
            const int_type = try typeExpr(gz, scope, params[0]);
            const log2_int_type = try gz.addUnNode(.log2_int_type, int_type, params[0]);
            const ptr_type = try gz.add(.{ .tag = .ptr_type_simple, .data = .{
                .ptr_type_simple = .{
                    .is_allowzero = false,
                    .is_mutable = true,
                    .is_volatile = false,
                    .size = .One,
                    .elem_type = int_type,
                },
            } });
            const lhs = try expr(gz, scope, .{ .ty = int_type }, params[1]);
            const rhs = try expr(gz, scope, .{ .ty = log2_int_type }, params[2]);
            const ptr = try expr(gz, scope, .{ .ty = ptr_type }, params[3]);
            const result = try gz.addExtendedPayload(.shl_with_overflow, Zir.Inst.OverflowArithmetic{
                .node = gz.nodeIndexToRelative(node),
                .lhs = lhs,
                .rhs = rhs,
                .ptr = ptr,
            });
            return rvalue(gz, rl, result, node);
        },

        .atomic_load => {
            const int_type = try typeExpr(gz, scope, params[0]);
            const ptr_type = try gz.add(.{ .tag = .ptr_type_simple, .data = .{
                .ptr_type_simple = .{
                    .is_allowzero = false,
                    .is_mutable = false,
                    .is_volatile = false,
                    .size = .One,
                    .elem_type = int_type,
                },
            } });
            const ptr = try expr(gz, scope, .{ .ty = ptr_type }, params[1]);
            const ordering = try expr(gz, scope, .{ .ty = .atomic_ordering_type }, params[2]);
            const result = try gz.addPlNode(.atomic_load, node, Zir.Inst.Bin{
                .lhs = ptr,
                .rhs = ordering,
            });
            return rvalue(gz, rl, result, node);
        },
        .atomic_rmw => {
            const int_type = try typeExpr(gz, scope, params[0]);
            const ptr_type = try gz.add(.{ .tag = .ptr_type_simple, .data = .{
                .ptr_type_simple = .{
                    .is_allowzero = false,
                    .is_mutable = true,
                    .is_volatile = false,
                    .size = .One,
                    .elem_type = int_type,
                },
            } });
            const ptr = try expr(gz, scope, .{ .ty = ptr_type }, params[1]);
            const operation = try expr(gz, scope, .{ .ty = .atomic_rmw_op_type }, params[2]);
            const operand = try expr(gz, scope, .{ .ty = int_type }, params[3]);
            const ordering = try expr(gz, scope, .{ .ty = .atomic_ordering_type }, params[4]);
            const result = try gz.addPlNode(.atomic_rmw, node, Zir.Inst.AtomicRmw{
                .ptr = ptr,
                .operation = operation,
                .operand = operand,
                .ordering = ordering,
            });
            return rvalue(gz, rl, result, node);
        },
        .atomic_store => {
            const int_type = try typeExpr(gz, scope, params[0]);
            const ptr_type = try gz.add(.{ .tag = .ptr_type_simple, .data = .{
                .ptr_type_simple = .{
                    .is_allowzero = false,
                    .is_mutable = true,
                    .is_volatile = false,
                    .size = .One,
                    .elem_type = int_type,
                },
            } });
            const ptr = try expr(gz, scope, .{ .ty = ptr_type }, params[1]);
            const operand = try expr(gz, scope, .{ .ty = int_type }, params[2]);
            const ordering = try expr(gz, scope, .{ .ty = .atomic_ordering_type }, params[3]);
            const result = try gz.addPlNode(.atomic_store, node, Zir.Inst.AtomicStore{
                .ptr = ptr,
                .operand = operand,
                .ordering = ordering,
            });
            return rvalue(gz, rl, result, node);
        },
        .mul_add => {
            const float_type = try typeExpr(gz, scope, params[0]);
            const mulend1 = try expr(gz, scope, .{ .ty = float_type }, params[1]);
            const mulend2 = try expr(gz, scope, .{ .ty = float_type }, params[2]);
            const addend = try expr(gz, scope, .{ .ty = float_type }, params[3]);
            const result = try gz.addPlNode(.mul_add, node, Zir.Inst.MulAdd{
                .mulend1 = mulend1,
                .mulend2 = mulend2,
                .addend = addend,
            });
            return rvalue(gz, rl, result, node);
        },
        .call => {
            const options = try comptimeExpr(gz, scope, .{ .ty = .call_options_type }, params[0]);
            const callee = try expr(gz, scope, .none, params[1]);
            const args = try expr(gz, scope, .none, params[2]);
            const result = try gz.addPlNode(.builtin_call, node, Zir.Inst.BuiltinCall{
                .options = options,
                .callee = callee,
                .args = args,
            });
            return rvalue(gz, rl, result, node);
        },
        .field_parent_ptr => {
            const parent_type = try typeExpr(gz, scope, params[0]);
            const field_name = try comptimeExpr(gz, scope, .{ .ty = .const_slice_u8_type }, params[1]);
            const field_ptr_type = try gz.addBin(.field_ptr_type, parent_type, field_name);
            const result = try gz.addPlNode(.field_parent_ptr, node, Zir.Inst.FieldParentPtr{
                .parent_type = parent_type,
                .field_name = field_name,
                .field_ptr = try expr(gz, scope, .{ .ty = field_ptr_type }, params[2]),
            });
            return rvalue(gz, rl, result, node);
        },
        .memcpy => {
            const result = try gz.addPlNode(.memcpy, node, Zir.Inst.Memcpy{
                .dest = try expr(gz, scope, .{ .ty = .manyptr_u8_type }, params[0]),
                .source = try expr(gz, scope, .{ .ty = .manyptr_const_u8_type }, params[1]),
                .byte_count = try expr(gz, scope, .{ .ty = .usize_type }, params[2]),
            });
            return rvalue(gz, rl, result, node);
        },
        .memset => {
            const result = try gz.addPlNode(.memset, node, Zir.Inst.Memset{
                .dest = try expr(gz, scope, .{ .ty = .manyptr_u8_type }, params[0]),
                .byte = try expr(gz, scope, .{ .ty = .u8_type }, params[1]),
                .byte_count = try expr(gz, scope, .{ .ty = .usize_type }, params[2]),
            });
            return rvalue(gz, rl, result, node);
        },
        .shuffle => {
            const result = try gz.addPlNode(.shuffle, node, Zir.Inst.Shuffle{
                .elem_type = try typeExpr(gz, scope, params[0]),
                .a = try expr(gz, scope, .none, params[1]),
                .b = try expr(gz, scope, .none, params[2]),
                .mask = try comptimeExpr(gz, scope, .none, params[3]),
            });
            return rvalue(gz, rl, result, node);
        },
        .async_call => {
            const result = try gz.addPlNode(.builtin_async_call, node, Zir.Inst.AsyncCall{
                .frame_buffer = try expr(gz, scope, .none, params[0]),
                .result_ptr = try expr(gz, scope, .none, params[1]),
                .fn_ptr = try expr(gz, scope, .none, params[2]),
                .args = try expr(gz, scope, .none, params[3]),
            });
            return rvalue(gz, rl, result, node);
        },
        .Vector => {
            const result = try gz.addPlNode(.vector_type, node, Zir.Inst.Bin{
                .lhs = try comptimeExpr(gz, scope, .{.ty = .u32_type}, params[0]),
                .rhs = try typeExpr(gz, scope, params[1]),
            });
            return rvalue(gz, rl, result, node);
        },

    }
    // zig fmt: on
}

fn simpleNoOpVoid(
    gz: *GenZir,
    rl: ResultLoc,
    node: ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    _ = try gz.addNode(tag, node);
    return rvalue(gz, rl, .void_value, node);
}

fn hasDeclOrField(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    lhs_node: ast.Node.Index,
    rhs_node: ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const container_type = try typeExpr(gz, scope, lhs_node);
    const name = try comptimeExpr(gz, scope, .{ .ty = .const_slice_u8_type }, rhs_node);
    const result = try gz.addPlNode(tag, node, Zir.Inst.Bin{
        .lhs = container_type,
        .rhs = name,
    });
    return rvalue(gz, rl, result, node);
}

fn typeCast(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    lhs_node: ast.Node.Index,
    rhs_node: ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const result = try gz.addPlNode(tag, node, Zir.Inst.Bin{
        .lhs = try typeExpr(gz, scope, lhs_node),
        .rhs = try expr(gz, scope, .none, rhs_node),
    });
    return rvalue(gz, rl, result, node);
}

fn simpleUnOpType(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    operand_node: ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const operand = try typeExpr(gz, scope, operand_node);
    const result = try gz.addUnNode(tag, operand, node);
    return rvalue(gz, rl, result, node);
}

fn simpleUnOp(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    operand_rl: ResultLoc,
    operand_node: ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const operand = try expr(gz, scope, operand_rl, operand_node);
    const result = try gz.addUnNode(tag, operand, node);
    return rvalue(gz, rl, result, node);
}

fn cmpxchg(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    params: []const ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const int_type = try typeExpr(gz, scope, params[0]);
    const ptr_type = try gz.add(.{ .tag = .ptr_type_simple, .data = .{
        .ptr_type_simple = .{
            .is_allowzero = false,
            .is_mutable = true,
            .is_volatile = false,
            .size = .One,
            .elem_type = int_type,
        },
    } });
    const result = try gz.addPlNode(tag, node, Zir.Inst.Cmpxchg{
        // zig fmt: off
        .ptr            = try expr(gz, scope, .{ .ty = ptr_type },              params[1]),
        .expected_value = try expr(gz, scope, .{ .ty = int_type },              params[2]),
        .new_value      = try expr(gz, scope, .{ .ty = int_type },              params[3]),
        .success_order  = try expr(gz, scope, .{ .ty = .atomic_ordering_type }, params[4]),
        .fail_order     = try expr(gz, scope, .{ .ty = .atomic_ordering_type }, params[5]),
        // zig fmt: on
    });
    return rvalue(gz, rl, result, node);
}

fn bitBuiltin(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    int_type_node: ast.Node.Index,
    operand_node: ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const int_type = try typeExpr(gz, scope, int_type_node);
    const operand = try expr(gz, scope, .{ .ty = int_type }, operand_node);
    const result = try gz.addUnNode(tag, operand, node);
    return rvalue(gz, rl, result, node);
}

fn divBuiltin(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    lhs_node: ast.Node.Index,
    rhs_node: ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const result = try gz.addPlNode(tag, node, Zir.Inst.Bin{
        .lhs = try expr(gz, scope, .none, lhs_node),
        .rhs = try expr(gz, scope, .none, rhs_node),
    });
    return rvalue(gz, rl, result, node);
}

fn simpleCBuiltin(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    operand_node: ast.Node.Index,
    tag: Zir.Inst.Extended,
) InnerError!Zir.Inst.Ref {
    const operand = try comptimeExpr(gz, scope, .{ .ty = .const_slice_u8_type }, operand_node);
    _ = try gz.addExtendedPayload(tag, Zir.Inst.UnNode{
        .node = gz.nodeIndexToRelative(node),
        .operand = operand,
    });
    return rvalue(gz, rl, .void_value, node);
}

fn offsetOf(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    lhs_node: ast.Node.Index,
    rhs_node: ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const type_inst = try typeExpr(gz, scope, lhs_node);
    const field_name = try comptimeExpr(gz, scope, .{ .ty = .const_slice_u8_type }, rhs_node);
    const result = try gz.addPlNode(tag, node, Zir.Inst.Bin{
        .lhs = type_inst,
        .rhs = field_name,
    });
    return rvalue(gz, rl, result, node);
}

fn shiftOp(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    lhs_node: ast.Node.Index,
    rhs_node: ast.Node.Index,
    tag: Zir.Inst.Tag,
) InnerError!Zir.Inst.Ref {
    const lhs = try expr(gz, scope, .none, lhs_node);
    const log2_int_type = try gz.addUnNode(.typeof_log2_int_type, lhs, lhs_node);
    const rhs = try expr(gz, scope, .{ .ty = log2_int_type }, rhs_node);
    const result = try gz.addPlNode(tag, node, Zir.Inst.Bin{
        .lhs = lhs,
        .rhs = rhs,
    });
    return rvalue(gz, rl, result, node);
}

fn cImport(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    body_node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const gpa = astgen.gpa;

    var block_scope = gz.makeSubBlock(scope);
    block_scope.force_comptime = true;
    defer block_scope.instructions.deinit(gpa);

    const block_inst = try gz.addBlock(.c_import, node);
    const block_result = try expr(&block_scope, &block_scope.base, .none, body_node);
    if (!gz.refIsNoReturn(block_result)) {
        _ = try block_scope.addBreak(.break_inline, block_inst, .void_value);
    }
    try block_scope.setBlockBody(block_inst);
    try gz.instructions.append(gpa, block_inst);

    return rvalue(gz, rl, .void_value, node);
}

fn overflowArithmetic(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    params: []const ast.Node.Index,
    tag: Zir.Inst.Extended,
) InnerError!Zir.Inst.Ref {
    const int_type = try typeExpr(gz, scope, params[0]);
    const ptr_type = try gz.add(.{ .tag = .ptr_type_simple, .data = .{
        .ptr_type_simple = .{
            .is_allowzero = false,
            .is_mutable = true,
            .is_volatile = false,
            .size = .One,
            .elem_type = int_type,
        },
    } });
    const lhs = try expr(gz, scope, .{ .ty = int_type }, params[1]);
    const rhs = try expr(gz, scope, .{ .ty = int_type }, params[2]);
    const ptr = try expr(gz, scope, .{ .ty = ptr_type }, params[3]);
    const result = try gz.addExtendedPayload(tag, Zir.Inst.OverflowArithmetic{
        .node = gz.nodeIndexToRelative(node),
        .lhs = lhs,
        .rhs = rhs,
        .ptr = ptr,
    });
    return rvalue(gz, rl, result, node);
}

fn callExpr(
    gz: *GenZir,
    scope: *Scope,
    rl: ResultLoc,
    node: ast.Node.Index,
    call: ast.full.Call,
) InnerError!Zir.Inst.Ref {
    const astgen = gz.astgen;
    const lhs = try expr(gz, scope, .none, call.ast.fn_expr);

    const args = try astgen.gpa.alloc(Zir.Inst.Ref, call.ast.params.len);
    defer astgen.gpa.free(args);

    for (call.ast.params) |param_node, i| {
        const param_type = try gz.add(.{
            .tag = .param_type,
            .data = .{ .param_type = .{
                .callee = lhs,
                .param_index = @intCast(u32, i),
            } },
        });
        args[i] = try expr(gz, scope, .{ .ty = param_type }, param_node);
    }

    const modifier: std.builtin.CallOptions.Modifier = blk: {
        if (gz.force_comptime) {
            break :blk .compile_time;
        }
        if (call.async_token != null) {
            break :blk .async_kw;
        }
        if (gz.nosuspend_node != 0) {
            break :blk .no_async;
        }
        break :blk .auto;
    };
    const result: Zir.Inst.Ref = res: {
        const tag: Zir.Inst.Tag = switch (modifier) {
            .auto => .call,
            .async_kw => .call_async,
            .never_tail => unreachable,
            .never_inline => unreachable,
            .no_async => .call_nosuspend,
            .always_tail => unreachable,
            .always_inline => unreachable,
            .compile_time => .call_compile_time,
        };
        break :res try gz.addCall(tag, lhs, args, node);
    };
    return rvalue(gz, rl, result, node); // TODO function call with result location
}

pub const simple_types = std.ComptimeStringMap(Zir.Inst.Ref, .{
    .{ "anyerror", .anyerror_type },
    .{ "anyframe", .anyframe_type },
    .{ "bool", .bool_type },
    .{ "c_int", .c_int_type },
    .{ "c_long", .c_long_type },
    .{ "c_longdouble", .c_longdouble_type },
    .{ "c_longlong", .c_longlong_type },
    .{ "c_short", .c_short_type },
    .{ "c_uint", .c_uint_type },
    .{ "c_ulong", .c_ulong_type },
    .{ "c_ulonglong", .c_ulonglong_type },
    .{ "c_ushort", .c_ushort_type },
    .{ "c_void", .c_void_type },
    .{ "comptime_float", .comptime_float_type },
    .{ "comptime_int", .comptime_int_type },
    .{ "f128", .f128_type },
    .{ "f16", .f16_type },
    .{ "f32", .f32_type },
    .{ "f64", .f64_type },
    .{ "false", .bool_false },
    .{ "i16", .i16_type },
    .{ "i32", .i32_type },
    .{ "i64", .i64_type },
    .{ "i128", .i128_type },
    .{ "i8", .i8_type },
    .{ "isize", .isize_type },
    .{ "noreturn", .noreturn_type },
    .{ "null", .null_value },
    .{ "true", .bool_true },
    .{ "type", .type_type },
    .{ "u16", .u16_type },
    .{ "u32", .u32_type },
    .{ "u64", .u64_type },
    .{ "u128", .u128_type },
    .{ "u8", .u8_type },
    .{ "undefined", .undef },
    .{ "usize", .usize_type },
    .{ "void", .void_type },
});

fn nodeMayNeedMemoryLocation(tree: *const ast.Tree, start_node: ast.Node.Index) bool {
    const node_tags = tree.nodes.items(.tag);
    const node_datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);

    var node = start_node;
    while (true) {
        switch (node_tags[node]) {
            .root,
            .@"usingnamespace",
            .test_decl,
            .switch_case,
            .switch_case_one,
            .container_field_init,
            .container_field_align,
            .container_field,
            .asm_output,
            .asm_input,
            => unreachable,

            .@"return",
            .@"break",
            .@"continue",
            .bit_not,
            .bool_not,
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            .@"defer",
            .@"errdefer",
            .address_of,
            .optional_type,
            .negation,
            .negation_wrap,
            .@"resume",
            .array_type,
            .array_type_sentinel,
            .ptr_type_aligned,
            .ptr_type_sentinel,
            .ptr_type,
            .ptr_type_bit_range,
            .@"suspend",
            .@"anytype",
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            .fn_decl,
            .anyframe_type,
            .anyframe_literal,
            .integer_literal,
            .float_literal,
            .enum_literal,
            .string_literal,
            .multiline_string_literal,
            .char_literal,
            .true_literal,
            .false_literal,
            .null_literal,
            .undefined_literal,
            .unreachable_literal,
            .identifier,
            .error_set_decl,
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            .@"asm",
            .asm_simple,
            .add,
            .add_wrap,
            .array_cat,
            .array_mult,
            .assign,
            .assign_bit_and,
            .assign_bit_or,
            .assign_bit_shift_left,
            .assign_bit_shift_right,
            .assign_bit_xor,
            .assign_div,
            .assign_sub,
            .assign_sub_wrap,
            .assign_mod,
            .assign_add,
            .assign_add_wrap,
            .assign_mul,
            .assign_mul_wrap,
            .bang_equal,
            .bit_and,
            .bit_or,
            .bit_shift_left,
            .bit_shift_right,
            .bit_xor,
            .bool_and,
            .bool_or,
            .div,
            .equal_equal,
            .error_union,
            .greater_or_equal,
            .greater_than,
            .less_or_equal,
            .less_than,
            .merge_error_sets,
            .mod,
            .mul,
            .mul_wrap,
            .switch_range,
            .field_access,
            .sub,
            .sub_wrap,
            .slice,
            .slice_open,
            .slice_sentinel,
            .deref,
            .array_access,
            .error_value,
            .while_simple, // This variant cannot have an else expression.
            .while_cont, // This variant cannot have an else expression.
            .for_simple, // This variant cannot have an else expression.
            .if_simple, // This variant cannot have an else expression.
            => return false,

            // Forward the question to the LHS sub-expression.
            .grouped_expression,
            .@"try",
            .@"await",
            .@"comptime",
            .@"nosuspend",
            .unwrap_optional,
            => node = node_datas[node].lhs,

            // Forward the question to the RHS sub-expression.
            .@"catch",
            .@"orelse",
            => node = node_datas[node].rhs,

            // True because these are exactly the expressions we need memory locations for.
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init,
            .array_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init,
            .struct_init_comma,
            => return true,

            // True because depending on comptime conditions, sub-expressions
            // may be the kind that need memory locations.
            .@"while", // This variant always has an else expression.
            .@"if", // This variant always has an else expression.
            .@"for", // This variant always has an else expression.
            .@"switch",
            .switch_comma,
            .call_one,
            .call_one_comma,
            .async_call_one,
            .async_call_one_comma,
            .call,
            .call_comma,
            .async_call,
            .async_call_comma,
            => return true,

            .block_two,
            .block_two_semicolon,
            .block,
            .block_semicolon,
            => {
                const lbrace = main_tokens[node];
                if (token_tags[lbrace - 1] == .colon) {
                    // Labeled blocks may need a memory location to forward
                    // to their break statements.
                    return true;
                } else {
                    return false;
                }
            },

            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => {
                const builtin_token = main_tokens[node];
                const builtin_name = tree.tokenSlice(builtin_token);
                // If the builtin is an invalid name, we don't cause an error here; instead
                // let it pass, and the error will be "invalid builtin function" later.
                const builtin_info = BuiltinFn.list.get(builtin_name) orelse return false;
                return builtin_info.needs_mem_loc;
            },
        }
    }
}

fn nodeMayEvalToError(tree: *const ast.Tree, start_node: ast.Node.Index) enum { never, always, maybe } {
    const node_tags = tree.nodes.items(.tag);
    const node_datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);

    var node = start_node;
    while (true) {
        switch (node_tags[node]) {
            .root,
            .@"usingnamespace",
            .test_decl,
            .switch_case,
            .switch_case_one,
            .container_field_init,
            .container_field_align,
            .container_field,
            .asm_output,
            .asm_input,
            => unreachable,

            .error_value => return .always,

            .@"asm",
            .asm_simple,
            .identifier,
            .field_access,
            .deref,
            .array_access,
            .while_simple,
            .while_cont,
            .for_simple,
            .if_simple,
            .@"while",
            .@"if",
            .@"for",
            .@"switch",
            .switch_comma,
            .call_one,
            .call_one_comma,
            .async_call_one,
            .async_call_one_comma,
            .call,
            .call_comma,
            .async_call,
            .async_call_comma,
            => return .maybe,

            .@"return",
            .@"break",
            .@"continue",
            .bit_not,
            .bool_not,
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            .@"defer",
            .@"errdefer",
            .address_of,
            .optional_type,
            .negation,
            .negation_wrap,
            .@"resume",
            .array_type,
            .array_type_sentinel,
            .ptr_type_aligned,
            .ptr_type_sentinel,
            .ptr_type,
            .ptr_type_bit_range,
            .@"suspend",
            .@"anytype",
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            .fn_decl,
            .anyframe_type,
            .anyframe_literal,
            .integer_literal,
            .float_literal,
            .enum_literal,
            .string_literal,
            .multiline_string_literal,
            .char_literal,
            .true_literal,
            .false_literal,
            .null_literal,
            .undefined_literal,
            .unreachable_literal,
            .error_set_decl,
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            .add,
            .add_wrap,
            .array_cat,
            .array_mult,
            .assign,
            .assign_bit_and,
            .assign_bit_or,
            .assign_bit_shift_left,
            .assign_bit_shift_right,
            .assign_bit_xor,
            .assign_div,
            .assign_sub,
            .assign_sub_wrap,
            .assign_mod,
            .assign_add,
            .assign_add_wrap,
            .assign_mul,
            .assign_mul_wrap,
            .bang_equal,
            .bit_and,
            .bit_or,
            .bit_shift_left,
            .bit_shift_right,
            .bit_xor,
            .bool_and,
            .bool_or,
            .div,
            .equal_equal,
            .error_union,
            .greater_or_equal,
            .greater_than,
            .less_or_equal,
            .less_than,
            .merge_error_sets,
            .mod,
            .mul,
            .mul_wrap,
            .switch_range,
            .sub,
            .sub_wrap,
            .slice,
            .slice_open,
            .slice_sentinel,
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init,
            .array_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init,
            .struct_init_comma,
            => return .never,

            // Forward the question to the LHS sub-expression.
            .grouped_expression,
            .@"try",
            .@"await",
            .@"comptime",
            .@"nosuspend",
            .unwrap_optional,
            => node = node_datas[node].lhs,

            // Forward the question to the RHS sub-expression.
            .@"catch",
            .@"orelse",
            => node = node_datas[node].rhs,

            .block_two,
            .block_two_semicolon,
            .block,
            .block_semicolon,
            => {
                const lbrace = main_tokens[node];
                if (token_tags[lbrace - 1] == .colon) {
                    // Labeled blocks may need a memory location to forward
                    // to their break statements.
                    return .maybe;
                } else {
                    return .never;
                }
            },

            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => {
                const builtin_token = main_tokens[node];
                const builtin_name = tree.tokenSlice(builtin_token);
                // If the builtin is an invalid name, we don't cause an error here; instead
                // let it pass, and the error will be "invalid builtin function" later.
                const builtin_info = BuiltinFn.list.get(builtin_name) orelse return .maybe;
                if (builtin_info.tag == .err_set_cast) {
                    return .always;
                } else {
                    return .never;
                }
            },
        }
    }
}

/// Applies `rl` semantics to `inst`. Expressions which do not do their own handling of
/// result locations must call this function on their result.
/// As an example, if the `ResultLoc` is `ptr`, it will write the result to the pointer.
/// If the `ResultLoc` is `ty`, it will coerce the result to the type.
fn rvalue(
    gz: *GenZir,
    rl: ResultLoc,
    result: Zir.Inst.Ref,
    src_node: ast.Node.Index,
) InnerError!Zir.Inst.Ref {
    switch (rl) {
        .none, .none_or_ref => return result,
        .discard => {
            // Emit a compile error for discarding error values.
            _ = try gz.addUnNode(.ensure_result_non_error, result, src_node);
            return result;
        },
        .ref => {
            // We need a pointer but we have a value.
            const tree = gz.astgen.tree;
            const src_token = tree.firstToken(src_node);
            return gz.addUnTok(.ref, result, src_token);
        },
        .ty => |ty_inst| {
            // Quickly eliminate some common, unnecessary type coercion.
            const as_ty = @as(u64, @enumToInt(Zir.Inst.Ref.type_type)) << 32;
            const as_comptime_int = @as(u64, @enumToInt(Zir.Inst.Ref.comptime_int_type)) << 32;
            const as_bool = @as(u64, @enumToInt(Zir.Inst.Ref.bool_type)) << 32;
            const as_usize = @as(u64, @enumToInt(Zir.Inst.Ref.usize_type)) << 32;
            const as_void = @as(u64, @enumToInt(Zir.Inst.Ref.void_type)) << 32;
            switch ((@as(u64, @enumToInt(ty_inst)) << 32) | @as(u64, @enumToInt(result))) {
                as_ty | @enumToInt(Zir.Inst.Ref.u8_type),
                as_ty | @enumToInt(Zir.Inst.Ref.i8_type),
                as_ty | @enumToInt(Zir.Inst.Ref.u16_type),
                as_ty | @enumToInt(Zir.Inst.Ref.i16_type),
                as_ty | @enumToInt(Zir.Inst.Ref.u32_type),
                as_ty | @enumToInt(Zir.Inst.Ref.i32_type),
                as_ty | @enumToInt(Zir.Inst.Ref.u64_type),
                as_ty | @enumToInt(Zir.Inst.Ref.i64_type),
                as_ty | @enumToInt(Zir.Inst.Ref.usize_type),
                as_ty | @enumToInt(Zir.Inst.Ref.isize_type),
                as_ty | @enumToInt(Zir.Inst.Ref.c_short_type),
                as_ty | @enumToInt(Zir.Inst.Ref.c_ushort_type),
                as_ty | @enumToInt(Zir.Inst.Ref.c_int_type),
                as_ty | @enumToInt(Zir.Inst.Ref.c_uint_type),
                as_ty | @enumToInt(Zir.Inst.Ref.c_long_type),
                as_ty | @enumToInt(Zir.Inst.Ref.c_ulong_type),
                as_ty | @enumToInt(Zir.Inst.Ref.c_longlong_type),
                as_ty | @enumToInt(Zir.Inst.Ref.c_ulonglong_type),
                as_ty | @enumToInt(Zir.Inst.Ref.c_longdouble_type),
                as_ty | @enumToInt(Zir.Inst.Ref.f16_type),
                as_ty | @enumToInt(Zir.Inst.Ref.f32_type),
                as_ty | @enumToInt(Zir.Inst.Ref.f64_type),
                as_ty | @enumToInt(Zir.Inst.Ref.f128_type),
                as_ty | @enumToInt(Zir.Inst.Ref.c_void_type),
                as_ty | @enumToInt(Zir.Inst.Ref.bool_type),
                as_ty | @enumToInt(Zir.Inst.Ref.void_type),
                as_ty | @enumToInt(Zir.Inst.Ref.type_type),
                as_ty | @enumToInt(Zir.Inst.Ref.anyerror_type),
                as_ty | @enumToInt(Zir.Inst.Ref.comptime_int_type),
                as_ty | @enumToInt(Zir.Inst.Ref.comptime_float_type),
                as_ty | @enumToInt(Zir.Inst.Ref.noreturn_type),
                as_ty | @enumToInt(Zir.Inst.Ref.null_type),
                as_ty | @enumToInt(Zir.Inst.Ref.undefined_type),
                as_ty | @enumToInt(Zir.Inst.Ref.fn_noreturn_no_args_type),
                as_ty | @enumToInt(Zir.Inst.Ref.fn_void_no_args_type),
                as_ty | @enumToInt(Zir.Inst.Ref.fn_naked_noreturn_no_args_type),
                as_ty | @enumToInt(Zir.Inst.Ref.fn_ccc_void_no_args_type),
                as_ty | @enumToInt(Zir.Inst.Ref.single_const_pointer_to_comptime_int_type),
                as_ty | @enumToInt(Zir.Inst.Ref.const_slice_u8_type),
                as_ty | @enumToInt(Zir.Inst.Ref.enum_literal_type),
                as_comptime_int | @enumToInt(Zir.Inst.Ref.zero),
                as_comptime_int | @enumToInt(Zir.Inst.Ref.one),
                as_bool | @enumToInt(Zir.Inst.Ref.bool_true),
                as_bool | @enumToInt(Zir.Inst.Ref.bool_false),
                as_usize | @enumToInt(Zir.Inst.Ref.zero_usize),
                as_usize | @enumToInt(Zir.Inst.Ref.one_usize),
                as_void | @enumToInt(Zir.Inst.Ref.void_value),
                => return result, // type of result is already correct

                // Need an explicit type coercion instruction.
                else => return gz.addPlNode(.as_node, src_node, Zir.Inst.As{
                    .dest_type = ty_inst,
                    .operand = result,
                }),
            }
        },
        .ptr => |ptr_inst| {
            _ = try gz.addPlNode(.store_node, src_node, Zir.Inst.Bin{
                .lhs = ptr_inst,
                .rhs = result,
            });
            return result;
        },
        .inferred_ptr => |alloc| {
            _ = try gz.addBin(.store_to_inferred_ptr, alloc, result);
            return result;
        },
        .block_ptr => |block_scope| {
            block_scope.rvalue_rl_count += 1;
            _ = try gz.addBin(.store_to_block_ptr, block_scope.rl_ptr, result);
            return result;
        },
    }
}

/// Given an identifier token, obtain the string for it.
/// If the token uses @"" syntax, parses as a string, reports errors if applicable,
/// and allocates the result within `astgen.arena`.
/// Otherwise, returns a reference to the source code bytes directly.
/// See also `appendIdentStr` and `parseStrLit`.
fn identifierTokenString(astgen: *AstGen, token: ast.TokenIndex) InnerError![]const u8 {
    const tree = astgen.tree;
    const token_tags = tree.tokens.items(.tag);
    assert(token_tags[token] == .identifier);
    const ident_name = tree.tokenSlice(token);
    if (!mem.startsWith(u8, ident_name, "@")) {
        return ident_name;
    }
    var buf: ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(astgen.gpa);
    try astgen.parseStrLit(token, &buf, ident_name, 1);
    const duped = try astgen.arena.dupe(u8, buf.items);
    return duped;
}

/// Given an identifier token, obtain the string for it (possibly parsing as a string
/// literal if it is @"" syntax), and append the string to `buf`.
/// See also `identifierTokenString` and `parseStrLit`.
fn appendIdentStr(
    astgen: *AstGen,
    token: ast.TokenIndex,
    buf: *ArrayListUnmanaged(u8),
) InnerError!void {
    const tree = astgen.tree;
    const token_tags = tree.tokens.items(.tag);
    assert(token_tags[token] == .identifier);
    const ident_name = tree.tokenSlice(token);
    if (!mem.startsWith(u8, ident_name, "@")) {
        return buf.appendSlice(astgen.gpa, ident_name);
    } else {
        return astgen.parseStrLit(token, buf, ident_name, 1);
    }
}

/// Appends the result to `buf`.
fn parseStrLit(
    astgen: *AstGen,
    token: ast.TokenIndex,
    buf: *ArrayListUnmanaged(u8),
    bytes: []const u8,
    offset: u32,
) InnerError!void {
    const raw_string = bytes[offset..];
    var buf_managed = buf.toManaged(astgen.gpa);
    const result = std.zig.string_literal.parseAppend(&buf_managed, raw_string);
    buf.* = buf_managed.toUnmanaged();
    switch (try result) {
        .success => return,
        .invalid_character => |bad_index| {
            return astgen.failOff(
                token,
                offset + @intCast(u32, bad_index),
                "invalid string literal character: '{c}'",
                .{raw_string[bad_index]},
            );
        },
        .expected_hex_digits => |bad_index| {
            return astgen.failOff(
                token,
                offset + @intCast(u32, bad_index),
                "expected hex digits after '\\x'",
                .{},
            );
        },
        .invalid_hex_escape => |bad_index| {
            return astgen.failOff(
                token,
                offset + @intCast(u32, bad_index),
                "invalid hex digit: '{c}'",
                .{raw_string[bad_index]},
            );
        },
        .invalid_unicode_escape => |bad_index| {
            return astgen.failOff(
                token,
                offset + @intCast(u32, bad_index),
                "invalid unicode digit: '{c}'",
                .{raw_string[bad_index]},
            );
        },
        .missing_matching_rbrace => |bad_index| {
            return astgen.failOff(
                token,
                offset + @intCast(u32, bad_index),
                "missing matching '}}' character",
                .{},
            );
        },
        .expected_unicode_digits => |bad_index| {
            return astgen.failOff(
                token,
                offset + @intCast(u32, bad_index),
                "expected unicode digits after '\\u'",
                .{},
            );
        },
    }
}

fn failNode(
    astgen: *AstGen,
    node: ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    return astgen.failNodeNotes(node, format, args, &[0]u32{});
}

fn failNodeNotes(
    astgen: *AstGen,
    node: ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) InnerError {
    @setCold(true);
    const string_bytes = &astgen.string_bytes;
    const msg = @intCast(u32, string_bytes.items.len);
    {
        var managed = string_bytes.toManaged(astgen.gpa);
        defer string_bytes.* = managed.toUnmanaged();
        try managed.writer().print(format ++ "\x00", args);
    }
    const notes_index: u32 = if (notes.len != 0) blk: {
        const notes_start = astgen.extra.items.len;
        try astgen.extra.ensureCapacity(astgen.gpa, notes_start + 1 + notes.len);
        astgen.extra.appendAssumeCapacity(@intCast(u32, notes.len));
        astgen.extra.appendSliceAssumeCapacity(notes);
        break :blk @intCast(u32, notes_start);
    } else 0;
    try astgen.compile_errors.append(astgen.gpa, .{
        .msg = msg,
        .node = node,
        .token = 0,
        .byte_offset = 0,
        .notes = notes_index,
    });
    return error.AnalysisFail;
}

fn failTok(
    astgen: *AstGen,
    token: ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    return astgen.failTokNotes(token, format, args, &[0]u32{});
}

fn failTokNotes(
    astgen: *AstGen,
    token: ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) InnerError {
    @setCold(true);
    const string_bytes = &astgen.string_bytes;
    const msg = @intCast(u32, string_bytes.items.len);
    {
        var managed = string_bytes.toManaged(astgen.gpa);
        defer string_bytes.* = managed.toUnmanaged();
        try managed.writer().print(format ++ "\x00", args);
    }
    const notes_index: u32 = if (notes.len != 0) blk: {
        const notes_start = astgen.extra.items.len;
        try astgen.extra.ensureCapacity(astgen.gpa, notes_start + 1 + notes.len);
        astgen.extra.appendAssumeCapacity(@intCast(u32, notes.len));
        astgen.extra.appendSliceAssumeCapacity(notes);
        break :blk @intCast(u32, notes_start);
    } else 0;
    try astgen.compile_errors.append(astgen.gpa, .{
        .msg = msg,
        .node = 0,
        .token = token,
        .byte_offset = 0,
        .notes = notes_index,
    });
    return error.AnalysisFail;
}

/// Same as `fail`, except given an absolute byte offset.
fn failOff(
    astgen: *AstGen,
    token: ast.TokenIndex,
    byte_offset: u32,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    @setCold(true);
    const string_bytes = &astgen.string_bytes;
    const msg = @intCast(u32, string_bytes.items.len);
    {
        var managed = string_bytes.toManaged(astgen.gpa);
        defer string_bytes.* = managed.toUnmanaged();
        try managed.writer().print(format ++ "\x00", args);
    }
    try astgen.compile_errors.append(astgen.gpa, .{
        .msg = msg,
        .node = 0,
        .token = token,
        .byte_offset = byte_offset,
        .notes = 0,
    });
    return error.AnalysisFail;
}

fn errNoteTok(
    astgen: *AstGen,
    token: ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!u32 {
    @setCold(true);
    const string_bytes = &astgen.string_bytes;
    const msg = @intCast(u32, string_bytes.items.len);
    {
        var managed = string_bytes.toManaged(astgen.gpa);
        defer string_bytes.* = managed.toUnmanaged();
        try managed.writer().print(format ++ "\x00", args);
    }
    return astgen.addExtra(Zir.Inst.CompileErrors.Item{
        .msg = msg,
        .node = 0,
        .token = token,
        .byte_offset = 0,
        .notes = 0,
    });
}

fn errNoteNode(
    astgen: *AstGen,
    node: ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!u32 {
    @setCold(true);
    const string_bytes = &astgen.string_bytes;
    const msg = @intCast(u32, string_bytes.items.len);
    {
        var managed = string_bytes.toManaged(astgen.gpa);
        defer string_bytes.* = managed.toUnmanaged();
        try managed.writer().print(format ++ "\x00", args);
    }
    return astgen.addExtra(Zir.Inst.CompileErrors.Item{
        .msg = msg,
        .node = node,
        .token = 0,
        .byte_offset = 0,
        .notes = 0,
    });
}

fn identAsString(astgen: *AstGen, ident_token: ast.TokenIndex) !u32 {
    const gpa = astgen.gpa;
    const string_bytes = &astgen.string_bytes;
    const str_index = @intCast(u32, string_bytes.items.len);
    try astgen.appendIdentStr(ident_token, string_bytes);
    const key = string_bytes.items[str_index..];
    const gop = try astgen.string_table.getOrPut(gpa, key);
    if (gop.found_existing) {
        string_bytes.shrinkRetainingCapacity(str_index);
        return gop.value_ptr.*;
    } else {
        // We have to dupe the key into the arena, otherwise the memory
        // becomes invalidated when string_bytes gets data appended.
        // TODO https://github.com/ziglang/zig/issues/8528
        gop.key_ptr.* = try astgen.arena.dupe(u8, key);
        gop.value_ptr.* = str_index;
        try string_bytes.append(gpa, 0);
        return str_index;
    }
}

const IndexSlice = struct { index: u32, len: u32 };

fn strLitAsString(astgen: *AstGen, str_lit_token: ast.TokenIndex) !IndexSlice {
    const gpa = astgen.gpa;
    const string_bytes = &astgen.string_bytes;
    const str_index = @intCast(u32, string_bytes.items.len);
    const token_bytes = astgen.tree.tokenSlice(str_lit_token);
    try astgen.parseStrLit(str_lit_token, string_bytes, token_bytes, 0);
    const key = string_bytes.items[str_index..];
    const gop = try astgen.string_table.getOrPut(gpa, key);
    if (gop.found_existing) {
        string_bytes.shrinkRetainingCapacity(str_index);
        return IndexSlice{
            .index = gop.value_ptr.*,
            .len = @intCast(u32, key.len),
        };
    } else {
        // We have to dupe the key into the arena, otherwise the memory
        // becomes invalidated when string_bytes gets data appended.
        // TODO https://github.com/ziglang/zig/issues/8528
        gop.key_ptr.* = try astgen.arena.dupe(u8, key);
        gop.value_ptr.* = str_index;
        // Still need a null byte because we are using the same table
        // to lookup null terminated strings, so if we get a match, it has to
        // be null terminated for that to work.
        try string_bytes.append(gpa, 0);
        return IndexSlice{
            .index = str_index,
            .len = @intCast(u32, key.len),
        };
    }
}

fn testNameString(astgen: *AstGen, str_lit_token: ast.TokenIndex) !u32 {
    const gpa = astgen.gpa;
    const string_bytes = &astgen.string_bytes;
    const str_index = @intCast(u32, string_bytes.items.len);
    const token_bytes = astgen.tree.tokenSlice(str_lit_token);
    try string_bytes.append(gpa, 0); // Indicates this is a test.
    try astgen.parseStrLit(str_lit_token, string_bytes, token_bytes, 0);
    try string_bytes.append(gpa, 0);
    return str_index;
}

const Scope = struct {
    tag: Tag,

    fn cast(base: *Scope, comptime T: type) ?*T {
        if (T == Defer) {
            switch (base.tag) {
                .defer_normal, .defer_error => return @fieldParentPtr(T, "base", base),
                else => return null,
            }
        }
        if (base.tag != T.base_tag)
            return null;

        return @fieldParentPtr(T, "base", base);
    }

    const Tag = enum {
        gen_zir,
        local_val,
        local_ptr,
        defer_normal,
        defer_error,
        namespace,
        top,
    };

    /// The category of identifier. These tag names are user-visible in compile errors.
    const IdCat = enum {
        @"function parameter",
        @"local constant",
        @"local variable",
        @"loop index capture",
        @"capture",
    };

    /// This is always a `const` local and importantly the `inst` is a value type, not a pointer.
    /// This structure lives as long as the AST generation of the Block
    /// node that contains the variable.
    const LocalVal = struct {
        const base_tag: Tag = .local_val;
        base: Scope = Scope{ .tag = base_tag },
        /// Parents can be: `LocalVal`, `LocalPtr`, `GenZir`, `Defer`.
        parent: *Scope,
        gen_zir: *GenZir,
        inst: Zir.Inst.Ref,
        /// Source location of the corresponding variable declaration.
        token_src: ast.TokenIndex,
        /// String table index.
        name: u32,
        id_cat: IdCat,
        /// Track whether the name has been referenced.
        used: bool = false,
    };

    /// This could be a `const` or `var` local. It has a pointer instead of a value.
    /// This structure lives as long as the AST generation of the Block
    /// node that contains the variable.
    const LocalPtr = struct {
        const base_tag: Tag = .local_ptr;
        base: Scope = Scope{ .tag = base_tag },
        /// Parents can be: `LocalVal`, `LocalPtr`, `GenZir`, `Defer`.
        parent: *Scope,
        gen_zir: *GenZir,
        ptr: Zir.Inst.Ref,
        /// Source location of the corresponding variable declaration.
        token_src: ast.TokenIndex,
        /// String table index.
        name: u32,
        id_cat: IdCat,
        /// true means we find out during Sema whether the value is comptime.
        /// false means it is already known at AstGen the value is runtime-known.
        maybe_comptime: bool,
        /// Track whether the name has been referenced.
        used: bool = false,
    };

    const Defer = struct {
        base: Scope,
        /// Parents can be: `LocalVal`, `LocalPtr`, `GenZir`, `Defer`.
        parent: *Scope,
        defer_node: ast.Node.Index,
    };

    /// Represents a global scope that has any number of declarations in it.
    /// Each declaration has this as the parent scope.
    const Namespace = struct {
        const base_tag: Tag = .namespace;
        base: Scope = Scope{ .tag = base_tag },

        parent: *Scope,
        /// Maps string table index to the source location of declaration,
        /// for the purposes of reporting name shadowing compile errors.
        decls: std.AutoHashMapUnmanaged(u32, ast.Node.Index) = .{},
    };

    const Top = struct {
        const base_tag: Scope.Tag = .top;
        base: Scope = Scope{ .tag = base_tag },
    };
};

/// This is a temporary structure; references to it are valid only
/// while constructing a `Zir`.
const GenZir = struct {
    const base_tag: Scope.Tag = .gen_zir;
    base: Scope = Scope{ .tag = base_tag },
    force_comptime: bool,
    in_defer: bool,
    /// How decls created in this scope should be named.
    anon_name_strategy: Zir.Inst.NameStrategy = .anon,
    /// The containing decl AST node.
    decl_node_index: ast.Node.Index,
    /// The containing decl line index, absolute.
    decl_line: u32,
    parent: *Scope,
    /// All `GenZir` scopes for the same ZIR share this.
    astgen: *AstGen,
    /// Keeps track of the list of instructions in this scope only. Indexes
    /// to instructions in `astgen`.
    instructions: ArrayListUnmanaged(Zir.Inst.Index) = .{},
    label: ?Label = null,
    break_block: Zir.Inst.Index = 0,
    continue_block: Zir.Inst.Index = 0,
    /// Only valid when setBreakResultLoc is called.
    break_result_loc: AstGen.ResultLoc = undefined,
    /// When a block has a pointer result location, here it is.
    rl_ptr: Zir.Inst.Ref = .none,
    /// When a block has a type result location, here it is.
    rl_ty_inst: Zir.Inst.Ref = .none,
    /// Keeps track of how many branches of a block did not actually
    /// consume the result location. astgen uses this to figure out
    /// whether to rely on break instructions or writing to the result
    /// pointer for the result instruction.
    rvalue_rl_count: usize = 0,
    /// Keeps track of how many break instructions there are. When astgen is finished
    /// with a block, it can check this against rvalue_rl_count to find out whether
    /// the break instructions should be downgraded to break_void.
    break_count: usize = 0,
    /// Tracks `break :foo bar` instructions so they can possibly be elided later if
    /// the labeled block ends up not needing a result location pointer.
    labeled_breaks: ArrayListUnmanaged(Zir.Inst.Index) = .{},
    /// Tracks `store_to_block_ptr` instructions that correspond to break instructions
    /// so they can possibly be elided later if the labeled block ends up not needing
    /// a result location pointer.
    labeled_store_to_block_ptr_list: ArrayListUnmanaged(Zir.Inst.Index) = .{},

    suspend_node: ast.Node.Index = 0,
    nosuspend_node: ast.Node.Index = 0,

    fn makeSubBlock(gz: *GenZir, scope: *Scope) GenZir {
        return .{
            .force_comptime = gz.force_comptime,
            .in_defer = gz.in_defer,
            .decl_node_index = gz.decl_node_index,
            .decl_line = gz.decl_line,
            .parent = scope,
            .astgen = gz.astgen,
            .suspend_node = gz.suspend_node,
            .nosuspend_node = gz.nosuspend_node,
        };
    }

    const Label = struct {
        token: ast.TokenIndex,
        block_inst: Zir.Inst.Index,
        used: bool = false,
    };

    fn refIsNoReturn(gz: GenZir, inst_ref: Zir.Inst.Ref) bool {
        if (inst_ref == .unreachable_value) return true;
        if (refToIndex(inst_ref)) |inst_index| {
            return gz.astgen.instructions.items(.tag)[inst_index].isNoReturn();
        }
        return false;
    }

    fn calcLine(gz: GenZir, node: ast.Node.Index) u32 {
        const astgen = gz.astgen;
        const tree = astgen.tree;
        const source = tree.source;
        const token_starts = tree.tokens.items(.start);
        const node_start = token_starts[tree.firstToken(node)];

        astgen.advanceSourceCursor(source, node_start);

        return @intCast(u32, gz.decl_line + astgen.source_line);
    }

    fn tokSrcLoc(gz: GenZir, token_index: ast.TokenIndex) LazySrcLoc {
        return .{ .token_offset = token_index - gz.srcToken() };
    }

    fn nodeSrcLoc(gz: GenZir, node_index: ast.Node.Index) LazySrcLoc {
        return .{ .node_offset = gz.nodeIndexToRelative(node_index) };
    }

    fn nodeIndexToRelative(gz: GenZir, node_index: ast.Node.Index) i32 {
        return @bitCast(i32, node_index) - @bitCast(i32, gz.decl_node_index);
    }

    fn tokenIndexToRelative(gz: GenZir, token: ast.TokenIndex) u32 {
        return token - gz.srcToken();
    }

    fn srcToken(gz: GenZir) ast.TokenIndex {
        return gz.astgen.tree.firstToken(gz.decl_node_index);
    }

    fn setBreakResultLoc(gz: *GenZir, parent_rl: AstGen.ResultLoc) void {
        // Depending on whether the result location is a pointer or value, different
        // ZIR needs to be generated. In the former case we rely on storing to the
        // pointer to communicate the result, and use breakvoid; in the latter case
        // the block break instructions will have the result values.
        // One more complication: when the result location is a pointer, we detect
        // the scenario where the result location is not consumed. In this case
        // we emit ZIR for the block break instructions to have the result values,
        // and then rvalue() on that to pass the value to the result location.
        switch (parent_rl) {
            .ty => |ty_inst| {
                gz.rl_ty_inst = ty_inst;
                gz.break_result_loc = parent_rl;
            },
            .none_or_ref => {
                gz.break_result_loc = .ref;
            },
            .discard, .none, .ptr, .ref => {
                gz.break_result_loc = parent_rl;
            },

            .inferred_ptr => |ptr| {
                gz.rl_ptr = ptr;
                gz.break_result_loc = .{ .block_ptr = gz };
            },

            .block_ptr => |parent_block_scope| {
                gz.rl_ty_inst = parent_block_scope.rl_ty_inst;
                gz.rl_ptr = parent_block_scope.rl_ptr;
                gz.break_result_loc = .{ .block_ptr = gz };
            },
        }
    }

    fn setBoolBrBody(gz: GenZir, inst: Zir.Inst.Index) !void {
        const gpa = gz.astgen.gpa;
        try gz.astgen.extra.ensureCapacity(gpa, gz.astgen.extra.items.len +
            @typeInfo(Zir.Inst.Block).Struct.fields.len + gz.instructions.items.len);
        const zir_datas = gz.astgen.instructions.items(.data);
        zir_datas[inst].bool_br.payload_index = gz.astgen.addExtraAssumeCapacity(
            Zir.Inst.Block{ .body_len = @intCast(u32, gz.instructions.items.len) },
        );
        gz.astgen.extra.appendSliceAssumeCapacity(gz.instructions.items);
    }

    fn setBlockBody(gz: GenZir, inst: Zir.Inst.Index) !void {
        const gpa = gz.astgen.gpa;
        try gz.astgen.extra.ensureCapacity(gpa, gz.astgen.extra.items.len +
            @typeInfo(Zir.Inst.Block).Struct.fields.len + gz.instructions.items.len);
        const zir_datas = gz.astgen.instructions.items(.data);
        zir_datas[inst].pl_node.payload_index = gz.astgen.addExtraAssumeCapacity(
            Zir.Inst.Block{ .body_len = @intCast(u32, gz.instructions.items.len) },
        );
        gz.astgen.extra.appendSliceAssumeCapacity(gz.instructions.items);
    }

    /// Same as `setBlockBody` except we don't copy instructions which are
    /// `store_to_block_ptr` instructions with lhs set to .none.
    fn setBlockBodyEliding(gz: GenZir, inst: Zir.Inst.Index) !void {
        const gpa = gz.astgen.gpa;
        try gz.astgen.extra.ensureCapacity(gpa, gz.astgen.extra.items.len +
            @typeInfo(Zir.Inst.Block).Struct.fields.len + gz.instructions.items.len);
        const zir_datas = gz.astgen.instructions.items(.data);
        const zir_tags = gz.astgen.instructions.items(.tag);
        const block_pl_index = gz.astgen.addExtraAssumeCapacity(Zir.Inst.Block{
            .body_len = @intCast(u32, gz.instructions.items.len),
        });
        zir_datas[inst].pl_node.payload_index = block_pl_index;
        for (gz.instructions.items) |sub_inst| {
            if (zir_tags[sub_inst] == .store_to_block_ptr and
                zir_datas[sub_inst].bin.lhs == .none)
            {
                // Decrement `body_len`.
                gz.astgen.extra.items[block_pl_index] -= 1;
                continue;
            }
            gz.astgen.extra.appendAssumeCapacity(sub_inst);
        }
    }

    fn addFunc(gz: *GenZir, args: struct {
        src_node: ast.Node.Index,
        param_types: []const Zir.Inst.Ref,
        body: []const Zir.Inst.Index,
        ret_ty: Zir.Inst.Ref,
        cc: Zir.Inst.Ref,
        align_inst: Zir.Inst.Ref,
        lib_name: u32,
        is_var_args: bool,
        is_inferred_error: bool,
        is_test: bool,
        is_extern: bool,
    }) !Zir.Inst.Ref {
        assert(args.src_node != 0);
        assert(args.ret_ty != .none);
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);

        var src_locs_buffer: [3]u32 = undefined;
        var src_locs: []u32 = src_locs_buffer[0..0];
        if (args.body.len != 0) {
            const tree = astgen.tree;
            const node_tags = tree.nodes.items(.tag);
            const node_datas = tree.nodes.items(.data);
            const token_starts = tree.tokens.items(.start);
            const fn_decl = args.src_node;
            assert(node_tags[fn_decl] == .fn_decl or node_tags[fn_decl] == .test_decl);
            const block = node_datas[fn_decl].rhs;
            const lbrace_start = token_starts[tree.firstToken(block)];
            const rbrace_start = token_starts[tree.lastToken(block)];

            astgen.advanceSourceCursor(tree.source, lbrace_start);
            const lbrace_line = @intCast(u32, astgen.source_line);
            const lbrace_column = @intCast(u32, astgen.source_column);

            astgen.advanceSourceCursor(tree.source, rbrace_start);
            const rbrace_line = @intCast(u32, astgen.source_line);
            const rbrace_column = @intCast(u32, astgen.source_column);

            const columns = lbrace_column | (rbrace_column << 16);
            src_locs_buffer[0] = lbrace_line;
            src_locs_buffer[1] = rbrace_line;
            src_locs_buffer[2] = columns;
            src_locs = &src_locs_buffer;
        }

        if (args.cc != .none or args.lib_name != 0 or
            args.is_var_args or args.is_test or args.align_inst != .none or
            args.is_extern)
        {
            try astgen.extra.ensureUnusedCapacity(
                gpa,
                @typeInfo(Zir.Inst.ExtendedFunc).Struct.fields.len +
                    args.param_types.len + args.body.len + src_locs.len +
                    @boolToInt(args.lib_name != 0) +
                    @boolToInt(args.align_inst != .none) +
                    @boolToInt(args.cc != .none),
            );
            const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.ExtendedFunc{
                .src_node = gz.nodeIndexToRelative(args.src_node),
                .return_type = args.ret_ty,
                .param_types_len = @intCast(u32, args.param_types.len),
                .body_len = @intCast(u32, args.body.len),
            });
            if (args.lib_name != 0) {
                astgen.extra.appendAssumeCapacity(args.lib_name);
            }
            if (args.cc != .none) {
                astgen.extra.appendAssumeCapacity(@enumToInt(args.cc));
            }
            if (args.align_inst != .none) {
                astgen.extra.appendAssumeCapacity(@enumToInt(args.align_inst));
            }
            astgen.appendRefsAssumeCapacity(args.param_types);
            astgen.extra.appendSliceAssumeCapacity(args.body);
            astgen.extra.appendSliceAssumeCapacity(src_locs);

            const new_index = @intCast(Zir.Inst.Index, astgen.instructions.len);
            astgen.instructions.appendAssumeCapacity(.{
                .tag = .extended,
                .data = .{ .extended = .{
                    .opcode = .func,
                    .small = @bitCast(u16, Zir.Inst.ExtendedFunc.Small{
                        .is_var_args = args.is_var_args,
                        .is_inferred_error = args.is_inferred_error,
                        .has_lib_name = args.lib_name != 0,
                        .has_cc = args.cc != .none,
                        .has_align = args.align_inst != .none,
                        .is_test = args.is_test,
                        .is_extern = args.is_extern,
                    }),
                    .operand = payload_index,
                } },
            });
            gz.instructions.appendAssumeCapacity(new_index);
            return indexToRef(new_index);
        } else {
            try gz.astgen.extra.ensureUnusedCapacity(
                gpa,
                @typeInfo(Zir.Inst.Func).Struct.fields.len +
                    args.param_types.len + args.body.len + src_locs.len,
            );

            const payload_index = gz.astgen.addExtraAssumeCapacity(Zir.Inst.Func{
                .return_type = args.ret_ty,
                .param_types_len = @intCast(u32, args.param_types.len),
                .body_len = @intCast(u32, args.body.len),
            });
            gz.astgen.appendRefsAssumeCapacity(args.param_types);
            gz.astgen.extra.appendSliceAssumeCapacity(args.body);
            gz.astgen.extra.appendSliceAssumeCapacity(src_locs);

            const tag: Zir.Inst.Tag = if (args.is_inferred_error) .func_inferred else .func;
            const new_index = @intCast(Zir.Inst.Index, gz.astgen.instructions.len);
            gz.astgen.instructions.appendAssumeCapacity(.{
                .tag = tag,
                .data = .{ .pl_node = .{
                    .src_node = gz.nodeIndexToRelative(args.src_node),
                    .payload_index = payload_index,
                } },
            });
            gz.instructions.appendAssumeCapacity(new_index);
            return indexToRef(new_index);
        }
    }

    fn addVar(gz: *GenZir, args: struct {
        align_inst: Zir.Inst.Ref,
        lib_name: u32,
        var_type: Zir.Inst.Ref,
        init: Zir.Inst.Ref,
        is_extern: bool,
        is_threadlocal: bool,
    }) !Zir.Inst.Ref {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);

        try astgen.extra.ensureUnusedCapacity(
            gpa,
            @typeInfo(Zir.Inst.ExtendedVar).Struct.fields.len +
                @boolToInt(args.lib_name != 0) +
                @boolToInt(args.align_inst != .none) +
                @boolToInt(args.init != .none),
        );
        const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.ExtendedVar{
            .var_type = args.var_type,
        });
        if (args.lib_name != 0) {
            astgen.extra.appendAssumeCapacity(args.lib_name);
        }
        if (args.align_inst != .none) {
            astgen.extra.appendAssumeCapacity(@enumToInt(args.align_inst));
        }
        if (args.init != .none) {
            astgen.extra.appendAssumeCapacity(@enumToInt(args.init));
        }

        const new_index = @intCast(Zir.Inst.Index, astgen.instructions.len);
        astgen.instructions.appendAssumeCapacity(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .variable,
                .small = @bitCast(u16, Zir.Inst.ExtendedVar.Small{
                    .has_lib_name = args.lib_name != 0,
                    .has_align = args.align_inst != .none,
                    .has_init = args.init != .none,
                    .is_extern = args.is_extern,
                    .is_threadlocal = args.is_threadlocal,
                }),
                .operand = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return indexToRef(new_index);
    }

    fn addCall(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        callee: Zir.Inst.Ref,
        args: []const Zir.Inst.Ref,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: ast.Node.Index,
    ) !Zir.Inst.Ref {
        assert(callee != .none);
        assert(src_node != 0);
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureCapacity(gpa, gz.instructions.items.len + 1);
        try gz.astgen.instructions.ensureCapacity(gpa, gz.astgen.instructions.len + 1);
        try gz.astgen.extra.ensureCapacity(gpa, gz.astgen.extra.items.len +
            @typeInfo(Zir.Inst.Call).Struct.fields.len + args.len);

        const payload_index = gz.astgen.addExtraAssumeCapacity(Zir.Inst.Call{
            .callee = callee,
            .args_len = @intCast(u32, args.len),
        });
        gz.astgen.appendRefsAssumeCapacity(args);

        const new_index = @intCast(Zir.Inst.Index, gz.astgen.instructions.len);
        gz.astgen.instructions.appendAssumeCapacity(.{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gz.nodeIndexToRelative(src_node),
                .payload_index = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return indexToRef(new_index);
    }

    /// Note that this returns a `Zir.Inst.Index` not a ref.
    /// Leaves the `payload_index` field undefined.
    fn addBoolBr(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        lhs: Zir.Inst.Ref,
    ) !Zir.Inst.Index {
        assert(lhs != .none);
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureCapacity(gpa, gz.instructions.items.len + 1);
        try gz.astgen.instructions.ensureCapacity(gpa, gz.astgen.instructions.len + 1);

        const new_index = @intCast(Zir.Inst.Index, gz.astgen.instructions.len);
        gz.astgen.instructions.appendAssumeCapacity(.{
            .tag = tag,
            .data = .{ .bool_br = .{
                .lhs = lhs,
                .payload_index = undefined,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index;
    }

    fn addInt(gz: *GenZir, integer: u64) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = .int,
            .data = .{ .int = integer },
        });
    }

    fn addIntBig(gz: *GenZir, limbs: []const std.math.big.Limb) !Zir.Inst.Ref {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;
        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.string_bytes.ensureUnusedCapacity(gpa, @sizeOf(std.math.big.Limb) * limbs.len);

        const new_index = @intCast(Zir.Inst.Index, astgen.instructions.len);
        astgen.instructions.appendAssumeCapacity(.{
            .tag = .int_big,
            .data = .{ .str = .{
                .start = @intCast(u32, astgen.string_bytes.items.len),
                .len = @intCast(u32, limbs.len),
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        astgen.string_bytes.appendSliceAssumeCapacity(mem.sliceAsBytes(limbs));
        return indexToRef(new_index);
    }

    fn addFloat(gz: *GenZir, number: f32, src_node: ast.Node.Index) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = .float,
            .data = .{ .float = .{
                .src_node = gz.nodeIndexToRelative(src_node),
                .number = number,
            } },
        });
    }

    fn addUnNode(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        operand: Zir.Inst.Ref,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: ast.Node.Index,
    ) !Zir.Inst.Ref {
        assert(operand != .none);
        return gz.add(.{
            .tag = tag,
            .data = .{ .un_node = .{
                .operand = operand,
                .src_node = gz.nodeIndexToRelative(src_node),
            } },
        });
    }

    fn addPlNode(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: ast.Node.Index,
        extra: anytype,
    ) !Zir.Inst.Ref {
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureCapacity(gpa, gz.instructions.items.len + 1);
        try gz.astgen.instructions.ensureCapacity(gpa, gz.astgen.instructions.len + 1);

        const payload_index = try gz.astgen.addExtra(extra);
        const new_index = @intCast(Zir.Inst.Index, gz.astgen.instructions.len);
        gz.astgen.instructions.appendAssumeCapacity(.{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gz.nodeIndexToRelative(src_node),
                .payload_index = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return indexToRef(new_index);
    }

    fn addExtendedPayload(
        gz: *GenZir,
        opcode: Zir.Inst.Extended,
        extra: anytype,
    ) !Zir.Inst.Ref {
        const gpa = gz.astgen.gpa;

        try gz.instructions.ensureCapacity(gpa, gz.instructions.items.len + 1);
        try gz.astgen.instructions.ensureCapacity(gpa, gz.astgen.instructions.len + 1);

        const payload_index = try gz.astgen.addExtra(extra);
        const new_index = @intCast(Zir.Inst.Index, gz.astgen.instructions.len);
        gz.astgen.instructions.appendAssumeCapacity(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = opcode,
                .small = undefined,
                .operand = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return indexToRef(new_index);
    }

    fn addExtendedMultiOp(
        gz: *GenZir,
        opcode: Zir.Inst.Extended,
        node: ast.Node.Index,
        operands: []const Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.extra.ensureUnusedCapacity(
            gpa,
            @typeInfo(Zir.Inst.NodeMultiOp).Struct.fields.len + operands.len,
        );

        const payload_index = astgen.addExtraAssumeCapacity(Zir.Inst.NodeMultiOp{
            .src_node = gz.nodeIndexToRelative(node),
        });
        const new_index = @intCast(Zir.Inst.Index, astgen.instructions.len);
        astgen.instructions.appendAssumeCapacity(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = opcode,
                .small = @intCast(u16, operands.len),
                .operand = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        astgen.appendRefsAssumeCapacity(operands);
        return indexToRef(new_index);
    }

    fn addArrayTypeSentinel(
        gz: *GenZir,
        len: Zir.Inst.Ref,
        sentinel: Zir.Inst.Ref,
        elem_type: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureCapacity(gpa, gz.instructions.items.len + 1);
        try gz.astgen.instructions.ensureCapacity(gpa, gz.astgen.instructions.len + 1);

        const payload_index = try gz.astgen.addExtra(Zir.Inst.ArrayTypeSentinel{
            .sentinel = sentinel,
            .elem_type = elem_type,
        });
        const new_index = @intCast(Zir.Inst.Index, gz.astgen.instructions.len);
        gz.astgen.instructions.appendAssumeCapacity(.{
            .tag = .array_type_sentinel,
            .data = .{ .array_type_sentinel = .{
                .len = len,
                .payload_index = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return indexToRef(new_index);
    }

    fn addUnTok(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        operand: Zir.Inst.Ref,
        /// Absolute token index. This function does the conversion to Decl offset.
        abs_tok_index: ast.TokenIndex,
    ) !Zir.Inst.Ref {
        assert(operand != .none);
        return gz.add(.{
            .tag = tag,
            .data = .{ .un_tok = .{
                .operand = operand,
                .src_tok = gz.tokenIndexToRelative(abs_tok_index),
            } },
        });
    }

    fn addStrTok(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        str_index: u32,
        /// Absolute token index. This function does the conversion to Decl offset.
        abs_tok_index: ast.TokenIndex,
    ) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = tag,
            .data = .{ .str_tok = .{
                .start = str_index,
                .src_tok = gz.tokenIndexToRelative(abs_tok_index),
            } },
        });
    }

    fn addBreak(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        break_block: Zir.Inst.Index,
        operand: Zir.Inst.Ref,
    ) !Zir.Inst.Index {
        return gz.addAsIndex(.{
            .tag = tag,
            .data = .{ .@"break" = .{
                .block_inst = break_block,
                .operand = operand,
            } },
        });
    }

    fn addBin(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        lhs: Zir.Inst.Ref,
        rhs: Zir.Inst.Ref,
    ) !Zir.Inst.Ref {
        assert(lhs != .none);
        assert(rhs != .none);
        return gz.add(.{
            .tag = tag,
            .data = .{ .bin = .{
                .lhs = lhs,
                .rhs = rhs,
            } },
        });
    }

    fn addDecl(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        decl_index: u32,
        src_node: ast.Node.Index,
    ) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gz.nodeIndexToRelative(src_node),
                .payload_index = decl_index,
            } },
        });
    }

    fn addNode(
        gz: *GenZir,
        tag: Zir.Inst.Tag,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: ast.Node.Index,
    ) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = tag,
            .data = .{ .node = gz.nodeIndexToRelative(src_node) },
        });
    }

    fn addNodeExtended(
        gz: *GenZir,
        opcode: Zir.Inst.Extended,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: ast.Node.Index,
    ) !Zir.Inst.Ref {
        return gz.add(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = opcode,
                .small = undefined,
                .operand = @bitCast(u32, gz.nodeIndexToRelative(src_node)),
            } },
        });
    }

    fn addAllocExtended(
        gz: *GenZir,
        args: struct {
            /// Absolute node index. This function does the conversion to offset from Decl.
            node: ast.Node.Index,
            type_inst: Zir.Inst.Ref,
            align_inst: Zir.Inst.Ref,
            is_const: bool,
            is_comptime: bool,
        },
    ) !Zir.Inst.Ref {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.extra.ensureUnusedCapacity(
            gpa,
            @typeInfo(Zir.Inst.AllocExtended).Struct.fields.len +
                @as(usize, @boolToInt(args.type_inst != .none)) +
                @as(usize, @boolToInt(args.align_inst != .none)),
        );
        const payload_index = gz.astgen.addExtraAssumeCapacity(Zir.Inst.AllocExtended{
            .src_node = gz.nodeIndexToRelative(args.node),
        });
        if (args.type_inst != .none) {
            astgen.extra.appendAssumeCapacity(@enumToInt(args.type_inst));
        }
        if (args.align_inst != .none) {
            astgen.extra.appendAssumeCapacity(@enumToInt(args.align_inst));
        }

        const has_type: u4 = @boolToInt(args.type_inst != .none);
        const has_align: u4 = @boolToInt(args.align_inst != .none);
        const is_const: u4 = @boolToInt(args.is_const);
        const is_comptime: u4 = @boolToInt(args.is_comptime);
        const small: u16 = has_type | (has_align << 1) | (is_const << 2) | (is_comptime << 3);

        const new_index = @intCast(Zir.Inst.Index, astgen.instructions.len);
        astgen.instructions.appendAssumeCapacity(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .alloc,
                .small = small,
                .operand = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return indexToRef(new_index);
    }

    fn addAsm(
        gz: *GenZir,
        args: struct {
            /// Absolute node index. This function does the conversion to offset from Decl.
            node: ast.Node.Index,
            asm_source: Zir.Inst.Ref,
            output_type_bits: u32,
            is_volatile: bool,
            outputs: []const Zir.Inst.Asm.Output,
            inputs: []const Zir.Inst.Asm.Input,
            clobbers: []const u32,
        },
    ) !Zir.Inst.Ref {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.instructions.ensureUnusedCapacity(gpa, 1);
        try astgen.extra.ensureUnusedCapacity(gpa, @typeInfo(Zir.Inst.Asm).Struct.fields.len +
            args.outputs.len * @typeInfo(Zir.Inst.Asm.Output).Struct.fields.len +
            args.inputs.len * @typeInfo(Zir.Inst.Asm.Input).Struct.fields.len +
            args.clobbers.len);

        const payload_index = gz.astgen.addExtraAssumeCapacity(Zir.Inst.Asm{
            .src_node = gz.nodeIndexToRelative(args.node),
            .asm_source = args.asm_source,
            .output_type_bits = args.output_type_bits,
        });
        for (args.outputs) |output| {
            _ = gz.astgen.addExtraAssumeCapacity(output);
        }
        for (args.inputs) |input| {
            _ = gz.astgen.addExtraAssumeCapacity(input);
        }
        gz.astgen.extra.appendSliceAssumeCapacity(args.clobbers);

        //  * 0b00000000_000XXXXX - `outputs_len`.
        //  * 0b000000XX_XXX00000 - `inputs_len`.
        //  * 0b0XXXXX00_00000000 - `clobbers_len`.
        //  * 0bX0000000_00000000 - is volatile
        const small: u16 = @intCast(u16, args.outputs.len) |
            @intCast(u16, args.inputs.len << 5) |
            @intCast(u16, args.clobbers.len << 10) |
            (@as(u16, @boolToInt(args.is_volatile)) << 15);

        const new_index = @intCast(Zir.Inst.Index, astgen.instructions.len);
        astgen.instructions.appendAssumeCapacity(.{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .@"asm",
                .small = small,
                .operand = payload_index,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return indexToRef(new_index);
    }

    /// Note that this returns a `Zir.Inst.Index` not a ref.
    /// Does *not* append the block instruction to the scope.
    /// Leaves the `payload_index` field undefined.
    fn addBlock(gz: *GenZir, tag: Zir.Inst.Tag, node: ast.Node.Index) !Zir.Inst.Index {
        const new_index = @intCast(Zir.Inst.Index, gz.astgen.instructions.len);
        const gpa = gz.astgen.gpa;
        try gz.astgen.instructions.append(gpa, .{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gz.nodeIndexToRelative(node),
                .payload_index = undefined,
            } },
        });
        return new_index;
    }

    /// Note that this returns a `Zir.Inst.Index` not a ref.
    /// Leaves the `payload_index` field undefined.
    fn addCondBr(gz: *GenZir, tag: Zir.Inst.Tag, node: ast.Node.Index) !Zir.Inst.Index {
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureCapacity(gpa, gz.instructions.items.len + 1);
        const new_index = @intCast(Zir.Inst.Index, gz.astgen.instructions.len);
        try gz.astgen.instructions.append(gpa, .{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gz.nodeIndexToRelative(node),
                .payload_index = undefined,
            } },
        });
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index;
    }

    fn setStruct(gz: *GenZir, inst: Zir.Inst.Index, args: struct {
        src_node: ast.Node.Index,
        body_len: u32,
        fields_len: u32,
        decls_len: u32,
        layout: std.builtin.TypeInfo.ContainerLayout,
    }) !void {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try astgen.extra.ensureUnusedCapacity(gpa, 4);
        const payload_index = @intCast(u32, astgen.extra.items.len);

        if (args.src_node != 0) {
            const node_offset = gz.nodeIndexToRelative(args.src_node);
            astgen.extra.appendAssumeCapacity(@bitCast(u32, node_offset));
        }
        if (args.body_len != 0) {
            astgen.extra.appendAssumeCapacity(args.body_len);
        }
        if (args.fields_len != 0) {
            astgen.extra.appendAssumeCapacity(args.fields_len);
        }
        if (args.decls_len != 0) {
            astgen.extra.appendAssumeCapacity(args.decls_len);
        }
        astgen.instructions.set(inst, .{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .struct_decl,
                .small = @bitCast(u16, Zir.Inst.StructDecl.Small{
                    .has_src_node = args.src_node != 0,
                    .has_body_len = args.body_len != 0,
                    .has_fields_len = args.fields_len != 0,
                    .has_decls_len = args.decls_len != 0,
                    .name_strategy = gz.anon_name_strategy,
                    .layout = args.layout,
                }),
                .operand = payload_index,
            } },
        });
    }

    fn setUnion(gz: *GenZir, inst: Zir.Inst.Index, args: struct {
        src_node: ast.Node.Index,
        tag_type: Zir.Inst.Ref,
        body_len: u32,
        fields_len: u32,
        decls_len: u32,
        layout: std.builtin.TypeInfo.ContainerLayout,
        auto_enum_tag: bool,
    }) !void {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try astgen.extra.ensureUnusedCapacity(gpa, 5);
        const payload_index = @intCast(u32, astgen.extra.items.len);

        if (args.src_node != 0) {
            const node_offset = gz.nodeIndexToRelative(args.src_node);
            astgen.extra.appendAssumeCapacity(@bitCast(u32, node_offset));
        }
        if (args.tag_type != .none) {
            astgen.extra.appendAssumeCapacity(@enumToInt(args.tag_type));
        }
        if (args.body_len != 0) {
            astgen.extra.appendAssumeCapacity(args.body_len);
        }
        if (args.fields_len != 0) {
            astgen.extra.appendAssumeCapacity(args.fields_len);
        }
        if (args.decls_len != 0) {
            astgen.extra.appendAssumeCapacity(args.decls_len);
        }
        astgen.instructions.set(inst, .{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .union_decl,
                .small = @bitCast(u16, Zir.Inst.UnionDecl.Small{
                    .has_src_node = args.src_node != 0,
                    .has_tag_type = args.tag_type != .none,
                    .has_body_len = args.body_len != 0,
                    .has_fields_len = args.fields_len != 0,
                    .has_decls_len = args.decls_len != 0,
                    .name_strategy = gz.anon_name_strategy,
                    .layout = args.layout,
                    .auto_enum_tag = args.auto_enum_tag,
                }),
                .operand = payload_index,
            } },
        });
    }

    fn setEnum(gz: *GenZir, inst: Zir.Inst.Index, args: struct {
        src_node: ast.Node.Index,
        tag_type: Zir.Inst.Ref,
        body_len: u32,
        fields_len: u32,
        decls_len: u32,
        nonexhaustive: bool,
    }) !void {
        const astgen = gz.astgen;
        const gpa = astgen.gpa;

        try astgen.extra.ensureUnusedCapacity(gpa, 5);
        const payload_index = @intCast(u32, astgen.extra.items.len);

        if (args.src_node != 0) {
            const node_offset = gz.nodeIndexToRelative(args.src_node);
            astgen.extra.appendAssumeCapacity(@bitCast(u32, node_offset));
        }
        if (args.tag_type != .none) {
            astgen.extra.appendAssumeCapacity(@enumToInt(args.tag_type));
        }
        if (args.body_len != 0) {
            astgen.extra.appendAssumeCapacity(args.body_len);
        }
        if (args.fields_len != 0) {
            astgen.extra.appendAssumeCapacity(args.fields_len);
        }
        if (args.decls_len != 0) {
            astgen.extra.appendAssumeCapacity(args.decls_len);
        }
        astgen.instructions.set(inst, .{
            .tag = .extended,
            .data = .{ .extended = .{
                .opcode = .enum_decl,
                .small = @bitCast(u16, Zir.Inst.EnumDecl.Small{
                    .has_src_node = args.src_node != 0,
                    .has_tag_type = args.tag_type != .none,
                    .has_body_len = args.body_len != 0,
                    .has_fields_len = args.fields_len != 0,
                    .has_decls_len = args.decls_len != 0,
                    .name_strategy = gz.anon_name_strategy,
                    .nonexhaustive = args.nonexhaustive,
                }),
                .operand = payload_index,
            } },
        });
    }

    fn add(gz: *GenZir, inst: Zir.Inst) !Zir.Inst.Ref {
        return indexToRef(try gz.addAsIndex(inst));
    }

    fn addAsIndex(gz: *GenZir, inst: Zir.Inst) !Zir.Inst.Index {
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try gz.astgen.instructions.ensureUnusedCapacity(gpa, 1);

        const new_index = @intCast(Zir.Inst.Index, gz.astgen.instructions.len);
        gz.astgen.instructions.appendAssumeCapacity(inst);
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index;
    }

    fn reserveInstructionIndex(gz: *GenZir) !Zir.Inst.Index {
        const gpa = gz.astgen.gpa;
        try gz.instructions.ensureUnusedCapacity(gpa, 1);
        try gz.astgen.instructions.ensureUnusedCapacity(gpa, 1);

        const new_index = @intCast(Zir.Inst.Index, gz.astgen.instructions.len);
        gz.astgen.instructions.len += 1;
        gz.instructions.appendAssumeCapacity(new_index);
        return new_index;
    }
};

/// This can only be for short-lived references; the memory becomes invalidated
/// when another string is added.
fn nullTerminatedString(astgen: AstGen, index: usize) [*:0]const u8 {
    return @ptrCast([*:0]const u8, astgen.string_bytes.items.ptr) + index;
}

fn declareNewName(
    astgen: *AstGen,
    start_scope: *Scope,
    name_index: u32,
    node: ast.Node.Index,
) !void {
    const gpa = astgen.gpa;
    var scope = start_scope;
    while (true) {
        switch (scope.tag) {
            .gen_zir => scope = scope.cast(GenZir).?.parent,
            .local_val => scope = scope.cast(Scope.LocalVal).?.parent,
            .local_ptr => scope = scope.cast(Scope.LocalPtr).?.parent,
            .defer_normal, .defer_error => scope = scope.cast(Scope.Defer).?.parent,
            .namespace => {
                const ns = scope.cast(Scope.Namespace).?;
                const gop = try ns.decls.getOrPut(gpa, name_index);
                if (gop.found_existing) {
                    const name = try gpa.dupe(u8, mem.spanZ(astgen.nullTerminatedString(name_index)));
                    defer gpa.free(name);
                    return astgen.failNodeNotes(node, "redeclaration of '{s}'", .{
                        name,
                    }, &[_]u32{
                        try astgen.errNoteNode(gop.value_ptr.*, "other declaration here", .{}),
                    });
                }
                gop.value_ptr.* = node;
                break;
            },
            .top => break,
        }
    }
}

/// Local variables shadowing detection, including function parameters.
fn detectLocalShadowing(
    astgen: *AstGen,
    scope: *Scope,
    ident_name: u32,
    name_token: ast.TokenIndex,
) !void {
    const gpa = astgen.gpa;

    var s = scope;
    while (true) switch (s.tag) {
        .local_val => {
            const local_val = s.cast(Scope.LocalVal).?;
            if (local_val.name == ident_name) {
                const name = try gpa.dupe(u8, mem.spanZ(astgen.nullTerminatedString(ident_name)));
                defer gpa.free(name);
                return astgen.failTokNotes(name_token, "redeclaration of {s} '{s}'", .{
                    @tagName(local_val.id_cat), name,
                }, &[_]u32{
                    try astgen.errNoteTok(
                        local_val.token_src,
                        "previous declaration here",
                        .{},
                    ),
                });
            }
            s = local_val.parent;
        },
        .local_ptr => {
            const local_ptr = s.cast(Scope.LocalPtr).?;
            if (local_ptr.name == ident_name) {
                const name = try gpa.dupe(u8, mem.spanZ(astgen.nullTerminatedString(ident_name)));
                defer gpa.free(name);
                return astgen.failTokNotes(name_token, "redeclaration of {s} '{s}'", .{
                    @tagName(local_ptr.id_cat), name,
                }, &[_]u32{
                    try astgen.errNoteTok(
                        local_ptr.token_src,
                        "previous declaration here",
                        .{},
                    ),
                });
            }
            s = local_ptr.parent;
        },
        .namespace => {
            const ns = s.cast(Scope.Namespace).?;
            const decl_node = ns.decls.get(ident_name) orelse {
                s = ns.parent;
                continue;
            };
            const name = try gpa.dupe(u8, mem.spanZ(astgen.nullTerminatedString(ident_name)));
            defer gpa.free(name);
            return astgen.failTokNotes(name_token, "local shadows declaration of '{s}'", .{
                name,
            }, &[_]u32{
                try astgen.errNoteNode(decl_node, "declared here", .{}),
            });
        },
        .gen_zir => s = s.cast(GenZir).?.parent,
        .defer_normal, .defer_error => s = s.cast(Scope.Defer).?.parent,
        .top => break,
    };
}

fn advanceSourceCursor(astgen: *AstGen, source: []const u8, end: usize) void {
    var i = astgen.source_offset;
    var line = astgen.source_line;
    var column = astgen.source_column;
    while (i < end) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    astgen.source_offset = i;
    astgen.source_line = line;
    astgen.source_column = column;
}

const ref_start_index: u32 = Zir.Inst.Ref.typed_value_map.len;

fn indexToRef(inst: Zir.Inst.Index) Zir.Inst.Ref {
    return @intToEnum(Zir.Inst.Ref, ref_start_index + inst);
}

fn refToIndex(inst: Zir.Inst.Ref) ?Zir.Inst.Index {
    const ref_int = @enumToInt(inst);
    if (ref_int >= ref_start_index) {
        return ref_int - ref_start_index;
    } else {
        return null;
    }
}
