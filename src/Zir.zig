//! Zig Intermediate Representation. Astgen.zig converts AST nodes to these
//! untyped IR instructions. Next, Sema.zig processes these into AIR.
//! The minimum amount of information needed to represent a list of ZIR instructions.
//! Once this structure is completed, it can be used to generate AIR, followed by
//! machine code, without any memory access into the AST tree token list, node list,
//! or source bytes. Exceptions include:
//!  * Compile errors, which may need to reach into these data structures to
//!    create a useful report.
//!  * In the future, possibly inline assembly, which needs to get parsed and
//!    handled by the codegen backend, and errors reported there. However for now,
//!    inline assembly is not an exception.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const ast = std.zig.ast;

const Zir = @This();
const Type = @import("type.zig").Type;
const Value = @import("value.zig").Value;
const TypedValue = @import("TypedValue.zig");
const Module = @import("Module.zig");
const LazySrcLoc = Module.LazySrcLoc;

instructions: std.MultiArrayList(Inst).Slice,
/// In order to store references to strings in fewer bytes, we copy all
/// string bytes into here. String bytes can be null. It is up to whomever
/// is referencing the data here whether they want to store both index and length,
/// thus allowing null bytes, or store only index, and use null-termination. The
/// `string_bytes` array is agnostic to either usage.
/// Indexes 0 and 1 are reserved for special cases.
string_bytes: []u8,
/// The meaning of this data is determined by `Inst.Tag` value.
/// The first few indexes are reserved. See `ExtraIndex` for the values.
extra: []u32,

/// The data stored at byte offset 0 when ZIR is stored in a file.
pub const Header = extern struct {
    instructions_len: u32,
    string_bytes_len: u32,
    extra_len: u32,

    stat_inode: std.fs.File.INode,
    stat_size: u64,
    stat_mtime: i128,
};

pub const ExtraIndex = enum(u32) {
    /// Ref. The main struct decl for this file.
    main_struct,
    /// If this is 0, no compile errors. Otherwise there is a `CompileErrors`
    /// payload at this index.
    compile_errors,
    /// If this is 0, this file contains no imports. Otherwise there is a `Imports`
    /// payload at this index.
    imports,

    _,
};

pub fn getMainStruct(zir: Zir) Zir.Inst.Index {
    return zir.extra[@enumToInt(ExtraIndex.main_struct)] -
        @intCast(u32, Inst.Ref.typed_value_map.len);
}

/// Returns the requested data, as well as the new index which is at the start of the
/// trailers for the object.
pub fn extraData(code: Zir, comptime T: type, index: usize) struct { data: T, end: usize } {
    const fields = std.meta.fields(T);
    var i: usize = index;
    var result: T = undefined;
    inline for (fields) |field| {
        @field(result, field.name) = switch (field.field_type) {
            u32 => code.extra[i],
            Inst.Ref => @intToEnum(Inst.Ref, code.extra[i]),
            i32 => @bitCast(i32, code.extra[i]),
            else => @compileError("bad field type"),
        };
        i += 1;
    }
    return .{
        .data = result,
        .end = i,
    };
}

/// Given an index into `string_bytes` returns the null-terminated string found there.
pub fn nullTerminatedString(code: Zir, index: usize) [:0]const u8 {
    var end: usize = index;
    while (code.string_bytes[end] != 0) {
        end += 1;
    }
    return code.string_bytes[index..end :0];
}

pub fn refSlice(code: Zir, start: usize, len: usize) []Inst.Ref {
    const raw_slice = code.extra[start..][0..len];
    return @bitCast([]Inst.Ref, raw_slice);
}

pub fn hasCompileErrors(code: Zir) bool {
    return code.extra[@enumToInt(ExtraIndex.compile_errors)] != 0;
}

pub fn deinit(code: *Zir, gpa: *Allocator) void {
    code.instructions.deinit(gpa);
    gpa.free(code.string_bytes);
    gpa.free(code.extra);
    code.* = undefined;
}

/// Write human-readable, debug formatted ZIR code to a file.
pub fn renderAsTextToFile(
    gpa: *Allocator,
    scope_file: *Module.Scope.File,
    fs_file: std.fs.File,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var writer: Writer = .{
        .gpa = gpa,
        .arena = &arena.allocator,
        .file = scope_file,
        .code = scope_file.zir,
        .indent = 0,
        .parent_decl_node = 0,
    };

    const main_struct_inst = scope_file.zir.getMainStruct();
    try fs_file.writer().print("%{d} ", .{main_struct_inst});
    try writer.writeInstToStream(fs_file.writer(), main_struct_inst);
    try fs_file.writeAll("\n");
    const imports_index = scope_file.zir.extra[@enumToInt(ExtraIndex.imports)];
    if (imports_index != 0) {
        try fs_file.writeAll("Imports:\n");
        const imports_len = scope_file.zir.extra[imports_index];
        for (scope_file.zir.extra[imports_index + 1 ..][0..imports_len]) |import_inst| {
            const inst_data = writer.code.instructions.items(.data)[import_inst].str_tok;
            const src = inst_data.src();
            const import_path = inst_data.get(writer.code);
            try fs_file.writer().print("  @import(\"{}\") ", .{
                std.zig.fmtEscapes(import_path),
            });
            try writer.writeSrc(fs_file.writer(), src);
            try fs_file.writer().writeAll("\n");
        }
    }
}

/// These are untyped instructions generated from an Abstract Syntax Tree.
/// The data here is immutable because it is possible to have multiple
/// analyses on the same ZIR happening at the same time.
pub const Inst = struct {
    tag: Tag,
    data: Data,

    /// These names are used directly as the instruction names in the text format.
    /// See `data_field_map` for a list of which `Data` fields are used by each `Tag`.
    pub const Tag = enum(u8) {
        /// Arithmetic addition, asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        add,
        /// Twos complement wrapping integer addition.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        addwrap,
        /// Declares a parameter of the current function. Used for debug info and
        /// for checking shadowing against declarations in the current namespace.
        /// Uses the `str_tok` field. Token is the parameter name, string is the
        /// parameter name.
        arg,
        /// Array concatenation. `a ++ b`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        array_cat,
        /// Array multiplication `a ** b`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        array_mul,
        /// `[N]T` syntax. No source location provided.
        /// Uses the `bin` union field. lhs is length, rhs is element type.
        array_type,
        /// `[N:S]T` syntax. No source location provided.
        /// Uses the `array_type_sentinel` field.
        array_type_sentinel,
        /// `@Vector` builtin.
        /// Uses the `pl_node` union field with `Bin` payload.
        /// lhs is length, rhs is element type.
        vector_type,
        /// Given an array type, returns the element type.
        /// Uses the `un_node` union field.
        elem_type,
        /// Given a pointer to an indexable object, returns the len property. This is
        /// used by for loops. This instruction also emits a for-loop specific compile
        /// error if the indexable object is not indexable.
        /// Uses the `un_node` field. The AST node is the for loop node.
        indexable_ptr_len,
        /// Create a `anyframe->T` type.
        /// Uses the `un_node` field.
        anyframe_type,
        /// Type coercion. No source location attached.
        /// Uses the `bin` field.
        as,
        /// Type coercion to the function's return type.
        /// Uses the `pl_node` field. Payload is `As`. AST node could be many things.
        as_node,
        /// Bitwise AND. `&`
        bit_and,
        /// Reinterpret the memory representation of a value as a different type.
        /// Uses the pl_node field with payload `Bin`.
        bitcast,
        /// A typed result location pointer is bitcasted to a new result location pointer.
        /// The new result location pointer has an inferred type.
        /// Uses the pl_node field with payload `Bin`.
        bitcast_result_ptr,
        /// Bitwise NOT. `~`
        /// Uses `un_node`.
        bit_not,
        /// Bitwise OR. `|`
        bit_or,
        /// A labeled block of code, which can return a value.
        /// Uses the `pl_node` union field. Payload is `Block`.
        block,
        /// A list of instructions which are analyzed in the parent context, without
        /// generating a runtime block. Must terminate with an "inline" variant of
        /// a noreturn instruction.
        /// Uses the `pl_node` union field. Payload is `Block`.
        block_inline,
        /// Implements `suspend {...}`.
        /// Uses the `pl_node` union field. Payload is `Block`.
        suspend_block,
        /// Boolean AND. See also `bit_and`.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        bool_and,
        /// Boolean NOT. See also `bit_not`.
        /// Uses the `un_node` field.
        bool_not,
        /// Boolean OR. See also `bit_or`.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        bool_or,
        /// Short-circuiting boolean `and`. `lhs` is a boolean `Ref` and the other operand
        /// is a block, which is evaluated if `lhs` is `true`.
        /// Uses the `bool_br` union field.
        bool_br_and,
        /// Short-circuiting boolean `or`. `lhs` is a boolean `Ref` and the other operand
        /// is a block, which is evaluated if `lhs` is `false`.
        /// Uses the `bool_br` union field.
        bool_br_or,
        /// Return a value from a block.
        /// Uses the `break` union field.
        /// Uses the source information from previous instruction.
        @"break",
        /// Return a value from a block. This instruction is used as the terminator
        /// of a `block_inline`. It allows using the return value from `Sema.analyzeBody`.
        /// This instruction may also be used when it is known that there is only one
        /// break instruction in a block, and the target block is the parent.
        /// Uses the `break` union field.
        break_inline,
        /// Uses the `node` union field.
        breakpoint,
        /// Function call with modifier `.auto`.
        /// Uses `pl_node`. AST node is the function call. Payload is `Call`.
        call,
        /// Same as `call` but it also does `ensure_result_used` on the return value.
        call_chkused,
        /// Same as `call` but with modifier `.compile_time`.
        call_compile_time,
        /// Same as `call` but with modifier `.no_suspend`.
        call_nosuspend,
        /// Same as `call` but with modifier `.async_kw`.
        call_async,
        /// `<`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_lt,
        /// `<=`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_lte,
        /// `==`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_eq,
        /// `>=`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_gte,
        /// `>`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_gt,
        /// `!=`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        cmp_neq,
        /// Coerces a result location pointer to a new element type. It is evaluated "backwards"-
        /// as type coercion from the new element type to the old element type.
        /// Uses the `bin` union field.
        /// LHS is destination element type, RHS is result pointer.
        coerce_result_ptr,
        /// Conditional branch. Splits control flow based on a boolean condition value.
        /// Uses the `pl_node` union field. AST node is an if, while, for, etc.
        /// Payload is `CondBr`.
        condbr,
        /// Same as `condbr`, except the condition is coerced to a comptime value, and
        /// only the taken branch is analyzed. The then block and else block must
        /// terminate with an "inline" variant of a noreturn instruction.
        condbr_inline,
        /// An opaque type definition. Provides an AST node only.
        /// Uses the `pl_node` union field. Payload is `OpaqueDecl`.
        opaque_decl,
        opaque_decl_anon,
        opaque_decl_func,
        /// An error set type definition. Contains a list of field names.
        /// Uses the `pl_node` union field. Payload is `ErrorSetDecl`.
        error_set_decl,
        error_set_decl_anon,
        error_set_decl_func,
        /// Declares the beginning of a statement. Used for debug info.
        /// Uses the `dbg_stmt` union field. The line and column are offset
        /// from the parent declaration.
        dbg_stmt,
        /// Uses a name to identify a Decl and takes a pointer to it.
        /// Uses the `str_tok` union field.
        decl_ref,
        /// Uses a name to identify a Decl and uses it as a value.
        /// Uses the `str_tok` union field.
        decl_val,
        /// Load the value from a pointer. Assumes `x.*` syntax.
        /// Uses `un_node` field. AST node is the `x.*` syntax.
        load,
        /// Arithmetic division. Asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        div,
        /// Given a pointer to an array, slice, or pointer, returns a pointer to the element at
        /// the provided index. Uses the `bin` union field. Source location is implied
        /// to be the same as the previous instruction.
        elem_ptr,
        /// Same as `elem_ptr` except also stores a source location node.
        /// Uses the `pl_node` union field. AST node is a[b] syntax. Payload is `Bin`.
        elem_ptr_node,
        /// Given an array, slice, or pointer, returns the element at the provided index.
        /// Uses the `bin` union field. Source location is implied to be the same
        /// as the previous instruction.
        elem_val,
        /// Same as `elem_val` except also stores a source location node.
        /// Uses the `pl_node` union field. AST node is a[b] syntax. Payload is `Bin`.
        elem_val_node,
        /// Emits a compile error if the operand is not `void`.
        /// Uses the `un_node` field.
        ensure_result_used,
        /// Emits a compile error if an error is ignored.
        /// Uses the `un_node` field.
        ensure_result_non_error,
        /// Create a `E!T` type.
        /// Uses the `pl_node` field with `Bin` payload.
        error_union_type,
        /// `error.Foo` syntax. Uses the `str_tok` field of the Data union.
        error_value,
        /// Implements the `@export` builtin function, based on either an identifier to a Decl,
        /// or field access of a Decl.
        /// Uses the `pl_node` union field. Payload is `Export`.
        @"export",
        /// Given a pointer to a struct or object that contains virtual fields, returns a pointer
        /// to the named field. The field name is stored in string_bytes. Used by a.b syntax.
        /// Uses `pl_node` field. The AST node is the a.b syntax. Payload is Field.
        field_ptr,
        /// Given a struct or object that contains virtual fields, returns the named field.
        /// The field name is stored in string_bytes. Used by a.b syntax.
        /// This instruction also accepts a pointer.
        /// Uses `pl_node` field. The AST node is the a.b syntax. Payload is Field.
        field_val,
        /// Given a pointer to a struct or object that contains virtual fields, returns a pointer
        /// to the named field. The field name is a comptime instruction. Used by @field.
        /// Uses `pl_node` field. The AST node is the builtin call. Payload is FieldNamed.
        field_ptr_named,
        /// Given a struct or object that contains virtual fields, returns the named field.
        /// The field name is a comptime instruction. Used by @field.
        /// Uses `pl_node` field. The AST node is the builtin call. Payload is FieldNamed.
        field_val_named,
        /// Returns a function type, or a function instance, depending on whether
        /// the body_len is 0. Calling convention is auto.
        /// Uses the `pl_node` union field. `payload_index` points to a `Func`.
        func,
        /// Same as `func` but has an inferred error set.
        func_inferred,
        /// Implements the `@import` builtin.
        /// Uses the `str_tok` field.
        import,
        /// Integer literal that fits in a u64. Uses the `int` union field.
        int,
        /// Arbitrary sized integer literal. Uses the `str` union field.
        int_big,
        /// A float literal that fits in a f32. Uses the float union value.
        float,
        /// A float literal that fits in a f128. Uses the `pl_node` union value.
        /// Payload is `Float128`.
        float128,
        /// Make an integer type out of signedness and bit count.
        /// Payload is `int_type`
        int_type,
        /// Return a boolean false if an optional is null. `x != null`
        /// Uses the `un_node` field.
        is_non_null,
        /// Return a boolean false if an optional is null. `x.* != null`
        /// Uses the `un_node` field.
        is_non_null_ptr,
        /// Return a boolean false if value is an error
        /// Uses the `un_node` field.
        is_non_err,
        /// Return a boolean false if dereferenced pointer is an error
        /// Uses the `un_node` field.
        is_non_err_ptr,
        /// A labeled block of code that loops forever. At the end of the body will have either
        /// a `repeat` instruction or a `repeat_inline` instruction.
        /// Uses the `pl_node` field. The AST node is either a for loop or while loop.
        /// This ZIR instruction is needed because AIR does not (yet?) match ZIR, and Sema
        /// needs to emit more than 1 AIR block for this instruction.
        /// The payload is `Block`.
        loop,
        /// Sends runtime control flow back to the beginning of the current block.
        /// Uses the `node` field.
        repeat,
        /// Sends comptime control flow back to the beginning of the current block.
        /// Uses the `node` field.
        repeat_inline,
        /// Merge two error sets into one, `E1 || E2`.
        /// Uses the `pl_node` field with payload `Bin`.
        merge_error_sets,
        /// Ambiguously remainder division or modulus. If the computation would possibly have
        /// a different value depending on whether the operation is remainder division or modulus,
        /// a compile error is emitted. Otherwise the computation is performed.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        mod_rem,
        /// Arithmetic multiplication. Asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        mul,
        /// Twos complement wrapping integer multiplication.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        mulwrap,
        /// Given a reference to a function and a parameter index, returns the
        /// type of the parameter. The only usage of this instruction is for the
        /// result location of parameters of function calls. In the case of a function's
        /// parameter type being `anytype`, it is the type coercion's job to detect this
        /// scenario and skip the coercion, so that semantic analysis of this instruction
        /// is not in a position where it must create an invalid type.
        /// Uses the `param_type` union field.
        param_type,
        /// Turns an R-Value into a const L-Value. In other words, it takes a value,
        /// stores it in a memory location, and returns a const pointer to it. If the value
        /// is `comptime`, the memory location is global static constant data. Otherwise,
        /// the memory location is in the stack frame, local to the scope containing the
        /// instruction.
        /// Uses the `un_tok` union field.
        ref,
        /// Sends control flow back to the function's callee.
        /// Includes an operand as the return value.
        /// Includes an AST node source location.
        /// Uses the `un_node` union field.
        ret_node,
        /// Sends control flow back to the function's callee.
        /// Includes an operand as the return value.
        /// Includes a token source location.
        /// Uses the `un_tok` union field.
        /// The operand needs to get coerced to the function's return type.
        ret_coerce,
        /// Sends control flow back to the function's callee.
        /// The return operand is `error.foo` where `foo` is given by the string.
        /// If the current function has an inferred error set, the error given by the
        /// name is added to it.
        /// Uses the `str_tok` union field.
        ret_err_value,
        /// A string name is provided which is an anonymous error set value.
        /// If the current function has an inferred error set, the error given by the
        /// name is added to it.
        /// Results in the error code. Note that control flow is not diverted with
        /// this instruction; a following 'ret' instruction will do the diversion.
        /// Uses the `str_tok` union field.
        ret_err_value_code,
        /// Create a pointer type that does not have a sentinel, alignment, or bit range specified.
        /// Uses the `ptr_type_simple` union field.
        ptr_type_simple,
        /// Create a pointer type which can have a sentinel, alignment, and/or bit range.
        /// Uses the `ptr_type` union field.
        ptr_type,
        /// Slice operation `lhs[rhs..]`. No sentinel and no end offset.
        /// Uses the `pl_node` field. AST node is the slice syntax. Payload is `SliceStart`.
        slice_start,
        /// Slice operation `array_ptr[start..end]`. No sentinel.
        /// Uses the `pl_node` field. AST node is the slice syntax. Payload is `SliceEnd`.
        slice_end,
        /// Slice operation `array_ptr[start..end:sentinel]`.
        /// Uses the `pl_node` field. AST node is the slice syntax. Payload is `SliceSentinel`.
        slice_sentinel,
        /// Write a value to a pointer. For loading, see `load`.
        /// Source location is assumed to be same as previous instruction.
        /// Uses the `bin` union field.
        store,
        /// Same as `store` except provides a source location.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        store_node,
        /// Same as `store` but the type of the value being stored will be used to infer
        /// the block type. The LHS is the pointer to store to.
        /// Uses the `bin` union field.
        /// If the pointer is none, it means this instruction has been elided in
        /// AstGen, but AstGen was unable to actually omit it from the ZIR code.
        store_to_block_ptr,
        /// Same as `store` but the type of the value being stored will be used to infer
        /// the pointer type.
        /// Uses the `bin` union field - Astgen.zig depends on the ability to change
        /// the tag of an instruction from `store_to_block_ptr` to `store_to_inferred_ptr`
        /// without changing the data.
        store_to_inferred_ptr,
        /// String Literal. Makes an anonymous Decl and then takes a pointer to it.
        /// Uses the `str` union field.
        str,
        /// Arithmetic subtraction. Asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        sub,
        /// Twos complement wrapping integer subtraction.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        subwrap,
        /// Arithmetic negation. Asserts no integer overflow.
        /// Same as sub with a lhs of 0, split into a separate instruction to save memory.
        /// Uses `un_node`.
        negate,
        /// Twos complement wrapping integer negation.
        /// Same as subwrap with a lhs of 0, split into a separate instruction to save memory.
        /// Uses `un_node`.
        negate_wrap,
        /// Returns the type of a value.
        /// Uses the `un_node` field.
        typeof,
        /// Given a value which is a pointer, returns the element type.
        /// Uses the `un_node` field.
        typeof_elem,
        /// Given a value, look at the type of it, which must be an integer type.
        /// Returns the integer type for the RHS of a shift operation.
        /// Uses the `un_node` field.
        typeof_log2_int_type,
        /// Given an integer type, returns the integer type for the RHS of a shift operation.
        /// Uses the `un_node` field.
        log2_int_type,
        /// Asserts control-flow will not reach this instruction (`unreachable`).
        /// Uses the `unreachable` union field.
        @"unreachable",
        /// Bitwise XOR. `^`
        /// Uses the `pl_node` union field. Payload is `Bin`.
        xor,
        /// Create an optional type '?T'
        /// Uses the `un_node` field.
        optional_type,
        /// ?T => T with safety.
        /// Given an optional value, returns the payload value, with a safety check that
        /// the value is non-null. Used for `orelse`, `if` and `while`.
        /// Uses the `un_node` field.
        optional_payload_safe,
        /// ?T => T without safety.
        /// Given an optional value, returns the payload value. No safety checks.
        /// Uses the `un_node` field.
        optional_payload_unsafe,
        /// *?T => *T with safety.
        /// Given a pointer to an optional value, returns a pointer to the payload value,
        /// with a safety check that the value is non-null. Used for `orelse`, `if` and `while`.
        /// Uses the `un_node` field.
        optional_payload_safe_ptr,
        /// *?T => *T without safety.
        /// Given a pointer to an optional value, returns a pointer to the payload value.
        /// No safety checks.
        /// Uses the `un_node` field.
        optional_payload_unsafe_ptr,
        /// E!T => T with safety.
        /// Given an error union value, returns the payload value, with a safety check
        /// that the value is not an error. Used for catch, if, and while.
        /// Uses the `un_node` field.
        err_union_payload_safe,
        /// E!T => T without safety.
        /// Given an error union value, returns the payload value. No safety checks.
        /// Uses the `un_node` field.
        err_union_payload_unsafe,
        /// *E!T => *T with safety.
        /// Given a pointer to an error union value, returns a pointer to the payload value,
        /// with a safety check that the value is not an error. Used for catch, if, and while.
        /// Uses the `un_node` field.
        err_union_payload_safe_ptr,
        /// *E!T => *T without safety.
        /// Given a pointer to a error union value, returns a pointer to the payload value.
        /// No safety checks.
        /// Uses the `un_node` field.
        err_union_payload_unsafe_ptr,
        /// E!T => E without safety.
        /// Given an error union value, returns the error code. No safety checks.
        /// Uses the `un_node` field.
        err_union_code,
        /// *E!T => E without safety.
        /// Given a pointer to an error union value, returns the error code. No safety checks.
        /// Uses the `un_node` field.
        err_union_code_ptr,
        /// Takes a *E!T and raises a compiler error if T != void
        /// Uses the `un_tok` field.
        ensure_err_payload_void,
        /// An enum literal. Uses the `str_tok` union field.
        enum_literal,
        /// A switch expression. Uses the `pl_node` union field.
        /// AST node is the switch, payload is `SwitchBlock`.
        /// All prongs of target handled.
        switch_block,
        /// Same as switch_block, except one or more prongs have multiple items.
        /// Payload is `SwitchBlockMulti`
        switch_block_multi,
        /// Same as switch_block, except has an else prong.
        switch_block_else,
        /// Same as switch_block_else, except one or more prongs have multiple items.
        /// Payload is `SwitchBlockMulti`
        switch_block_else_multi,
        /// Same as switch_block, except has an underscore prong.
        switch_block_under,
        /// Same as switch_block, except one or more prongs have multiple items.
        /// Payload is `SwitchBlockMulti`
        switch_block_under_multi,
        /// Same as `switch_block` but the target is a pointer to the value being switched on.
        switch_block_ref,
        /// Same as `switch_block_multi` but the target is a pointer to the value being switched on.
        /// Payload is `SwitchBlockMulti`
        switch_block_ref_multi,
        /// Same as `switch_block_else` but the target is a pointer to the value being switched on.
        switch_block_ref_else,
        /// Same as `switch_block_else_multi` but the target is a pointer to the
        /// value being switched on.
        /// Payload is `SwitchBlockMulti`
        switch_block_ref_else_multi,
        /// Same as `switch_block_under` but the target is a pointer to the value
        /// being switched on.
        switch_block_ref_under,
        /// Same as `switch_block_under_multi` but the target is a pointer to
        /// the value being switched on.
        /// Payload is `SwitchBlockMulti`
        switch_block_ref_under_multi,
        /// Produces the capture value for a switch prong.
        /// Uses the `switch_capture` field.
        switch_capture,
        /// Produces the capture value for a switch prong.
        /// Result is a pointer to the value.
        /// Uses the `switch_capture` field.
        switch_capture_ref,
        /// Produces the capture value for a switch prong.
        /// The prong is one of the multi cases.
        /// Uses the `switch_capture` field.
        switch_capture_multi,
        /// Produces the capture value for a switch prong.
        /// The prong is one of the multi cases.
        /// Result is a pointer to the value.
        /// Uses the `switch_capture` field.
        switch_capture_multi_ref,
        /// Produces the capture value for the else/'_' switch prong.
        /// Uses the `switch_capture` field.
        switch_capture_else,
        /// Produces the capture value for the else/'_' switch prong.
        /// Result is a pointer to the value.
        /// Uses the `switch_capture` field.
        switch_capture_else_ref,
        /// Given a set of `field_ptr` instructions, assumes they are all part of a struct
        /// initialization expression, and emits compile errors for duplicate fields
        /// as well as missing fields, if applicable.
        /// This instruction asserts that there is at least one field_ptr instruction,
        /// because it must use one of them to find out the struct type.
        /// Uses the `pl_node` field. Payload is `Block`.
        validate_struct_init_ptr,
        /// Given a set of `elem_ptr_node` instructions, assumes they are all part of an
        /// array initialization expression, and emits a compile error if the number of
        /// elements does not match the array type.
        /// This instruction asserts that there is at least one elem_ptr_node instruction,
        /// because it must use one of them to find out the array type.
        /// Uses the `pl_node` field. Payload is `Block`.
        validate_array_init_ptr,
        /// A struct literal with a specified type, with no fields.
        /// Uses the `un_node` field.
        struct_init_empty,
        /// Given a struct, union, or enum, and a field name as a string index,
        /// returns the field type. Uses the `pl_node` field. Payload is `FieldType`.
        field_type,
        /// Given a struct, union, or enum, and a field name as a Ref,
        /// returns the field type. Uses the `pl_node` field. Payload is `FieldTypeRef`.
        field_type_ref,
        /// Finalizes a typed struct initialization, performs validation, and returns the
        /// struct value.
        /// Uses the `pl_node` field. Payload is `StructInit`.
        struct_init,
        /// Struct initialization syntax, make the result a pointer.
        /// Uses the `pl_node` field. Payload is `StructInit`.
        struct_init_ref,
        /// Struct initialization without a type.
        /// Uses the `pl_node` field. Payload is `StructInitAnon`.
        struct_init_anon,
        /// Anonymous struct initialization syntax, make the result a pointer.
        /// Uses the `pl_node` field. Payload is `StructInitAnon`.
        struct_init_anon_ref,
        /// Array initialization syntax.
        /// Uses the `pl_node` field. Payload is `MultiOp`.
        array_init,
        /// Anonymous array initialization syntax.
        /// Uses the `pl_node` field. Payload is `MultiOp`.
        array_init_anon,
        /// Array initialization syntax, make the result a pointer.
        /// Uses the `pl_node` field. Payload is `MultiOp`.
        array_init_ref,
        /// Anonymous array initialization syntax, make the result a pointer.
        /// Uses the `pl_node` field. Payload is `MultiOp`.
        array_init_anon_ref,
        /// Given a pointer to a union and a comptime known field name, activates that field
        /// and returns a pointer to it.
        /// Uses the `pl_node` field. Payload is `UnionInitPtr`.
        union_init_ptr,
        /// Implements the `@typeInfo` builtin. Uses `un_node`.
        type_info,
        /// Implements the `@sizeOf` builtin. Uses `un_node`.
        size_of,
        /// Implements the `@bitSizeOf` builtin. Uses `un_node`.
        bit_size_of,
        /// Implements the `@fence` builtin. Uses `node`.
        fence,

        /// Implement builtin `@ptrToInt`. Uses `un_node`.
        /// Convert a pointer to a `usize` integer.
        ptr_to_int,
        /// Implement builtin `@errToInt`. Uses `un_node`.
        error_to_int,
        /// Implement builtin `@intToError`. Uses `un_node`.
        int_to_error,
        /// Emit an error message and fail compilation.
        /// Uses the `un_node` field.
        compile_error,
        /// Changes the maximum number of backwards branches that compile-time
        /// code execution can use before giving up and making a compile error.
        /// Uses the `un_node` union field.
        set_eval_branch_quota,
        /// Converts an enum value into an integer. Resulting type will be the tag type
        /// of the enum. Uses `un_node`.
        enum_to_int,
        /// Implement builtin `@alignOf`. Uses `un_node`.
        align_of,
        /// Implement builtin `@boolToInt`. Uses `un_node`.
        bool_to_int,
        /// Implement builtin `@embedFile`. Uses `un_node`.
        embed_file,
        /// Implement builtin `@errorName`. Uses `un_node`.
        error_name,
        /// Implement builtin `@panic`. Uses `un_node`.
        panic,
        /// Implement builtin `@setAlignStack`. Uses `un_node`.
        set_align_stack,
        /// Implement builtin `@setCold`. Uses `un_node`.
        set_cold,
        /// Implement builtin `@setFloatMode`. Uses `un_node`.
        set_float_mode,
        /// Implement builtin `@setRuntimeSafety`. Uses `un_node`.
        set_runtime_safety,
        /// Implement builtin `@sqrt`. Uses `un_node`.
        sqrt,
        /// Implement builtin `@sin`. Uses `un_node`.
        sin,
        /// Implement builtin `@cos`. Uses `un_node`.
        cos,
        /// Implement builtin `@exp`. Uses `un_node`.
        exp,
        /// Implement builtin `@exp2`. Uses `un_node`.
        exp2,
        /// Implement builtin `@log`. Uses `un_node`.
        log,
        /// Implement builtin `@log2`. Uses `un_node`.
        log2,
        /// Implement builtin `@log10`. Uses `un_node`.
        log10,
        /// Implement builtin `@fabs`. Uses `un_node`.
        fabs,
        /// Implement builtin `@floor`. Uses `un_node`.
        floor,
        /// Implement builtin `@ceil`. Uses `un_node`.
        ceil,
        /// Implement builtin `@trunc`. Uses `un_node`.
        trunc,
        /// Implement builtin `@round`. Uses `un_node`.
        round,
        /// Implement builtin `@tagName`. Uses `un_node`.
        tag_name,
        /// Implement builtin `@Type`. Uses `un_node`.
        reify,
        /// Implement builtin `@typeName`. Uses `un_node`.
        type_name,
        /// Implement builtin `@Frame`. Uses `un_node`.
        frame_type,
        /// Implement builtin `@frameSize`. Uses `un_node`.
        frame_size,

        /// Implements the `@floatToInt` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        float_to_int,
        /// Implements the `@intToFloat` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        int_to_float,
        /// Implements the `@intToPtr` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        int_to_ptr,
        /// Converts an integer into an enum value.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        int_to_enum,
        /// Convert a larger float type to any other float type, possibly causing
        /// a loss of precision.
        /// Uses the `pl_node` field. AST is the `@floatCast` syntax.
        /// Payload is `Bin` with lhs as the dest type, rhs the operand.
        float_cast,
        /// Implements the `@intCast` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        /// Convert an integer value to another integer type, asserting that the destination type
        /// can hold the same mathematical value.
        int_cast,
        /// Implements the `@errSetCast` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        err_set_cast,
        /// Implements the `@ptrCast` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        ptr_cast,
        /// Implements the `@truncate` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest type, `rhs` is operand.
        truncate,
        /// Implements the `@alignCast` builtin.
        /// Uses `pl_node` with payload `Bin`. `lhs` is dest alignment, `rhs` is operand.
        align_cast,

        /// Implements the `@hasDecl` builtin.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        has_decl,
        /// Implements the `@hasField` builtin.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        has_field,

        /// Implements the `@clz` builtin. Uses the `un_node` union field.
        clz,
        /// Implements the `@ctz` builtin. Uses the `un_node` union field.
        ctz,
        /// Implements the `@popCount` builtin. Uses the `un_node` union field.
        pop_count,
        /// Implements the `@byteSwap` builtin. Uses the `un_node` union field.
        byte_swap,
        /// Implements the `@bitReverse` builtin. Uses the `un_node` union field.
        bit_reverse,

        /// Implements the `@divExact` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        div_exact,
        /// Implements the `@divFloor` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        div_floor,
        /// Implements the `@divTrunc` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        div_trunc,
        /// Implements the `@mod` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        mod,
        /// Implements the `@rem` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        rem,

        /// Integer shift-left. Zeroes are shifted in from the right hand side.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        shl,
        /// Implements the `@shlExact` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        shl_exact,
        /// Integer shift-right. Arithmetic or logical depending on the signedness of the integer type.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        shr,
        /// Implements the `@shrExact` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        shr_exact,

        /// Implements the `@bitOffsetOf` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        bit_offset_of,
        /// Implements the `@offsetOf` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        offset_of,
        /// Implements the `@cmpxchgStrong` builtin.
        /// Uses the `pl_node` union field with payload `Cmpxchg`.
        cmpxchg_strong,
        /// Implements the `@cmpxchgWeak` builtin.
        /// Uses the `pl_node` union field with payload `Cmpxchg`.
        cmpxchg_weak,
        /// Implements the `@splat` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        splat,
        /// Implements the `@reduce` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        reduce,
        /// Implements the `@shuffle` builtin.
        /// Uses the `pl_node` union field with payload `Shuffle`.
        shuffle,
        /// Implements the `@atomicLoad` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        atomic_load,
        /// Implements the `@atomicRmw` builtin.
        /// Uses the `pl_node` union field with payload `AtomicRmw`.
        atomic_rmw,
        /// Implements the `@atomicStore` builtin.
        /// Uses the `pl_node` union field with payload `AtomicStore`.
        atomic_store,
        /// Implements the `@mulAdd` builtin.
        /// Uses the `pl_node` union field with payload `MulAdd`.
        mul_add,
        /// Implements the `@call` builtin.
        /// Uses the `pl_node` union field with payload `BuiltinCall`.
        builtin_call,
        /// Given a type and a field name, returns a pointer to the field type.
        /// Assumed to be part of a `@fieldParentPtr` builtin call.
        /// Uses the `bin` union field. LHS is type, RHS is field name.
        field_ptr_type,
        /// Implements the `@fieldParentPtr` builtin.
        /// Uses the `pl_node` union field with payload `FieldParentPtr`.
        field_parent_ptr,
        /// Implements the `@memcpy` builtin.
        /// Uses the `pl_node` union field with payload `Memcpy`.
        memcpy,
        /// Implements the `@memset` builtin.
        /// Uses the `pl_node` union field with payload `Memset`.
        memset,
        /// Implements the `@asyncCall` builtin.
        /// Uses the `pl_node` union field with payload `AsyncCall`.
        builtin_async_call,
        /// Implements the `@cImport` builtin.
        /// Uses the `pl_node` union field with payload `Block`.
        c_import,

        /// Allocates stack local memory.
        /// Uses the `un_node` union field. The operand is the type of the allocated object.
        /// The node source location points to a var decl node.
        alloc,
        /// Same as `alloc` except mutable.
        alloc_mut,
        /// Allocates comptime-mutable memory.
        /// Uses the `un_node` union field. The operand is the type of the allocated object.
        /// The node source location points to a var decl node.
        alloc_comptime,
        /// Same as `alloc` except the type is inferred.
        /// Uses the `node` union field.
        alloc_inferred,
        /// Same as `alloc_inferred` except mutable.
        alloc_inferred_mut,
        /// Same as `alloc_comptime` except the type is inferred.
        alloc_inferred_comptime,
        /// Each `store_to_inferred_ptr` puts the type of the stored value into a set,
        /// and then `resolve_inferred_alloc` triggers peer type resolution on the set.
        /// The operand is a `alloc_inferred` or `alloc_inferred_mut` instruction, which
        /// is the allocation that needs to have its type inferred.
        /// Uses the `un_node` field. The AST node is the var decl.
        resolve_inferred_alloc,

        /// Implements `resume` syntax. Uses `un_node` field.
        @"resume",
        @"await",
        await_nosuspend,

        /// The ZIR instruction tag is one of the `Extended` ones.
        /// Uses the `extended` union field.
        extended,

        /// Returns whether the instruction is one of the control flow "noreturn" types.
        /// Function calls do not count.
        pub fn isNoReturn(tag: Tag) bool {
            return switch (tag) {
                .arg,
                .add,
                .addwrap,
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
                .breakpoint,
                .fence,
                .call,
                .call_chkused,
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
                .opaque_decl,
                .opaque_decl_anon,
                .opaque_decl_func,
                .error_set_decl,
                .error_set_decl_anon,
                .error_set_decl_func,
                .dbg_stmt,
                .decl_ref,
                .decl_val,
                .load,
                .div,
                .elem_ptr,
                .elem_val,
                .elem_ptr_node,
                .elem_val_node,
                .ensure_result_used,
                .ensure_result_non_error,
                .@"export",
                .field_ptr,
                .field_val,
                .field_ptr_named,
                .field_val_named,
                .func,
                .func_inferred,
                .has_decl,
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
                .store,
                .store_node,
                .store_to_block_ptr,
                .store_to_inferred_ptr,
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
                .error_to_int,
                .int_to_error,
                .ptr_type,
                .ptr_type_simple,
                .ensure_err_payload_void,
                .enum_literal,
                .merge_error_sets,
                .error_union_type,
                .bit_not,
                .error_value,
                .slice_start,
                .slice_end,
                .slice_sentinel,
                .import,
                .typeof_log2_int_type,
                .log2_int_type,
                .resolve_inferred_alloc,
                .set_eval_branch_quota,
                .switch_capture,
                .switch_capture_ref,
                .switch_capture_multi,
                .switch_capture_multi_ref,
                .switch_capture_else,
                .switch_capture_else_ref,
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
                .validate_struct_init_ptr,
                .validate_array_init_ptr,
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
                .int_to_enum,
                .enum_to_int,
                .type_info,
                .size_of,
                .bit_size_of,
                .ptr_to_int,
                .align_of,
                .bool_to_int,
                .embed_file,
                .error_name,
                .set_align_stack,
                .set_cold,
                .set_float_mode,
                .set_runtime_safety,
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
                => false,

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
                => true,
            };
        }

        /// Used by debug safety-checking code.
        pub const data_tags = list: {
            @setEvalBranchQuota(2000);
            break :list std.enums.directEnumArray(Tag, Data.FieldEnum, 0, .{
                .add = .pl_node,
                .addwrap = .pl_node,
                .arg = .str_tok,
                .array_cat = .pl_node,
                .array_mul = .pl_node,
                .array_type = .bin,
                .array_type_sentinel = .array_type_sentinel,
                .vector_type = .pl_node,
                .elem_type = .un_node,
                .indexable_ptr_len = .un_node,
                .anyframe_type = .un_node,
                .as = .bin,
                .as_node = .pl_node,
                .bit_and = .pl_node,
                .bitcast = .pl_node,
                .bitcast_result_ptr = .pl_node,
                .bit_not = .un_node,
                .bit_or = .pl_node,
                .block = .pl_node,
                .block_inline = .pl_node,
                .suspend_block = .pl_node,
                .bool_and = .pl_node,
                .bool_not = .un_node,
                .bool_or = .pl_node,
                .bool_br_and = .bool_br,
                .bool_br_or = .bool_br,
                .@"break" = .@"break",
                .break_inline = .@"break",
                .breakpoint = .node,
                .call = .pl_node,
                .call_chkused = .pl_node,
                .call_compile_time = .pl_node,
                .call_nosuspend = .pl_node,
                .call_async = .pl_node,
                .cmp_lt = .pl_node,
                .cmp_lte = .pl_node,
                .cmp_eq = .pl_node,
                .cmp_gte = .pl_node,
                .cmp_gt = .pl_node,
                .cmp_neq = .pl_node,
                .coerce_result_ptr = .bin,
                .condbr = .pl_node,
                .condbr_inline = .pl_node,
                .opaque_decl = .pl_node,
                .opaque_decl_anon = .pl_node,
                .opaque_decl_func = .pl_node,
                .error_set_decl = .pl_node,
                .error_set_decl_anon = .pl_node,
                .error_set_decl_func = .pl_node,
                .dbg_stmt = .dbg_stmt,
                .decl_ref = .str_tok,
                .decl_val = .str_tok,
                .load = .un_node,
                .div = .pl_node,
                .elem_ptr = .bin,
                .elem_ptr_node = .pl_node,
                .elem_val = .bin,
                .elem_val_node = .pl_node,
                .ensure_result_used = .un_node,
                .ensure_result_non_error = .un_node,
                .error_union_type = .pl_node,
                .error_value = .str_tok,
                .@"export" = .pl_node,
                .field_ptr = .pl_node,
                .field_val = .pl_node,
                .field_ptr_named = .pl_node,
                .field_val_named = .pl_node,
                .func = .pl_node,
                .func_inferred = .pl_node,
                .import = .str_tok,
                .int = .int,
                .int_big = .str,
                .float = .float,
                .float128 = .pl_node,
                .int_type = .int_type,
                .is_non_null = .un_node,
                .is_non_null_ptr = .un_node,
                .is_non_err = .un_node,
                .is_non_err_ptr = .un_node,
                .loop = .pl_node,
                .repeat = .node,
                .repeat_inline = .node,
                .merge_error_sets = .pl_node,
                .mod_rem = .pl_node,
                .mul = .pl_node,
                .mulwrap = .pl_node,
                .param_type = .param_type,
                .ref = .un_tok,
                .ret_node = .un_node,
                .ret_coerce = .un_tok,
                .ret_err_value = .str_tok,
                .ret_err_value_code = .str_tok,
                .ptr_type_simple = .ptr_type_simple,
                .ptr_type = .ptr_type,
                .slice_start = .pl_node,
                .slice_end = .pl_node,
                .slice_sentinel = .pl_node,
                .store = .bin,
                .store_node = .pl_node,
                .store_to_block_ptr = .bin,
                .store_to_inferred_ptr = .bin,
                .str = .str,
                .sub = .pl_node,
                .subwrap = .pl_node,
                .negate = .un_node,
                .negate_wrap = .un_node,
                .typeof = .un_node,
                .typeof_elem = .un_node,
                .typeof_log2_int_type = .un_node,
                .log2_int_type = .un_node,
                .@"unreachable" = .@"unreachable",
                .xor = .pl_node,
                .optional_type = .un_node,
                .optional_payload_safe = .un_node,
                .optional_payload_unsafe = .un_node,
                .optional_payload_safe_ptr = .un_node,
                .optional_payload_unsafe_ptr = .un_node,
                .err_union_payload_safe = .un_node,
                .err_union_payload_unsafe = .un_node,
                .err_union_payload_safe_ptr = .un_node,
                .err_union_payload_unsafe_ptr = .un_node,
                .err_union_code = .un_node,
                .err_union_code_ptr = .un_node,
                .ensure_err_payload_void = .un_tok,
                .enum_literal = .str_tok,
                .switch_block = .pl_node,
                .switch_block_multi = .pl_node,
                .switch_block_else = .pl_node,
                .switch_block_else_multi = .pl_node,
                .switch_block_under = .pl_node,
                .switch_block_under_multi = .pl_node,
                .switch_block_ref = .pl_node,
                .switch_block_ref_multi = .pl_node,
                .switch_block_ref_else = .pl_node,
                .switch_block_ref_else_multi = .pl_node,
                .switch_block_ref_under = .pl_node,
                .switch_block_ref_under_multi = .pl_node,
                .switch_capture = .switch_capture,
                .switch_capture_ref = .switch_capture,
                .switch_capture_multi = .switch_capture,
                .switch_capture_multi_ref = .switch_capture,
                .switch_capture_else = .switch_capture,
                .switch_capture_else_ref = .switch_capture,
                .validate_struct_init_ptr = .pl_node,
                .validate_array_init_ptr = .pl_node,
                .struct_init_empty = .un_node,
                .field_type = .pl_node,
                .field_type_ref = .pl_node,
                .struct_init = .pl_node,
                .struct_init_ref = .pl_node,
                .struct_init_anon = .pl_node,
                .struct_init_anon_ref = .pl_node,
                .array_init = .pl_node,
                .array_init_anon = .pl_node,
                .array_init_ref = .pl_node,
                .array_init_anon_ref = .pl_node,
                .union_init_ptr = .pl_node,
                .type_info = .un_node,
                .size_of = .un_node,
                .bit_size_of = .un_node,
                .fence = .node,

                .ptr_to_int = .un_node,
                .error_to_int = .un_node,
                .int_to_error = .un_node,
                .compile_error = .un_node,
                .set_eval_branch_quota = .un_node,
                .enum_to_int = .un_node,
                .align_of = .un_node,
                .bool_to_int = .un_node,
                .embed_file = .un_node,
                .error_name = .un_node,
                .panic = .un_node,
                .set_align_stack = .un_node,
                .set_cold = .un_node,
                .set_float_mode = .un_node,
                .set_runtime_safety = .un_node,
                .sqrt = .un_node,
                .sin = .un_node,
                .cos = .un_node,
                .exp = .un_node,
                .exp2 = .un_node,
                .log = .un_node,
                .log2 = .un_node,
                .log10 = .un_node,
                .fabs = .un_node,
                .floor = .un_node,
                .ceil = .un_node,
                .trunc = .un_node,
                .round = .un_node,
                .tag_name = .un_node,
                .reify = .un_node,
                .type_name = .un_node,
                .frame_type = .un_node,
                .frame_size = .un_node,

                .float_to_int = .pl_node,
                .int_to_float = .pl_node,
                .int_to_ptr = .pl_node,
                .int_to_enum = .pl_node,
                .float_cast = .pl_node,
                .int_cast = .pl_node,
                .err_set_cast = .pl_node,
                .ptr_cast = .pl_node,
                .truncate = .pl_node,
                .align_cast = .pl_node,

                .has_decl = .pl_node,
                .has_field = .pl_node,

                .clz = .un_node,
                .ctz = .un_node,
                .pop_count = .un_node,
                .byte_swap = .un_node,
                .bit_reverse = .un_node,

                .div_exact = .pl_node,
                .div_floor = .pl_node,
                .div_trunc = .pl_node,
                .mod = .pl_node,
                .rem = .pl_node,

                .shl = .pl_node,
                .shl_exact = .pl_node,
                .shr = .pl_node,
                .shr_exact = .pl_node,

                .bit_offset_of = .pl_node,
                .offset_of = .pl_node,
                .cmpxchg_strong = .pl_node,
                .cmpxchg_weak = .pl_node,
                .splat = .pl_node,
                .reduce = .pl_node,
                .shuffle = .pl_node,
                .atomic_load = .pl_node,
                .atomic_rmw = .pl_node,
                .atomic_store = .pl_node,
                .mul_add = .pl_node,
                .builtin_call = .pl_node,
                .field_ptr_type = .bin,
                .field_parent_ptr = .pl_node,
                .memcpy = .pl_node,
                .memset = .pl_node,
                .builtin_async_call = .pl_node,
                .c_import = .pl_node,

                .alloc = .un_node,
                .alloc_mut = .un_node,
                .alloc_comptime = .un_node,
                .alloc_inferred = .node,
                .alloc_inferred_mut = .node,
                .alloc_inferred_comptime = .node,
                .resolve_inferred_alloc = .un_node,

                .@"resume" = .un_node,
                .@"await" = .un_node,
                .await_nosuspend = .un_node,

                .extended = .extended,
            });
        };
    };

    /// Rarer instructions are here; ones that do not fit in the 8-bit `Tag` enum.
    /// `noreturn` instructions may not go here; they must be part of the main `Tag` enum.
    pub const Extended = enum(u16) {
        /// Represents a function declaration or function prototype, depending on
        /// whether body_len is 0.
        /// `operand` is payload index to `ExtendedFunc`.
        /// `small` is `ExtendedFunc.Small`.
        func,
        /// Declares a global variable.
        /// `operand` is payload index to `ExtendedVar`.
        /// `small` is `ExtendedVar.Small`.
        variable,
        /// A struct type definition. Contains references to ZIR instructions for
        /// the field types, defaults, and alignments.
        /// `operand` is payload index to `StructDecl`.
        /// `small` is `StructDecl.Small`.
        struct_decl,
        /// An enum type definition. Contains references to ZIR instructions for
        /// the field value expressions and optional type tag expression.
        /// `operand` is payload index to `EnumDecl`.
        /// `small` is `EnumDecl.Small`.
        enum_decl,
        /// A union type definition. Contains references to ZIR instructions for
        /// the field types and optional type tag expression.
        /// `operand` is payload index to `UnionDecl`.
        /// `small` is `UnionDecl.Small`.
        union_decl,
        /// Obtains a pointer to the return value.
        /// `operand` is `src_node: i32`.
        ret_ptr,
        /// Obtains the return type of the in-scope function.
        /// `operand` is `src_node: i32`.
        ret_type,
        /// Implements the `@This` builtin.
        /// `operand` is `src_node: i32`.
        this,
        /// Implements the `@returnAddress` builtin.
        /// `operand` is `src_node: i32`.
        ret_addr,
        /// Implements the `@src` builtin.
        /// `operand` is `src_node: i32`.
        builtin_src,
        /// Implements the `@errorReturnTrace` builtin.
        /// `operand` is `src_node: i32`.
        error_return_trace,
        /// Implements the `@frame` builtin.
        /// `operand` is `src_node: i32`.
        frame,
        /// Implements the `@frameAddress` builtin.
        /// `operand` is `src_node: i32`.
        frame_address,
        /// Same as `alloc` from `Tag` but may contain an alignment instruction.
        /// `operand` is payload index to `AllocExtended`.
        /// `small`:
        ///  * 0b000X - has type
        ///  * 0b00X0 - has alignment
        ///  * 0b0X00 - 1=const, 0=var
        ///  * 0bX000 - is comptime
        alloc,
        /// The `@extern` builtin.
        /// `operand` is payload index to `BinNode`.
        builtin_extern,
        /// Inline assembly.
        /// `small`:
        ///  * 0b00000000_000XXXXX - `outputs_len`.
        ///  * 0b000000XX_XXX00000 - `inputs_len`.
        ///  * 0b0XXXXX00_00000000 - `clobbers_len`.
        ///  * 0bX0000000_00000000 - is volatile
        /// `operand` is payload index to `Asm`.
        @"asm",
        /// Log compile time variables and emit an error message.
        /// `operand` is payload index to `NodeMultiOp`.
        /// `small` is `operands_len`.
        /// The AST node is the compile log builtin call.
        compile_log,
        /// The builtin `@TypeOf` which returns the type after Peer Type Resolution
        /// of one or more params.
        /// `operand` is payload index to `NodeMultiOp`.
        /// `small` is `operands_len`.
        /// The AST node is the builtin call.
        typeof_peer,
        /// Implements the `@addWithOverflow` builtin.
        /// `operand` is payload index to `OverflowArithmetic`.
        /// `small` is unused.
        add_with_overflow,
        /// Implements the `@subWithOverflow` builtin.
        /// `operand` is payload index to `OverflowArithmetic`.
        /// `small` is unused.
        sub_with_overflow,
        /// Implements the `@mulWithOverflow` builtin.
        /// `operand` is payload index to `OverflowArithmetic`.
        /// `small` is unused.
        mul_with_overflow,
        /// Implements the `@shlWithOverflow` builtin.
        /// `operand` is payload index to `OverflowArithmetic`.
        /// `small` is unused.
        shl_with_overflow,
        /// `operand` is payload index to `UnNode`.
        c_undef,
        /// `operand` is payload index to `UnNode`.
        c_include,
        /// `operand` is payload index to `BinNode`.
        c_define,
        /// `operand` is payload index to `UnNode`.
        wasm_memory_size,
        /// `operand` is payload index to `BinNode`.
        wasm_memory_grow,

        pub const InstData = struct {
            opcode: Extended,
            small: u16,
            operand: u32,
        };
    };

    /// The position of a ZIR instruction within the `Zir` instructions array.
    pub const Index = u32;

    /// A reference to a TypedValue or ZIR instruction.
    ///
    /// If the Ref has a tag in this enum, it refers to a TypedValue which may be
    /// retrieved with Ref.toTypedValue().
    ///
    /// If the value of a Ref does not have a tag, it refers to a ZIR instruction.
    ///
    /// The first values after the the last tag refer to ZIR instructions which may
    /// be derived by subtracting `typed_value_map.len`.
    ///
    /// When adding a tag to this enum, consider adding a corresponding entry to
    /// `simple_types` in astgen.
    ///
    /// The tag type is specified so that it is safe to bitcast between `[]u32`
    /// and `[]Ref`.
    pub const Ref = enum(u32) {
        /// This Ref does not correspond to any ZIR instruction or constant
        /// value and may instead be used as a sentinel to indicate null.
        none,

        u8_type,
        i8_type,
        u16_type,
        i16_type,
        u32_type,
        i32_type,
        u64_type,
        i64_type,
        u128_type,
        i128_type,
        usize_type,
        isize_type,
        c_short_type,
        c_ushort_type,
        c_int_type,
        c_uint_type,
        c_long_type,
        c_ulong_type,
        c_longlong_type,
        c_ulonglong_type,
        c_longdouble_type,
        f16_type,
        f32_type,
        f64_type,
        f128_type,
        c_void_type,
        bool_type,
        void_type,
        type_type,
        anyerror_type,
        comptime_int_type,
        comptime_float_type,
        noreturn_type,
        anyframe_type,
        null_type,
        undefined_type,
        enum_literal_type,
        atomic_ordering_type,
        atomic_rmw_op_type,
        calling_convention_type,
        float_mode_type,
        reduce_op_type,
        call_options_type,
        export_options_type,
        extern_options_type,
        manyptr_u8_type,
        manyptr_const_u8_type,
        fn_noreturn_no_args_type,
        fn_void_no_args_type,
        fn_naked_noreturn_no_args_type,
        fn_ccc_void_no_args_type,
        single_const_pointer_to_comptime_int_type,
        const_slice_u8_type,

        /// `undefined` (untyped)
        undef,
        /// `0` (comptime_int)
        zero,
        /// `1` (comptime_int)
        one,
        /// `{}`
        void_value,
        /// `unreachable` (noreturn type)
        unreachable_value,
        /// `null` (untyped)
        null_value,
        /// `true`
        bool_true,
        /// `false`
        bool_false,
        /// `.{}` (untyped)
        empty_struct,
        /// `0` (usize)
        zero_usize,
        /// `1` (usize)
        one_usize,
        /// `std.builtin.CallingConvention.C`
        calling_convention_c,
        /// `std.builtin.CallingConvention.Inline`
        calling_convention_inline,

        _,

        pub const typed_value_map = std.enums.directEnumArray(Ref, TypedValue, 0, .{
            .none = undefined,

            .u8_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.u8_type),
            },
            .i8_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.i8_type),
            },
            .u16_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.u16_type),
            },
            .i16_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.i16_type),
            },
            .u32_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.u32_type),
            },
            .i32_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.i32_type),
            },
            .u64_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.u64_type),
            },
            .i64_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.i64_type),
            },
            .u128_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.u128_type),
            },
            .i128_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.i128_type),
            },
            .usize_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.usize_type),
            },
            .isize_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.isize_type),
            },
            .c_short_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.c_short_type),
            },
            .c_ushort_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.c_ushort_type),
            },
            .c_int_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.c_int_type),
            },
            .c_uint_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.c_uint_type),
            },
            .c_long_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.c_long_type),
            },
            .c_ulong_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.c_ulong_type),
            },
            .c_longlong_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.c_longlong_type),
            },
            .c_ulonglong_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.c_ulonglong_type),
            },
            .c_longdouble_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.c_longdouble_type),
            },
            .f16_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.f16_type),
            },
            .f32_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.f32_type),
            },
            .f64_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.f64_type),
            },
            .f128_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.f128_type),
            },
            .c_void_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.c_void_type),
            },
            .bool_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.bool_type),
            },
            .void_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.void_type),
            },
            .type_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.type_type),
            },
            .anyerror_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.anyerror_type),
            },
            .comptime_int_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.comptime_int_type),
            },
            .comptime_float_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.comptime_float_type),
            },
            .noreturn_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.noreturn_type),
            },
            .anyframe_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.anyframe_type),
            },
            .null_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.null_type),
            },
            .undefined_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.undefined_type),
            },
            .fn_noreturn_no_args_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.fn_noreturn_no_args_type),
            },
            .fn_void_no_args_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.fn_void_no_args_type),
            },
            .fn_naked_noreturn_no_args_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.fn_naked_noreturn_no_args_type),
            },
            .fn_ccc_void_no_args_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.fn_ccc_void_no_args_type),
            },
            .single_const_pointer_to_comptime_int_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.single_const_pointer_to_comptime_int_type),
            },
            .const_slice_u8_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.const_slice_u8_type),
            },
            .enum_literal_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.enum_literal_type),
            },
            .manyptr_u8_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.manyptr_u8_type),
            },
            .manyptr_const_u8_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.manyptr_const_u8_type),
            },
            .atomic_ordering_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.atomic_ordering_type),
            },
            .atomic_rmw_op_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.atomic_rmw_op_type),
            },
            .calling_convention_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.calling_convention_type),
            },
            .float_mode_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.float_mode_type),
            },
            .reduce_op_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.reduce_op_type),
            },
            .call_options_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.call_options_type),
            },
            .export_options_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.export_options_type),
            },
            .extern_options_type = .{
                .ty = Type.initTag(.type),
                .val = Value.initTag(.extern_options_type),
            },

            .undef = .{
                .ty = Type.initTag(.@"undefined"),
                .val = Value.initTag(.undef),
            },
            .zero = .{
                .ty = Type.initTag(.comptime_int),
                .val = Value.initTag(.zero),
            },
            .zero_usize = .{
                .ty = Type.initTag(.usize),
                .val = Value.initTag(.zero),
            },
            .one = .{
                .ty = Type.initTag(.comptime_int),
                .val = Value.initTag(.one),
            },
            .one_usize = .{
                .ty = Type.initTag(.usize),
                .val = Value.initTag(.one),
            },
            .void_value = .{
                .ty = Type.initTag(.void),
                .val = Value.initTag(.void_value),
            },
            .unreachable_value = .{
                .ty = Type.initTag(.noreturn),
                .val = Value.initTag(.unreachable_value),
            },
            .null_value = .{
                .ty = Type.initTag(.@"null"),
                .val = Value.initTag(.null_value),
            },
            .bool_true = .{
                .ty = Type.initTag(.bool),
                .val = Value.initTag(.bool_true),
            },
            .bool_false = .{
                .ty = Type.initTag(.bool),
                .val = Value.initTag(.bool_false),
            },
            .empty_struct = .{
                .ty = Type.initTag(.empty_struct_literal),
                .val = Value.initTag(.empty_struct_value),
            },
            .calling_convention_c = .{
                .ty = Type.initTag(.calling_convention),
                .val = .{ .ptr_otherwise = &calling_convention_c_payload.base },
            },
            .calling_convention_inline = .{
                .ty = Type.initTag(.calling_convention),
                .val = .{ .ptr_otherwise = &calling_convention_inline_payload.base },
            },
        });
    };

    /// We would like this to be const but `Value` wants a mutable pointer for
    /// its payload field. Nothing should mutate this though.
    var calling_convention_c_payload: Value.Payload.U32 = .{
        .base = .{ .tag = .enum_field_index },
        .data = @enumToInt(std.builtin.CallingConvention.C),
    };

    /// We would like this to be const but `Value` wants a mutable pointer for
    /// its payload field. Nothing should mutate this though.
    var calling_convention_inline_payload: Value.Payload.U32 = .{
        .base = .{ .tag = .enum_field_index },
        .data = @enumToInt(std.builtin.CallingConvention.Inline),
    };

    /// All instructions have an 8-byte payload, which is contained within
    /// this union. `Tag` determines which union field is active, as well as
    /// how to interpret the data within.
    pub const Data = union {
        /// Used for `Tag.extended`. The extended opcode determines the meaning
        /// of the `small` and `operand` fields.
        extended: Extended.InstData,
        /// Used for unary operators, with an AST node source location.
        un_node: struct {
            /// Offset from Decl AST node index.
            src_node: i32,
            /// The meaning of this operand depends on the corresponding `Tag`.
            operand: Ref,

            pub fn src(self: @This()) LazySrcLoc {
                return .{ .node_offset = self.src_node };
            }
        },
        /// Used for unary operators, with a token source location.
        un_tok: struct {
            /// Offset from Decl AST token index.
            src_tok: ast.TokenIndex,
            /// The meaning of this operand depends on the corresponding `Tag`.
            operand: Ref,

            pub fn src(self: @This()) LazySrcLoc {
                return .{ .token_offset = self.src_tok };
            }
        },
        pl_node: struct {
            /// Offset from Decl AST node index.
            /// `Tag` determines which kind of AST node this points to.
            src_node: i32,
            /// index into extra.
            /// `Tag` determines what lives there.
            payload_index: u32,

            pub fn src(self: @This()) LazySrcLoc {
                return .{ .node_offset = self.src_node };
            }
        },
        bin: Bin,
        /// For strings which may contain null bytes.
        str: struct {
            /// Offset into `string_bytes`.
            start: u32,
            /// Number of bytes in the string.
            len: u32,

            pub fn get(self: @This(), code: Zir) []const u8 {
                return code.string_bytes[self.start..][0..self.len];
            }
        },
        str_tok: struct {
            /// Offset into `string_bytes`. Null-terminated.
            start: u32,
            /// Offset from Decl AST token index.
            src_tok: u32,

            pub fn get(self: @This(), code: Zir) [:0]const u8 {
                return code.nullTerminatedString(self.start);
            }

            pub fn src(self: @This()) LazySrcLoc {
                return .{ .token_offset = self.src_tok };
            }
        },
        /// Offset from Decl AST token index.
        tok: ast.TokenIndex,
        /// Offset from Decl AST node index.
        node: i32,
        int: u64,
        float: struct {
            /// Offset from Decl AST node index.
            /// `Tag` determines which kind of AST node this points to.
            src_node: i32,
            number: f32,

            pub fn src(self: @This()) LazySrcLoc {
                return .{ .node_offset = self.src_node };
            }
        },
        array_type_sentinel: struct {
            len: Ref,
            /// index into extra, points to an `ArrayTypeSentinel`
            payload_index: u32,
        },
        ptr_type_simple: struct {
            is_allowzero: bool,
            is_mutable: bool,
            is_volatile: bool,
            size: std.builtin.TypeInfo.Pointer.Size,
            elem_type: Ref,
        },
        ptr_type: struct {
            flags: packed struct {
                is_allowzero: bool,
                is_mutable: bool,
                is_volatile: bool,
                has_sentinel: bool,
                has_align: bool,
                has_bit_range: bool,
                _: u2 = undefined,
            },
            size: std.builtin.TypeInfo.Pointer.Size,
            /// Index into extra. See `PtrType`.
            payload_index: u32,
        },
        int_type: struct {
            /// Offset from Decl AST node index.
            /// `Tag` determines which kind of AST node this points to.
            src_node: i32,
            signedness: std.builtin.Signedness,
            bit_count: u16,

            pub fn src(self: @This()) LazySrcLoc {
                return .{ .node_offset = self.src_node };
            }
        },
        bool_br: struct {
            lhs: Ref,
            /// Points to a `Block`.
            payload_index: u32,
        },
        param_type: struct {
            callee: Ref,
            param_index: u32,
        },
        @"unreachable": struct {
            /// Offset from Decl AST node index.
            /// `Tag` determines which kind of AST node this points to.
            src_node: i32,
            /// `false`: Not safety checked - the compiler will assume the
            /// correctness of this instruction.
            /// `true`: In safety-checked modes, this will generate a call
            /// to the panic function unless it can be proven unreachable by the compiler.
            safety: bool,

            pub fn src(self: @This()) LazySrcLoc {
                return .{ .node_offset = self.src_node };
            }
        },
        @"break": struct {
            block_inst: Index,
            operand: Ref,
        },
        switch_capture: struct {
            switch_inst: Index,
            prong_index: u32,
        },
        dbg_stmt: struct {
            line: u32,
            column: u32,
        },

        // Make sure we don't accidentally add a field to make this union
        // bigger than expected. Note that in Debug builds, Zig is allowed
        // to insert a secret field for safety checks.
        comptime {
            if (std.builtin.mode != .Debug) {
                assert(@sizeOf(Data) == 8);
            }
        }

        /// TODO this has to be kept in sync with `Data` which we want to be an untagged
        /// union. There is some kind of language awkwardness here and it has to do with
        /// deserializing an untagged union (in this case `Data`) from a file, and trying
        /// to preserve the hidden safety field.
        pub const FieldEnum = enum {
            extended,
            un_node,
            un_tok,
            pl_node,
            bin,
            str,
            str_tok,
            tok,
            node,
            int,
            float,
            array_type_sentinel,
            ptr_type_simple,
            ptr_type,
            int_type,
            bool_br,
            param_type,
            @"unreachable",
            @"break",
            switch_capture,
            dbg_stmt,
        };
    };

    /// Trailing:
    /// 0. Output for every outputs_len
    /// 1. Input for every inputs_len
    /// 2. clobber: u32 // index into string_bytes (null terminated) for every clobbers_len.
    pub const Asm = struct {
        src_node: i32,
        asm_source: Ref,
        /// 1 bit for each outputs_len: whether it uses `-> T` or not.
        ///   0b0 - operand is a pointer to where to store the output.
        ///   0b1 - operand is a type; asm expression has the output as the result.
        /// 0b0X is the first output, 0bX0 is the second, etc.
        output_type_bits: u32,

        pub const Output = struct {
            /// index into string_bytes (null terminated)
            name: u32,
            /// index into string_bytes (null terminated)
            constraint: u32,
            /// How to interpret this is determined by `output_type_bits`.
            operand: Ref,
        };

        pub const Input = struct {
            /// index into string_bytes (null terminated)
            name: u32,
            /// index into string_bytes (null terminated)
            constraint: u32,
            operand: Ref,
        };
    };

    /// Trailing:
    /// 0. lib_name: u32, // null terminated string index, if has_lib_name is set
    /// 1. cc: Ref, // if has_cc is set
    /// 2. align: Ref, // if has_align is set
    /// 3. param_type: Ref // for each param_types_len
    /// 4. body: Index // for each body_len
    /// 5. src_locs: Func.SrcLocs // if body_len != 0
    pub const ExtendedFunc = struct {
        src_node: i32,
        return_type: Ref,
        param_types_len: u32,
        body_len: u32,

        pub const Small = packed struct {
            is_var_args: bool,
            is_inferred_error: bool,
            has_lib_name: bool,
            has_cc: bool,
            has_align: bool,
            is_test: bool,
            is_extern: bool,
            _: u9 = undefined,
        };
    };

    /// Trailing:
    /// 0. lib_name: u32, // null terminated string index, if has_lib_name is set
    /// 1. align: Ref, // if has_align is set
    /// 2. init: Ref // if has_init is set
    /// The source node is obtained from the containing `block_inline`.
    pub const ExtendedVar = struct {
        var_type: Ref,

        pub const Small = packed struct {
            has_lib_name: bool,
            has_align: bool,
            has_init: bool,
            is_extern: bool,
            is_threadlocal: bool,
            _: u11 = undefined,
        };
    };

    /// Trailing:
    /// 0. param_type: Ref // for each param_types_len
    ///    - `none` indicates that the param type is `anytype`.
    /// 1. body: Index // for each body_len
    /// 2. src_locs: SrcLocs // if body_len != 0
    pub const Func = struct {
        return_type: Ref,
        param_types_len: u32,
        body_len: u32,

        pub const SrcLocs = struct {
            /// Absolute line index in the source file.
            lbrace_line: u32,
            /// Absolute line index in the source file.
            rbrace_line: u32,
            /// lbrace_column is least significant bits u16
            /// rbrace_column is most significant bits u16
            columns: u32,
        };
    };

    /// This data is stored inside extra, with trailing operands according to `operands_len`.
    /// Each operand is a `Ref`.
    pub const MultiOp = struct {
        operands_len: u32,
    };

    /// Trailing: operand: Ref, // for each `operands_len` (stored in `small`).
    pub const NodeMultiOp = struct {
        src_node: i32,
    };

    /// This data is stored inside extra, with trailing operands according to `body_len`.
    /// Each operand is an `Index`.
    pub const Block = struct {
        body_len: u32,
    };

    /// Stored inside extra, with trailing arguments according to `args_len`.
    /// Each argument is a `Ref`.
    pub const Call = struct {
        callee: Ref,
        args_len: u32,
    };

    pub const BuiltinCall = struct {
        options: Ref,
        callee: Ref,
        args: Ref,
    };

    /// This data is stored inside extra, with two sets of trailing `Ref`:
    /// * 0. the then body, according to `then_body_len`.
    /// * 1. the else body, according to `else_body_len`.
    pub const CondBr = struct {
        condition: Ref,
        then_body_len: u32,
        else_body_len: u32,
    };

    /// Stored in extra. Depending on the flags in Data, there will be up to 4
    /// trailing Ref fields:
    /// 0. sentinel: Ref // if `has_sentinel` flag is set
    /// 1. align: Ref // if `has_align` flag is set
    /// 2. bit_start: Ref // if `has_bit_range` flag is set
    /// 3. bit_end: Ref // if `has_bit_range` flag is set
    pub const PtrType = struct {
        elem_type: Ref,
    };

    pub const ArrayTypeSentinel = struct {
        sentinel: Ref,
        elem_type: Ref,
    };

    pub const SliceStart = struct {
        lhs: Ref,
        start: Ref,
    };

    pub const SliceEnd = struct {
        lhs: Ref,
        start: Ref,
        end: Ref,
    };

    pub const SliceSentinel = struct {
        lhs: Ref,
        start: Ref,
        end: Ref,
        sentinel: Ref,
    };

    /// The meaning of these operands depends on the corresponding `Tag`.
    pub const Bin = struct {
        lhs: Ref,
        rhs: Ref,
    };

    pub const BinNode = struct {
        node: i32,
        lhs: Ref,
        rhs: Ref,
    };

    pub const UnNode = struct {
        node: i32,
        operand: Ref,
    };

    /// This form is supported when there are no ranges, and exactly 1 item per block.
    /// Depending on zir tag and len fields, extra fields trail
    /// this one in the extra array.
    /// 0. else_body { // If the tag has "_else" or "_under" in it.
    ///        body_len: u32,
    ///        body member Index for every body_len
    ///     }
    /// 1. cases: {
    ///        item: Ref,
    ///        body_len: u32,
    ///        body member Index for every body_len
    ///    } for every cases_len
    pub const SwitchBlock = struct {
        operand: Ref,
        cases_len: u32,
    };

    /// This form is required when there exists a block which has more than one item,
    /// or a range.
    /// Depending on zir tag and len fields, extra fields trail
    /// this one in the extra array.
    /// 0. else_body { // If the tag has "_else" or "_under" in it.
    ///        body_len: u32,
    ///        body member Index for every body_len
    ///     }
    /// 1. scalar_cases: { // for every scalar_cases_len
    ///        item: Ref,
    ///        body_len: u32,
    ///        body member Index for every body_len
    ///     }
    /// 2. multi_cases: { // for every multi_cases_len
    ///        items_len: u32,
    ///        ranges_len: u32,
    ///        body_len: u32,
    ///        item: Ref // for every items_len
    ///        ranges: { // for every ranges_len
    ///            item_first: Ref,
    ///            item_last: Ref,
    ///        }
    ///        body member Index for every body_len
    ///    }
    pub const SwitchBlockMulti = struct {
        operand: Ref,
        scalar_cases_len: u32,
        multi_cases_len: u32,
    };

    pub const Field = struct {
        lhs: Ref,
        /// Offset into `string_bytes`.
        field_name_start: u32,
    };

    pub const FieldNamed = struct {
        lhs: Ref,
        field_name: Ref,
    };

    pub const As = struct {
        dest_type: Ref,
        operand: Ref,
    };

    /// Trailing:
    /// 0. src_node: i32, // if has_src_node
    /// 1. body_len: u32, // if has_body_len
    /// 2. fields_len: u32, // if has_fields_len
    /// 3. decls_len: u32, // if has_decls_len
    /// 4. decl_bits: u32 // for every 8 decls
    ///    - sets of 4 bits:
    ///      0b000X: whether corresponding decl is pub
    ///      0b00X0: whether corresponding decl is exported
    ///      0b0X00: whether corresponding decl has an align expression
    ///      0bX000: whether corresponding decl has a linksection expression
    /// 5. decl: { // for every decls_len
    ///        src_hash: [4]u32, // hash of source bytes
    ///        line: u32, // line number of decl, relative to parent
    ///        name: u32, // null terminated string index
    ///        - 0 means comptime or usingnamespace decl.
    ///          - if name == 0 `is_exported` determines which one: 0=comptime,1=usingnamespace
    ///        - 1 means test decl with no name.
    ///        - if there is a 0 byte at the position `name` indexes, it indicates
    ///          this is a test decl, and the name starts at `name+1`.
    ///        value: Index,
    ///        align: Ref, // if corresponding bit is set
    ///        link_section: Ref, // if corresponding bit is set
    ///    }
    /// 6. inst: Index // for every body_len
    /// 7. flags: u32 // for every 8 fields
    ///    - sets of 4 bits:
    ///      0b000X: whether corresponding field has an align expression
    ///      0b00X0: whether corresponding field has a default expression
    ///      0b0X00: whether corresponding field is comptime
    ///      0bX000: unused
    /// 8. fields: { // for every fields_len
    ///        field_name: u32,
    ///        field_type: Ref,
    ///        - if none, means `anytype`.
    ///        align: Ref, // if corresponding bit is set
    ///        default_value: Ref, // if corresponding bit is set
    ///    }
    pub const StructDecl = struct {
        pub const Small = packed struct {
            has_src_node: bool,
            has_body_len: bool,
            has_fields_len: bool,
            has_decls_len: bool,
            name_strategy: NameStrategy,
            layout: std.builtin.TypeInfo.ContainerLayout,
            _: u8 = undefined,
        };
    };

    pub const NameStrategy = enum(u2) {
        /// Use the same name as the parent declaration name.
        /// e.g. `const Foo = struct {...};`.
        parent,
        /// Use the name of the currently executing comptime function call,
        /// with the current parameters. e.g. `ArrayList(i32)`.
        func,
        /// Create an anonymous name for this declaration.
        /// Like this: "ParentDeclName_struct_69"
        anon,
    };

    /// Trailing:
    /// 0. src_node: i32, // if has_src_node
    /// 1. tag_type: Ref, // if has_tag_type
    /// 2. body_len: u32, // if has_body_len
    /// 3. fields_len: u32, // if has_fields_len
    /// 4. decls_len: u32, // if has_decls_len
    /// 5. decl_bits: u32 // for every 8 decls
    ///    - sets of 4 bits:
    ///      0b000X: whether corresponding decl is pub
    ///      0b00X0: whether corresponding decl is exported
    ///      0b0X00: whether corresponding decl has an align expression
    ///      0bX000: whether corresponding decl has a linksection expression
    /// 6. decl: { // for every decls_len
    ///        src_hash: [4]u32, // hash of source bytes
    ///        line: u32, // line number of decl, relative to parent
    ///        name: u32, // null terminated string index
    ///        - 0 means comptime or usingnamespace decl.
    ///          - if name == 0 `is_exported` determines which one: 0=comptime,1=usingnamespace
    ///        - 1 means test decl with no name.
    ///        - if there is a 0 byte at the position `name` indexes, it indicates
    ///          this is a test decl, and the name starts at `name+1`.
    ///        value: Index,
    ///        align: Ref, // if corresponding bit is set
    ///        link_section: Ref, // if corresponding bit is set
    ///    }
    /// 7. inst: Index // for every body_len
    /// 8. has_bits: u32 // for every 32 fields
    ///    - the bit is whether corresponding field has an value expression
    /// 9. fields: { // for every fields_len
    ///        field_name: u32,
    ///        value: Ref, // if corresponding bit is set
    ///    }
    pub const EnumDecl = struct {
        pub const Small = packed struct {
            has_src_node: bool,
            has_tag_type: bool,
            has_body_len: bool,
            has_fields_len: bool,
            has_decls_len: bool,
            name_strategy: NameStrategy,
            nonexhaustive: bool,
            _: u8 = undefined,
        };
    };

    /// Trailing:
    /// 0. src_node: i32, // if has_src_node
    /// 1. tag_type: Ref, // if has_tag_type
    /// 2. body_len: u32, // if has_body_len
    /// 3. fields_len: u32, // if has_fields_len
    /// 4. decls_len: u32, // if has_decls_len
    /// 5. decl_bits: u32 // for every 8 decls
    ///    - sets of 4 bits:
    ///      0b000X: whether corresponding decl is pub
    ///      0b00X0: whether corresponding decl is exported
    ///      0b0X00: whether corresponding decl has an align expression
    ///      0bX000: whether corresponding decl has a linksection expression
    /// 6. decl: { // for every decls_len
    ///        src_hash: [4]u32, // hash of source bytes
    ///        line: u32, // line number of decl, relative to parent
    ///        name: u32, // null terminated string index
    ///        - 0 means comptime or usingnamespace decl.
    ///          - if name == 0 `is_exported` determines which one: 0=comptime,1=usingnamespace
    ///        - 1 means test decl with no name.
    ///        - if there is a 0 byte at the position `name` indexes, it indicates
    ///          this is a test decl, and the name starts at `name+1`.
    ///        value: Index,
    ///        align: Ref, // if corresponding bit is set
    ///        link_section: Ref, // if corresponding bit is set
    ///    }
    /// 7. inst: Index // for every body_len
    /// 8. has_bits: u32 // for every 8 fields
    ///    - sets of 4 bits:
    ///      0b000X: whether corresponding field has a type expression
    ///      0b00X0: whether corresponding field has a align expression
    ///      0b0X00: whether corresponding field has a tag value expression
    ///      0bX000: unused
    /// 9. fields: { // for every fields_len
    ///        field_name: u32, // null terminated string index
    ///        field_type: Ref, // if corresponding bit is set
    ///        align: Ref, // if corresponding bit is set
    ///        tag_value: Ref, // if corresponding bit is set
    ///    }
    pub const UnionDecl = struct {
        pub const Small = packed struct {
            has_src_node: bool,
            has_tag_type: bool,
            has_body_len: bool,
            has_fields_len: bool,
            has_decls_len: bool,
            name_strategy: NameStrategy,
            layout: std.builtin.TypeInfo.ContainerLayout,
            /// false: union(tag_type)
            ///  true: union(enum(tag_type))
            auto_enum_tag: bool,
            _: u6 = undefined,
        };
    };

    /// Trailing:
    /// 0. decl_bits: u32 // for every 8 decls
    ///    - sets of 4 bits:
    ///      0b000X: whether corresponding decl is pub
    ///      0b00X0: whether corresponding decl is exported
    ///      0b0X00: whether corresponding decl has an align expression
    ///      0bX000: whether corresponding decl has a linksection expression
    /// 1. decl: { // for every decls_len
    ///        src_hash: [4]u32, // hash of source bytes
    ///        line: u32, // line number of decl, relative to parent
    ///        name: u32, // null terminated string index
    ///        - 0 means comptime or usingnamespace decl.
    ///          - if name == 0 `is_exported` determines which one: 0=comptime,1=usingnamespace
    ///        - 1 means test decl with no name.
    ///        - if there is a 0 byte at the position `name` indexes, it indicates
    ///          this is a test decl, and the name starts at `name+1`.
    ///        value: Index,
    ///        align: Ref, // if corresponding bit is set
    ///        link_section: Ref, // if corresponding bit is set
    ///    }
    pub const OpaqueDecl = struct {
        decls_len: u32,
    };

    /// Trailing: field_name: u32 // for every field: null terminated string index
    pub const ErrorSetDecl = struct {
        fields_len: u32,
    };

    /// A f128 value, broken up into 4 u32 parts.
    pub const Float128 = struct {
        piece0: u32,
        piece1: u32,
        piece2: u32,
        piece3: u32,

        pub fn get(self: Float128) f128 {
            const int_bits = @as(u128, self.piece0) |
                (@as(u128, self.piece1) << 32) |
                (@as(u128, self.piece2) << 64) |
                (@as(u128, self.piece3) << 96);
            return @bitCast(f128, int_bits);
        }
    };

    /// Trailing is an item per field.
    pub const StructInit = struct {
        fields_len: u32,

        pub const Item = struct {
            /// The `field_type` ZIR instruction for this field init.
            field_type: Index,
            /// The field init expression to be used as the field value.
            init: Ref,
        };
    };

    /// Trailing is an item per field.
    pub const StructInitAnon = struct {
        fields_len: u32,

        pub const Item = struct {
            /// Null-terminated string table index.
            field_name: u32,
            /// The field init expression to be used as the field value.
            init: Ref,
        };
    };

    pub const FieldType = struct {
        container_type: Ref,
        /// Offset into `string_bytes`, null terminated.
        name_start: u32,
    };

    pub const FieldTypeRef = struct {
        container_type: Ref,
        field_name: Ref,
    };

    pub const OverflowArithmetic = struct {
        node: i32,
        lhs: Ref,
        rhs: Ref,
        ptr: Ref,
    };

    pub const Cmpxchg = struct {
        ptr: Ref,
        expected_value: Ref,
        new_value: Ref,
        success_order: Ref,
        fail_order: Ref,
    };

    pub const AtomicRmw = struct {
        ptr: Ref,
        operation: Ref,
        operand: Ref,
        ordering: Ref,
    };

    pub const UnionInitPtr = struct {
        result_ptr: Ref,
        union_type: Ref,
        field_name: Ref,
    };

    pub const AtomicStore = struct {
        ptr: Ref,
        operand: Ref,
        ordering: Ref,
    };

    pub const MulAdd = struct {
        mulend1: Ref,
        mulend2: Ref,
        addend: Ref,
    };

    pub const FieldParentPtr = struct {
        parent_type: Ref,
        field_name: Ref,
        field_ptr: Ref,
    };

    pub const Memcpy = struct {
        dest: Ref,
        source: Ref,
        byte_count: Ref,
    };

    pub const Memset = struct {
        dest: Ref,
        byte: Ref,
        byte_count: Ref,
    };

    pub const Shuffle = struct {
        elem_type: Ref,
        a: Ref,
        b: Ref,
        mask: Ref,
    };

    pub const AsyncCall = struct {
        frame_buffer: Ref,
        result_ptr: Ref,
        fn_ptr: Ref,
        args: Ref,
    };

    /// Trailing:
    /// 0. type_inst: Ref,  // if small 0b000X is set
    /// 1. align_inst: Ref, // if small 0b00X0 is set
    pub const AllocExtended = struct {
        src_node: i32,
    };

    pub const Export = struct {
        /// If present, this is referring to a Decl via field access, e.g. `a.b`.
        /// If omitted, this is referring to a Decl via identifier, e.g. `a`.
        namespace: Ref,
        /// Null-terminated string index.
        decl_name: u32,
        options: Ref,
    };

    /// Trailing: `CompileErrors.Item` for each `items_len`.
    pub const CompileErrors = struct {
        items_len: u32,

        /// Trailing: `note_payload_index: u32` for each `notes_len`.
        /// It's a payload index of another `Item`.
        pub const Item = struct {
            /// null terminated string index
            msg: u32,
            node: ast.Node.Index,
            /// If node is 0 then this will be populated.
            token: ast.TokenIndex,
            /// Can be used in combination with `token`.
            byte_offset: u32,
            /// 0 or a payload index of a `Block`, each is a payload
            /// index of another `Item`.
            notes: u32,
        };
    };

    /// Trailing: for each `imports_len` there is an instruction index
    /// to an import instruction.
    pub const Imports = struct {
        imports_len: Zir.Inst.Index,
    };
};

pub const SpecialProng = enum { none, @"else", under };

const Writer = struct {
    gpa: *Allocator,
    arena: *Allocator,
    file: *Module.Scope.File,
    code: Zir,
    indent: u32,
    parent_decl_node: u32,

    fn relativeToNodeIndex(self: *Writer, offset: i32) ast.Node.Index {
        return @bitCast(ast.Node.Index, offset + @bitCast(i32, self.parent_decl_node));
    }

    fn writeInstToStream(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const tags = self.code.instructions.items(.tag);
        const tag = tags[inst];
        try stream.print("= {s}(", .{@tagName(tags[inst])});
        switch (tag) {
            .array_type,
            .as,
            .coerce_result_ptr,
            .elem_ptr,
            .elem_val,
            .store,
            .store_to_block_ptr,
            .store_to_inferred_ptr,
            .field_ptr_type,
            => try self.writeBin(stream, inst),

            .alloc,
            .alloc_mut,
            .alloc_comptime,
            .indexable_ptr_len,
            .anyframe_type,
            .bit_not,
            .bool_not,
            .negate,
            .negate_wrap,
            .load,
            .ensure_result_used,
            .ensure_result_non_error,
            .ret_node,
            .resolve_inferred_alloc,
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
            .is_non_null,
            .is_non_null_ptr,
            .is_non_err,
            .is_non_err_ptr,
            .typeof,
            .typeof_elem,
            .struct_init_empty,
            .type_info,
            .size_of,
            .bit_size_of,
            .typeof_log2_int_type,
            .log2_int_type,
            .ptr_to_int,
            .error_to_int,
            .int_to_error,
            .compile_error,
            .set_eval_branch_quota,
            .enum_to_int,
            .align_of,
            .bool_to_int,
            .embed_file,
            .error_name,
            .panic,
            .set_align_stack,
            .set_cold,
            .set_float_mode,
            .set_runtime_safety,
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
            .clz,
            .ctz,
            .pop_count,
            .byte_swap,
            .bit_reverse,
            .elem_type,
            .@"resume",
            .@"await",
            .await_nosuspend,
            => try self.writeUnNode(stream, inst),

            .ref,
            .ret_coerce,
            .ensure_err_payload_void,
            => try self.writeUnTok(stream, inst),

            .bool_br_and,
            .bool_br_or,
            => try self.writeBoolBr(stream, inst),

            .array_type_sentinel => try self.writeArrayTypeSentinel(stream, inst),
            .param_type => try self.writeParamType(stream, inst),
            .ptr_type_simple => try self.writePtrTypeSimple(stream, inst),
            .ptr_type => try self.writePtrType(stream, inst),
            .int => try self.writeInt(stream, inst),
            .int_big => try self.writeIntBig(stream, inst),
            .float => try self.writeFloat(stream, inst),
            .float128 => try self.writeFloat128(stream, inst),
            .str => try self.writeStr(stream, inst),
            .int_type => try self.writeIntType(stream, inst),

            .@"break",
            .break_inline,
            => try self.writeBreak(stream, inst),

            .elem_ptr_node,
            .elem_val_node,
            .field_ptr_named,
            .field_val_named,
            .slice_start,
            .slice_end,
            .slice_sentinel,
            .array_init,
            .array_init_anon,
            .array_init_ref,
            .array_init_anon_ref,
            .union_init_ptr,
            .cmpxchg_strong,
            .cmpxchg_weak,
            .shuffle,
            .atomic_rmw,
            .atomic_store,
            .mul_add,
            .builtin_call,
            .field_parent_ptr,
            .memcpy,
            .memset,
            .builtin_async_call,
            => try self.writePlNode(stream, inst),

            .struct_init,
            .struct_init_ref,
            => try self.writeStructInit(stream, inst),

            .struct_init_anon,
            .struct_init_anon_ref,
            => try self.writeStructInitAnon(stream, inst),

            .field_type => try self.writeFieldType(stream, inst),
            .field_type_ref => try self.writeFieldTypeRef(stream, inst),

            .add,
            .addwrap,
            .array_cat,
            .array_mul,
            .mul,
            .mulwrap,
            .sub,
            .subwrap,
            .bool_and,
            .bool_or,
            .cmp_lt,
            .cmp_lte,
            .cmp_eq,
            .cmp_gte,
            .cmp_gt,
            .cmp_neq,
            .div,
            .has_decl,
            .has_field,
            .mod_rem,
            .shl,
            .shl_exact,
            .shr,
            .shr_exact,
            .xor,
            .store_node,
            .error_union_type,
            .merge_error_sets,
            .bit_and,
            .bit_or,
            .float_to_int,
            .int_to_float,
            .int_to_ptr,
            .int_to_enum,
            .float_cast,
            .int_cast,
            .err_set_cast,
            .ptr_cast,
            .truncate,
            .align_cast,
            .div_exact,
            .div_floor,
            .div_trunc,
            .mod,
            .rem,
            .bit_offset_of,
            .offset_of,
            .splat,
            .reduce,
            .atomic_load,
            .bitcast,
            .bitcast_result_ptr,
            .vector_type,
            => try self.writePlNodeBin(stream, inst),

            .@"export" => try self.writePlNodeExport(stream, inst),

            .call,
            .call_chkused,
            .call_compile_time,
            .call_nosuspend,
            .call_async,
            => try self.writePlNodeCall(stream, inst),

            .block,
            .block_inline,
            .suspend_block,
            .loop,
            .validate_struct_init_ptr,
            .validate_array_init_ptr,
            .c_import,
            => try self.writePlNodeBlock(stream, inst),

            .condbr,
            .condbr_inline,
            => try self.writePlNodeCondBr(stream, inst),

            .opaque_decl => try self.writeOpaqueDecl(stream, inst, .parent),
            .opaque_decl_anon => try self.writeOpaqueDecl(stream, inst, .anon),
            .opaque_decl_func => try self.writeOpaqueDecl(stream, inst, .func),

            .error_set_decl => try self.writeErrorSetDecl(stream, inst, .parent),
            .error_set_decl_anon => try self.writeErrorSetDecl(stream, inst, .anon),
            .error_set_decl_func => try self.writeErrorSetDecl(stream, inst, .func),

            .switch_block => try self.writePlNodeSwitchBr(stream, inst, .none),
            .switch_block_else => try self.writePlNodeSwitchBr(stream, inst, .@"else"),
            .switch_block_under => try self.writePlNodeSwitchBr(stream, inst, .under),
            .switch_block_ref => try self.writePlNodeSwitchBr(stream, inst, .none),
            .switch_block_ref_else => try self.writePlNodeSwitchBr(stream, inst, .@"else"),
            .switch_block_ref_under => try self.writePlNodeSwitchBr(stream, inst, .under),

            .switch_block_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .none),
            .switch_block_else_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .@"else"),
            .switch_block_under_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .under),
            .switch_block_ref_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .none),
            .switch_block_ref_else_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .@"else"),
            .switch_block_ref_under_multi => try self.writePlNodeSwitchBlockMulti(stream, inst, .under),

            .field_ptr,
            .field_val,
            => try self.writePlNodeField(stream, inst),

            .as_node => try self.writeAs(stream, inst),

            .breakpoint,
            .fence,
            .repeat,
            .repeat_inline,
            .alloc_inferred,
            .alloc_inferred_mut,
            .alloc_inferred_comptime,
            => try self.writeNode(stream, inst),

            .error_value,
            .enum_literal,
            .decl_ref,
            .decl_val,
            .import,
            .arg,
            .ret_err_value,
            .ret_err_value_code,
            => try self.writeStrTok(stream, inst),

            .func => try self.writeFunc(stream, inst, false),
            .func_inferred => try self.writeFunc(stream, inst, true),

            .@"unreachable" => try self.writeUnreachable(stream, inst),

            .switch_capture,
            .switch_capture_ref,
            .switch_capture_multi,
            .switch_capture_multi_ref,
            .switch_capture_else,
            .switch_capture_else_ref,
            => try self.writeSwitchCapture(stream, inst),

            .dbg_stmt => try self.writeDbgStmt(stream, inst),

            .extended => try self.writeExtended(stream, inst),
        }
    }

    fn writeExtended(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const extended = self.code.instructions.items(.data)[inst].extended;
        try stream.print("{s}(", .{@tagName(extended.opcode)});
        switch (extended.opcode) {
            .ret_ptr,
            .ret_type,
            .this,
            .ret_addr,
            .error_return_trace,
            .frame,
            .frame_address,
            .builtin_src,
            => try self.writeExtNode(stream, extended),

            .@"asm" => try self.writeAsm(stream, extended),
            .func => try self.writeFuncExtended(stream, extended),
            .variable => try self.writeVarExtended(stream, extended),

            .compile_log,
            .typeof_peer,
            => try self.writeNodeMultiOp(stream, extended),

            .add_with_overflow,
            .sub_with_overflow,
            .mul_with_overflow,
            .shl_with_overflow,
            => try self.writeOverflowArithmetic(stream, extended),

            .struct_decl => try self.writeStructDecl(stream, extended),
            .union_decl => try self.writeUnionDecl(stream, extended),
            .enum_decl => try self.writeEnumDecl(stream, extended),

            .alloc,
            .builtin_extern,
            .c_undef,
            .c_include,
            .c_define,
            .wasm_memory_size,
            .wasm_memory_grow,
            => try stream.writeAll("TODO))"),
        }
    }

    fn writeExtNode(self: *Writer, stream: anytype, extended: Inst.Extended.InstData) !void {
        const src: LazySrcLoc = .{ .node_offset = @bitCast(i32, extended.operand) };
        try stream.writeAll(")) ");
        try self.writeSrc(stream, src);
    }

    fn writeBin(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].bin;
        try self.writeInstRef(stream, inst_data.lhs);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, inst_data.rhs);
        try stream.writeByte(')');
    }

    fn writeUnNode(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].un_node;
        try self.writeInstRef(stream, inst_data.operand);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeUnTok(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].un_tok;
        try self.writeInstRef(stream, inst_data.operand);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeArrayTypeSentinel(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].array_type_sentinel;
        _ = inst_data;
        try stream.writeAll("TODO)");
    }

    fn writeParamType(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].param_type;
        try self.writeInstRef(stream, inst_data.callee);
        try stream.print(", {d})", .{inst_data.param_index});
    }

    fn writePtrTypeSimple(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].ptr_type_simple;
        const str_allowzero = if (inst_data.is_allowzero) "allowzero, " else "";
        const str_const = if (!inst_data.is_mutable) "const, " else "";
        const str_volatile = if (inst_data.is_volatile) "volatile, " else "";
        try self.writeInstRef(stream, inst_data.elem_type);
        try stream.print(", {s}{s}{s}{s})", .{
            str_allowzero,
            str_const,
            str_volatile,
            @tagName(inst_data.size),
        });
    }

    fn writePtrType(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].ptr_type;
        _ = inst_data;
        try stream.writeAll("TODO)");
    }

    fn writeInt(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].int;
        try stream.print("{d})", .{inst_data});
    }

    fn writeIntBig(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].str;
        const byte_count = inst_data.len * @sizeOf(std.math.big.Limb);
        const limb_bytes = self.code.string_bytes[inst_data.start..][0..byte_count];
        // limb_bytes is not aligned properly; we must allocate and copy the bytes
        // in order to accomplish this.
        const limbs = try self.gpa.alloc(std.math.big.Limb, inst_data.len);
        defer self.gpa.free(limbs);

        mem.copy(u8, mem.sliceAsBytes(limbs), limb_bytes);
        const big_int: std.math.big.int.Const = .{
            .limbs = limbs,
            .positive = true,
        };
        const as_string = try big_int.toStringAlloc(self.gpa, 10, .lower);
        defer self.gpa.free(as_string);
        try stream.print("{s})", .{as_string});
    }

    fn writeFloat(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].float;
        const src = inst_data.src();
        try stream.print("{d}) ", .{inst_data.number});
        try self.writeSrc(stream, src);
    }

    fn writeFloat128(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.Float128, inst_data.payload_index).data;
        const src = inst_data.src();
        const number = extra.get();
        // TODO improve std.format to be able to print f128 values
        try stream.print("{d}) ", .{@floatCast(f64, number)});
        try self.writeSrc(stream, src);
    }

    fn writeStr(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].str;
        const str = inst_data.get(self.code);
        try stream.print("\"{}\")", .{std.zig.fmtEscapes(str)});
    }

    fn writePlNode(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        try stream.writeAll("TODO) ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeBin(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.Bin, inst_data.payload_index).data;
        try self.writeInstRef(stream, extra.lhs);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.rhs);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeExport(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.Export, inst_data.payload_index).data;
        const decl_name = self.code.nullTerminatedString(extra.decl_name);

        try self.writeInstRef(stream, extra.namespace);
        try stream.print(", {}, ", .{std.zig.fmtId(decl_name)});
        try self.writeInstRef(stream, extra.options);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeStructInit(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.StructInit, inst_data.payload_index);
        var field_i: u32 = 0;
        var extra_index = extra.end;

        while (field_i < extra.data.fields_len) : (field_i += 1) {
            const item = self.code.extraData(Inst.StructInit.Item, extra_index);
            extra_index = item.end;

            if (field_i != 0) {
                try stream.writeAll(", [");
            } else {
                try stream.writeAll("[");
            }
            try self.writeInstIndex(stream, item.data.field_type);
            try stream.writeAll(", ");
            try self.writeInstRef(stream, item.data.init);
            try stream.writeAll("]");
        }
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeStructInitAnon(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.StructInitAnon, inst_data.payload_index);
        var field_i: u32 = 0;
        var extra_index = extra.end;

        while (field_i < extra.data.fields_len) : (field_i += 1) {
            const item = self.code.extraData(Inst.StructInitAnon.Item, extra_index);
            extra_index = item.end;

            const field_name = self.code.nullTerminatedString(item.data.field_name);

            const prefix = if (field_i != 0) ", [" else "[";
            try stream.print("{s}[{s}=", .{ prefix, field_name });
            try self.writeInstRef(stream, item.data.init);
            try stream.writeAll("]");
        }
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeFieldType(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.FieldType, inst_data.payload_index).data;
        try self.writeInstRef(stream, extra.container_type);
        const field_name = self.code.nullTerminatedString(extra.name_start);
        try stream.print(", {s}) ", .{field_name});
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeFieldTypeRef(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.FieldTypeRef, inst_data.payload_index).data;
        try self.writeInstRef(stream, extra.container_type);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.field_name);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeNodeMultiOp(self: *Writer, stream: anytype, extended: Inst.Extended.InstData) !void {
        const extra = self.code.extraData(Inst.NodeMultiOp, extended.operand);
        const src: LazySrcLoc = .{ .node_offset = extra.data.src_node };
        const operands = self.code.refSlice(extra.end, extended.small);

        for (operands) |operand, i| {
            if (i != 0) try stream.writeAll(", ");
            try self.writeInstRef(stream, operand);
        }
        try stream.writeAll(")) ");
        try self.writeSrc(stream, src);
    }

    fn writeAsm(self: *Writer, stream: anytype, extended: Inst.Extended.InstData) !void {
        const extra = self.code.extraData(Inst.Asm, extended.operand);
        const src: LazySrcLoc = .{ .node_offset = extra.data.src_node };
        const outputs_len = @truncate(u5, extended.small);
        const inputs_len = @truncate(u5, extended.small >> 5);
        const clobbers_len = @truncate(u5, extended.small >> 10);
        const is_volatile = @truncate(u1, extended.small >> 15) != 0;

        try self.writeFlag(stream, "volatile, ", is_volatile);
        try self.writeInstRef(stream, extra.data.asm_source);
        try stream.writeAll(", ");

        var extra_i: usize = extra.end;
        var output_type_bits = extra.data.output_type_bits;
        {
            var i: usize = 0;
            while (i < outputs_len) : (i += 1) {
                const output = self.code.extraData(Inst.Asm.Output, extra_i);
                extra_i = output.end;

                const is_type = @truncate(u1, output_type_bits) != 0;
                output_type_bits >>= 1;

                const name = self.code.nullTerminatedString(output.data.name);
                const constraint = self.code.nullTerminatedString(output.data.constraint);
                try stream.print("output({}, \"{}\", ", .{
                    std.zig.fmtId(name), std.zig.fmtEscapes(constraint),
                });
                try self.writeFlag(stream, "->", is_type);
                try self.writeInstRef(stream, output.data.operand);
                try stream.writeAll(")");
                if (i + 1 < outputs_len) {
                    try stream.writeAll("), ");
                }
            }
        }
        {
            var i: usize = 0;
            while (i < inputs_len) : (i += 1) {
                const input = self.code.extraData(Inst.Asm.Input, extra_i);
                extra_i = input.end;

                const name = self.code.nullTerminatedString(input.data.name);
                const constraint = self.code.nullTerminatedString(input.data.constraint);
                try stream.print("input({}, \"{}\", ", .{
                    std.zig.fmtId(name), std.zig.fmtEscapes(constraint),
                });
                try self.writeInstRef(stream, input.data.operand);
                try stream.writeAll(")");
                if (i + 1 < inputs_len) {
                    try stream.writeAll(", ");
                }
            }
        }
        {
            var i: usize = 0;
            while (i < clobbers_len) : (i += 1) {
                const str_index = self.code.extra[extra_i];
                extra_i += 1;
                const clobber = self.code.nullTerminatedString(str_index);
                try stream.print("{}", .{std.zig.fmtId(clobber)});
                if (i + 1 < clobbers_len) {
                    try stream.writeAll(", ");
                }
            }
        }
        try stream.writeAll(")) ");
        try self.writeSrc(stream, src);
    }

    fn writeOverflowArithmetic(self: *Writer, stream: anytype, extended: Inst.Extended.InstData) !void {
        const extra = self.code.extraData(Zir.Inst.OverflowArithmetic, extended.operand).data;
        const src: LazySrcLoc = .{ .node_offset = extra.node };

        try self.writeInstRef(stream, extra.lhs);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.rhs);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.ptr);
        try stream.writeAll(")) ");
        try self.writeSrc(stream, src);
    }

    fn writePlNodeCall(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.Call, inst_data.payload_index);
        const args = self.code.refSlice(extra.end, extra.data.args_len);

        try self.writeInstRef(stream, extra.data.callee);
        try stream.writeAll(", [");
        for (args) |arg, i| {
            if (i != 0) try stream.writeAll(", ");
            try self.writeInstRef(stream, arg);
        }
        try stream.writeAll("]) ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeBlock(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        try self.writePlNodeBlockWithoutSrc(stream, inst);
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeBlockWithoutSrc(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.Block, inst_data.payload_index);
        const body = self.code.extra[extra.end..][0..extra.data.body_len];
        try stream.writeAll("{\n");
        self.indent += 2;
        try self.writeBody(stream, body);
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("}) ");
    }

    fn writePlNodeCondBr(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.CondBr, inst_data.payload_index);
        const then_body = self.code.extra[extra.end..][0..extra.data.then_body_len];
        const else_body = self.code.extra[extra.end + then_body.len ..][0..extra.data.else_body_len];
        try self.writeInstRef(stream, extra.data.condition);
        try stream.writeAll(", {\n");
        self.indent += 2;
        try self.writeBody(stream, then_body);
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("}, {\n");
        self.indent += 2;
        try self.writeBody(stream, else_body);
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("}) ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeStructDecl(self: *Writer, stream: anytype, extended: Inst.Extended.InstData) !void {
        const small = @bitCast(Inst.StructDecl.Small, extended.small);

        var extra_index: usize = extended.operand;

        const src_node: ?i32 = if (small.has_src_node) blk: {
            const src_node = @bitCast(i32, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk src_node;
        } else null;

        const body_len = if (small.has_body_len) blk: {
            const body_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk body_len;
        } else 0;

        const fields_len = if (small.has_fields_len) blk: {
            const fields_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk fields_len;
        } else 0;

        const decls_len = if (small.has_decls_len) blk: {
            const decls_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk decls_len;
        } else 0;

        try stream.print("{s}, {s}, ", .{
            @tagName(small.name_strategy), @tagName(small.layout),
        });

        if (decls_len == 0) {
            try stream.writeAll("{}, ");
        } else {
            try stream.writeAll("{\n");
            self.indent += 2;
            extra_index = try self.writeDecls(stream, decls_len, extra_index);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}, ");
        }

        const body = self.code.extra[extra_index..][0..body_len];
        extra_index += body.len;

        if (fields_len == 0) {
            assert(body.len == 0);
            try stream.writeAll("{}, {})");
        } else {
            const prev_parent_decl_node = self.parent_decl_node;
            if (src_node) |off| self.parent_decl_node = self.relativeToNodeIndex(off);
            self.indent += 2;
            if (body.len == 0) {
                try stream.writeAll("{}, {\n");
            } else {
                try stream.writeAll("{\n");
                try self.writeBody(stream, body);

                try stream.writeByteNTimes(' ', self.indent - 2);
                try stream.writeAll("}, {\n");
            }

            const bits_per_field = 4;
            const fields_per_u32 = 32 / bits_per_field;
            const bit_bags_count = std.math.divCeil(usize, fields_len, fields_per_u32) catch unreachable;
            var bit_bag_index: usize = extra_index;
            extra_index += bit_bags_count;
            var cur_bit_bag: u32 = undefined;
            var field_i: u32 = 0;
            while (field_i < fields_len) : (field_i += 1) {
                if (field_i % fields_per_u32 == 0) {
                    cur_bit_bag = self.code.extra[bit_bag_index];
                    bit_bag_index += 1;
                }
                const has_align = @truncate(u1, cur_bit_bag) != 0;
                cur_bit_bag >>= 1;
                const has_default = @truncate(u1, cur_bit_bag) != 0;
                cur_bit_bag >>= 1;
                const is_comptime = @truncate(u1, cur_bit_bag) != 0;
                cur_bit_bag >>= 1;
                const unused = @truncate(u1, cur_bit_bag) != 0;
                cur_bit_bag >>= 1;

                _ = unused;

                const field_name = self.code.nullTerminatedString(self.code.extra[extra_index]);
                extra_index += 1;
                const field_type = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;

                try stream.writeByteNTimes(' ', self.indent);
                try self.writeFlag(stream, "comptime ", is_comptime);
                try stream.print("{}: ", .{std.zig.fmtId(field_name)});
                try self.writeInstRef(stream, field_type);

                if (has_align) {
                    const align_ref = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                    extra_index += 1;

                    try stream.writeAll(" align(");
                    try self.writeInstRef(stream, align_ref);
                    try stream.writeAll(")");
                }
                if (has_default) {
                    const default_ref = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                    extra_index += 1;

                    try stream.writeAll(" = ");
                    try self.writeInstRef(stream, default_ref);
                }
                try stream.writeAll(",\n");
            }

            self.parent_decl_node = prev_parent_decl_node;
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("})");
        }
        try self.writeSrcNode(stream, src_node);
    }

    fn writeUnionDecl(self: *Writer, stream: anytype, extended: Inst.Extended.InstData) !void {
        const small = @bitCast(Inst.UnionDecl.Small, extended.small);

        var extra_index: usize = extended.operand;

        const src_node: ?i32 = if (small.has_src_node) blk: {
            const src_node = @bitCast(i32, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk src_node;
        } else null;

        const tag_type_ref = if (small.has_tag_type) blk: {
            const tag_type_ref = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk tag_type_ref;
        } else .none;

        const body_len = if (small.has_body_len) blk: {
            const body_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk body_len;
        } else 0;

        const fields_len = if (small.has_fields_len) blk: {
            const fields_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk fields_len;
        } else 0;

        const decls_len = if (small.has_decls_len) blk: {
            const decls_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk decls_len;
        } else 0;

        try stream.print("{s}, {s}, ", .{
            @tagName(small.name_strategy), @tagName(small.layout),
        });
        try self.writeFlag(stream, "autoenum, ", small.auto_enum_tag);

        if (decls_len == 0) {
            try stream.writeAll("{}, ");
        } else {
            try stream.writeAll("{\n");
            self.indent += 2;
            extra_index = try self.writeDecls(stream, decls_len, extra_index);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}, ");
        }

        assert(fields_len != 0);

        if (tag_type_ref != .none) {
            try self.writeInstRef(stream, tag_type_ref);
            try stream.writeAll(", ");
        }

        const body = self.code.extra[extra_index..][0..body_len];
        extra_index += body.len;

        const prev_parent_decl_node = self.parent_decl_node;
        if (src_node) |off| self.parent_decl_node = self.relativeToNodeIndex(off);
        self.indent += 2;
        if (body.len == 0) {
            try stream.writeAll("{}, {\n");
        } else {
            try stream.writeAll("{\n");
            try self.writeBody(stream, body);

            try stream.writeByteNTimes(' ', self.indent - 2);
            try stream.writeAll("}, {\n");
        }

        const bits_per_field = 4;
        const fields_per_u32 = 32 / bits_per_field;
        const bit_bags_count = std.math.divCeil(usize, fields_len, fields_per_u32) catch unreachable;
        const body_end = extra_index;
        extra_index += bit_bags_count;
        var bit_bag_index: usize = body_end;
        var cur_bit_bag: u32 = undefined;
        var field_i: u32 = 0;
        while (field_i < fields_len) : (field_i += 1) {
            if (field_i % fields_per_u32 == 0) {
                cur_bit_bag = self.code.extra[bit_bag_index];
                bit_bag_index += 1;
            }
            const has_type = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const has_align = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const has_value = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const unused = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;

            _ = unused;

            const field_name = self.code.nullTerminatedString(self.code.extra[extra_index]);
            extra_index += 1;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.print("{}", .{std.zig.fmtId(field_name)});

            if (has_type) {
                const field_type = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;

                try stream.writeAll(": ");
                try self.writeInstRef(stream, field_type);
            }
            if (has_align) {
                const align_ref = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;

                try stream.writeAll(" align(");
                try self.writeInstRef(stream, align_ref);
                try stream.writeAll(")");
            }
            if (has_value) {
                const default_ref = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;

                try stream.writeAll(" = ");
                try self.writeInstRef(stream, default_ref);
            }
            try stream.writeAll(",\n");
        }

        self.parent_decl_node = prev_parent_decl_node;
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("})");
        try self.writeSrcNode(stream, src_node);
    }

    fn writeDecls(self: *Writer, stream: anytype, decls_len: u32, extra_start: usize) !usize {
        const parent_decl_node = self.parent_decl_node;
        const bit_bags_count = std.math.divCeil(usize, decls_len, 8) catch unreachable;
        var extra_index = extra_start + bit_bags_count;
        var bit_bag_index: usize = extra_start;
        var cur_bit_bag: u32 = undefined;
        var decl_i: u32 = 0;
        while (decl_i < decls_len) : (decl_i += 1) {
            if (decl_i % 8 == 0) {
                cur_bit_bag = self.code.extra[bit_bag_index];
                bit_bag_index += 1;
            }
            const is_pub = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const is_exported = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const has_align = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;
            const has_section = @truncate(u1, cur_bit_bag) != 0;
            cur_bit_bag >>= 1;

            const sub_index = extra_index;

            const hash_u32s = self.code.extra[extra_index..][0..4];
            extra_index += 4;
            const line = self.code.extra[extra_index];
            extra_index += 1;
            const decl_name_index = self.code.extra[extra_index];
            extra_index += 1;
            const decl_index = self.code.extra[extra_index];
            extra_index += 1;
            const align_inst: Inst.Ref = if (!has_align) .none else inst: {
                const inst = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;
                break :inst inst;
            };
            const section_inst: Inst.Ref = if (!has_section) .none else inst: {
                const inst = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;
                break :inst inst;
            };

            const pub_str = if (is_pub) "pub " else "";
            const hash_bytes = @bitCast([16]u8, hash_u32s.*);
            try stream.writeByteNTimes(' ', self.indent);
            if (decl_name_index == 0) {
                const name = if (is_exported) "usingnamespace" else "comptime";
                try stream.writeAll(pub_str);
                try stream.writeAll(name);
            } else if (decl_name_index == 1) {
                try stream.writeAll("test");
            } else {
                const raw_decl_name = self.code.nullTerminatedString(decl_name_index);
                const decl_name = if (raw_decl_name.len == 0)
                    self.code.nullTerminatedString(decl_name_index + 1)
                else
                    raw_decl_name;
                const test_str = if (raw_decl_name.len == 0) "test " else "";
                const export_str = if (is_exported) "export " else "";
                try stream.print("[{d}] {s}{s}{s}{}", .{
                    sub_index, pub_str, test_str, export_str, std.zig.fmtId(decl_name),
                });
                if (align_inst != .none) {
                    try stream.writeAll(" align(");
                    try self.writeInstRef(stream, align_inst);
                    try stream.writeAll(")");
                }
                if (section_inst != .none) {
                    try stream.writeAll(" linksection(");
                    try self.writeInstRef(stream, section_inst);
                    try stream.writeAll(")");
                }
            }
            const tag = self.code.instructions.items(.tag)[decl_index];
            try stream.print(" line({d}) hash({}): %{d} = {s}(", .{
                line, std.fmt.fmtSliceHexLower(&hash_bytes), decl_index, @tagName(tag),
            });

            const decl_block_inst_data = self.code.instructions.items(.data)[decl_index].pl_node;
            const sub_decl_node_off = decl_block_inst_data.src_node;
            self.parent_decl_node = self.relativeToNodeIndex(sub_decl_node_off);
            try self.writePlNodeBlockWithoutSrc(stream, decl_index);
            self.parent_decl_node = parent_decl_node;
            try self.writeSrc(stream, decl_block_inst_data.src());
            try stream.writeAll("\n");
        }
        return extra_index;
    }

    fn writeEnumDecl(self: *Writer, stream: anytype, extended: Inst.Extended.InstData) !void {
        const small = @bitCast(Inst.EnumDecl.Small, extended.small);
        var extra_index: usize = extended.operand;

        const src_node: ?i32 = if (small.has_src_node) blk: {
            const src_node = @bitCast(i32, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk src_node;
        } else null;

        const tag_type_ref = if (small.has_tag_type) blk: {
            const tag_type_ref = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk tag_type_ref;
        } else .none;

        const body_len = if (small.has_body_len) blk: {
            const body_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk body_len;
        } else 0;

        const fields_len = if (small.has_fields_len) blk: {
            const fields_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk fields_len;
        } else 0;

        const decls_len = if (small.has_decls_len) blk: {
            const decls_len = self.code.extra[extra_index];
            extra_index += 1;
            break :blk decls_len;
        } else 0;

        try stream.print("{s}, ", .{@tagName(small.name_strategy)});
        try self.writeFlag(stream, "nonexhaustive, ", small.nonexhaustive);

        if (decls_len == 0) {
            try stream.writeAll("{}, ");
        } else {
            try stream.writeAll("{\n");
            self.indent += 2;
            extra_index = try self.writeDecls(stream, decls_len, extra_index);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}, ");
        }

        if (tag_type_ref != .none) {
            try self.writeInstRef(stream, tag_type_ref);
            try stream.writeAll(", ");
        }

        const body = self.code.extra[extra_index..][0..body_len];
        extra_index += body.len;

        if (fields_len == 0) {
            assert(body.len == 0);
            try stream.writeAll("{}, {})");
        } else {
            const prev_parent_decl_node = self.parent_decl_node;
            if (src_node) |off| self.parent_decl_node = self.relativeToNodeIndex(off);
            self.indent += 2;
            if (body.len == 0) {
                try stream.writeAll("{}, {\n");
            } else {
                try stream.writeAll("{\n");
                try self.writeBody(stream, body);

                try stream.writeByteNTimes(' ', self.indent - 2);
                try stream.writeAll("}, {\n");
            }

            const bit_bags_count = std.math.divCeil(usize, fields_len, 32) catch unreachable;
            const body_end = extra_index;
            extra_index += bit_bags_count;
            var bit_bag_index: usize = body_end;
            var cur_bit_bag: u32 = undefined;
            var field_i: u32 = 0;
            while (field_i < fields_len) : (field_i += 1) {
                if (field_i % 32 == 0) {
                    cur_bit_bag = self.code.extra[bit_bag_index];
                    bit_bag_index += 1;
                }
                const has_tag_value = @truncate(u1, cur_bit_bag) != 0;
                cur_bit_bag >>= 1;

                const field_name = self.code.nullTerminatedString(self.code.extra[extra_index]);
                extra_index += 1;

                try stream.writeByteNTimes(' ', self.indent);
                try stream.print("{}", .{std.zig.fmtId(field_name)});

                if (has_tag_value) {
                    const tag_value_ref = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                    extra_index += 1;

                    try stream.writeAll(" = ");
                    try self.writeInstRef(stream, tag_value_ref);
                }
                try stream.writeAll(",\n");
            }
            self.parent_decl_node = prev_parent_decl_node;
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("})");
        }
        try self.writeSrcNode(stream, src_node);
    }

    fn writeOpaqueDecl(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
        name_strategy: Inst.NameStrategy,
    ) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.OpaqueDecl, inst_data.payload_index);
        const decls_len = extra.data.decls_len;

        try stream.print("{s}, ", .{@tagName(name_strategy)});

        if (decls_len == 0) {
            try stream.writeAll("}) ");
        } else {
            try stream.writeAll("\n");
            self.indent += 2;
            _ = try self.writeDecls(stream, decls_len, extra.end);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}) ");
        }
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeErrorSetDecl(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
        name_strategy: Inst.NameStrategy,
    ) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.ErrorSetDecl, inst_data.payload_index);
        const fields = self.code.extra[extra.end..][0..extra.data.fields_len];

        try stream.print("{s}, ", .{@tagName(name_strategy)});

        try stream.writeAll("{\n");
        self.indent += 2;
        for (fields) |str_index| {
            const name = self.code.nullTerminatedString(str_index);
            try stream.writeByteNTimes(' ', self.indent);
            try stream.print("{},\n", .{std.zig.fmtId(name)});
        }
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("}) ");

        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeSwitchBr(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
        special_prong: SpecialProng,
    ) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.SwitchBlock, inst_data.payload_index);
        const special: struct {
            body: []const Inst.Index,
            end: usize,
        } = switch (special_prong) {
            .none => .{ .body = &.{}, .end = extra.end },
            .under, .@"else" => blk: {
                const body_len = self.code.extra[extra.end];
                const extra_body_start = extra.end + 1;
                break :blk .{
                    .body = self.code.extra[extra_body_start..][0..body_len],
                    .end = extra_body_start + body_len,
                };
            },
        };

        try self.writeInstRef(stream, extra.data.operand);

        if (special.body.len != 0) {
            const prong_name = switch (special_prong) {
                .@"else" => "else",
                .under => "_",
                else => unreachable,
            };
            try stream.print(", {s} => {{\n", .{prong_name});
            self.indent += 2;
            try self.writeBody(stream, special.body);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}");
        }

        var extra_index: usize = special.end;
        {
            var scalar_i: usize = 0;
            while (scalar_i < extra.data.cases_len) : (scalar_i += 1) {
                const item_ref = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;
                const body_len = self.code.extra[extra_index];
                extra_index += 1;
                const body = self.code.extra[extra_index..][0..body_len];
                extra_index += body_len;

                try stream.writeAll(", ");
                try self.writeInstRef(stream, item_ref);
                try stream.writeAll(" => {\n");
                self.indent += 2;
                try self.writeBody(stream, body);
                self.indent -= 2;
                try stream.writeByteNTimes(' ', self.indent);
                try stream.writeAll("}");
            }
        }
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeSwitchBlockMulti(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
        special_prong: SpecialProng,
    ) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.SwitchBlockMulti, inst_data.payload_index);
        const special: struct {
            body: []const Inst.Index,
            end: usize,
        } = switch (special_prong) {
            .none => .{ .body = &.{}, .end = extra.end },
            .under, .@"else" => blk: {
                const body_len = self.code.extra[extra.end];
                const extra_body_start = extra.end + 1;
                break :blk .{
                    .body = self.code.extra[extra_body_start..][0..body_len],
                    .end = extra_body_start + body_len,
                };
            },
        };

        try self.writeInstRef(stream, extra.data.operand);

        if (special.body.len != 0) {
            const prong_name = switch (special_prong) {
                .@"else" => "else",
                .under => "_",
                else => unreachable,
            };
            try stream.print(", {s} => {{\n", .{prong_name});
            self.indent += 2;
            try self.writeBody(stream, special.body);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}");
        }

        var extra_index: usize = special.end;
        {
            var scalar_i: usize = 0;
            while (scalar_i < extra.data.scalar_cases_len) : (scalar_i += 1) {
                const item_ref = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                extra_index += 1;
                const body_len = self.code.extra[extra_index];
                extra_index += 1;
                const body = self.code.extra[extra_index..][0..body_len];
                extra_index += body_len;

                try stream.writeAll(", ");
                try self.writeInstRef(stream, item_ref);
                try stream.writeAll(" => {\n");
                self.indent += 2;
                try self.writeBody(stream, body);
                self.indent -= 2;
                try stream.writeByteNTimes(' ', self.indent);
                try stream.writeAll("}");
            }
        }
        {
            var multi_i: usize = 0;
            while (multi_i < extra.data.multi_cases_len) : (multi_i += 1) {
                const items_len = self.code.extra[extra_index];
                extra_index += 1;
                const ranges_len = self.code.extra[extra_index];
                extra_index += 1;
                const body_len = self.code.extra[extra_index];
                extra_index += 1;
                const items = self.code.refSlice(extra_index, items_len);
                extra_index += items_len;

                for (items) |item_ref| {
                    try stream.writeAll(", ");
                    try self.writeInstRef(stream, item_ref);
                }

                var range_i: usize = 0;
                while (range_i < ranges_len) : (range_i += 1) {
                    const item_first = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                    extra_index += 1;
                    const item_last = @intToEnum(Inst.Ref, self.code.extra[extra_index]);
                    extra_index += 1;

                    try stream.writeAll(", ");
                    try self.writeInstRef(stream, item_first);
                    try stream.writeAll("...");
                    try self.writeInstRef(stream, item_last);
                }

                const body = self.code.extra[extra_index..][0..body_len];
                extra_index += body_len;
                try stream.writeAll(" => {\n");
                self.indent += 2;
                try self.writeBody(stream, body);
                self.indent -= 2;
                try stream.writeByteNTimes(' ', self.indent);
                try stream.writeAll("}");
            }
        }
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writePlNodeField(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.Field, inst_data.payload_index).data;
        const name = self.code.nullTerminatedString(extra.field_name_start);
        try self.writeInstRef(stream, extra.lhs);
        try stream.print(", \"{}\") ", .{std.zig.fmtEscapes(name)});
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeAs(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const extra = self.code.extraData(Inst.As, inst_data.payload_index).data;
        try self.writeInstRef(stream, extra.dest_type);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, extra.operand);
        try stream.writeAll(") ");
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeNode(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const src_node = self.code.instructions.items(.data)[inst].node;
        const src: LazySrcLoc = .{ .node_offset = src_node };
        try stream.writeAll(") ");
        try self.writeSrc(stream, src);
    }

    fn writeStrTok(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
    ) (@TypeOf(stream).Error || error{OutOfMemory})!void {
        const inst_data = self.code.instructions.items(.data)[inst].str_tok;
        const str = inst_data.get(self.code);
        try stream.print("\"{}\") ", .{std.zig.fmtEscapes(str)});
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeFunc(
        self: *Writer,
        stream: anytype,
        inst: Inst.Index,
        inferred_error_set: bool,
    ) !void {
        const inst_data = self.code.instructions.items(.data)[inst].pl_node;
        const src = inst_data.src();
        const extra = self.code.extraData(Inst.Func, inst_data.payload_index);
        const param_types = self.code.refSlice(extra.end, extra.data.param_types_len);
        const body = self.code.extra[extra.end + param_types.len ..][0..extra.data.body_len];
        var src_locs: Zir.Inst.Func.SrcLocs = undefined;
        if (body.len != 0) {
            const extra_index = extra.end + param_types.len + body.len;
            src_locs = self.code.extraData(Zir.Inst.Func.SrcLocs, extra_index).data;
        }
        return self.writeFuncCommon(
            stream,
            param_types,
            extra.data.return_type,
            inferred_error_set,
            false,
            false,
            .none,
            .none,
            body,
            src,
            src_locs,
        );
    }

    fn writeFuncExtended(self: *Writer, stream: anytype, extended: Inst.Extended.InstData) !void {
        const extra = self.code.extraData(Inst.ExtendedFunc, extended.operand);
        const src: LazySrcLoc = .{ .node_offset = extra.data.src_node };
        const small = @bitCast(Inst.ExtendedFunc.Small, extended.small);

        var extra_index: usize = extra.end;
        if (small.has_lib_name) {
            const lib_name = self.code.nullTerminatedString(self.code.extra[extra_index]);
            extra_index += 1;
            try stream.print("lib_name=\"{}\", ", .{std.zig.fmtEscapes(lib_name)});
        }
        try self.writeFlag(stream, "test, ", small.is_test);
        const cc: Inst.Ref = if (!small.has_cc) .none else blk: {
            const cc = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk cc;
        };
        const align_inst: Inst.Ref = if (!small.has_align) .none else blk: {
            const align_inst = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk align_inst;
        };

        const param_types = self.code.refSlice(extra_index, extra.data.param_types_len);
        extra_index += param_types.len;

        const body = self.code.extra[extra_index..][0..extra.data.body_len];
        extra_index += body.len;

        var src_locs: Zir.Inst.Func.SrcLocs = undefined;
        if (body.len != 0) {
            src_locs = self.code.extraData(Zir.Inst.Func.SrcLocs, extra_index).data;
        }
        return self.writeFuncCommon(
            stream,
            param_types,
            extra.data.return_type,
            small.is_inferred_error,
            small.is_var_args,
            small.is_extern,
            cc,
            align_inst,
            body,
            src,
            src_locs,
        );
    }

    fn writeVarExtended(self: *Writer, stream: anytype, extended: Inst.Extended.InstData) !void {
        const extra = self.code.extraData(Inst.ExtendedVar, extended.operand);
        const small = @bitCast(Inst.ExtendedVar.Small, extended.small);

        try self.writeInstRef(stream, extra.data.var_type);

        var extra_index: usize = extra.end;
        if (small.has_lib_name) {
            const lib_name = self.code.nullTerminatedString(self.code.extra[extra_index]);
            extra_index += 1;
            try stream.print(", lib_name=\"{}\"", .{std.zig.fmtEscapes(lib_name)});
        }
        const align_inst: Inst.Ref = if (!small.has_align) .none else blk: {
            const align_inst = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk align_inst;
        };
        const init_inst: Inst.Ref = if (!small.has_init) .none else blk: {
            const init_inst = @intToEnum(Zir.Inst.Ref, self.code.extra[extra_index]);
            extra_index += 1;
            break :blk init_inst;
        };
        try self.writeFlag(stream, ", is_extern", small.is_extern);
        try self.writeOptionalInstRef(stream, ", align=", align_inst);
        try self.writeOptionalInstRef(stream, ", init=", init_inst);
        try stream.writeAll("))");
    }

    fn writeBoolBr(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].bool_br;
        const extra = self.code.extraData(Inst.Block, inst_data.payload_index);
        const body = self.code.extra[extra.end..][0..extra.data.body_len];
        try self.writeInstRef(stream, inst_data.lhs);
        try stream.writeAll(", {\n");
        self.indent += 2;
        try self.writeBody(stream, body);
        self.indent -= 2;
        try stream.writeByteNTimes(' ', self.indent);
        try stream.writeAll("})");
    }

    fn writeIntType(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const int_type = self.code.instructions.items(.data)[inst].int_type;
        const prefix: u8 = switch (int_type.signedness) {
            .signed => 'i',
            .unsigned => 'u',
        };
        try stream.print("{c}{d}) ", .{ prefix, int_type.bit_count });
        try self.writeSrc(stream, int_type.src());
    }

    fn writeBreak(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].@"break";

        try self.writeInstIndex(stream, inst_data.block_inst);
        try stream.writeAll(", ");
        try self.writeInstRef(stream, inst_data.operand);
        try stream.writeAll(")");
    }

    fn writeUnreachable(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].@"unreachable";
        const safety_str = if (inst_data.safety) "safe" else "unsafe";
        try stream.print("{s}) ", .{safety_str});
        try self.writeSrc(stream, inst_data.src());
    }

    fn writeFuncCommon(
        self: *Writer,
        stream: anytype,
        param_types: []const Inst.Ref,
        ret_ty: Inst.Ref,
        inferred_error_set: bool,
        var_args: bool,
        is_extern: bool,
        cc: Inst.Ref,
        align_inst: Inst.Ref,
        body: []const Inst.Index,
        src: LazySrcLoc,
        src_locs: Zir.Inst.Func.SrcLocs,
    ) !void {
        try stream.writeAll("[");
        for (param_types) |param_type, i| {
            if (i != 0) try stream.writeAll(", ");
            try self.writeInstRef(stream, param_type);
        }
        try stream.writeAll("], ");
        try self.writeInstRef(stream, ret_ty);
        try self.writeOptionalInstRef(stream, ", cc=", cc);
        try self.writeOptionalInstRef(stream, ", align=", align_inst);
        try self.writeFlag(stream, ", vargs", var_args);
        try self.writeFlag(stream, ", extern", is_extern);
        try self.writeFlag(stream, ", inferror", inferred_error_set);

        if (body.len == 0) {
            try stream.writeAll(", {}) ");
        } else {
            try stream.writeAll(", {\n");
            self.indent += 2;
            try self.writeBody(stream, body);
            self.indent -= 2;
            try stream.writeByteNTimes(' ', self.indent);
            try stream.writeAll("}) ");
        }
        if (body.len != 0) {
            try stream.print("(lbrace={d}:{d},rbrace={d}:{d}) ", .{
                src_locs.lbrace_line, @truncate(u16, src_locs.columns),
                src_locs.rbrace_line, @truncate(u16, src_locs.columns >> 16),
            });
        }
        try self.writeSrc(stream, src);
    }

    fn writeSwitchCapture(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].switch_capture;
        try self.writeInstIndex(stream, inst_data.switch_inst);
        try stream.print(", {d})", .{inst_data.prong_index});
    }

    fn writeDbgStmt(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        const inst_data = self.code.instructions.items(.data)[inst].dbg_stmt;
        try stream.print("{d}, {d})", .{ inst_data.line, inst_data.column });
    }

    fn writeInstRef(self: *Writer, stream: anytype, ref: Inst.Ref) !void {
        var i: usize = @enumToInt(ref);

        if (i < Inst.Ref.typed_value_map.len) {
            return stream.print("@{}", .{ref});
        }
        i -= Inst.Ref.typed_value_map.len;

        return self.writeInstIndex(stream, @intCast(Inst.Index, i));
    }

    fn writeInstIndex(self: *Writer, stream: anytype, inst: Inst.Index) !void {
        _ = self;
        return stream.print("%{d}", .{inst});
    }

    fn writeOptionalInstRef(
        self: *Writer,
        stream: anytype,
        prefix: []const u8,
        inst: Inst.Ref,
    ) !void {
        if (inst == .none) return;
        try stream.writeAll(prefix);
        try self.writeInstRef(stream, inst);
    }

    fn writeFlag(
        self: *Writer,
        stream: anytype,
        name: []const u8,
        flag: bool,
    ) !void {
        _ = self;
        if (!flag) return;
        try stream.writeAll(name);
    }

    fn writeSrc(self: *Writer, stream: anytype, src: LazySrcLoc) !void {
        const tree = self.file.tree;
        const src_loc: Module.SrcLoc = .{
            .file_scope = self.file,
            .parent_decl_node = self.parent_decl_node,
            .lazy = src,
        };
        // Caller must ensure AST tree is loaded.
        const abs_byte_off = src_loc.byteOffset(self.gpa) catch unreachable;
        const delta_line = std.zig.findLineColumn(tree.source, abs_byte_off);
        try stream.print("{s}:{d}:{d}", .{
            @tagName(src), delta_line.line + 1, delta_line.column + 1,
        });
    }

    fn writeSrcNode(self: *Writer, stream: anytype, src_node: ?i32) !void {
        const node_offset = src_node orelse return;
        const src: LazySrcLoc = .{ .node_offset = node_offset };
        try stream.writeAll(" ");
        return self.writeSrc(stream, src);
    }

    fn writeBody(self: *Writer, stream: anytype, body: []const Inst.Index) !void {
        for (body) |inst| {
            try stream.writeByteNTimes(' ', self.indent);
            try stream.print("%{d} ", .{inst});
            try self.writeInstToStream(stream, inst);
            try stream.writeByte('\n');
        }
    }
};

pub const DeclIterator = struct {
    extra_index: usize,
    bit_bag_index: usize,
    cur_bit_bag: u32,
    decl_i: u32,
    decls_len: u32,
    zir: Zir,

    pub const Item = struct {
        name: [:0]const u8,
        sub_index: u32,
    };

    pub fn next(it: *DeclIterator) ?Item {
        if (it.decl_i >= it.decls_len) return null;

        if (it.decl_i % 8 == 0) {
            it.cur_bit_bag = it.zir.extra[it.bit_bag_index];
            it.bit_bag_index += 1;
        }
        it.decl_i += 1;

        const flags = @truncate(u4, it.cur_bit_bag);
        it.cur_bit_bag >>= 4;

        const sub_index = @intCast(u32, it.extra_index);
        it.extra_index += 5; // src_hash(4) + line(1)
        const name = it.zir.nullTerminatedString(it.zir.extra[it.extra_index]);
        it.extra_index += 2; // name(1) + value(1)
        it.extra_index += @truncate(u1, flags >> 2);
        it.extra_index += @truncate(u1, flags >> 3);

        return Item{
            .sub_index = sub_index,
            .name = name,
        };
    }
};

pub fn declIterator(zir: Zir, decl_inst: u32) DeclIterator {
    const tags = zir.instructions.items(.tag);
    const datas = zir.instructions.items(.data);
    switch (tags[decl_inst]) {
        .opaque_decl,
        .opaque_decl_anon,
        .opaque_decl_func,
        => {
            const inst_data = datas[decl_inst].pl_node;
            const extra = zir.extraData(Inst.OpaqueDecl, inst_data.payload_index);
            return declIteratorInner(zir, extra.end, extra.data.decls_len);
        },

        // Functions are allowed and yield no iterations.
        // There is one case matching this in the extended instruction set below.
        .func,
        .func_inferred,
        => return declIteratorInner(zir, 0, 0),

        .extended => {
            const extended = datas[decl_inst].extended;
            switch (extended.opcode) {
                .func => return declIteratorInner(zir, 0, 0),
                .struct_decl => {
                    const small = @bitCast(Inst.StructDecl.Small, extended.small);
                    var extra_index: usize = extended.operand;
                    extra_index += @boolToInt(small.has_src_node);
                    extra_index += @boolToInt(small.has_body_len);
                    extra_index += @boolToInt(small.has_fields_len);
                    const decls_len = if (small.has_decls_len) decls_len: {
                        const decls_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :decls_len decls_len;
                    } else 0;

                    return declIteratorInner(zir, extra_index, decls_len);
                },
                .enum_decl => {
                    const small = @bitCast(Inst.EnumDecl.Small, extended.small);
                    var extra_index: usize = extended.operand;
                    extra_index += @boolToInt(small.has_src_node);
                    extra_index += @boolToInt(small.has_tag_type);
                    extra_index += @boolToInt(small.has_body_len);
                    extra_index += @boolToInt(small.has_fields_len);
                    const decls_len = if (small.has_decls_len) decls_len: {
                        const decls_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :decls_len decls_len;
                    } else 0;

                    return declIteratorInner(zir, extra_index, decls_len);
                },
                .union_decl => {
                    const small = @bitCast(Inst.UnionDecl.Small, extended.small);
                    var extra_index: usize = extended.operand;
                    extra_index += @boolToInt(small.has_src_node);
                    extra_index += @boolToInt(small.has_tag_type);
                    extra_index += @boolToInt(small.has_body_len);
                    extra_index += @boolToInt(small.has_fields_len);
                    const decls_len = if (small.has_decls_len) decls_len: {
                        const decls_len = zir.extra[extra_index];
                        extra_index += 1;
                        break :decls_len decls_len;
                    } else 0;

                    return declIteratorInner(zir, extra_index, decls_len);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

pub fn declIteratorInner(zir: Zir, extra_index: usize, decls_len: u32) DeclIterator {
    const bit_bags_count = std.math.divCeil(usize, decls_len, 8) catch unreachable;
    return .{
        .zir = zir,
        .extra_index = extra_index + bit_bags_count,
        .bit_bag_index = extra_index,
        .cur_bit_bag = undefined,
        .decl_i = 0,
        .decls_len = decls_len,
    };
}

/// The iterator would have to allocate memory anyway to iterate. So here we populate
/// an ArrayList as the result.
pub fn findDecls(zir: Zir, list: *std.ArrayList(Zir.Inst.Index), decl_sub_index: u32) !void {
    const block_inst = zir.extra[decl_sub_index + 6];
    list.clearRetainingCapacity();

    return zir.findDeclsInner(list, block_inst);
}

fn findDeclsInner(
    zir: Zir,
    list: *std.ArrayList(Zir.Inst.Index),
    inst: Zir.Inst.Index,
) Allocator.Error!void {
    const tags = zir.instructions.items(.tag);
    const datas = zir.instructions.items(.data);

    switch (tags[inst]) {
        // Decl instructions are interesting but have no body.
        // TODO yes they do have a body actually. recurse over them just like block instructions.
        .opaque_decl,
        .opaque_decl_anon,
        .opaque_decl_func,
        => return list.append(inst),

        // Functions instructions are interesting and have a body.
        .func,
        .func_inferred,
        => {
            try list.append(inst);

            const inst_data = datas[inst].pl_node;
            const extra = zir.extraData(Inst.Func, inst_data.payload_index);
            const param_types_len = extra.data.param_types_len;
            const body = zir.extra[extra.end + param_types_len ..][0..extra.data.body_len];
            return zir.findDeclsBody(list, body);
        },
        .extended => {
            const extended = datas[inst].extended;
            switch (extended.opcode) {
                .func => {
                    try list.append(inst);

                    const extra = zir.extraData(Inst.ExtendedFunc, extended.operand);
                    const small = @bitCast(Inst.ExtendedFunc.Small, extended.small);
                    var extra_index: usize = extra.end;
                    extra_index += @boolToInt(small.has_lib_name);
                    extra_index += @boolToInt(small.has_cc);
                    extra_index += @boolToInt(small.has_align);
                    extra_index += extra.data.param_types_len;
                    const body = zir.extra[extra_index..][0..extra.data.body_len];
                    return zir.findDeclsBody(list, body);
                },

                .struct_decl,
                .union_decl,
                .enum_decl,
                => return list.append(inst),

                else => return,
            }
        },

        // Block instructions, recurse over the bodies.

        .block, .block_inline => {
            const inst_data = datas[inst].pl_node;
            const extra = zir.extraData(Inst.Block, inst_data.payload_index);
            const body = zir.extra[extra.end..][0..extra.data.body_len];
            return zir.findDeclsBody(list, body);
        },
        .condbr, .condbr_inline => {
            const inst_data = datas[inst].pl_node;
            const extra = zir.extraData(Inst.CondBr, inst_data.payload_index);
            const then_body = zir.extra[extra.end..][0..extra.data.then_body_len];
            const else_body = zir.extra[extra.end + then_body.len ..][0..extra.data.else_body_len];
            try zir.findDeclsBody(list, then_body);
            try zir.findDeclsBody(list, else_body);
        },
        .switch_block => return findDeclsSwitch(zir, list, inst, .none),
        .switch_block_else => return findDeclsSwitch(zir, list, inst, .@"else"),
        .switch_block_under => return findDeclsSwitch(zir, list, inst, .under),
        .switch_block_ref => return findDeclsSwitch(zir, list, inst, .none),
        .switch_block_ref_else => return findDeclsSwitch(zir, list, inst, .@"else"),
        .switch_block_ref_under => return findDeclsSwitch(zir, list, inst, .under),

        .switch_block_multi => return findDeclsSwitchMulti(zir, list, inst, .none),
        .switch_block_else_multi => return findDeclsSwitchMulti(zir, list, inst, .@"else"),
        .switch_block_under_multi => return findDeclsSwitchMulti(zir, list, inst, .under),
        .switch_block_ref_multi => return findDeclsSwitchMulti(zir, list, inst, .none),
        .switch_block_ref_else_multi => return findDeclsSwitchMulti(zir, list, inst, .@"else"),
        .switch_block_ref_under_multi => return findDeclsSwitchMulti(zir, list, inst, .under),

        .suspend_block => @panic("TODO iterate suspend block"),

        else => return, // Regular instruction, not interesting.
    }
}

fn findDeclsSwitch(
    zir: Zir,
    list: *std.ArrayList(Zir.Inst.Index),
    inst: Zir.Inst.Index,
    special_prong: SpecialProng,
) Allocator.Error!void {
    const inst_data = zir.instructions.items(.data)[inst].pl_node;
    const extra = zir.extraData(Inst.SwitchBlock, inst_data.payload_index);
    const special: struct {
        body: []const Inst.Index,
        end: usize,
    } = switch (special_prong) {
        .none => .{ .body = &.{}, .end = extra.end },
        .under, .@"else" => blk: {
            const body_len = zir.extra[extra.end];
            const extra_body_start = extra.end + 1;
            break :blk .{
                .body = zir.extra[extra_body_start..][0..body_len],
                .end = extra_body_start + body_len,
            };
        },
    };

    try zir.findDeclsBody(list, special.body);

    var extra_index: usize = special.end;
    var scalar_i: usize = 0;
    while (scalar_i < extra.data.cases_len) : (scalar_i += 1) {
        extra_index += 1;
        const body_len = zir.extra[extra_index];
        extra_index += 1;
        const body = zir.extra[extra_index..][0..body_len];
        extra_index += body_len;

        try zir.findDeclsBody(list, body);
    }
}

fn findDeclsSwitchMulti(
    zir: Zir,
    list: *std.ArrayList(Zir.Inst.Index),
    inst: Zir.Inst.Index,
    special_prong: SpecialProng,
) Allocator.Error!void {
    const inst_data = zir.instructions.items(.data)[inst].pl_node;
    const extra = zir.extraData(Inst.SwitchBlockMulti, inst_data.payload_index);
    const special: struct {
        body: []const Inst.Index,
        end: usize,
    } = switch (special_prong) {
        .none => .{ .body = &.{}, .end = extra.end },
        .under, .@"else" => blk: {
            const body_len = zir.extra[extra.end];
            const extra_body_start = extra.end + 1;
            break :blk .{
                .body = zir.extra[extra_body_start..][0..body_len],
                .end = extra_body_start + body_len,
            };
        },
    };

    try zir.findDeclsBody(list, special.body);

    var extra_index: usize = special.end;
    {
        var scalar_i: usize = 0;
        while (scalar_i < extra.data.scalar_cases_len) : (scalar_i += 1) {
            extra_index += 1;
            const body_len = zir.extra[extra_index];
            extra_index += 1;
            const body = zir.extra[extra_index..][0..body_len];
            extra_index += body_len;

            try zir.findDeclsBody(list, body);
        }
    }
    {
        var multi_i: usize = 0;
        while (multi_i < extra.data.multi_cases_len) : (multi_i += 1) {
            const items_len = zir.extra[extra_index];
            extra_index += 1;
            const ranges_len = zir.extra[extra_index];
            extra_index += 1;
            const body_len = zir.extra[extra_index];
            extra_index += 1;
            const items = zir.refSlice(extra_index, items_len);
            extra_index += items_len;
            _ = items;

            var range_i: usize = 0;
            while (range_i < ranges_len) : (range_i += 1) {
                extra_index += 1;
                extra_index += 1;
            }

            const body = zir.extra[extra_index..][0..body_len];
            extra_index += body_len;

            try zir.findDeclsBody(list, body);
        }
    }
}

fn findDeclsBody(
    zir: Zir,
    list: *std.ArrayList(Zir.Inst.Index),
    body: []const Zir.Inst.Index,
) Allocator.Error!void {
    for (body) |member| {
        try zir.findDeclsInner(list, member);
    }
}
