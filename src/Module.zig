//! Compilation of all Zig source code is represented by one `Module`.
//! Each `Compilation` has exactly one or zero `Module`, depending on whether
//! there is or is not any zig source code, respectively.

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;
const log = std.log.scoped(.module);
const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const Target = std.Target;
const ast = std.zig.ast;

const Module = @This();
const Compilation = @import("Compilation.zig");
const Cache = @import("Cache.zig");
const Value = @import("value.zig").Value;
const Type = @import("type.zig").Type;
const TypedValue = @import("TypedValue.zig");
const Package = @import("Package.zig");
const link = @import("link.zig");
const ir = @import("air.zig");
const Zir = @import("Zir.zig");
const trace = @import("tracy.zig").trace;
const AstGen = @import("AstGen.zig");
const Sema = @import("Sema.zig");
const target_util = @import("target.zig");
const build_options = @import("build_options");

/// General-purpose allocator. Used for both temporary and long-term storage.
gpa: *Allocator,
comp: *Compilation,

/// Where our incremental compilation metadata serialization will go.
zig_cache_artifact_directory: Compilation.Directory,
/// Pointer to externally managed resource. `null` if there is no zig file being compiled.
root_pkg: *Package,

/// Used by AstGen worker to load and store ZIR cache.
global_zir_cache: Compilation.Directory,
/// Used by AstGen worker to load and store ZIR cache.
local_zir_cache: Compilation.Directory,
/// It's rare for a decl to be exported, so we save memory by having a sparse
/// map of Decl pointers to details about them being exported.
/// The Export memory is owned by the `export_owners` table; the slice itself
/// is owned by this table. The slice is guaranteed to not be empty.
decl_exports: std.AutoArrayHashMapUnmanaged(*Decl, []*Export) = .{},
/// This models the Decls that perform exports, so that `decl_exports` can be updated when a Decl
/// is modified. Note that the key of this table is not the Decl being exported, but the Decl that
/// is performing the export of another Decl.
/// This table owns the Export memory.
export_owners: std.AutoArrayHashMapUnmanaged(*Decl, []*Export) = .{},
/// The set of all the files in the Module. We keep track of this in order to iterate
/// over it and check which source files have been modified on the file system when
/// an update is requested, as well as to cache `@import` results.
/// Keys are fully resolved file paths. This table owns the keys and values.
import_table: std.StringArrayHashMapUnmanaged(*Scope.File) = .{},

/// We optimize memory usage for a compilation with no compile errors by storing the
/// error messages and mapping outside of `Decl`.
/// The ErrorMsg memory is owned by the decl, using Module's general purpose allocator.
/// Note that a Decl can succeed but the Fn it represents can fail. In this case,
/// a Decl can have a failed_decls entry but have analysis status of success.
failed_decls: std.AutoArrayHashMapUnmanaged(*Decl, *ErrorMsg) = .{},
/// Keep track of one `@compileLog` callsite per owner Decl.
/// The value is the AST node index offset from the Decl.
compile_log_decls: std.AutoArrayHashMapUnmanaged(*Decl, i32) = .{},
/// Using a map here for consistency with the other fields here.
/// The ErrorMsg memory is owned by the `Scope.File`, using Module's general purpose allocator.
failed_files: std.AutoArrayHashMapUnmanaged(*Scope.File, ?*ErrorMsg) = .{},
/// Using a map here for consistency with the other fields here.
/// The ErrorMsg memory is owned by the `Export`, using Module's general purpose allocator.
failed_exports: std.AutoArrayHashMapUnmanaged(*Export, *ErrorMsg) = .{},

next_anon_name_index: usize = 0,

/// Candidates for deletion. After a semantic analysis update completes, this list
/// contains Decls that need to be deleted if they end up having no references to them.
deletion_set: std.AutoArrayHashMapUnmanaged(*Decl, void) = .{},

/// Error tags and their values, tag names are duped with mod.gpa.
/// Corresponds with `error_name_list`.
global_error_set: std.StringHashMapUnmanaged(ErrorInt) = .{},

/// ErrorInt -> []const u8 for fast lookups for @intToError at comptime
/// Corresponds with `global_error_set`.
error_name_list: ArrayListUnmanaged([]const u8) = .{},

/// Incrementing integer used to compare against the corresponding Decl
/// field to determine whether a Decl's status applies to an ongoing update, or a
/// previous analysis.
generation: u32 = 0,

stage1_flags: packed struct {
    have_winmain: bool = false,
    have_wwinmain: bool = false,
    have_winmain_crt_startup: bool = false,
    have_wwinmain_crt_startup: bool = false,
    have_dllmain_crt_startup: bool = false,
    have_c_main: bool = false,
    reserved: u2 = 0,
} = .{},

job_queued_update_builtin_zig: bool = true,

compile_log_text: ArrayListUnmanaged(u8) = .{},

emit_h: ?*GlobalEmitH,

/// A `Module` has zero or one of these depending on whether `-femit-h` is enabled.
pub const GlobalEmitH = struct {
    /// Where to put the output.
    loc: Compilation.EmitLoc,
    /// When emit_h is non-null, each Decl gets one more compile error slot for
    /// emit-h failing for that Decl. This table is also how we tell if a Decl has
    /// failed emit-h or succeeded.
    failed_decls: std.AutoArrayHashMapUnmanaged(*Decl, *ErrorMsg) = .{},
    /// Tracks all decls in order to iterate over them and emit .h code for them.
    decl_table: std.AutoArrayHashMapUnmanaged(*Decl, void) = .{},
};

pub const ErrorInt = u32;

pub const Export = struct {
    options: std.builtin.ExportOptions,
    src: LazySrcLoc,
    /// Represents the position of the export, if any, in the output file.
    link: link.File.Export,
    /// The Decl that performs the export. Note that this is *not* the Decl being exported.
    owner_decl: *Decl,
    /// The Decl being exported. Note this is *not* the Decl performing the export.
    exported_decl: *Decl,
    status: enum {
        in_progress,
        failed,
        /// Indicates that the failure was due to a temporary issue, such as an I/O error
        /// when writing to the output file. Retrying the export may succeed.
        failed_retryable,
        complete,
    },

    pub fn getSrcLoc(exp: Export) SrcLoc {
        return .{
            .file_scope = exp.owner_decl.namespace.file_scope,
            .parent_decl_node = exp.owner_decl.src_node,
            .lazy = exp.src,
        };
    }
};

/// When Module emit_h field is non-null, each Decl is allocated via this struct, so that
/// there can be EmitH state attached to each Decl.
pub const DeclPlusEmitH = struct {
    decl: Decl,
    emit_h: EmitH,
};

pub const Decl = struct {
    /// Allocated with Module's allocator; outlives the ZIR code.
    name: [*:0]const u8,
    /// The most recent Type of the Decl after a successful semantic analysis.
    /// Populated when `has_tv`.
    ty: Type,
    /// The most recent Value of the Decl after a successful semantic analysis.
    /// Populated when `has_tv`.
    val: Value,
    /// Populated when `has_tv`.
    align_val: Value,
    /// Populated when `has_tv`.
    linksection_val: Value,
    /// The memory for ty, val, align_val, linksection_val.
    /// If this is `null` then there is no memory management needed.
    value_arena: ?*std.heap.ArenaAllocator.State = null,
    /// The direct parent namespace of the Decl.
    /// Reference to externally owned memory.
    /// In the case of the Decl corresponding to a file, this is
    /// the namespace of the struct, since there is no parent.
    namespace: *Scope.Namespace,

    /// An integer that can be checked against the corresponding incrementing
    /// generation field of Module. This is used to determine whether `complete` status
    /// represents pre- or post- re-analysis.
    generation: u32,
    /// The AST node index of this declaration.
    /// Must be recomputed when the corresponding source file is modified.
    src_node: ast.Node.Index,
    /// Line number corresponding to `src_node`. Stored separately so that source files
    /// do not need to be loaded into memory in order to compute debug line numbers.
    src_line: u32,
    /// Index to ZIR `extra` array to the entry in the parent's decl structure
    /// (the part that says "for every decls_len"). The first item at this index is
    /// the contents hash, followed by line, name, etc.
    /// For anonymous decls and also the root Decl for a File, this is 0.
    zir_decl_index: Zir.Inst.Index,

    /// Represents the "shallow" analysis status. For example, for decls that are functions,
    /// the function type is analyzed with this set to `in_progress`, however, the semantic
    /// analysis of the function body is performed with this value set to `success`. Functions
    /// have their own analysis status field.
    analysis: enum {
        /// This Decl corresponds to an AST Node that has not been referenced yet, and therefore
        /// because of Zig's lazy declaration analysis, it will remain unanalyzed until referenced.
        unreferenced,
        /// Semantic analysis for this Decl is running right now.
        /// This state detects dependency loops.
        in_progress,
        /// The file corresponding to this Decl had a parse error or ZIR error.
        /// There will be a corresponding ErrorMsg in Module.failed_files.
        file_failure,
        /// This Decl might be OK but it depends on another one which did not successfully complete
        /// semantic analysis.
        dependency_failure,
        /// Semantic analysis failure.
        /// There will be a corresponding ErrorMsg in Module.failed_decls.
        sema_failure,
        /// There will be a corresponding ErrorMsg in Module.failed_decls.
        /// This indicates the failure was something like running out of disk space,
        /// and attempting semantic analysis again may succeed.
        sema_failure_retryable,
        /// There will be a corresponding ErrorMsg in Module.failed_decls.
        codegen_failure,
        /// There will be a corresponding ErrorMsg in Module.failed_decls.
        /// This indicates the failure was something like running out of disk space,
        /// and attempting codegen again may succeed.
        codegen_failure_retryable,
        /// Everything is done. During an update, this Decl may be out of date, depending
        /// on its dependencies. The `generation` field can be used to determine if this
        /// completion status occurred before or after a given update.
        complete,
        /// A Module update is in progress, and this Decl has been flagged as being known
        /// to require re-analysis.
        outdated,
    },
    /// Whether `typed_value`, `align_val`, and `linksection_val` are populated.
    has_tv: bool,
    /// If `true` it means the `Decl` is the resource owner of the type/value associated
    /// with it. That means when `Decl` is destroyed, the cleanup code should additionally
    /// check if the value owns a `Namespace`, and destroy that too.
    owns_tv: bool,
    /// This flag is set when this Decl is added to `Module.deletion_set`, and cleared
    /// when removed.
    deletion_flag: bool,
    /// Whether the corresponding AST decl has a `pub` keyword.
    is_pub: bool,
    /// Whether the corresponding AST decl has a `export` keyword.
    is_exported: bool,
    /// Whether the ZIR code provides an align instruction.
    has_align: bool,
    /// Whether the ZIR code provides a linksection instruction.
    has_linksection: bool,

    /// Represents the position of the code in the output file.
    /// This is populated regardless of semantic analysis and code generation.
    link: link.File.LinkBlock,

    /// Represents the function in the linked output file, if the `Decl` is a function.
    /// This is stored here and not in `Fn` because `Decl` survives across updates but
    /// `Fn` does not.
    /// TODO Look into making `Fn` a longer lived structure and moving this field there
    /// to save on memory usage.
    fn_link: link.File.LinkFn,

    /// The shallow set of other decls whose typed_value could possibly change if this Decl's
    /// typed_value is modified.
    dependants: DepsTable = .{},
    /// The shallow set of other decls whose typed_value changing indicates that this Decl's
    /// typed_value may need to be regenerated.
    dependencies: DepsTable = .{},

    pub const DepsTable = std.AutoArrayHashMapUnmanaged(*Decl, void);

    pub fn clearName(decl: *Decl, gpa: *Allocator) void {
        gpa.free(mem.spanZ(decl.name));
        decl.name = undefined;
    }

    pub fn destroy(decl: *Decl, module: *Module) void {
        const gpa = module.gpa;
        log.debug("destroy {*} ({s})", .{ decl, decl.name });
        if (decl.deletion_flag) {
            assert(module.deletion_set.swapRemove(decl));
        }
        if (decl.has_tv) {
            if (decl.getInnerNamespace()) |namespace| {
                namespace.destroyDecls(module);
            }
            decl.clearValues(gpa);
        }
        decl.dependants.deinit(gpa);
        decl.dependencies.deinit(gpa);
        decl.clearName(gpa);
        if (module.emit_h != null) {
            const decl_plus_emit_h = @fieldParentPtr(DeclPlusEmitH, "decl", decl);
            decl_plus_emit_h.emit_h.fwd_decl.deinit(gpa);
            gpa.destroy(decl_plus_emit_h);
        } else {
            gpa.destroy(decl);
        }
    }

    pub fn clearValues(decl: *Decl, gpa: *Allocator) void {
        if (decl.getFunction()) |func| {
            func.deinit(gpa);
            gpa.destroy(func);
        }
        if (decl.getVariable()) |variable| {
            gpa.destroy(variable);
        }
        if (decl.value_arena) |arena_state| {
            arena_state.promote(gpa).deinit();
            decl.value_arena = null;
            decl.has_tv = false;
            decl.owns_tv = false;
        }
    }

    pub fn finalizeNewArena(decl: *Decl, arena: *std.heap.ArenaAllocator) !void {
        assert(decl.value_arena == null);
        const arena_state = try arena.allocator.create(std.heap.ArenaAllocator.State);
        arena_state.* = arena.state;
        decl.value_arena = arena_state;
    }

    /// This name is relative to the containing namespace of the decl.
    /// The memory is owned by the containing File ZIR.
    pub fn getName(decl: Decl) ?[:0]const u8 {
        const zir = decl.namespace.file_scope.zir;
        return decl.getNameZir(zir);
    }

    pub fn getNameZir(decl: Decl, zir: Zir) ?[:0]const u8 {
        assert(decl.zir_decl_index != 0);
        const name_index = zir.extra[decl.zir_decl_index + 5];
        if (name_index <= 1) return null;
        return zir.nullTerminatedString(name_index);
    }

    pub fn contentsHash(decl: Decl) std.zig.SrcHash {
        const zir = decl.namespace.file_scope.zir;
        return decl.contentsHashZir(zir);
    }

    pub fn contentsHashZir(decl: Decl, zir: Zir) std.zig.SrcHash {
        assert(decl.zir_decl_index != 0);
        const hash_u32s = zir.extra[decl.zir_decl_index..][0..4];
        const contents_hash = @bitCast(std.zig.SrcHash, hash_u32s.*);
        return contents_hash;
    }

    pub fn zirBlockIndex(decl: *const Decl) Zir.Inst.Index {
        assert(decl.zir_decl_index != 0);
        const zir = decl.namespace.file_scope.zir;
        return zir.extra[decl.zir_decl_index + 6];
    }

    pub fn zirAlignRef(decl: Decl) Zir.Inst.Ref {
        if (!decl.has_align) return .none;
        assert(decl.zir_decl_index != 0);
        const zir = decl.namespace.file_scope.zir;
        return @intToEnum(Zir.Inst.Ref, zir.extra[decl.zir_decl_index + 6]);
    }

    pub fn zirLinksectionRef(decl: Decl) Zir.Inst.Ref {
        if (!decl.has_linksection) return .none;
        assert(decl.zir_decl_index != 0);
        const zir = decl.namespace.file_scope.zir;
        const extra_index = decl.zir_decl_index + 6 + @boolToInt(decl.has_align);
        return @intToEnum(Zir.Inst.Ref, zir.extra[extra_index]);
    }

    /// Returns true if and only if the Decl is the top level struct associated with a File.
    pub fn isRoot(decl: *const Decl) bool {
        if (decl.namespace.parent != null)
            return false;
        return decl == decl.namespace.ty.getOwnerDecl();
    }

    pub fn relativeToLine(decl: Decl, offset: u32) u32 {
        return decl.src_line + offset;
    }

    pub fn relativeToNodeIndex(decl: Decl, offset: i32) ast.Node.Index {
        return @bitCast(ast.Node.Index, offset + @bitCast(i32, decl.src_node));
    }

    pub fn nodeIndexToRelative(decl: Decl, node_index: ast.Node.Index) i32 {
        return @bitCast(i32, node_index) - @bitCast(i32, decl.src_node);
    }

    pub fn tokSrcLoc(decl: Decl, token_index: ast.TokenIndex) LazySrcLoc {
        return .{ .token_offset = token_index - decl.srcToken() };
    }

    pub fn nodeSrcLoc(decl: Decl, node_index: ast.Node.Index) LazySrcLoc {
        return .{ .node_offset = decl.nodeIndexToRelative(node_index) };
    }

    pub fn srcLoc(decl: Decl) SrcLoc {
        return decl.nodeOffsetSrcLoc(0);
    }

    pub fn nodeOffsetSrcLoc(decl: Decl, node_offset: i32) SrcLoc {
        return .{
            .file_scope = decl.getFileScope(),
            .parent_decl_node = decl.src_node,
            .lazy = .{ .node_offset = node_offset },
        };
    }

    pub fn srcToken(decl: Decl) ast.TokenIndex {
        const tree = &decl.namespace.file_scope.tree;
        return tree.firstToken(decl.src_node);
    }

    pub fn srcByteOffset(decl: Decl) u32 {
        const tree = &decl.namespace.file_scope.tree;
        return tree.tokens.items(.start)[decl.srcToken()];
    }

    pub fn renderFullyQualifiedName(decl: Decl, writer: anytype) !void {
        const unqualified_name = mem.spanZ(decl.name);
        return decl.namespace.renderFullyQualifiedName(unqualified_name, writer);
    }

    pub fn getFullyQualifiedName(decl: Decl, gpa: *Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(gpa);
        defer buffer.deinit();
        try decl.renderFullyQualifiedName(buffer.writer());
        return buffer.toOwnedSlice();
    }

    pub fn typedValue(decl: Decl) error{AnalysisFail}!TypedValue {
        if (!decl.has_tv) return error.AnalysisFail;
        return TypedValue{
            .ty = decl.ty,
            .val = decl.val,
        };
    }

    pub fn value(decl: *Decl) error{AnalysisFail}!Value {
        return (try decl.typedValue()).val;
    }

    pub fn isFunction(decl: *Decl) !bool {
        const tv = try decl.typedValue();
        return tv.ty.zigTypeTag() == .Fn;
    }

    /// If the Decl has a value and it is a struct, return it,
    /// otherwise null.
    pub fn getStruct(decl: *Decl) ?*Struct {
        if (!decl.owns_tv) return null;
        const ty = (decl.val.castTag(.ty) orelse return null).data;
        const struct_obj = (ty.castTag(.@"struct") orelse return null).data;
        assert(struct_obj.owner_decl == decl);
        return struct_obj;
    }

    /// If the Decl has a value and it is a union, return it,
    /// otherwise null.
    pub fn getUnion(decl: *Decl) ?*Union {
        if (!decl.owns_tv) return null;
        const ty = (decl.val.castTag(.ty) orelse return null).data;
        const union_obj = (ty.cast(Type.Payload.Union) orelse return null).data;
        assert(union_obj.owner_decl == decl);
        return union_obj;
    }

    /// If the Decl has a value and it is a function, return it,
    /// otherwise null.
    pub fn getFunction(decl: *Decl) ?*Fn {
        if (!decl.owns_tv) return null;
        const func = (decl.val.castTag(.function) orelse return null).data;
        assert(func.owner_decl == decl);
        return func;
    }

    pub fn getVariable(decl: *Decl) ?*Var {
        if (!decl.owns_tv) return null;
        const variable = (decl.val.castTag(.variable) orelse return null).data;
        assert(variable.owner_decl == decl);
        return variable;
    }

    /// Gets the namespace that this Decl creates by being a struct, union,
    /// enum, or opaque.
    /// Only returns it if the Decl is the owner.
    pub fn getInnerNamespace(decl: *Decl) ?*Scope.Namespace {
        if (!decl.owns_tv) return null;
        const ty = (decl.val.castTag(.ty) orelse return null).data;
        switch (ty.tag()) {
            .@"struct" => {
                const struct_obj = ty.castTag(.@"struct").?.data;
                assert(struct_obj.owner_decl == decl);
                return &struct_obj.namespace;
            },
            .enum_full => {
                const enum_obj = ty.castTag(.enum_full).?.data;
                assert(enum_obj.owner_decl == decl);
                return &enum_obj.namespace;
            },
            .empty_struct => {
                return ty.castTag(.empty_struct).?.data;
            },
            .@"opaque" => {
                @panic("TODO opaque types");
            },
            .@"union", .union_tagged => {
                const union_obj = ty.cast(Type.Payload.Union).?.data;
                assert(union_obj.owner_decl == decl);
                return &union_obj.namespace;
            },

            else => return null,
        }
    }

    pub fn dump(decl: *Decl) void {
        const loc = std.zig.findLineColumn(decl.scope.source.bytes, decl.src);
        std.debug.print("{s}:{d}:{d} name={s} status={s}", .{
            decl.scope.sub_file_path,
            loc.line + 1,
            loc.column + 1,
            mem.spanZ(decl.name),
            @tagName(decl.analysis),
        });
        if (decl.has_tv) {
            std.debug.print(" ty={} val={}", .{ decl.ty, decl.val });
        }
        std.debug.print("\n", .{});
    }

    pub fn getFileScope(decl: Decl) *Scope.File {
        return decl.namespace.file_scope;
    }

    pub fn getEmitH(decl: *Decl, module: *Module) *EmitH {
        assert(module.emit_h != null);
        const decl_plus_emit_h = @fieldParentPtr(DeclPlusEmitH, "decl", decl);
        return &decl_plus_emit_h.emit_h;
    }

    fn removeDependant(decl: *Decl, other: *Decl) void {
        assert(decl.dependants.swapRemove(other));
    }

    fn removeDependency(decl: *Decl, other: *Decl) void {
        assert(decl.dependencies.swapRemove(other));
    }
};

/// This state is attached to every Decl when Module emit_h is non-null.
pub const EmitH = struct {
    fwd_decl: ArrayListUnmanaged(u8) = .{},
};

/// Represents the data that an explicit error set syntax provides.
pub const ErrorSet = struct {
    /// The Decl that corresponds to the error set itself.
    owner_decl: *Decl,
    /// Offset from Decl node index, points to the error set AST node.
    node_offset: i32,
    names_len: u32,
    /// The string bytes are stored in the owner Decl arena.
    /// They are in the same order they appear in the AST.
    /// The length is given by `names_len`.
    names_ptr: [*]const []const u8,

    pub fn srcLoc(self: ErrorSet) SrcLoc {
        return .{
            .file_scope = self.owner_decl.getFileScope(),
            .parent_decl_node = self.owner_decl.src_node,
            .lazy = .{ .node_offset = self.node_offset },
        };
    }
};

/// Represents the data that a struct declaration provides.
pub const Struct = struct {
    /// The Decl that corresponds to the struct itself.
    owner_decl: *Decl,
    /// Set of field names in declaration order.
    fields: std.StringArrayHashMapUnmanaged(Field),
    /// Represents the declarations inside this struct.
    namespace: Scope.Namespace,
    /// Offset from `owner_decl`, points to the struct AST node.
    node_offset: i32,
    /// Index of the struct_decl ZIR instruction.
    zir_index: Zir.Inst.Index,

    layout: std.builtin.TypeInfo.ContainerLayout,
    status: enum {
        none,
        field_types_wip,
        have_field_types,
        layout_wip,
        have_layout,
    },

    pub const Field = struct {
        /// Uses `noreturn` to indicate `anytype`.
        /// undefined until `status` is `have_field_types` or `have_layout`.
        ty: Type,
        abi_align: Value,
        /// Uses `unreachable_value` to indicate no default.
        default_val: Value,
        /// undefined until `status` is `have_layout`.
        offset: u32,
        is_comptime: bool,
    };

    pub fn getFullyQualifiedName(s: *Struct, gpa: *Allocator) ![]u8 {
        return s.owner_decl.getFullyQualifiedName(gpa);
    }

    pub fn srcLoc(s: Struct) SrcLoc {
        return .{
            .file_scope = s.owner_decl.getFileScope(),
            .parent_decl_node = s.owner_decl.src_node,
            .lazy = .{ .node_offset = s.node_offset },
        };
    }

    pub fn haveFieldTypes(s: Struct) bool {
        return switch (s.status) {
            .none,
            .field_types_wip,
            => false,
            .have_field_types,
            .layout_wip,
            .have_layout,
            => true,
        };
    }
};

/// Represents the data that an enum declaration provides, when the fields
/// are auto-numbered, and there are no declarations. The integer tag type
/// is inferred to be the smallest power of two unsigned int that fits
/// the number of fields.
pub const EnumSimple = struct {
    /// The Decl that corresponds to the enum itself.
    owner_decl: *Decl,
    /// Set of field names in declaration order.
    fields: std.StringArrayHashMapUnmanaged(void),
    /// Offset from `owner_decl`, points to the enum decl AST node.
    node_offset: i32,

    pub fn srcLoc(self: EnumSimple) SrcLoc {
        return .{
            .file_scope = self.owner_decl.getFileScope(),
            .parent_decl_node = self.owner_decl.src_node,
            .lazy = .{ .node_offset = self.node_offset },
        };
    }
};

/// Represents the data that an enum declaration provides, when there is
/// at least one tag value explicitly specified, or at least one declaration.
pub const EnumFull = struct {
    /// The Decl that corresponds to the enum itself.
    owner_decl: *Decl,
    /// An integer type which is used for the numerical value of the enum.
    /// Whether zig chooses this type or the user specifies it, it is stored here.
    tag_ty: Type,
    /// Set of field names in declaration order.
    fields: std.StringArrayHashMapUnmanaged(void),
    /// Maps integer tag value to field index.
    /// Entries are in declaration order, same as `fields`.
    /// If this hash map is empty, it means the enum tags are auto-numbered.
    values: ValueMap,
    /// Represents the declarations inside this struct.
    namespace: Scope.Namespace,
    /// Offset from `owner_decl`, points to the enum decl AST node.
    node_offset: i32,

    pub const ValueMap = std.ArrayHashMapUnmanaged(Value, void, Value.ArrayHashContext, false);

    pub fn srcLoc(self: EnumFull) SrcLoc {
        return .{
            .file_scope = self.owner_decl.getFileScope(),
            .parent_decl_node = self.owner_decl.src_node,
            .lazy = .{ .node_offset = self.node_offset },
        };
    }
};

pub const Union = struct {
    /// The Decl that corresponds to the union itself.
    owner_decl: *Decl,
    /// An enum type which is used for the tag of the union.
    /// This type is created even for untagged unions, even when the memory
    /// layout does not store the tag.
    /// Whether zig chooses this type or the user specifies it, it is stored here.
    /// This will be set to the null type until status is `have_field_types`.
    tag_ty: Type,
    /// Set of field names in declaration order.
    fields: std.StringArrayHashMapUnmanaged(Field),
    /// Represents the declarations inside this union.
    namespace: Scope.Namespace,
    /// Offset from `owner_decl`, points to the union decl AST node.
    node_offset: i32,
    /// Index of the union_decl ZIR instruction.
    zir_index: Zir.Inst.Index,

    layout: std.builtin.TypeInfo.ContainerLayout,
    status: enum {
        none,
        field_types_wip,
        have_field_types,
        layout_wip,
        have_layout,
    },

    pub const Field = struct {
        /// undefined until `status` is `have_field_types` or `have_layout`.
        ty: Type,
        abi_align: Value,
    };

    pub fn getFullyQualifiedName(s: *Union, gpa: *Allocator) ![]u8 {
        return s.owner_decl.getFullyQualifiedName(gpa);
    }

    pub fn srcLoc(self: Union) SrcLoc {
        return .{
            .file_scope = self.owner_decl.getFileScope(),
            .parent_decl_node = self.owner_decl.src_node,
            .lazy = .{ .node_offset = self.node_offset },
        };
    }
};

/// Some Fn struct memory is owned by the Decl's TypedValue.Managed arena allocator.
/// Extern functions do not have this data structure; they are represented by
/// the `Decl` only, with a `Value` tag of `extern_fn`.
pub const Fn = struct {
    /// The Decl that corresponds to the function itself.
    owner_decl: *Decl,
    /// undefined unless analysis state is `success`.
    body: ir.Body,
    /// The ZIR instruction that is a function instruction. Use this to find
    /// the body. We store this rather than the body directly so that when ZIR
    /// is regenerated on update(), we can map this to the new corresponding
    /// ZIR instruction.
    zir_body_inst: Zir.Inst.Index,

    /// Relative to owner Decl.
    lbrace_line: u32,
    /// Relative to owner Decl.
    rbrace_line: u32,
    lbrace_column: u16,
    rbrace_column: u16,

    state: Analysis,
    is_cold: bool = false,

    pub const Analysis = enum {
        queued,
        /// This function intentionally only has ZIR generated because it is marked
        /// inline, which means no runtime version of the function will be generated.
        inline_only,
        in_progress,
        /// There will be a corresponding ErrorMsg in Module.failed_decls
        sema_failure,
        /// This Fn might be OK but it depends on another Decl which did not
        /// successfully complete semantic analysis.
        dependency_failure,
        success,
    };

    /// For debugging purposes.
    pub fn dump(func: *Fn, mod: Module) void {
        ir.dumpFn(mod, func);
    }

    pub fn deinit(func: *Fn, gpa: *Allocator) void {
        if (func.getInferredErrorSet()) |map| {
            map.deinit(gpa);
        }
    }

    pub fn getInferredErrorSet(func: *Fn) ?*std.StringHashMapUnmanaged(void) {
        const ret_ty = func.owner_decl.ty.fnReturnType();
        if (ret_ty.zigTypeTag() == .ErrorUnion) {
            if (ret_ty.errorUnionSet().castTag(.error_set_inferred)) |payload| {
                return &payload.data.map;
            }
        }
        return null;
    }
};

pub const Var = struct {
    /// if is_extern == true this is undefined
    init: Value,
    owner_decl: *Decl,

    is_extern: bool,
    is_mutable: bool,
    is_threadlocal: bool,
};

pub const Scope = struct {
    tag: Tag,

    pub fn cast(base: *Scope, comptime T: type) ?*T {
        if (base.tag != T.base_tag)
            return null;

        return @fieldParentPtr(T, "base", base);
    }

    pub fn ownerDecl(scope: *Scope) ?*Decl {
        return switch (scope.tag) {
            .block => scope.cast(Block).?.sema.owner_decl,
            .file => null,
            .namespace => null,
        };
    }

    pub fn srcDecl(scope: *Scope) ?*Decl {
        return switch (scope.tag) {
            .block => scope.cast(Block).?.src_decl,
            .file => null,
            .namespace => scope.cast(Namespace).?.getDecl(),
        };
    }

    /// Asserts the scope has a parent which is a Namespace and returns it.
    pub fn namespace(scope: *Scope) *Namespace {
        switch (scope.tag) {
            .block => return scope.cast(Block).?.sema.owner_decl.namespace,
            .file => return scope.cast(File).?.root_decl.?.namespace,
            .namespace => return scope.cast(Namespace).?,
        }
    }

    /// Asserts the scope has a parent which is a Namespace or File and
    /// returns the sub_file_path field.
    pub fn subFilePath(base: *Scope) []const u8 {
        switch (base.tag) {
            .namespace => return @fieldParentPtr(Namespace, "base", base).file_scope.sub_file_path,
            .file => return @fieldParentPtr(File, "base", base).sub_file_path,
            .block => unreachable,
        }
    }

    /// When called from inside a Block Scope, chases the src_decl, not the owner_decl.
    pub fn getFileScope(base: *Scope) *Scope.File {
        var cur = base;
        while (true) {
            cur = switch (cur.tag) {
                .namespace => return @fieldParentPtr(Namespace, "base", cur).file_scope,
                .file => return @fieldParentPtr(File, "base", cur),
                .block => return @fieldParentPtr(Block, "base", cur).src_decl.namespace.file_scope,
            };
        }
    }

    pub const Tag = enum {
        /// .zig source code.
        file,
        /// Namespace owned by structs, enums, unions, and opaques for decls.
        namespace,
        block,
    };

    /// The container that structs, enums, unions, and opaques have.
    pub const Namespace = struct {
        pub const base_tag: Tag = .namespace;
        base: Scope = Scope{ .tag = base_tag },

        parent: ?*Namespace,
        file_scope: *Scope.File,
        /// Will be a struct, enum, union, or opaque.
        ty: Type,
        /// Direct children of the namespace. Used during an update to detect
        /// which decls have been added/removed from source.
        /// Declaration order is preserved via entry order.
        /// Key memory is owned by `decl.name`.
        /// TODO save memory with https://github.com/ziglang/zig/issues/8619.
        /// Anonymous decls are not stored here; they are kept in `anon_decls` instead.
        decls: std.StringArrayHashMapUnmanaged(*Decl) = .{},

        anon_decls: std.AutoArrayHashMapUnmanaged(*Decl, void) = .{},

        pub fn deinit(ns: *Namespace, mod: *Module) void {
            ns.destroyDecls(mod);
            ns.* = undefined;
        }

        pub fn destroyDecls(ns: *Namespace, mod: *Module) void {
            const gpa = mod.gpa;

            log.debug("destroyDecls {*}", .{ns});

            var decls = ns.decls;
            ns.decls = .{};

            var anon_decls = ns.anon_decls;
            ns.anon_decls = .{};

            for (decls.values()) |value| {
                value.destroy(mod);
            }
            decls.deinit(gpa);

            for (anon_decls.keys()) |key| {
                key.destroy(mod);
            }
            anon_decls.deinit(gpa);
        }

        pub fn deleteAllDecls(
            ns: *Namespace,
            mod: *Module,
            outdated_decls: ?*std.AutoArrayHashMap(*Decl, void),
        ) !void {
            const gpa = mod.gpa;

            log.debug("deleteAllDecls {*}", .{ns});

            var decls = ns.decls;
            ns.decls = .{};

            var anon_decls = ns.anon_decls;
            ns.anon_decls = .{};

            // TODO rework this code to not panic on OOM.
            // (might want to coordinate with the clearDecl function)

            for (decls.values()) |child_decl| {
                mod.clearDecl(child_decl, outdated_decls) catch @panic("out of memory");
                child_decl.destroy(mod);
            }
            decls.deinit(gpa);

            for (anon_decls.keys()) |child_decl| {
                mod.clearDecl(child_decl, outdated_decls) catch @panic("out of memory");
                child_decl.destroy(mod);
            }
            anon_decls.deinit(gpa);
        }

        // This renders e.g. "std.fs.Dir.OpenOptions"
        pub fn renderFullyQualifiedName(
            ns: Namespace,
            name: []const u8,
            writer: anytype,
        ) @TypeOf(writer).Error!void {
            if (ns.parent) |parent| {
                const decl = ns.getDecl();
                try parent.renderFullyQualifiedName(mem.spanZ(decl.name), writer);
            } else {
                try ns.file_scope.renderFullyQualifiedName(writer);
            }
            if (name.len != 0) {
                try writer.writeAll(".");
                try writer.writeAll(name);
            }
        }

        pub fn getDecl(ns: Namespace) *Decl {
            return ns.ty.getOwnerDecl();
        }
    };

    pub const File = struct {
        pub const base_tag: Tag = .file;
        base: Scope = Scope{ .tag = base_tag },
        status: enum {
            never_loaded,
            retryable_failure,
            parse_failure,
            astgen_failure,
            success_zir,
        },
        source_loaded: bool,
        tree_loaded: bool,
        zir_loaded: bool,
        /// Relative to the owning package's root_src_dir.
        /// Memory is stored in gpa, owned by File.
        sub_file_path: []const u8,
        /// Whether this is populated depends on `source_loaded`.
        source: [:0]const u8,
        /// Whether this is populated depends on `status`.
        stat_size: u64,
        /// Whether this is populated depends on `status`.
        stat_inode: std.fs.File.INode,
        /// Whether this is populated depends on `status`.
        stat_mtime: i128,
        /// Whether this is populated or not depends on `tree_loaded`.
        tree: ast.Tree,
        /// Whether this is populated or not depends on `zir_loaded`.
        zir: Zir,
        /// Package that this file is a part of, managed externally.
        pkg: *Package,
        /// The Decl of the struct that represents this File.
        root_decl: ?*Decl,

        /// Used by change detection algorithm, after astgen, contains the
        /// set of decls that existed in the previous ZIR but not in the new one.
        deleted_decls: std.ArrayListUnmanaged(*Decl) = .{},
        /// Used by change detection algorithm, after astgen, contains the
        /// set of decls that existed both in the previous ZIR and in the new one,
        /// but their source code has been modified.
        outdated_decls: std.ArrayListUnmanaged(*Decl) = .{},

        /// The most recent successful ZIR for this file, with no errors.
        /// This is only populated when a previously successful ZIR
        /// newly introduces compile errors during an update. When ZIR is
        /// successful, this field is unloaded.
        prev_zir: ?*Zir = null,

        pub fn unload(file: *File, gpa: *Allocator) void {
            file.unloadTree(gpa);
            file.unloadSource(gpa);
            file.unloadZir(gpa);
        }

        pub fn unloadTree(file: *File, gpa: *Allocator) void {
            if (file.tree_loaded) {
                file.tree_loaded = false;
                file.tree.deinit(gpa);
            }
        }

        pub fn unloadSource(file: *File, gpa: *Allocator) void {
            if (file.source_loaded) {
                file.source_loaded = false;
                gpa.free(file.source);
            }
        }

        pub fn unloadZir(file: *File, gpa: *Allocator) void {
            if (file.zir_loaded) {
                file.zir_loaded = false;
                file.zir.deinit(gpa);
            }
        }

        pub fn deinit(file: *File, mod: *Module) void {
            const gpa = mod.gpa;
            log.debug("deinit File {s}", .{file.sub_file_path});
            file.deleted_decls.deinit(gpa);
            file.outdated_decls.deinit(gpa);
            if (file.root_decl) |root_decl| {
                root_decl.destroy(mod);
            }
            gpa.free(file.sub_file_path);
            file.unload(gpa);
            if (file.prev_zir) |prev_zir| {
                prev_zir.deinit(gpa);
                gpa.destroy(prev_zir);
            }
            file.* = undefined;
        }

        pub fn getSource(file: *File, gpa: *Allocator) ![:0]const u8 {
            if (file.source_loaded) return file.source;

            const root_dir_path = file.pkg.root_src_directory.path orelse ".";
            log.debug("File.getSource, not cached. pkgdir={s} sub_file_path={s}", .{
                root_dir_path, file.sub_file_path,
            });

            // Keep track of inode, file size, mtime, hash so we can detect which files
            // have been modified when an incremental update is requested.
            var f = try file.pkg.root_src_directory.handle.openFile(file.sub_file_path, .{});
            defer f.close();

            const stat = try f.stat();

            if (stat.size > std.math.maxInt(u32))
                return error.FileTooBig;

            const source = try gpa.allocSentinel(u8, @intCast(usize, stat.size), 0);
            defer if (!file.source_loaded) gpa.free(source);
            const amt = try f.readAll(source);
            if (amt != stat.size)
                return error.UnexpectedEndOfFile;

            // Here we do not modify stat fields because this function is the one
            // used for error reporting. We need to keep the stat fields stale so that
            // astGenFile can know to regenerate ZIR.

            file.source = source;
            file.source_loaded = true;
            return source;
        }

        pub fn getTree(file: *File, gpa: *Allocator) !*const ast.Tree {
            if (file.tree_loaded) return &file.tree;

            const source = try file.getSource(gpa);
            file.tree = try std.zig.parse(gpa, source);
            file.tree_loaded = true;
            return &file.tree;
        }

        pub fn destroy(file: *File, mod: *Module) void {
            const gpa = mod.gpa;
            file.deinit(mod);
            gpa.destroy(file);
        }

        pub fn renderFullyQualifiedName(file: File, writer: anytype) !void {
            // Convert all the slashes into dots and truncate the extension.
            const ext = std.fs.path.extension(file.sub_file_path);
            const noext = file.sub_file_path[0 .. file.sub_file_path.len - ext.len];
            for (noext) |byte| switch (byte) {
                '/', '\\' => try writer.writeByte('.'),
                else => try writer.writeByte(byte),
            };
        }

        pub fn fullyQualifiedNameZ(file: File, gpa: *Allocator) ![:0]u8 {
            var buf = std.ArrayList(u8).init(gpa);
            defer buf.deinit();
            try file.renderFullyQualifiedName(buf.writer());
            return buf.toOwnedSliceSentinel(0);
        }

        /// Returns the full path to this file relative to its package.
        pub fn fullPath(file: File, ally: *Allocator) ![]u8 {
            return file.pkg.root_src_directory.join(ally, &[_][]const u8{file.sub_file_path});
        }

        pub fn dumpSrc(file: *File, src: LazySrcLoc) void {
            const loc = std.zig.findLineColumn(file.source.bytes, src);
            std.debug.print("{s}:{d}:{d}\n", .{ file.sub_file_path, loc.line + 1, loc.column + 1 });
        }

        pub fn okToReportErrors(file: File) bool {
            return switch (file.status) {
                .parse_failure, .astgen_failure => false,
                else => true,
            };
        }
    };

    /// This is the context needed to semantically analyze ZIR instructions and
    /// produce AIR instructions.
    /// This is a temporary structure stored on the stack; references to it are valid only
    /// during semantic analysis of the block.
    pub const Block = struct {
        pub const base_tag: Tag = .block;

        base: Scope = Scope{ .tag = base_tag },
        parent: ?*Block,
        /// Shared among all child blocks.
        sema: *Sema,
        /// This Decl is the Decl according to the Zig source code corresponding to this Block.
        /// This can vary during inline or comptime function calls. See `Sema.owner_decl`
        /// for the one that will be the same for all Block instances.
        src_decl: *Decl,
        instructions: ArrayListUnmanaged(*ir.Inst),
        label: ?*Label = null,
        inlining: ?*Inlining,
        /// If runtime_index is not 0 then one of these is guaranteed to be non null.
        runtime_cond: ?LazySrcLoc = null,
        runtime_loop: ?LazySrcLoc = null,
        /// Non zero if a non-inline loop or a runtime conditional have been encountered.
        /// Stores to to comptime variables are only allowed when var.runtime_index <= runtime_index.
        runtime_index: u32 = 0,

        is_comptime: bool,

        /// when null, it is determined by build mode, changed by @setRuntimeSafety
        want_safety: ?bool = null,

        /// This `Block` maps a block ZIR instruction to the corresponding
        /// AIR instruction for break instruction analysis.
        pub const Label = struct {
            zir_block: Zir.Inst.Index,
            merges: Merges,
        };

        /// This `Block` indicates that an inline function call is happening
        /// and return instructions should be analyzed as a break instruction
        /// to this AIR block instruction.
        /// It is shared among all the blocks in an inline or comptime called
        /// function.
        pub const Inlining = struct {
            merges: Merges,
        };

        pub const Merges = struct {
            block_inst: *ir.Inst.Block,
            /// Separate array list from break_inst_list so that it can be passed directly
            /// to resolvePeerTypes.
            results: ArrayListUnmanaged(*ir.Inst),
            /// Keeps track of the break instructions so that the operand can be replaced
            /// if we need to add type coercion at the end of block analysis.
            /// Same indexes, capacity, length as `results`.
            br_list: ArrayListUnmanaged(*ir.Inst.Br),
        };

        /// For debugging purposes.
        pub fn dump(block: *Block, mod: Module) void {
            Zir.dumpBlock(mod, block);
        }

        pub fn makeSubBlock(parent: *Block) Block {
            return .{
                .parent = parent,
                .sema = parent.sema,
                .src_decl = parent.src_decl,
                .instructions = .{},
                .label = null,
                .inlining = parent.inlining,
                .is_comptime = parent.is_comptime,
                .runtime_cond = parent.runtime_cond,
                .runtime_loop = parent.runtime_loop,
                .runtime_index = parent.runtime_index,
                .want_safety = parent.want_safety,
            };
        }

        pub fn wantSafety(block: *const Block) bool {
            return block.want_safety orelse switch (block.sema.mod.optimizeMode()) {
                .Debug => true,
                .ReleaseSafe => true,
                .ReleaseFast => false,
                .ReleaseSmall => false,
            };
        }

        pub fn getFileScope(block: *Block) *Scope.File {
            return block.src_decl.namespace.file_scope;
        }

        pub fn addNoOp(
            block: *Scope.Block,
            src: LazySrcLoc,
            ty: Type,
            comptime tag: ir.Inst.Tag,
        ) !*ir.Inst {
            const inst = try block.sema.arena.create(tag.Type());
            inst.* = .{
                .base = .{
                    .tag = tag,
                    .ty = ty,
                    .src = src,
                },
            };
            try block.instructions.append(block.sema.gpa, &inst.base);
            return &inst.base;
        }

        pub fn addUnOp(
            block: *Scope.Block,
            src: LazySrcLoc,
            ty: Type,
            tag: ir.Inst.Tag,
            operand: *ir.Inst,
        ) !*ir.Inst {
            const inst = try block.sema.arena.create(ir.Inst.UnOp);
            inst.* = .{
                .base = .{
                    .tag = tag,
                    .ty = ty,
                    .src = src,
                },
                .operand = operand,
            };
            try block.instructions.append(block.sema.gpa, &inst.base);
            return &inst.base;
        }

        pub fn addBinOp(
            block: *Scope.Block,
            src: LazySrcLoc,
            ty: Type,
            tag: ir.Inst.Tag,
            lhs: *ir.Inst,
            rhs: *ir.Inst,
        ) !*ir.Inst {
            const inst = try block.sema.arena.create(ir.Inst.BinOp);
            inst.* = .{
                .base = .{
                    .tag = tag,
                    .ty = ty,
                    .src = src,
                },
                .lhs = lhs,
                .rhs = rhs,
            };
            try block.instructions.append(block.sema.gpa, &inst.base);
            return &inst.base;
        }

        pub fn addBr(
            scope_block: *Scope.Block,
            src: LazySrcLoc,
            target_block: *ir.Inst.Block,
            operand: *ir.Inst,
        ) !*ir.Inst.Br {
            const inst = try scope_block.sema.arena.create(ir.Inst.Br);
            inst.* = .{
                .base = .{
                    .tag = .br,
                    .ty = Type.initTag(.noreturn),
                    .src = src,
                },
                .operand = operand,
                .block = target_block,
            };
            try scope_block.instructions.append(scope_block.sema.gpa, &inst.base);
            return inst;
        }

        pub fn addCondBr(
            block: *Scope.Block,
            src: LazySrcLoc,
            condition: *ir.Inst,
            then_body: ir.Body,
            else_body: ir.Body,
        ) !*ir.Inst {
            const inst = try block.sema.arena.create(ir.Inst.CondBr);
            inst.* = .{
                .base = .{
                    .tag = .condbr,
                    .ty = Type.initTag(.noreturn),
                    .src = src,
                },
                .condition = condition,
                .then_body = then_body,
                .else_body = else_body,
            };
            try block.instructions.append(block.sema.gpa, &inst.base);
            return &inst.base;
        }

        pub fn addCall(
            block: *Scope.Block,
            src: LazySrcLoc,
            ty: Type,
            func: *ir.Inst,
            args: []const *ir.Inst,
        ) !*ir.Inst {
            const inst = try block.sema.arena.create(ir.Inst.Call);
            inst.* = .{
                .base = .{
                    .tag = .call,
                    .ty = ty,
                    .src = src,
                },
                .func = func,
                .args = args,
            };
            try block.instructions.append(block.sema.gpa, &inst.base);
            return &inst.base;
        }

        pub fn addSwitchBr(
            block: *Scope.Block,
            src: LazySrcLoc,
            operand: *ir.Inst,
            cases: []ir.Inst.SwitchBr.Case,
            else_body: ir.Body,
        ) !*ir.Inst {
            const inst = try block.sema.arena.create(ir.Inst.SwitchBr);
            inst.* = .{
                .base = .{
                    .tag = .switchbr,
                    .ty = Type.initTag(.noreturn),
                    .src = src,
                },
                .target = operand,
                .cases = cases,
                .else_body = else_body,
            };
            try block.instructions.append(block.sema.gpa, &inst.base);
            return &inst.base;
        }

        pub fn addDbgStmt(block: *Scope.Block, src: LazySrcLoc, line: u32, column: u32) !*ir.Inst {
            const inst = try block.sema.arena.create(ir.Inst.DbgStmt);
            inst.* = .{
                .base = .{
                    .tag = .dbg_stmt,
                    .ty = Type.initTag(.void),
                    .src = src,
                },
                .line = line,
                .column = column,
            };
            try block.instructions.append(block.sema.gpa, &inst.base);
            return &inst.base;
        }

        pub fn addStructFieldPtr(
            block: *Scope.Block,
            src: LazySrcLoc,
            ty: Type,
            struct_ptr: *ir.Inst,
            field_index: u32,
        ) !*ir.Inst {
            const inst = try block.sema.arena.create(ir.Inst.StructFieldPtr);
            inst.* = .{
                .base = .{
                    .tag = .struct_field_ptr,
                    .ty = ty,
                    .src = src,
                },
                .struct_ptr = struct_ptr,
                .field_index = field_index,
            };
            try block.instructions.append(block.sema.gpa, &inst.base);
            return &inst.base;
        }
    };
};

/// This struct holds data necessary to construct API-facing `AllErrors.Message`.
/// Its memory is managed with the general purpose allocator so that they
/// can be created and destroyed in response to incremental updates.
/// In some cases, the Scope.File could have been inferred from where the ErrorMsg
/// is stored. For example, if it is stored in Module.failed_decls, then the Scope.File
/// would be determined by the Decl Scope. However, the data structure contains the field
/// anyway so that `ErrorMsg` can be reused for error notes, which may be in a different
/// file than the parent error message. It also simplifies processing of error messages.
pub const ErrorMsg = struct {
    src_loc: SrcLoc,
    msg: []const u8,
    notes: []ErrorMsg = &.{},

    pub fn create(
        gpa: *Allocator,
        src_loc: SrcLoc,
        comptime format: []const u8,
        args: anytype,
    ) !*ErrorMsg {
        const err_msg = try gpa.create(ErrorMsg);
        errdefer gpa.destroy(err_msg);
        err_msg.* = try init(gpa, src_loc, format, args);
        return err_msg;
    }

    /// Assumes the ErrorMsg struct and msg were both allocated with `gpa`,
    /// as well as all notes.
    pub fn destroy(err_msg: *ErrorMsg, gpa: *Allocator) void {
        err_msg.deinit(gpa);
        gpa.destroy(err_msg);
    }

    pub fn init(
        gpa: *Allocator,
        src_loc: SrcLoc,
        comptime format: []const u8,
        args: anytype,
    ) !ErrorMsg {
        return ErrorMsg{
            .src_loc = src_loc,
            .msg = try std.fmt.allocPrint(gpa, format, args),
        };
    }

    pub fn deinit(err_msg: *ErrorMsg, gpa: *Allocator) void {
        for (err_msg.notes) |*note| {
            note.deinit(gpa);
        }
        gpa.free(err_msg.notes);
        gpa.free(err_msg.msg);
        err_msg.* = undefined;
    }
};

/// Canonical reference to a position within a source file.
pub const SrcLoc = struct {
    file_scope: *Scope.File,
    /// Might be 0 depending on tag of `lazy`.
    parent_decl_node: ast.Node.Index,
    /// Relative to `parent_decl_node`.
    lazy: LazySrcLoc,

    pub fn declSrcToken(src_loc: SrcLoc) ast.TokenIndex {
        const tree = src_loc.file_scope.tree;
        return tree.firstToken(src_loc.parent_decl_node);
    }

    pub fn declRelativeToNodeIndex(src_loc: SrcLoc, offset: i32) ast.TokenIndex {
        return @bitCast(ast.Node.Index, offset + @bitCast(i32, src_loc.parent_decl_node));
    }

    pub fn byteOffset(src_loc: SrcLoc, gpa: *Allocator) !u32 {
        switch (src_loc.lazy) {
            .unneeded => unreachable,
            .entire_file => return 0,

            .byte_abs => |byte_index| return byte_index,

            .token_abs => |tok_index| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_abs => |node| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const token_starts = tree.tokens.items(.start);
                const tok_index = tree.firstToken(node);
                return token_starts[tok_index];
            },
            .byte_offset => |byte_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const token_starts = tree.tokens.items(.start);
                return token_starts[src_loc.declSrcToken()] + byte_off;
            },
            .token_offset => |tok_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const tok_index = src_loc.declSrcToken() + tok_off;
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset, .node_offset_bin_op => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                assert(src_loc.file_scope.tree_loaded);
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[node];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_back2tok => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const tok_index = tree.firstToken(node) - 2;
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_var_decl_ty => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const node_tags = tree.nodes.items(.tag);
                const full = switch (node_tags[node]) {
                    .global_var_decl => tree.globalVarDecl(node),
                    .local_var_decl => tree.localVarDecl(node),
                    .simple_var_decl => tree.simpleVarDecl(node),
                    .aligned_var_decl => tree.alignedVarDecl(node),
                    else => unreachable,
                };
                const tok_index = if (full.ast.type_node != 0) blk: {
                    const main_tokens = tree.nodes.items(.main_token);
                    break :blk main_tokens[full.ast.type_node];
                } else blk: {
                    break :blk full.ast.mut_token + 1; // the name token
                };
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_builtin_call_arg0 => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_datas = tree.nodes.items(.data);
                const node_tags = tree.nodes.items(.tag);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const param = switch (node_tags[node]) {
                    .builtin_call_two, .builtin_call_two_comma => node_datas[node].lhs,
                    .builtin_call, .builtin_call_comma => tree.extra_data[node_datas[node].lhs],
                    else => unreachable,
                };
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[param];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_builtin_call_arg1 => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_datas = tree.nodes.items(.data);
                const node_tags = tree.nodes.items(.tag);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const param = switch (node_tags[node]) {
                    .builtin_call_two, .builtin_call_two_comma => node_datas[node].rhs,
                    .builtin_call, .builtin_call_comma => tree.extra_data[node_datas[node].lhs + 1],
                    else => unreachable,
                };
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[param];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_array_access_index => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_datas = tree.nodes.items(.data);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[node_datas[node].rhs];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_slice_sentinel => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_tags = tree.nodes.items(.tag);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const full = switch (node_tags[node]) {
                    .slice_open => tree.sliceOpen(node),
                    .slice => tree.slice(node),
                    .slice_sentinel => tree.sliceSentinel(node),
                    else => unreachable,
                };
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[full.ast.sentinel];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_call_func => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_tags = tree.nodes.items(.tag);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                var params: [1]ast.Node.Index = undefined;
                const full = switch (node_tags[node]) {
                    .call_one,
                    .call_one_comma,
                    .async_call_one,
                    .async_call_one_comma,
                    => tree.callOne(&params, node),

                    .call,
                    .call_comma,
                    .async_call,
                    .async_call_comma,
                    => tree.callFull(node),

                    else => unreachable,
                };
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[full.ast.fn_expr];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_field_name => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_datas = tree.nodes.items(.data);
                const node_tags = tree.nodes.items(.tag);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const tok_index = switch (node_tags[node]) {
                    .field_access => node_datas[node].rhs,
                    else => tree.firstToken(node) - 2,
                };
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_deref_ptr => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_datas = tree.nodes.items(.data);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const tok_index = node_datas[node].lhs;
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_asm_source => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_tags = tree.nodes.items(.tag);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const full = switch (node_tags[node]) {
                    .asm_simple => tree.asmSimple(node),
                    .@"asm" => tree.asmFull(node),
                    else => unreachable,
                };
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[full.ast.template];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_asm_ret_ty => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_tags = tree.nodes.items(.tag);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const full = switch (node_tags[node]) {
                    .asm_simple => tree.asmSimple(node),
                    .@"asm" => tree.asmFull(node),
                    else => unreachable,
                };
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[full.outputs[0]];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },

            .node_offset_for_cond, .node_offset_if_cond => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const node_tags = tree.nodes.items(.tag);
                const src_node = switch (node_tags[node]) {
                    .if_simple => tree.ifSimple(node).ast.cond_expr,
                    .@"if" => tree.ifFull(node).ast.cond_expr,
                    .while_simple => tree.whileSimple(node).ast.cond_expr,
                    .while_cont => tree.whileCont(node).ast.cond_expr,
                    .@"while" => tree.whileFull(node).ast.cond_expr,
                    .for_simple => tree.forSimple(node).ast.cond_expr,
                    .@"for" => tree.forFull(node).ast.cond_expr,
                    else => unreachable,
                };
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[src_node];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_bin_lhs => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const node_datas = tree.nodes.items(.data);
                const src_node = node_datas[node].lhs;
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[src_node];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
            .node_offset_bin_rhs => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const node_datas = tree.nodes.items(.data);
                const src_node = node_datas[node].rhs;
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[src_node];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },

            .node_offset_switch_operand => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                const node_datas = tree.nodes.items(.data);
                const src_node = node_datas[node].lhs;
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[src_node];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },

            .node_offset_switch_special_prong => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const switch_node = src_loc.declRelativeToNodeIndex(node_off);
                const node_datas = tree.nodes.items(.data);
                const node_tags = tree.nodes.items(.tag);
                const main_tokens = tree.nodes.items(.main_token);
                const extra = tree.extraData(node_datas[switch_node].rhs, ast.Node.SubRange);
                const case_nodes = tree.extra_data[extra.start..extra.end];
                for (case_nodes) |case_node| {
                    const case = switch (node_tags[case_node]) {
                        .switch_case_one => tree.switchCaseOne(case_node),
                        .switch_case => tree.switchCase(case_node),
                        else => unreachable,
                    };
                    const is_special = (case.ast.values.len == 0) or
                        (case.ast.values.len == 1 and
                        node_tags[case.ast.values[0]] == .identifier and
                        mem.eql(u8, tree.tokenSlice(main_tokens[case.ast.values[0]]), "_"));
                    if (!is_special) continue;

                    const tok_index = main_tokens[case_node];
                    const token_starts = tree.tokens.items(.start);
                    return token_starts[tok_index];
                } else unreachable;
            },

            .node_offset_switch_range => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const switch_node = src_loc.declRelativeToNodeIndex(node_off);
                const node_datas = tree.nodes.items(.data);
                const node_tags = tree.nodes.items(.tag);
                const main_tokens = tree.nodes.items(.main_token);
                const extra = tree.extraData(node_datas[switch_node].rhs, ast.Node.SubRange);
                const case_nodes = tree.extra_data[extra.start..extra.end];
                for (case_nodes) |case_node| {
                    const case = switch (node_tags[case_node]) {
                        .switch_case_one => tree.switchCaseOne(case_node),
                        .switch_case => tree.switchCase(case_node),
                        else => unreachable,
                    };
                    const is_special = (case.ast.values.len == 0) or
                        (case.ast.values.len == 1 and
                        node_tags[case.ast.values[0]] == .identifier and
                        mem.eql(u8, tree.tokenSlice(main_tokens[case.ast.values[0]]), "_"));
                    if (is_special) continue;

                    for (case.ast.values) |item_node| {
                        if (node_tags[item_node] == .switch_range) {
                            const tok_index = main_tokens[item_node];
                            const token_starts = tree.tokens.items(.start);
                            return token_starts[tok_index];
                        }
                    }
                } else unreachable;
            },

            .node_offset_fn_type_cc => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_tags = tree.nodes.items(.tag);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                var params: [1]ast.Node.Index = undefined;
                const full = switch (node_tags[node]) {
                    .fn_proto_simple => tree.fnProtoSimple(&params, node),
                    .fn_proto_multi => tree.fnProtoMulti(node),
                    .fn_proto_one => tree.fnProtoOne(&params, node),
                    .fn_proto => tree.fnProto(node),
                    else => unreachable,
                };
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[full.ast.callconv_expr];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },

            .node_offset_fn_type_ret_ty => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_tags = tree.nodes.items(.tag);
                const node = src_loc.declRelativeToNodeIndex(node_off);
                var params: [1]ast.Node.Index = undefined;
                const full = switch (node_tags[node]) {
                    .fn_proto_simple => tree.fnProtoSimple(&params, node),
                    .fn_proto_multi => tree.fnProtoMulti(node),
                    .fn_proto_one => tree.fnProtoOne(&params, node),
                    .fn_proto => tree.fnProto(node),
                    else => unreachable,
                };
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[full.ast.return_type];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },

            .node_offset_anyframe_type => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_datas = tree.nodes.items(.data);
                const parent_node = src_loc.declRelativeToNodeIndex(node_off);
                const node = node_datas[parent_node].rhs;
                const main_tokens = tree.nodes.items(.main_token);
                const tok_index = main_tokens[node];
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },

            .node_offset_lib_name => |node_off| {
                const tree = try src_loc.file_scope.getTree(gpa);
                const node_datas = tree.nodes.items(.data);
                const node_tags = tree.nodes.items(.tag);
                const parent_node = src_loc.declRelativeToNodeIndex(node_off);
                var params: [1]ast.Node.Index = undefined;
                const full = switch (node_tags[parent_node]) {
                    .fn_proto_simple => tree.fnProtoSimple(&params, parent_node),
                    .fn_proto_multi => tree.fnProtoMulti(parent_node),
                    .fn_proto_one => tree.fnProtoOne(&params, parent_node),
                    .fn_proto => tree.fnProto(parent_node),
                    .fn_decl => blk: {
                        const fn_proto = node_datas[parent_node].lhs;
                        break :blk switch (node_tags[fn_proto]) {
                            .fn_proto_simple => tree.fnProtoSimple(&params, fn_proto),
                            .fn_proto_multi => tree.fnProtoMulti(fn_proto),
                            .fn_proto_one => tree.fnProtoOne(&params, fn_proto),
                            .fn_proto => tree.fnProto(fn_proto),
                            else => unreachable,
                        };
                    },
                    else => unreachable,
                };
                const tok_index = full.lib_name.?;
                const token_starts = tree.tokens.items(.start);
                return token_starts[tok_index];
            },
        }
    }
};

/// Resolving a source location into a byte offset may require doing work
/// that we would rather not do unless the error actually occurs.
/// Therefore we need a data structure that contains the information necessary
/// to lazily produce a `SrcLoc` as required.
/// Most of the offsets in this data structure are relative to the containing Decl.
/// This makes the source location resolve properly even when a Decl gets
/// shifted up or down in the file, as long as the Decl's contents itself
/// do not change.
pub const LazySrcLoc = union(enum) {
    /// When this tag is set, the code that constructed this `LazySrcLoc` is asserting
    /// that all code paths which would need to resolve the source location are
    /// unreachable. If you are debugging this tag incorrectly being this value,
    /// look into using reverse-continue with a memory watchpoint to see where the
    /// value is being set to this tag.
    unneeded,
    /// Means the source location points to an entire file; not any particular
    /// location within the file. `file_scope` union field will be active.
    entire_file,
    /// The source location points to a byte offset within a source file,
    /// offset from 0. The source file is determined contextually.
    /// Inside a `SrcLoc`, the `file_scope` union field will be active.
    byte_abs: u32,
    /// The source location points to a token within a source file,
    /// offset from 0. The source file is determined contextually.
    /// Inside a `SrcLoc`, the `file_scope` union field will be active.
    token_abs: u32,
    /// The source location points to an AST node within a source file,
    /// offset from 0. The source file is determined contextually.
    /// Inside a `SrcLoc`, the `file_scope` union field will be active.
    node_abs: u32,
    /// The source location points to a byte offset within a source file,
    /// offset from the byte offset of the Decl within the file.
    /// The Decl is determined contextually.
    byte_offset: u32,
    /// This data is the offset into the token list from the Decl token.
    /// The Decl is determined contextually.
    token_offset: u32,
    /// The source location points to an AST node, which is this value offset
    /// from its containing Decl node AST index.
    /// The Decl is determined contextually.
    node_offset: i32,
    /// The source location points to two tokens left of the first token of an AST node,
    /// which is this value offset from its containing Decl node AST index.
    /// The Decl is determined contextually.
    node_offset_back2tok: i32,
    /// The source location points to a variable declaration type expression,
    /// found by taking this AST node index offset from the containing
    /// Decl AST node, which points to a variable declaration AST node. Next, navigate
    /// to the type expression.
    /// The Decl is determined contextually.
    node_offset_var_decl_ty: i32,
    /// The source location points to a for loop condition expression,
    /// found by taking this AST node index offset from the containing
    /// Decl AST node, which points to a for loop AST node. Next, navigate
    /// to the condition expression.
    /// The Decl is determined contextually.
    node_offset_for_cond: i32,
    /// The source location points to the first parameter of a builtin
    /// function call, found by taking this AST node index offset from the containing
    /// Decl AST node, which points to a builtin call AST node. Next, navigate
    /// to the first parameter.
    /// The Decl is determined contextually.
    node_offset_builtin_call_arg0: i32,
    /// Same as `node_offset_builtin_call_arg0` except arg index 1.
    node_offset_builtin_call_arg1: i32,
    /// The source location points to the index expression of an array access
    /// expression, found by taking this AST node index offset from the containing
    /// Decl AST node, which points to an array access AST node. Next, navigate
    /// to the index expression.
    /// The Decl is determined contextually.
    node_offset_array_access_index: i32,
    /// The source location points to the sentinel expression of a slice
    /// expression, found by taking this AST node index offset from the containing
    /// Decl AST node, which points to a slice AST node. Next, navigate
    /// to the sentinel expression.
    /// The Decl is determined contextually.
    node_offset_slice_sentinel: i32,
    /// The source location points to the callee expression of a function
    /// call expression, found by taking this AST node index offset from the containing
    /// Decl AST node, which points to a function call AST node. Next, navigate
    /// to the callee expression.
    /// The Decl is determined contextually.
    node_offset_call_func: i32,
    /// The payload is offset from the containing Decl AST node.
    /// The source location points to the field name of:
    ///  * a field access expression (`a.b`), or
    ///  * the operand ("b" node) of a field initialization expression (`.a = b`)
    /// The Decl is determined contextually.
    node_offset_field_name: i32,
    /// The source location points to the pointer of a pointer deref expression,
    /// found by taking this AST node index offset from the containing
    /// Decl AST node, which points to a pointer deref AST node. Next, navigate
    /// to the pointer expression.
    /// The Decl is determined contextually.
    node_offset_deref_ptr: i32,
    /// The source location points to the assembly source code of an inline assembly
    /// expression, found by taking this AST node index offset from the containing
    /// Decl AST node, which points to inline assembly AST node. Next, navigate
    /// to the asm template source code.
    /// The Decl is determined contextually.
    node_offset_asm_source: i32,
    /// The source location points to the return type of an inline assembly
    /// expression, found by taking this AST node index offset from the containing
    /// Decl AST node, which points to inline assembly AST node. Next, navigate
    /// to the return type expression.
    /// The Decl is determined contextually.
    node_offset_asm_ret_ty: i32,
    /// The source location points to the condition expression of an if
    /// expression, found by taking this AST node index offset from the containing
    /// Decl AST node, which points to an if expression AST node. Next, navigate
    /// to the condition expression.
    /// The Decl is determined contextually.
    node_offset_if_cond: i32,
    /// The source location points to a binary expression, such as `a + b`, found
    /// by taking this AST node index offset from the containing Decl AST node.
    /// The Decl is determined contextually.
    node_offset_bin_op: i32,
    /// The source location points to the LHS of a binary expression, found
    /// by taking this AST node index offset from the containing Decl AST node,
    /// which points to a binary expression AST node. Next, nagivate to the LHS.
    /// The Decl is determined contextually.
    node_offset_bin_lhs: i32,
    /// The source location points to the RHS of a binary expression, found
    /// by taking this AST node index offset from the containing Decl AST node,
    /// which points to a binary expression AST node. Next, nagivate to the RHS.
    /// The Decl is determined contextually.
    node_offset_bin_rhs: i32,
    /// The source location points to the operand of a switch expression, found
    /// by taking this AST node index offset from the containing Decl AST node,
    /// which points to a switch expression AST node. Next, nagivate to the operand.
    /// The Decl is determined contextually.
    node_offset_switch_operand: i32,
    /// The source location points to the else/`_` prong of a switch expression, found
    /// by taking this AST node index offset from the containing Decl AST node,
    /// which points to a switch expression AST node. Next, nagivate to the else/`_` prong.
    /// The Decl is determined contextually.
    node_offset_switch_special_prong: i32,
    /// The source location points to all the ranges of a switch expression, found
    /// by taking this AST node index offset from the containing Decl AST node,
    /// which points to a switch expression AST node. Next, nagivate to any of the
    /// range nodes. The error applies to all of them.
    /// The Decl is determined contextually.
    node_offset_switch_range: i32,
    /// The source location points to the calling convention of a function type
    /// expression, found by taking this AST node index offset from the containing
    /// Decl AST node, which points to a function type AST node. Next, nagivate to
    /// the calling convention node.
    /// The Decl is determined contextually.
    node_offset_fn_type_cc: i32,
    /// The source location points to the return type of a function type
    /// expression, found by taking this AST node index offset from the containing
    /// Decl AST node, which points to a function type AST node. Next, nagivate to
    /// the return type node.
    /// The Decl is determined contextually.
    node_offset_fn_type_ret_ty: i32,
    /// The source location points to the type expression of an `anyframe->T`
    /// expression, found by taking this AST node index offset from the containing
    /// Decl AST node, which points to a `anyframe->T` expression AST node. Next, navigate
    /// to the type expression.
    /// The Decl is determined contextually.
    node_offset_anyframe_type: i32,
    /// The source location points to the string literal of `extern "foo"`, found
    /// by taking this AST node index offset from the containing
    /// Decl AST node, which points to a function prototype or variable declaration
    /// expression AST node. Next, navigate to the string literal of the `extern "foo"`.
    /// The Decl is determined contextually.
    node_offset_lib_name: i32,

    /// Upgrade to a `SrcLoc` based on the `Decl` or file in the provided scope.
    pub fn toSrcLoc(lazy: LazySrcLoc, scope: *Scope) SrcLoc {
        return switch (lazy) {
            .unneeded,
            .entire_file,
            .byte_abs,
            .token_abs,
            .node_abs,
            => .{
                .file_scope = scope.getFileScope(),
                .parent_decl_node = 0,
                .lazy = lazy,
            },

            .byte_offset,
            .token_offset,
            .node_offset,
            .node_offset_back2tok,
            .node_offset_var_decl_ty,
            .node_offset_for_cond,
            .node_offset_builtin_call_arg0,
            .node_offset_builtin_call_arg1,
            .node_offset_array_access_index,
            .node_offset_slice_sentinel,
            .node_offset_call_func,
            .node_offset_field_name,
            .node_offset_deref_ptr,
            .node_offset_asm_source,
            .node_offset_asm_ret_ty,
            .node_offset_if_cond,
            .node_offset_bin_op,
            .node_offset_bin_lhs,
            .node_offset_bin_rhs,
            .node_offset_switch_operand,
            .node_offset_switch_special_prong,
            .node_offset_switch_range,
            .node_offset_fn_type_cc,
            .node_offset_fn_type_ret_ty,
            .node_offset_anyframe_type,
            .node_offset_lib_name,
            => .{
                .file_scope = scope.getFileScope(),
                .parent_decl_node = scope.srcDecl().?.src_node,
                .lazy = lazy,
            },
        };
    }

    /// Upgrade to a `SrcLoc` based on the `Decl` provided.
    pub fn toSrcLocWithDecl(lazy: LazySrcLoc, decl: *Decl) SrcLoc {
        return switch (lazy) {
            .unneeded,
            .entire_file,
            .byte_abs,
            .token_abs,
            .node_abs,
            => .{
                .file_scope = decl.getFileScope(),
                .parent_decl_node = 0,
                .lazy = lazy,
            },

            .byte_offset,
            .token_offset,
            .node_offset,
            .node_offset_back2tok,
            .node_offset_var_decl_ty,
            .node_offset_for_cond,
            .node_offset_builtin_call_arg0,
            .node_offset_builtin_call_arg1,
            .node_offset_array_access_index,
            .node_offset_slice_sentinel,
            .node_offset_call_func,
            .node_offset_field_name,
            .node_offset_deref_ptr,
            .node_offset_asm_source,
            .node_offset_asm_ret_ty,
            .node_offset_if_cond,
            .node_offset_bin_op,
            .node_offset_bin_lhs,
            .node_offset_bin_rhs,
            .node_offset_switch_operand,
            .node_offset_switch_special_prong,
            .node_offset_switch_range,
            .node_offset_fn_type_cc,
            .node_offset_fn_type_ret_ty,
            .node_offset_anyframe_type,
            .node_offset_lib_name,
            => .{
                .file_scope = decl.getFileScope(),
                .parent_decl_node = decl.src_node,
                .lazy = lazy,
            },
        };
    }
};

pub const InnerError = error{ OutOfMemory, AnalysisFail };

pub fn deinit(mod: *Module) void {
    const gpa = mod.gpa;

    for (mod.import_table.keys()) |key| {
        gpa.free(key);
    }
    for (mod.import_table.values()) |value| {
        value.destroy(mod);
    }
    mod.import_table.deinit(gpa);

    mod.deletion_set.deinit(gpa);

    // The callsite of `Compilation.create` owns the `root_pkg`, however
    // Module owns the builtin and std packages that it adds.
    if (mod.root_pkg.table.fetchRemove("builtin")) |kv| {
        gpa.free(kv.key);
        kv.value.destroy(gpa);
    }
    if (mod.root_pkg.table.fetchRemove("std")) |kv| {
        gpa.free(kv.key);
        kv.value.destroy(gpa);
    }
    if (mod.root_pkg.table.fetchRemove("root")) |kv| {
        gpa.free(kv.key);
    }

    mod.compile_log_text.deinit(gpa);

    mod.zig_cache_artifact_directory.handle.close();
    mod.local_zir_cache.handle.close();
    mod.global_zir_cache.handle.close();

    for (mod.failed_decls.values()) |value| {
        value.destroy(gpa);
    }
    mod.failed_decls.deinit(gpa);

    if (mod.emit_h) |emit_h| {
        for (emit_h.failed_decls.values()) |value| {
            value.destroy(gpa);
        }
        emit_h.failed_decls.deinit(gpa);
        emit_h.decl_table.deinit(gpa);
        gpa.destroy(emit_h);
    }

    for (mod.failed_files.values()) |value| {
        if (value) |msg| msg.destroy(gpa);
    }
    mod.failed_files.deinit(gpa);

    for (mod.failed_exports.values()) |value| {
        value.destroy(gpa);
    }
    mod.failed_exports.deinit(gpa);

    mod.compile_log_decls.deinit(gpa);

    for (mod.decl_exports.values()) |export_list| {
        gpa.free(export_list);
    }
    mod.decl_exports.deinit(gpa);

    for (mod.export_owners.values()) |value| {
        freeExportList(gpa, value);
    }
    mod.export_owners.deinit(gpa);

    var it = mod.global_error_set.keyIterator();
    while (it.next()) |key| {
        gpa.free(key.*);
    }
    mod.global_error_set.deinit(gpa);

    mod.error_name_list.deinit(gpa);
}

fn freeExportList(gpa: *Allocator, export_list: []*Export) void {
    for (export_list) |exp| {
        gpa.free(exp.options.name);
        gpa.destroy(exp);
    }
    gpa.free(export_list);
}

const data_has_safety_tag = @sizeOf(Zir.Inst.Data) != 8;
// TODO This is taking advantage of matching stage1 debug union layout.
// We need a better language feature for initializing a union with
// a runtime known tag.
const Stage1DataLayout = extern struct {
    data: [8]u8 align(8),
    safety_tag: u8,
};
comptime {
    if (data_has_safety_tag) {
        assert(@sizeOf(Stage1DataLayout) == @sizeOf(Zir.Inst.Data));
    }
}

pub fn astGenFile(mod: *Module, file: *Scope.File) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const comp = mod.comp;
    const gpa = mod.gpa;

    // In any case we need to examine the stat of the file to determine the course of action.
    var source_file = try file.pkg.root_src_directory.handle.openFile(file.sub_file_path, .{});
    defer source_file.close();

    const stat = try source_file.stat();

    const want_local_cache = file.pkg == mod.root_pkg;
    const digest = hash: {
        var path_hash: Cache.HashHelper = .{};
        path_hash.addBytes(build_options.version);
        if (!want_local_cache) {
            path_hash.addOptionalBytes(file.pkg.root_src_directory.path);
        }
        path_hash.addBytes(file.sub_file_path);
        break :hash path_hash.final();
    };
    const cache_directory = if (want_local_cache) mod.local_zir_cache else mod.global_zir_cache;
    const zir_dir = cache_directory.handle;

    var cache_file: ?std.fs.File = null;
    defer if (cache_file) |f| f.close();

    // Determine whether we need to reload the file from disk and redo parsing and AstGen.
    switch (file.status) {
        .never_loaded, .retryable_failure => cached: {
            // First, load the cached ZIR code, if any.
            log.debug("AstGen checking cache: {s} (local={}, digest={s})", .{
                file.sub_file_path, want_local_cache, &digest,
            });

            // We ask for a lock in order to coordinate with other zig processes.
            // If another process is already working on this file, we will get the cached
            // version. Likewise if we're working on AstGen and another process asks for
            // the cached file, they'll get it.
            cache_file = zir_dir.openFile(&digest, .{ .lock = .Shared }) catch |err| switch (err) {
                error.PathAlreadyExists => unreachable, // opening for reading
                error.NoSpaceLeft => unreachable, // opening for reading
                error.NotDir => unreachable, // no dir components
                error.InvalidUtf8 => unreachable, // it's a hex encoded name
                error.BadPathName => unreachable, // it's a hex encoded name
                error.NameTooLong => unreachable, // it's a fixed size name
                error.PipeBusy => unreachable, // it's not a pipe
                error.WouldBlock => unreachable, // not asking for non-blocking I/O

                error.SymLinkLoop,
                error.FileNotFound,
                error.Unexpected,
                => break :cached,

                else => |e| return e, // Retryable errors are handled at callsite.
            };

            // First we read the header to determine the lengths of arrays.
            const header = cache_file.?.reader().readStruct(Zir.Header) catch |err| switch (err) {
                // This can happen if Zig bails out of this function between creating
                // the cached file and writing it.
                error.EndOfStream => break :cached,
                else => |e| return e,
            };
            const unchanged_metadata =
                stat.size == header.stat_size and
                stat.mtime == header.stat_mtime and
                stat.inode == header.stat_inode;

            if (!unchanged_metadata) {
                log.debug("AstGen cache stale: {s}", .{file.sub_file_path});
                break :cached;
            }
            log.debug("AstGen cache hit: {s} instructions_len={d}", .{
                file.sub_file_path, header.instructions_len,
            });

            var instructions: std.MultiArrayList(Zir.Inst) = .{};
            defer instructions.deinit(gpa);

            try instructions.setCapacity(gpa, header.instructions_len);
            instructions.len = header.instructions_len;

            var zir: Zir = .{
                .instructions = instructions.toOwnedSlice(),
                .string_bytes = &.{},
                .extra = &.{},
            };
            var keep_zir = false;
            defer if (!keep_zir) zir.deinit(gpa);

            zir.string_bytes = try gpa.alloc(u8, header.string_bytes_len);
            zir.extra = try gpa.alloc(u32, header.extra_len);

            const safety_buffer = if (data_has_safety_tag)
                try gpa.alloc([8]u8, header.instructions_len)
            else
                undefined;
            defer if (data_has_safety_tag) gpa.free(safety_buffer);

            const data_ptr = if (data_has_safety_tag)
                @ptrCast([*]u8, safety_buffer.ptr)
            else
                @ptrCast([*]u8, zir.instructions.items(.data).ptr);

            var iovecs = [_]std.os.iovec{
                .{
                    .iov_base = @ptrCast([*]u8, zir.instructions.items(.tag).ptr),
                    .iov_len = header.instructions_len,
                },
                .{
                    .iov_base = data_ptr,
                    .iov_len = header.instructions_len * 8,
                },
                .{
                    .iov_base = zir.string_bytes.ptr,
                    .iov_len = header.string_bytes_len,
                },
                .{
                    .iov_base = @ptrCast([*]u8, zir.extra.ptr),
                    .iov_len = header.extra_len * 4,
                },
            };
            const amt_read = try cache_file.?.readvAll(&iovecs);
            const amt_expected = zir.instructions.len * 9 +
                zir.string_bytes.len +
                zir.extra.len * 4;
            if (amt_read != amt_expected) {
                log.warn("unexpected EOF reading cached ZIR for {s}", .{file.sub_file_path});
                zir.deinit(gpa);
                break :cached;
            }
            if (data_has_safety_tag) {
                const tags = zir.instructions.items(.tag);
                for (zir.instructions.items(.data)) |*data, i| {
                    const union_tag = Zir.Inst.Tag.data_tags[@enumToInt(tags[i])];
                    const as_struct = @ptrCast(*Stage1DataLayout, data);
                    as_struct.* = .{
                        .safety_tag = @enumToInt(union_tag),
                        .data = safety_buffer[i],
                    };
                }
            }

            keep_zir = true;
            file.zir = zir;
            file.zir_loaded = true;
            file.stat_size = header.stat_size;
            file.stat_inode = header.stat_inode;
            file.stat_mtime = header.stat_mtime;
            file.status = .success_zir;
            log.debug("AstGen cached success: {s}", .{file.sub_file_path});

            // TODO don't report compile errors until Sema @importFile
            if (file.zir.hasCompileErrors()) {
                {
                    const lock = comp.mutex.acquire();
                    defer lock.release();
                    try mod.failed_files.putNoClobber(gpa, file, null);
                }
                file.status = .astgen_failure;
                return error.AnalysisFail;
            }
            return;
        },
        .parse_failure, .astgen_failure, .success_zir => {
            const unchanged_metadata =
                stat.size == file.stat_size and
                stat.mtime == file.stat_mtime and
                stat.inode == file.stat_inode;

            if (unchanged_metadata) {
                log.debug("unmodified metadata of file: {s}", .{file.sub_file_path});
                return;
            }

            log.debug("metadata changed: {s}", .{file.sub_file_path});
        },
    }
    if (cache_file) |f| {
        f.close();
        cache_file = null;
    }
    cache_file = zir_dir.createFile(&digest, .{ .lock = .Exclusive }) catch |err| switch (err) {
        error.NotDir => unreachable, // no dir components
        error.InvalidUtf8 => unreachable, // it's a hex encoded name
        error.BadPathName => unreachable, // it's a hex encoded name
        error.NameTooLong => unreachable, // it's a fixed size name
        error.PipeBusy => unreachable, // it's not a pipe
        error.WouldBlock => unreachable, // not asking for non-blocking I/O
        error.FileNotFound => unreachable, // no dir components

        else => |e| {
            const pkg_path = file.pkg.root_src_directory.path orelse ".";
            const cache_path = cache_directory.path orelse ".";
            log.warn("unable to save cached ZIR code for {s}/{s} to {s}/{s}: {s}", .{
                pkg_path, file.sub_file_path, cache_path, &digest, @errorName(e),
            });
            return;
        },
    };

    mod.lockAndClearFileCompileError(file);

    // If the previous ZIR does not have compile errors, keep it around
    // in case parsing or new ZIR fails. In case of successful ZIR update
    // at the end of this function we will free it.
    // We keep the previous ZIR loaded so that we can use it
    // for the update next time it does not have any compile errors. This avoids
    // needlessly tossing out semantic analysis work when an error is
    // temporarily introduced.
    if (file.zir_loaded and !file.zir.hasCompileErrors()) {
        assert(file.prev_zir == null);
        const prev_zir_ptr = try gpa.create(Zir);
        file.prev_zir = prev_zir_ptr;
        prev_zir_ptr.* = file.zir;
        file.zir = undefined;
        file.zir_loaded = false;
    }
    file.unload(gpa);

    if (stat.size > std.math.maxInt(u32))
        return error.FileTooBig;

    const source = try gpa.allocSentinel(u8, @intCast(usize, stat.size), 0);
    defer if (!file.source_loaded) gpa.free(source);
    const amt = try source_file.readAll(source);
    if (amt != stat.size)
        return error.UnexpectedEndOfFile;

    file.stat_size = stat.size;
    file.stat_inode = stat.inode;
    file.stat_mtime = stat.mtime;
    file.source = source;
    file.source_loaded = true;

    file.tree = try std.zig.parse(gpa, source);
    defer if (!file.tree_loaded) file.tree.deinit(gpa);

    if (file.tree.errors.len != 0) {
        const parse_err = file.tree.errors[0];

        var msg = std.ArrayList(u8).init(gpa);
        defer msg.deinit();

        const token_starts = file.tree.tokens.items(.start);
        const token_tags = file.tree.tokens.items(.tag);

        try file.tree.renderError(parse_err, msg.writer());
        const err_msg = try gpa.create(ErrorMsg);
        err_msg.* = .{
            .src_loc = .{
                .file_scope = file,
                .parent_decl_node = 0,
                .lazy = .{ .byte_abs = token_starts[parse_err.token] },
            },
            .msg = msg.toOwnedSlice(),
        };
        if (token_tags[parse_err.token] == .invalid) {
            const bad_off = @intCast(u32, file.tree.tokenSlice(parse_err.token).len);
            const byte_abs = token_starts[parse_err.token] + bad_off;
            try mod.errNoteNonLazy(.{
                .file_scope = file,
                .parent_decl_node = 0,
                .lazy = .{ .byte_abs = byte_abs },
            }, err_msg, "invalid byte: '{'}'", .{std.zig.fmtEscapes(source[byte_abs..][0..1])});
        }

        {
            const lock = comp.mutex.acquire();
            defer lock.release();
            try mod.failed_files.putNoClobber(gpa, file, err_msg);
        }
        file.status = .parse_failure;
        return error.AnalysisFail;
    }
    file.tree_loaded = true;

    file.zir = try AstGen.generate(gpa, file.tree);
    file.zir_loaded = true;
    file.status = .success_zir;
    log.debug("AstGen fresh success: {s}", .{file.sub_file_path});

    const safety_buffer = if (data_has_safety_tag)
        try gpa.alloc([8]u8, file.zir.instructions.len)
    else
        undefined;
    defer if (data_has_safety_tag) gpa.free(safety_buffer);
    const data_ptr = if (data_has_safety_tag)
        @ptrCast([*]const u8, safety_buffer.ptr)
    else
        @ptrCast([*]const u8, file.zir.instructions.items(.data).ptr);
    if (data_has_safety_tag) {
        // The `Data` union has a safety tag but in the file format we store it without.
        for (file.zir.instructions.items(.data)) |*data, i| {
            const as_struct = @ptrCast(*const Stage1DataLayout, data);
            safety_buffer[i] = as_struct.data;
        }
    }

    const header: Zir.Header = .{
        .instructions_len = @intCast(u32, file.zir.instructions.len),
        .string_bytes_len = @intCast(u32, file.zir.string_bytes.len),
        .extra_len = @intCast(u32, file.zir.extra.len),

        .stat_size = stat.size,
        .stat_inode = stat.inode,
        .stat_mtime = stat.mtime,
    };
    var iovecs = [_]std.os.iovec_const{
        .{
            .iov_base = @ptrCast([*]const u8, &header),
            .iov_len = @sizeOf(Zir.Header),
        },
        .{
            .iov_base = @ptrCast([*]const u8, file.zir.instructions.items(.tag).ptr),
            .iov_len = file.zir.instructions.len,
        },
        .{
            .iov_base = data_ptr,
            .iov_len = file.zir.instructions.len * 8,
        },
        .{
            .iov_base = file.zir.string_bytes.ptr,
            .iov_len = file.zir.string_bytes.len,
        },
        .{
            .iov_base = @ptrCast([*]const u8, file.zir.extra.ptr),
            .iov_len = file.zir.extra.len * 4,
        },
    };
    cache_file.?.writevAll(&iovecs) catch |err| {
        const pkg_path = file.pkg.root_src_directory.path orelse ".";
        const cache_path = cache_directory.path orelse ".";
        log.warn("unable to write cached ZIR code for {s}/{s} to {s}/{s}: {s}", .{
            pkg_path, file.sub_file_path, cache_path, &digest, @errorName(err),
        });
    };

    if (file.zir.hasCompileErrors()) {
        {
            const lock = comp.mutex.acquire();
            defer lock.release();
            try mod.failed_files.putNoClobber(gpa, file, null);
        }
        file.status = .astgen_failure;
        return error.AnalysisFail;
    }

    if (file.prev_zir) |prev_zir| {
        // Iterate over all Namespace objects contained within this File, looking at the
        // previous and new ZIR together and update the references to point
        // to the new one. For example, Decl name, Decl zir_decl_index, and Namespace
        // decl_table keys need to get updated to point to the new memory, even if the
        // underlying source code is unchanged.
        // We do not need to hold any locks at this time because all the Decl and Namespace
        // objects being touched are specific to this File, and the only other concurrent
        // tasks are touching other File objects.
        try updateZirRefs(gpa, file, prev_zir.*);
        // At this point, `file.outdated_decls` and `file.deleted_decls` are populated,
        // and semantic analysis will deal with them properly.
        // No need to keep previous ZIR.
        prev_zir.deinit(gpa);
        gpa.destroy(prev_zir);
        file.prev_zir = null;
    } else if (file.root_decl) |root_decl| {
        // This is an update, but it is the first time the File has succeeded
        // ZIR. We must mark it outdated since we have already tried to
        // semantically analyze it.
        try file.outdated_decls.resize(gpa, 1);
        file.outdated_decls.items[0] = root_decl;
    }
}

/// Patch ups:
/// * Struct.zir_index
/// * Decl.zir_index
/// * Fn.zir_body_inst
/// * Decl.zir_decl_index
fn updateZirRefs(gpa: *Allocator, file: *Scope.File, old_zir: Zir) !void {
    const new_zir = file.zir;

    // Maps from old ZIR to new ZIR, struct_decl, enum_decl, etc. Any instruction which
    // creates a namespace, gets mapped from old to new here.
    var inst_map: std.AutoHashMapUnmanaged(Zir.Inst.Index, Zir.Inst.Index) = .{};
    defer inst_map.deinit(gpa);
    // Maps from old ZIR to new ZIR, the extra data index for the sub-decl item.
    // e.g. the thing that Decl.zir_decl_index points to.
    var extra_map: std.AutoHashMapUnmanaged(u32, u32) = .{};
    defer extra_map.deinit(gpa);

    try mapOldZirToNew(gpa, old_zir, new_zir, &inst_map, &extra_map);

    // Walk the Decl graph, updating ZIR indexes, strings, and populating
    // the deleted and outdated lists.

    var decl_stack: std.ArrayListUnmanaged(*Decl) = .{};
    defer decl_stack.deinit(gpa);

    const root_decl = file.root_decl.?;
    try decl_stack.append(gpa, root_decl);

    file.deleted_decls.clearRetainingCapacity();
    file.outdated_decls.clearRetainingCapacity();

    // The root decl is always outdated; otherwise we would not have had
    // to re-generate ZIR for the File.
    try file.outdated_decls.append(gpa, root_decl);

    while (decl_stack.popOrNull()) |decl| {
        // Anonymous decls and the root decl have this set to 0. We still need
        // to walk them but we do not need to modify this value.
        // Anonymous decls should not be marked outdated. They will be re-generated
        // if their owner decl is marked outdated.
        if (decl.zir_decl_index != 0) {
            const old_zir_decl_index = decl.zir_decl_index;
            const new_zir_decl_index = extra_map.get(old_zir_decl_index) orelse {
                log.debug("updateZirRefs {s}: delete {*} ({s})", .{
                    file.sub_file_path, decl, decl.name,
                });
                try file.deleted_decls.append(gpa, decl);
                continue;
            };
            const old_hash = decl.contentsHashZir(old_zir);
            decl.zir_decl_index = new_zir_decl_index;
            const new_hash = decl.contentsHashZir(new_zir);
            if (!std.zig.srcHashEql(old_hash, new_hash)) {
                log.debug("updateZirRefs {s}: outdated {*} ({s}) {d} => {d}", .{
                    file.sub_file_path, decl, decl.name, old_zir_decl_index, new_zir_decl_index,
                });
                try file.outdated_decls.append(gpa, decl);
            } else {
                log.debug("updateZirRefs {s}: unchanged {*} ({s}) {d} => {d}", .{
                    file.sub_file_path, decl, decl.name, old_zir_decl_index, new_zir_decl_index,
                });
            }
        }

        if (!decl.owns_tv) continue;

        if (decl.getStruct()) |struct_obj| {
            struct_obj.zir_index = inst_map.get(struct_obj.zir_index) orelse {
                try file.deleted_decls.append(gpa, decl);
                continue;
            };
        }

        if (decl.getUnion()) |union_obj| {
            union_obj.zir_index = inst_map.get(union_obj.zir_index) orelse {
                try file.deleted_decls.append(gpa, decl);
                continue;
            };
        }

        if (decl.getFunction()) |func| {
            func.zir_body_inst = inst_map.get(func.zir_body_inst) orelse {
                try file.deleted_decls.append(gpa, decl);
                continue;
            };
        }

        if (decl.getInnerNamespace()) |namespace| {
            for (namespace.decls.values()) |sub_decl| {
                try decl_stack.append(gpa, sub_decl);
            }
            for (namespace.anon_decls.keys()) |sub_decl| {
                try decl_stack.append(gpa, sub_decl);
            }
        }
    }
}

pub fn mapOldZirToNew(
    gpa: *Allocator,
    old_zir: Zir,
    new_zir: Zir,
    inst_map: *std.AutoHashMapUnmanaged(Zir.Inst.Index, Zir.Inst.Index),
    extra_map: *std.AutoHashMapUnmanaged(u32, u32),
) Allocator.Error!void {
    // Contain ZIR indexes of declaration instructions.
    const MatchedZirDecl = struct {
        old_inst: Zir.Inst.Index,
        new_inst: Zir.Inst.Index,
    };
    var match_stack: std.ArrayListUnmanaged(MatchedZirDecl) = .{};
    defer match_stack.deinit(gpa);

    const old_main_struct_inst = old_zir.getMainStruct();
    const new_main_struct_inst = new_zir.getMainStruct();

    try match_stack.append(gpa, .{
        .old_inst = old_main_struct_inst,
        .new_inst = new_main_struct_inst,
    });

    var old_decls = std.ArrayList(Zir.Inst.Index).init(gpa);
    defer old_decls.deinit();
    var new_decls = std.ArrayList(Zir.Inst.Index).init(gpa);
    defer new_decls.deinit();

    while (match_stack.popOrNull()) |match_item| {
        try inst_map.put(gpa, match_item.old_inst, match_item.new_inst);

        // Maps name to extra index of decl sub item.
        var decl_map: std.StringHashMapUnmanaged(u32) = .{};
        defer decl_map.deinit(gpa);

        {
            var old_decl_it = old_zir.declIterator(match_item.old_inst);
            while (old_decl_it.next()) |old_decl| {
                try decl_map.put(gpa, old_decl.name, old_decl.sub_index);
            }
        }

        var new_decl_it = new_zir.declIterator(match_item.new_inst);
        while (new_decl_it.next()) |new_decl| {
            const old_extra_index = decl_map.get(new_decl.name) orelse continue;
            const new_extra_index = new_decl.sub_index;
            try extra_map.put(gpa, old_extra_index, new_extra_index);

            try old_zir.findDecls(&old_decls, old_extra_index);
            try new_zir.findDecls(&new_decls, new_extra_index);
            var i: usize = 0;
            while (true) : (i += 1) {
                if (i >= old_decls.items.len) break;
                if (i >= new_decls.items.len) break;
                try match_stack.append(gpa, .{
                    .old_inst = old_decls.items[i],
                    .new_inst = new_decls.items[i],
                });
            }
        }
    }
}

pub fn ensureDeclAnalyzed(mod: *Module, decl: *Decl) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const subsequent_analysis = switch (decl.analysis) {
        .in_progress => unreachable,

        .file_failure,
        .sema_failure,
        .sema_failure_retryable,
        .codegen_failure,
        .dependency_failure,
        .codegen_failure_retryable,
        => return error.AnalysisFail,

        .complete => return,

        .outdated => blk: {
            log.debug("re-analyzing {*} ({s})", .{ decl, decl.name });

            // The exports this Decl performs will be re-discovered, so we remove them here
            // prior to re-analysis.
            mod.deleteDeclExports(decl);
            // Dependencies will be re-discovered, so we remove them here prior to re-analysis.
            for (decl.dependencies.keys()) |dep| {
                dep.removeDependant(decl);
                if (dep.dependants.count() == 0 and !dep.deletion_flag) {
                    log.debug("insert {*} ({s}) dependant {*} ({s}) into deletion set", .{
                        decl, decl.name, dep, dep.name,
                    });
                    // We don't perform a deletion here, because this Decl or another one
                    // may end up referencing it before the update is complete.
                    dep.deletion_flag = true;
                    try mod.deletion_set.put(mod.gpa, dep, {});
                }
            }
            decl.dependencies.clearRetainingCapacity();

            break :blk true;
        },

        .unreferenced => false,
    };

    const type_changed = mod.semaDecl(decl) catch |err| switch (err) {
        error.AnalysisFail => {
            if (decl.analysis == .in_progress) {
                // If this decl caused the compile error, the analysis field would
                // be changed to indicate it was this Decl's fault. Because this
                // did not happen, we infer here that it was a dependency failure.
                decl.analysis = .dependency_failure;
            }
            return error.AnalysisFail;
        },
        else => {
            decl.analysis = .sema_failure_retryable;
            try mod.failed_decls.ensureUnusedCapacity(mod.gpa, 1);
            mod.failed_decls.putAssumeCapacityNoClobber(decl, try ErrorMsg.create(
                mod.gpa,
                decl.srcLoc(),
                "unable to analyze: {s}",
                .{@errorName(err)},
            ));
            return error.AnalysisFail;
        },
    };

    if (subsequent_analysis) {
        // We may need to chase the dependants and re-analyze them.
        // However, if the decl is a function, and the type is the same, we do not need to.
        if (type_changed or decl.ty.zigTypeTag() != .Fn) {
            for (decl.dependants.keys()) |dep| {
                switch (dep.analysis) {
                    .unreferenced => unreachable,
                    .in_progress => continue, // already doing analysis, ok
                    .outdated => continue, // already queued for update

                    .file_failure,
                    .dependency_failure,
                    .sema_failure,
                    .sema_failure_retryable,
                    .codegen_failure,
                    .codegen_failure_retryable,
                    .complete,
                    => if (dep.generation != mod.generation) {
                        try mod.markOutdatedDecl(dep);
                    },
                }
            }
        }
    }
}

pub fn semaPkg(mod: *Module, pkg: *Package) !void {
    const file = (try mod.importPkg(pkg)).file;
    return mod.semaFile(file);
}

/// Regardless of the file status, will create a `Decl` so that we
/// can track dependencies and re-analyze when the file becomes outdated.
pub fn semaFile(mod: *Module, file: *Scope.File) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    if (file.root_decl != null) return;

    const gpa = mod.gpa;
    var new_decl_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer new_decl_arena.deinit();

    const struct_obj = try new_decl_arena.allocator.create(Module.Struct);
    const struct_ty = try Type.Tag.@"struct".create(&new_decl_arena.allocator, struct_obj);
    const struct_val = try Value.Tag.ty.create(&new_decl_arena.allocator, struct_ty);
    struct_obj.* = .{
        .owner_decl = undefined, // set below
        .fields = .{},
        .node_offset = 0, // it's the struct for the root file
        .zir_index = undefined, // set below
        .layout = .Auto,
        .status = .none,
        .namespace = .{
            .parent = null,
            .ty = struct_ty,
            .file_scope = file,
        },
    };
    const new_decl = try mod.allocateNewDecl(&struct_obj.namespace, 0);
    file.root_decl = new_decl;
    struct_obj.owner_decl = new_decl;
    new_decl.src_line = 0;
    new_decl.name = try file.fullyQualifiedNameZ(gpa);
    new_decl.is_pub = true;
    new_decl.is_exported = false;
    new_decl.has_align = false;
    new_decl.has_linksection = false;
    new_decl.ty = struct_ty;
    new_decl.val = struct_val;
    new_decl.has_tv = true;
    new_decl.owns_tv = true;
    new_decl.analysis = .in_progress;
    new_decl.generation = mod.generation;

    if (file.status == .success_zir) {
        assert(file.zir_loaded);
        const main_struct_inst = file.zir.getMainStruct();
        struct_obj.zir_index = main_struct_inst;

        var sema_arena = std.heap.ArenaAllocator.init(gpa);
        defer sema_arena.deinit();

        var sema: Sema = .{
            .mod = mod,
            .gpa = gpa,
            .arena = &sema_arena.allocator,
            .code = file.zir,
            .owner_decl = new_decl,
            .namespace = &struct_obj.namespace,
            .func = null,
            .owner_func = null,
            .param_inst_list = &.{},
        };
        defer sema.deinit();
        var block_scope: Scope.Block = .{
            .parent = null,
            .sema = &sema,
            .src_decl = new_decl,
            .instructions = .{},
            .inlining = null,
            .is_comptime = true,
        };
        defer block_scope.instructions.deinit(gpa);

        if (sema.analyzeStructDecl(new_decl, main_struct_inst, struct_obj)) |_| {
            new_decl.analysis = .complete;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AnalysisFail => {},
        }
    } else {
        new_decl.analysis = .file_failure;
    }

    try new_decl.finalizeNewArena(&new_decl_arena);
}

/// Returns `true` if the Decl type changed.
/// Returns `true` if this is the first time analyzing the Decl.
/// Returns `false` otherwise.
fn semaDecl(mod: *Module, decl: *Decl) !bool {
    const tracy = trace(@src());
    defer tracy.end();

    if (decl.namespace.file_scope.status != .success_zir) {
        return error.AnalysisFail;
    }

    const gpa = mod.gpa;
    const zir = decl.namespace.file_scope.zir;
    const zir_datas = zir.instructions.items(.data);

    decl.analysis = .in_progress;

    var analysis_arena = std.heap.ArenaAllocator.init(gpa);
    defer analysis_arena.deinit();

    var sema: Sema = .{
        .mod = mod,
        .gpa = gpa,
        .arena = &analysis_arena.allocator,
        .code = zir,
        .owner_decl = decl,
        .namespace = decl.namespace,
        .func = null,
        .owner_func = null,
        .param_inst_list = &.{},
    };
    defer sema.deinit();

    if (decl.isRoot()) {
        log.debug("semaDecl root {*} ({s})", .{ decl, decl.name });
        const main_struct_inst = zir.getMainStruct();
        const struct_obj = decl.getStruct().?;
        // This might not have gotten set in `semaFile` if the first time had
        // a ZIR failure, so we set it here in case.
        struct_obj.zir_index = main_struct_inst;
        try sema.analyzeStructDecl(decl, main_struct_inst, struct_obj);
        decl.analysis = .complete;
        decl.generation = mod.generation;
        return false;
    }

    var block_scope: Scope.Block = .{
        .parent = null,
        .sema = &sema,
        .src_decl = decl,
        .instructions = .{},
        .inlining = null,
        .is_comptime = true,
    };
    defer block_scope.instructions.deinit(gpa);

    const zir_block_index = decl.zirBlockIndex();
    const inst_data = zir_datas[zir_block_index].pl_node;
    const extra = zir.extraData(Zir.Inst.Block, inst_data.payload_index);
    const body = zir.extra[extra.end..][0..extra.data.body_len];
    const break_index = try sema.analyzeBody(&block_scope, body);
    const result_ref = zir_datas[break_index].@"break".operand;
    const src: LazySrcLoc = .{ .node_offset = 0 };
    const decl_tv = try sema.resolveInstConst(&block_scope, src, result_ref);
    const align_val = blk: {
        const align_ref = decl.zirAlignRef();
        if (align_ref == .none) break :blk Value.initTag(.null_value);
        break :blk (try sema.resolveInstConst(&block_scope, src, align_ref)).val;
    };
    const linksection_val = blk: {
        const linksection_ref = decl.zirLinksectionRef();
        if (linksection_ref == .none) break :blk Value.initTag(.null_value);
        break :blk (try sema.resolveInstConst(&block_scope, src, linksection_ref)).val;
    };

    // We need the memory for the Type to go into the arena for the Decl
    var decl_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer decl_arena.deinit();
    const decl_arena_state = try decl_arena.allocator.create(std.heap.ArenaAllocator.State);

    if (decl_tv.val.castTag(.function)) |fn_payload| {
        var prev_type_has_bits = false;
        var prev_is_inline = false;
        var type_changed = true;

        if (decl.has_tv) {
            prev_type_has_bits = decl.ty.hasCodeGenBits();
            type_changed = !decl.ty.eql(decl_tv.ty);
            if (decl.getFunction()) |prev_func| {
                prev_is_inline = prev_func.state == .inline_only;
            }
            decl.clearValues(gpa);
        }

        decl.ty = try decl_tv.ty.copy(&decl_arena.allocator);
        decl.val = try decl_tv.val.copy(&decl_arena.allocator);
        decl.align_val = try align_val.copy(&decl_arena.allocator);
        decl.linksection_val = try linksection_val.copy(&decl_arena.allocator);
        decl.has_tv = true;
        decl.owns_tv = fn_payload.data.owner_decl == decl;
        decl_arena_state.* = decl_arena.state;
        decl.value_arena = decl_arena_state;
        decl.analysis = .complete;
        decl.generation = mod.generation;

        const is_inline = decl_tv.ty.fnCallingConvention() == .Inline;
        if (!is_inline and decl_tv.ty.hasCodeGenBits()) {
            // We don't fully codegen the decl until later, but we do need to reserve a global
            // offset table index for it. This allows us to codegen decls out of dependency order,
            // increasing how many computations can be done in parallel.
            try mod.comp.bin_file.allocateDeclIndexes(decl);
            try mod.comp.work_queue.writeItem(.{ .codegen_decl = decl });
            if (type_changed and mod.emit_h != null) {
                try mod.comp.work_queue.writeItem(.{ .emit_h_decl = decl });
            }
        } else if (!prev_is_inline and prev_type_has_bits) {
            mod.comp.bin_file.freeDecl(decl);
        }

        if (decl.is_exported) {
            const export_src = src; // TODO make this point at `export` token
            if (is_inline) {
                return mod.fail(&block_scope.base, export_src, "export of inline function", .{});
            }
            // The scope needs to have the decl in it.
            try mod.analyzeExport(&block_scope.base, export_src, mem.spanZ(decl.name), decl);
        }
        return type_changed or is_inline != prev_is_inline;
    } else {
        var type_changed = true;
        if (decl.has_tv) {
            type_changed = !decl.ty.eql(decl_tv.ty);
            decl.clearValues(gpa);
        }

        decl.owns_tv = false;
        var queue_linker_work = false;
        if (decl_tv.val.castTag(.variable)) |payload| {
            const variable = payload.data;
            if (variable.owner_decl == decl) {
                decl.owns_tv = true;
                queue_linker_work = true;

                const copied_init = try variable.init.copy(&decl_arena.allocator);
                variable.init = copied_init;
            }
        } else if (decl_tv.val.castTag(.extern_fn)) |payload| {
            const owner_decl = payload.data;
            if (decl == owner_decl) {
                decl.owns_tv = true;
                queue_linker_work = true;
            }
        }

        decl.ty = try decl_tv.ty.copy(&decl_arena.allocator);
        decl.val = try decl_tv.val.copy(&decl_arena.allocator);
        decl.align_val = try align_val.copy(&decl_arena.allocator);
        decl.linksection_val = try linksection_val.copy(&decl_arena.allocator);
        decl.has_tv = true;
        decl_arena_state.* = decl_arena.state;
        decl.value_arena = decl_arena_state;
        decl.analysis = .complete;
        decl.generation = mod.generation;

        if (queue_linker_work and decl.ty.hasCodeGenBits()) {
            try mod.comp.bin_file.allocateDeclIndexes(decl);
            try mod.comp.work_queue.writeItem(.{ .codegen_decl = decl });

            if (type_changed and mod.emit_h != null) {
                try mod.comp.work_queue.writeItem(.{ .emit_h_decl = decl });
            }
        }

        if (decl.is_exported) {
            const export_src = src; // TODO point to the export token
            // The scope needs to have the decl in it.
            try mod.analyzeExport(&block_scope.base, export_src, mem.spanZ(decl.name), decl);
        }

        return type_changed;
    }
}

/// Returns the depender's index of the dependee.
pub fn declareDeclDependency(mod: *Module, depender: *Decl, dependee: *Decl) !void {
    if (depender == dependee) return;

    log.debug("{*} ({s}) depends on {*} ({s})", .{
        depender, depender.name, dependee, dependee.name,
    });

    try depender.dependencies.ensureUnusedCapacity(mod.gpa, 1);
    try dependee.dependants.ensureUnusedCapacity(mod.gpa, 1);

    if (dependee.deletion_flag) {
        dependee.deletion_flag = false;
        assert(mod.deletion_set.swapRemove(dependee));
    }

    dependee.dependants.putAssumeCapacity(depender, {});
    depender.dependencies.putAssumeCapacity(dependee, {});
}

pub const ImportFileResult = struct {
    file: *Scope.File,
    is_new: bool,
};

pub fn importPkg(mod: *Module, pkg: *Package) !ImportFileResult {
    const gpa = mod.gpa;

    // The resolved path is used as the key in the import table, to detect if
    // an import refers to the same as another, despite different relative paths
    // or differently mapped package names.
    const resolved_path = try std.fs.path.resolve(gpa, &[_][]const u8{
        pkg.root_src_directory.path orelse ".", pkg.root_src_path,
    });
    var keep_resolved_path = false;
    defer if (!keep_resolved_path) gpa.free(resolved_path);

    const gop = try mod.import_table.getOrPut(gpa, resolved_path);
    if (gop.found_existing) return ImportFileResult{
        .file = gop.value_ptr.*,
        .is_new = false,
    };
    keep_resolved_path = true; // It's now owned by import_table.

    const sub_file_path = try gpa.dupe(u8, pkg.root_src_path);
    errdefer gpa.free(sub_file_path);

    const new_file = try gpa.create(Scope.File);
    errdefer gpa.destroy(new_file);

    gop.value_ptr.* = new_file;
    new_file.* = .{
        .sub_file_path = sub_file_path,
        .source = undefined,
        .source_loaded = false,
        .tree_loaded = false,
        .zir_loaded = false,
        .stat_size = undefined,
        .stat_inode = undefined,
        .stat_mtime = undefined,
        .tree = undefined,
        .zir = undefined,
        .status = .never_loaded,
        .pkg = pkg,
        .root_decl = null,
    };
    return ImportFileResult{
        .file = new_file,
        .is_new = true,
    };
}

pub fn importFile(
    mod: *Module,
    cur_file: *Scope.File,
    import_string: []const u8,
) !ImportFileResult {
    if (cur_file.pkg.table.get(import_string)) |pkg| {
        return mod.importPkg(pkg);
    }
    if (!mem.endsWith(u8, import_string, ".zig")) {
        return error.PackageNotFound;
    }
    const gpa = mod.gpa;

    // The resolved path is used as the key in the import table, to detect if
    // an import refers to the same as another, despite different relative paths
    // or differently mapped package names.
    const cur_pkg_dir_path = cur_file.pkg.root_src_directory.path orelse ".";
    const resolved_path = try std.fs.path.resolve(gpa, &[_][]const u8{
        cur_pkg_dir_path, cur_file.sub_file_path, "..", import_string,
    });
    var keep_resolved_path = false;
    defer if (!keep_resolved_path) gpa.free(resolved_path);

    const gop = try mod.import_table.getOrPut(gpa, resolved_path);
    if (gop.found_existing) return ImportFileResult{
        .file = gop.value_ptr.*,
        .is_new = false,
    };
    keep_resolved_path = true; // It's now owned by import_table.

    const new_file = try gpa.create(Scope.File);
    errdefer gpa.destroy(new_file);

    const resolved_root_path = try std.fs.path.resolve(gpa, &[_][]const u8{cur_pkg_dir_path});
    defer gpa.free(resolved_root_path);

    if (!mem.startsWith(u8, resolved_path, resolved_root_path)) {
        return error.ImportOutsidePkgPath;
    }
    // +1 for the directory separator here.
    const sub_file_path = try gpa.dupe(u8, resolved_path[resolved_root_path.len + 1 ..]);
    errdefer gpa.free(sub_file_path);

    log.debug("new importFile. resolved_root_path={s}, resolved_path={s}, sub_file_path={s}, import_string={s}", .{
        resolved_root_path, resolved_path, sub_file_path, import_string,
    });

    gop.value_ptr.* = new_file;
    new_file.* = .{
        .sub_file_path = sub_file_path,
        .source = undefined,
        .source_loaded = false,
        .tree_loaded = false,
        .zir_loaded = false,
        .stat_size = undefined,
        .stat_inode = undefined,
        .stat_mtime = undefined,
        .tree = undefined,
        .zir = undefined,
        .status = .never_loaded,
        .pkg = cur_file.pkg,
        .root_decl = null,
    };
    return ImportFileResult{
        .file = new_file,
        .is_new = true,
    };
}

pub fn scanNamespace(
    mod: *Module,
    namespace: *Scope.Namespace,
    extra_start: usize,
    decls_len: u32,
    parent_decl: *Decl,
) InnerError!usize {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = mod.gpa;
    const zir = namespace.file_scope.zir;

    try mod.comp.work_queue.ensureUnusedCapacity(decls_len);
    try namespace.decls.ensureCapacity(gpa, decls_len);

    const bit_bags_count = std.math.divCeil(usize, decls_len, 8) catch unreachable;
    var extra_index = extra_start + bit_bags_count;
    var bit_bag_index: usize = extra_start;
    var cur_bit_bag: u32 = undefined;
    var decl_i: u32 = 0;
    var scan_decl_iter: ScanDeclIter = .{
        .module = mod,
        .namespace = namespace,
        .parent_decl = parent_decl,
    };
    while (decl_i < decls_len) : (decl_i += 1) {
        if (decl_i % 8 == 0) {
            cur_bit_bag = zir.extra[bit_bag_index];
            bit_bag_index += 1;
        }
        const flags = @truncate(u4, cur_bit_bag);
        cur_bit_bag >>= 4;

        const decl_sub_index = extra_index;
        extra_index += 7; // src_hash(4) + line(1) + name(1) + value(1)
        extra_index += @truncate(u1, flags >> 2);
        extra_index += @truncate(u1, flags >> 3);

        try scanDecl(&scan_decl_iter, decl_sub_index, flags);
    }
    return extra_index;
}

const ScanDeclIter = struct {
    module: *Module,
    namespace: *Scope.Namespace,
    parent_decl: *Decl,
    usingnamespace_index: usize = 0,
    comptime_index: usize = 0,
    unnamed_test_index: usize = 0,
};

fn scanDecl(iter: *ScanDeclIter, decl_sub_index: usize, flags: u4) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const mod = iter.module;
    const namespace = iter.namespace;
    const gpa = mod.gpa;
    const zir = namespace.file_scope.zir;

    // zig fmt: off
    const is_pub          = (flags & 0b0001) != 0;
    const is_exported     = (flags & 0b0010) != 0;
    const has_align       = (flags & 0b0100) != 0;
    const has_linksection = (flags & 0b1000) != 0;
    // zig fmt: on

    const line = iter.parent_decl.relativeToLine(zir.extra[decl_sub_index + 4]);
    const decl_name_index = zir.extra[decl_sub_index + 5];
    const decl_index = zir.extra[decl_sub_index + 6];
    const decl_block_inst_data = zir.instructions.items(.data)[decl_index].pl_node;
    const decl_node = iter.parent_decl.relativeToNodeIndex(decl_block_inst_data.src_node);

    // Every Decl needs a name.
    var is_named_test = false;
    const decl_name: [:0]const u8 = switch (decl_name_index) {
        0 => name: {
            if (is_exported) {
                const i = iter.usingnamespace_index;
                iter.usingnamespace_index += 1;
                break :name try std.fmt.allocPrintZ(gpa, "usingnamespace_{d}", .{i});
            } else {
                const i = iter.comptime_index;
                iter.comptime_index += 1;
                break :name try std.fmt.allocPrintZ(gpa, "comptime_{d}", .{i});
            }
        },
        1 => name: {
            const i = iter.unnamed_test_index;
            iter.unnamed_test_index += 1;
            break :name try std.fmt.allocPrintZ(gpa, "test_{d}", .{i});
        },
        else => name: {
            const raw_name = zir.nullTerminatedString(decl_name_index);
            if (raw_name.len == 0) {
                is_named_test = true;
                const test_name = zir.nullTerminatedString(decl_name_index + 1);
                break :name try std.fmt.allocPrintZ(gpa, "test.{s}", .{test_name});
            } else {
                break :name try gpa.dupeZ(u8, raw_name);
            }
        },
    };

    // We create a Decl for it regardless of analysis status.
    const gop = try namespace.decls.getOrPut(gpa, decl_name);
    if (!gop.found_existing) {
        const new_decl = try mod.allocateNewDecl(namespace, decl_node);
        log.debug("scan new {*} ({s}) into {*}", .{ new_decl, decl_name, namespace });
        new_decl.src_line = line;
        new_decl.name = decl_name;
        gop.value_ptr.* = new_decl;
        // Exported decls, comptime decls, usingnamespace decls, and
        // test decls if in test mode, get analyzed.
        const want_analysis = is_exported or switch (decl_name_index) {
            0 => true, // comptime decl
            1 => mod.comp.bin_file.options.is_test, // test decl
            else => is_named_test and mod.comp.bin_file.options.is_test,
        };
        if (want_analysis) {
            mod.comp.work_queue.writeItemAssumeCapacity(.{ .analyze_decl = new_decl });
        }
        new_decl.is_pub = is_pub;
        new_decl.is_exported = is_exported;
        new_decl.has_align = has_align;
        new_decl.has_linksection = has_linksection;
        new_decl.zir_decl_index = @intCast(u32, decl_sub_index);
        return;
    }
    gpa.free(decl_name);
    const decl = gop.value_ptr.*;
    log.debug("scan existing {*} ({s}) of {*}", .{ decl, decl.name, namespace });
    // Update the AST node of the decl; even if its contents are unchanged, it may
    // have been re-ordered.
    decl.src_node = decl_node;
    decl.src_line = line;

    decl.is_pub = is_pub;
    decl.is_exported = is_exported;
    decl.has_align = has_align;
    decl.has_linksection = has_linksection;
    decl.zir_decl_index = @intCast(u32, decl_sub_index);
    if (decl.getFunction()) |_| {
        switch (mod.comp.bin_file.tag) {
            .coff => {
                // TODO Implement for COFF
            },
            .elf => if (decl.fn_link.elf.len != 0) {
                // TODO Look into detecting when this would be unnecessary by storing enough state
                // in `Decl` to notice that the line number did not change.
                mod.comp.work_queue.writeItemAssumeCapacity(.{ .update_line_number = decl });
            },
            .macho => if (decl.fn_link.macho.len != 0) {
                // TODO Look into detecting when this would be unnecessary by storing enough state
                // in `Decl` to notice that the line number did not change.
                mod.comp.work_queue.writeItemAssumeCapacity(.{ .update_line_number = decl });
            },
            .plan9 => {
                // TODO implement for plan9
            },
            .c, .wasm, .spirv => {},
        }
    }
}

/// Make it as if the semantic analysis for this Decl never happened.
pub fn clearDecl(
    mod: *Module,
    decl: *Decl,
    outdated_decls: ?*std.AutoArrayHashMap(*Decl, void),
) Allocator.Error!void {
    const tracy = trace(@src());
    defer tracy.end();

    log.debug("clearing {*} ({s})", .{ decl, decl.name });

    const gpa = mod.gpa;
    try mod.deletion_set.ensureUnusedCapacity(gpa, decl.dependencies.count());

    if (outdated_decls) |map| {
        _ = map.swapRemove(decl);
        try map.ensureUnusedCapacity(decl.dependants.count());
    }

    // Remove itself from its dependencies.
    for (decl.dependencies.keys()) |dep| {
        dep.removeDependant(decl);
        if (dep.dependants.count() == 0 and !dep.deletion_flag) {
            log.debug("insert {*} ({s}) dependant {*} ({s}) into deletion set", .{
                decl, decl.name, dep, dep.name,
            });
            // We don't recursively perform a deletion here, because during the update,
            // another reference to it may turn up.
            dep.deletion_flag = true;
            mod.deletion_set.putAssumeCapacity(dep, {});
        }
    }
    decl.dependencies.clearRetainingCapacity();

    // Anything that depends on this deleted decl needs to be re-analyzed.
    for (decl.dependants.keys()) |dep| {
        dep.removeDependency(decl);
        if (outdated_decls) |map| {
            map.putAssumeCapacity(dep, {});
        } else if (std.debug.runtime_safety) {
            // If `outdated_decls` is `null`, it means we're being called from
            // `Compilation` after `performAllTheWork` and we cannot queue up any
            // more work. `dep` must necessarily be another Decl that is no longer
            // being referenced, and will be in the `deletion_set`. Otherwise,
            // something has gone wrong.
            assert(mod.deletion_set.contains(dep));
        }
    }
    decl.dependants.clearRetainingCapacity();

    if (mod.failed_decls.fetchSwapRemove(decl)) |kv| {
        kv.value.destroy(gpa);
    }
    if (mod.emit_h) |emit_h| {
        if (emit_h.failed_decls.fetchSwapRemove(decl)) |kv| {
            kv.value.destroy(gpa);
        }
        assert(emit_h.decl_table.swapRemove(decl));
    }
    _ = mod.compile_log_decls.swapRemove(decl);
    mod.deleteDeclExports(decl);

    if (decl.has_tv) {
        if (decl.ty.hasCodeGenBits()) {
            mod.comp.bin_file.freeDecl(decl);

            // TODO instead of a union, put this memory trailing Decl objects,
            // and allow it to be variably sized.
            decl.link = switch (mod.comp.bin_file.tag) {
                .coff => .{ .coff = link.File.Coff.TextBlock.empty },
                .elf => .{ .elf = link.File.Elf.TextBlock.empty },
                .macho => .{ .macho = link.File.MachO.TextBlock.empty },
                .plan9 => .{ .plan9 = link.File.Plan9.DeclBlock.empty },
                .c => .{ .c = link.File.C.DeclBlock.empty },
                .wasm => .{ .wasm = link.File.Wasm.DeclBlock.empty },
                .spirv => .{ .spirv = {} },
            };
            decl.fn_link = switch (mod.comp.bin_file.tag) {
                .coff => .{ .coff = {} },
                .elf => .{ .elf = link.File.Elf.SrcFn.empty },
                .macho => .{ .macho = link.File.MachO.SrcFn.empty },
                .plan9 => .{ .plan9 = {} },
                .c => .{ .c = link.File.C.FnBlock.empty },
                .wasm => .{ .wasm = link.File.Wasm.FnData.empty },
                .spirv => .{ .spirv = .{} },
            };
        }
        if (decl.getInnerNamespace()) |namespace| {
            try namespace.deleteAllDecls(mod, outdated_decls);
        }
        decl.clearValues(gpa);
    }

    if (decl.deletion_flag) {
        decl.deletion_flag = false;
        assert(mod.deletion_set.swapRemove(decl));
    }

    decl.analysis = .unreferenced;
}

/// Delete all the Export objects that are caused by this Decl. Re-analysis of
/// this Decl will cause them to be re-created (or not).
fn deleteDeclExports(mod: *Module, decl: *Decl) void {
    const kv = mod.export_owners.fetchSwapRemove(decl) orelse return;

    for (kv.value) |exp| {
        if (mod.decl_exports.getPtr(exp.exported_decl)) |value_ptr| {
            // Remove exports with owner_decl matching the regenerating decl.
            const list = value_ptr.*;
            var i: usize = 0;
            var new_len = list.len;
            while (i < new_len) {
                if (list[i].owner_decl == decl) {
                    mem.copyBackwards(*Export, list[i..], list[i + 1 .. new_len]);
                    new_len -= 1;
                } else {
                    i += 1;
                }
            }
            value_ptr.* = mod.gpa.shrink(list, new_len);
            if (new_len == 0) {
                assert(mod.decl_exports.swapRemove(exp.exported_decl));
            }
        }
        if (mod.comp.bin_file.cast(link.File.Elf)) |elf| {
            elf.deleteExport(exp.link.elf);
        }
        if (mod.comp.bin_file.cast(link.File.MachO)) |macho| {
            macho.deleteExport(exp.link.macho);
        }
        if (mod.failed_exports.fetchSwapRemove(exp)) |failed_kv| {
            failed_kv.value.destroy(mod.gpa);
        }
        mod.gpa.free(exp.options.name);
        mod.gpa.destroy(exp);
    }
    mod.gpa.free(kv.value);
}

pub fn analyzeFnBody(mod: *Module, decl: *Decl, func: *Fn) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Use the Decl's arena for function memory.
    var arena = decl.value_arena.?.promote(mod.gpa);
    defer decl.value_arena.?.* = arena.state;

    const fn_ty = decl.ty;
    const param_inst_list = try mod.gpa.alloc(*ir.Inst, fn_ty.fnParamLen());
    defer mod.gpa.free(param_inst_list);

    for (param_inst_list) |*param_inst, param_index| {
        const param_type = fn_ty.fnParamType(param_index);
        const arg_inst = try arena.allocator.create(ir.Inst.Arg);
        arg_inst.* = .{
            .base = .{
                .tag = .arg,
                .ty = param_type,
                .src = .unneeded,
            },
            .name = undefined, // Set in the semantic analysis of the arg instruction.
        };
        param_inst.* = &arg_inst.base;
    }

    const zir = decl.namespace.file_scope.zir;

    var sema: Sema = .{
        .mod = mod,
        .gpa = mod.gpa,
        .arena = &arena.allocator,
        .code = zir,
        .owner_decl = decl,
        .namespace = decl.namespace,
        .func = func,
        .owner_func = func,
        .param_inst_list = param_inst_list,
    };
    defer sema.deinit();

    var inner_block: Scope.Block = .{
        .parent = null,
        .sema = &sema,
        .src_decl = decl,
        .instructions = .{},
        .inlining = null,
        .is_comptime = false,
    };
    defer inner_block.instructions.deinit(mod.gpa);

    // AIR currently requires the arg parameters to be the first N instructions
    try inner_block.instructions.appendSlice(mod.gpa, param_inst_list);

    func.state = .in_progress;
    log.debug("set {s} to in_progress", .{decl.name});

    try sema.analyzeFnBody(&inner_block, func.zir_body_inst);

    const instructions = try arena.allocator.dupe(*ir.Inst, inner_block.instructions.items);
    func.state = .success;
    func.body = .{ .instructions = instructions };
    log.debug("set {s} to success", .{decl.name});
}

fn markOutdatedDecl(mod: *Module, decl: *Decl) !void {
    log.debug("mark outdated {*} ({s})", .{ decl, decl.name });
    try mod.comp.work_queue.writeItem(.{ .analyze_decl = decl });
    if (mod.failed_decls.fetchSwapRemove(decl)) |kv| {
        kv.value.destroy(mod.gpa);
    }
    if (mod.emit_h) |emit_h| {
        if (emit_h.failed_decls.fetchSwapRemove(decl)) |kv| {
            kv.value.destroy(mod.gpa);
        }
    }
    _ = mod.compile_log_decls.swapRemove(decl);
    decl.analysis = .outdated;
}

fn allocateNewDecl(mod: *Module, namespace: *Scope.Namespace, src_node: ast.Node.Index) !*Decl {
    // If we have emit-h then we must allocate a bigger structure to store the emit-h state.
    const new_decl: *Decl = if (mod.emit_h != null) blk: {
        const parent_struct = try mod.gpa.create(DeclPlusEmitH);
        parent_struct.* = .{
            .emit_h = .{},
            .decl = undefined,
        };
        break :blk &parent_struct.decl;
    } else try mod.gpa.create(Decl);

    new_decl.* = .{
        .name = "",
        .namespace = namespace,
        .src_node = src_node,
        .src_line = undefined,
        .has_tv = false,
        .owns_tv = false,
        .ty = undefined,
        .val = undefined,
        .align_val = undefined,
        .linksection_val = undefined,
        .analysis = .unreferenced,
        .deletion_flag = false,
        .zir_decl_index = 0,
        .link = switch (mod.comp.bin_file.tag) {
            .coff => .{ .coff = link.File.Coff.TextBlock.empty },
            .elf => .{ .elf = link.File.Elf.TextBlock.empty },
            .macho => .{ .macho = link.File.MachO.TextBlock.empty },
            .plan9 => .{ .plan9 = link.File.Plan9.DeclBlock.empty },
            .c => .{ .c = link.File.C.DeclBlock.empty },
            .wasm => .{ .wasm = link.File.Wasm.DeclBlock.empty },
            .spirv => .{ .spirv = {} },
        },
        .fn_link = switch (mod.comp.bin_file.tag) {
            .coff => .{ .coff = {} },
            .elf => .{ .elf = link.File.Elf.SrcFn.empty },
            .macho => .{ .macho = link.File.MachO.SrcFn.empty },
            .plan9 => .{ .plan9 = {} },
            .c => .{ .c = link.File.C.FnBlock.empty },
            .wasm => .{ .wasm = link.File.Wasm.FnData.empty },
            .spirv => .{ .spirv = .{} },
        },
        .generation = 0,
        .is_pub = false,
        .is_exported = false,
        .has_linksection = false,
        .has_align = false,
    };
    return new_decl;
}

/// Get error value for error tag `name`.
pub fn getErrorValue(mod: *Module, name: []const u8) !std.StringHashMapUnmanaged(ErrorInt).KV {
    const gop = try mod.global_error_set.getOrPut(mod.gpa, name);
    if (gop.found_existing) {
        return std.StringHashMapUnmanaged(ErrorInt).KV{
            .key = gop.key_ptr.*,
            .value = gop.value_ptr.*,
        };
    }

    errdefer assert(mod.global_error_set.remove(name));
    try mod.error_name_list.ensureCapacity(mod.gpa, mod.error_name_list.items.len + 1);
    gop.key_ptr.* = try mod.gpa.dupe(u8, name);
    gop.value_ptr.* = @intCast(ErrorInt, mod.error_name_list.items.len);
    mod.error_name_list.appendAssumeCapacity(gop.key_ptr.*);
    return std.StringHashMapUnmanaged(ErrorInt).KV{
        .key = gop.key_ptr.*,
        .value = gop.value_ptr.*,
    };
}

pub fn analyzeExport(
    mod: *Module,
    scope: *Scope,
    src: LazySrcLoc,
    borrowed_symbol_name: []const u8,
    exported_decl: *Decl,
) !void {
    try mod.ensureDeclAnalyzed(exported_decl);
    switch (exported_decl.ty.zigTypeTag()) {
        .Fn => {},
        else => return mod.fail(scope, src, "unable to export type '{}'", .{exported_decl.ty}),
    }

    try mod.decl_exports.ensureCapacity(mod.gpa, mod.decl_exports.count() + 1);
    try mod.export_owners.ensureCapacity(mod.gpa, mod.export_owners.count() + 1);

    const new_export = try mod.gpa.create(Export);
    errdefer mod.gpa.destroy(new_export);

    const symbol_name = try mod.gpa.dupe(u8, borrowed_symbol_name);
    errdefer mod.gpa.free(symbol_name);

    const owner_decl = scope.ownerDecl().?;

    log.debug("exporting Decl '{s}' as symbol '{s}' from Decl '{s}'", .{
        exported_decl.name, borrowed_symbol_name, owner_decl.name,
    });

    new_export.* = .{
        .options = .{ .name = symbol_name },
        .src = src,
        .link = switch (mod.comp.bin_file.tag) {
            .coff => .{ .coff = {} },
            .elf => .{ .elf = link.File.Elf.Export{} },
            .macho => .{ .macho = link.File.MachO.Export{} },
            .plan9 => .{ .plan9 = null },
            .c => .{ .c = {} },
            .wasm => .{ .wasm = {} },
            .spirv => .{ .spirv = {} },
        },
        .owner_decl = owner_decl,
        .exported_decl = exported_decl,
        .status = .in_progress,
    };

    // Add to export_owners table.
    const eo_gop = mod.export_owners.getOrPutAssumeCapacity(owner_decl);
    if (!eo_gop.found_existing) {
        eo_gop.value_ptr.* = &[0]*Export{};
    }
    eo_gop.value_ptr.* = try mod.gpa.realloc(eo_gop.value_ptr.*, eo_gop.value_ptr.len + 1);
    eo_gop.value_ptr.*[eo_gop.value_ptr.len - 1] = new_export;
    errdefer eo_gop.value_ptr.* = mod.gpa.shrink(eo_gop.value_ptr.*, eo_gop.value_ptr.len - 1);

    // Add to exported_decl table.
    const de_gop = mod.decl_exports.getOrPutAssumeCapacity(exported_decl);
    if (!de_gop.found_existing) {
        de_gop.value_ptr.* = &[0]*Export{};
    }
    de_gop.value_ptr.* = try mod.gpa.realloc(de_gop.value_ptr.*, de_gop.value_ptr.len + 1);
    de_gop.value_ptr.*[de_gop.value_ptr.len - 1] = new_export;
    errdefer de_gop.value_ptr.* = mod.gpa.shrink(de_gop.value_ptr.*, de_gop.value_ptr.len - 1);
}
pub fn constInst(mod: *Module, arena: *Allocator, src: LazySrcLoc, typed_value: TypedValue) !*ir.Inst {
    _ = mod;
    const const_inst = try arena.create(ir.Inst.Constant);
    const_inst.* = .{
        .base = .{
            .tag = ir.Inst.Constant.base_tag,
            .ty = typed_value.ty,
            .src = src,
        },
        .val = typed_value.val,
    };
    return &const_inst.base;
}

pub fn constType(mod: *Module, arena: *Allocator, src: LazySrcLoc, ty: Type) !*ir.Inst {
    return mod.constInst(arena, src, .{
        .ty = Type.initTag(.type),
        .val = try ty.toValue(arena),
    });
}

pub fn constVoid(mod: *Module, arena: *Allocator, src: LazySrcLoc) !*ir.Inst {
    return mod.constInst(arena, src, .{
        .ty = Type.initTag(.void),
        .val = Value.initTag(.void_value),
    });
}

pub fn constNoReturn(mod: *Module, arena: *Allocator, src: LazySrcLoc) !*ir.Inst {
    return mod.constInst(arena, src, .{
        .ty = Type.initTag(.noreturn),
        .val = Value.initTag(.unreachable_value),
    });
}

pub fn constUndef(mod: *Module, arena: *Allocator, src: LazySrcLoc, ty: Type) !*ir.Inst {
    return mod.constInst(arena, src, .{
        .ty = ty,
        .val = Value.initTag(.undef),
    });
}

pub fn constBool(mod: *Module, arena: *Allocator, src: LazySrcLoc, v: bool) !*ir.Inst {
    return mod.constInst(arena, src, .{
        .ty = Type.initTag(.bool),
        .val = ([2]Value{ Value.initTag(.bool_false), Value.initTag(.bool_true) })[@boolToInt(v)],
    });
}

pub fn constIntUnsigned(mod: *Module, arena: *Allocator, src: LazySrcLoc, ty: Type, int: u64) !*ir.Inst {
    return mod.constInst(arena, src, .{
        .ty = ty,
        .val = try Value.Tag.int_u64.create(arena, int),
    });
}

pub fn constIntSigned(mod: *Module, arena: *Allocator, src: LazySrcLoc, ty: Type, int: i64) !*ir.Inst {
    return mod.constInst(arena, src, .{
        .ty = ty,
        .val = try Value.Tag.int_i64.create(arena, int),
    });
}

pub fn constIntBig(mod: *Module, arena: *Allocator, src: LazySrcLoc, ty: Type, big_int: BigIntConst) !*ir.Inst {
    if (big_int.positive) {
        if (big_int.to(u64)) |x| {
            return mod.constIntUnsigned(arena, src, ty, x);
        } else |err| switch (err) {
            error.NegativeIntoUnsigned => unreachable,
            error.TargetTooSmall => {}, // handled below
        }
        return mod.constInst(arena, src, .{
            .ty = ty,
            .val = try Value.Tag.int_big_positive.create(arena, big_int.limbs),
        });
    } else {
        if (big_int.to(i64)) |x| {
            return mod.constIntSigned(arena, src, ty, x);
        } else |err| switch (err) {
            error.NegativeIntoUnsigned => unreachable,
            error.TargetTooSmall => {}, // handled below
        }
        return mod.constInst(arena, src, .{
            .ty = ty,
            .val = try Value.Tag.int_big_negative.create(arena, big_int.limbs),
        });
    }
}

pub fn deleteAnonDecl(mod: *Module, scope: *Scope, decl: *Decl) void {
    const scope_decl = scope.ownerDecl().?;
    assert(scope_decl.namespace.anon_decls.swapRemove(decl));
    decl.destroy(mod);
}

/// Takes ownership of `name` even if it returns an error.
pub fn createAnonymousDeclNamed(
    mod: *Module,
    scope: *Scope,
    typed_value: TypedValue,
    name: [:0]u8,
) !*Decl {
    errdefer mod.gpa.free(name);

    const scope_decl = scope.ownerDecl().?;
    const namespace = scope_decl.namespace;
    try namespace.anon_decls.ensureUnusedCapacity(mod.gpa, 1);

    const new_decl = try mod.allocateNewDecl(namespace, scope_decl.src_node);

    new_decl.name = name;
    new_decl.src_line = scope_decl.src_line;
    new_decl.ty = typed_value.ty;
    new_decl.val = typed_value.val;
    new_decl.has_tv = true;
    new_decl.owns_tv = true;
    new_decl.analysis = .complete;
    new_decl.generation = mod.generation;

    namespace.anon_decls.putAssumeCapacityNoClobber(new_decl, {});

    // TODO: This generates the Decl into the machine code file if it is of a
    // type that is non-zero size. We should be able to further improve the
    // compiler to omit Decls which are only referenced at compile-time and not runtime.
    if (typed_value.ty.hasCodeGenBits()) {
        try mod.comp.bin_file.allocateDeclIndexes(new_decl);
        try mod.comp.work_queue.writeItem(.{ .codegen_decl = new_decl });
    }

    return new_decl;
}

pub fn createAnonymousDecl(mod: *Module, scope: *Scope, typed_value: TypedValue) !*Decl {
    const scope_decl = scope.ownerDecl().?;
    const name_index = mod.getNextAnonNameIndex();
    const name = try std.fmt.allocPrintZ(mod.gpa, "{s}__anon_{d}", .{
        scope_decl.name, name_index,
    });
    return mod.createAnonymousDeclNamed(scope, typed_value, name);
}

pub fn getNextAnonNameIndex(mod: *Module) usize {
    return @atomicRmw(usize, &mod.next_anon_name_index, .Add, 1, .Monotonic);
}

pub fn makeIntType(arena: *Allocator, signedness: std.builtin.Signedness, bits: u16) !Type {
    const int_payload = try arena.create(Type.Payload.Bits);
    int_payload.* = .{
        .base = .{
            .tag = switch (signedness) {
                .signed => .int_signed,
                .unsigned => .int_unsigned,
            },
        },
        .data = bits,
    };
    return Type.initPayload(&int_payload.base);
}

/// We don't return a pointer to the new error note because the pointer
/// becomes invalid when you add another one.
pub fn errNote(
    mod: *Module,
    scope: *Scope,
    src: LazySrcLoc,
    parent: *ErrorMsg,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    return mod.errNoteNonLazy(src.toSrcLoc(scope), parent, format, args);
}

pub fn errNoteNonLazy(
    mod: *Module,
    src_loc: SrcLoc,
    parent: *ErrorMsg,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    const msg = try std.fmt.allocPrint(mod.gpa, format, args);
    errdefer mod.gpa.free(msg);

    parent.notes = try mod.gpa.realloc(parent.notes, parent.notes.len + 1);
    parent.notes[parent.notes.len - 1] = .{
        .src_loc = src_loc,
        .msg = msg,
    };
}

pub fn errMsg(
    mod: *Module,
    scope: *Scope,
    src: LazySrcLoc,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!*ErrorMsg {
    return ErrorMsg.create(mod.gpa, src.toSrcLoc(scope), format, args);
}

pub fn fail(
    mod: *Module,
    scope: *Scope,
    src: LazySrcLoc,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    const err_msg = try mod.errMsg(scope, src, format, args);
    return mod.failWithOwnedErrorMsg(scope, err_msg);
}

/// Same as `fail`, except given a token index, and the function sets up the `LazySrcLoc`
/// for pointing at it relatively by subtracting from the containing `Decl`.
pub fn failTok(
    mod: *Module,
    scope: *Scope,
    token_index: ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    const src = scope.srcDecl().?.tokSrcLoc(token_index);
    return mod.fail(scope, src, format, args);
}

/// Same as `fail`, except given an AST node index, and the function sets up the `LazySrcLoc`
/// for pointing at it relatively by subtracting from the containing `Decl`.
pub fn failNode(
    mod: *Module,
    scope: *Scope,
    node_index: ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    const src = scope.srcDecl().?.nodeSrcLoc(node_index);
    return mod.fail(scope, src, format, args);
}

pub fn failWithOwnedErrorMsg(mod: *Module, scope: *Scope, err_msg: *ErrorMsg) InnerError {
    @setCold(true);

    {
        errdefer err_msg.destroy(mod.gpa);
        try mod.failed_decls.ensureCapacity(mod.gpa, mod.failed_decls.count() + 1);
        try mod.failed_files.ensureCapacity(mod.gpa, mod.failed_files.count() + 1);
    }
    switch (scope.tag) {
        .block => {
            const block = scope.cast(Scope.Block).?;
            if (block.sema.owner_func) |func| {
                func.state = .sema_failure;
            } else {
                block.sema.owner_decl.analysis = .sema_failure;
                block.sema.owner_decl.generation = mod.generation;
            }
            mod.failed_decls.putAssumeCapacityNoClobber(block.sema.owner_decl, err_msg);
        },
        .file => unreachable,
        .namespace => unreachable,
    }
    return error.AnalysisFail;
}

pub fn intAdd(allocator: *Allocator, lhs: Value, rhs: Value) !Value {
    // TODO is this a performance issue? maybe we should try the operation without
    // resorting to BigInt first.
    var lhs_space: Value.BigIntSpace = undefined;
    var rhs_space: Value.BigIntSpace = undefined;
    const lhs_bigint = lhs.toBigInt(&lhs_space);
    const rhs_bigint = rhs.toBigInt(&rhs_space);
    const limbs = try allocator.alloc(
        std.math.big.Limb,
        std.math.max(lhs_bigint.limbs.len, rhs_bigint.limbs.len) + 1,
    );
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.add(lhs_bigint, rhs_bigint);
    const result_limbs = result_bigint.limbs[0..result_bigint.len];

    if (result_bigint.positive) {
        return Value.Tag.int_big_positive.create(allocator, result_limbs);
    } else {
        return Value.Tag.int_big_negative.create(allocator, result_limbs);
    }
}

pub fn intSub(allocator: *Allocator, lhs: Value, rhs: Value) !Value {
    // TODO is this a performance issue? maybe we should try the operation without
    // resorting to BigInt first.
    var lhs_space: Value.BigIntSpace = undefined;
    var rhs_space: Value.BigIntSpace = undefined;
    const lhs_bigint = lhs.toBigInt(&lhs_space);
    const rhs_bigint = rhs.toBigInt(&rhs_space);
    const limbs = try allocator.alloc(
        std.math.big.Limb,
        std.math.max(lhs_bigint.limbs.len, rhs_bigint.limbs.len) + 1,
    );
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.sub(lhs_bigint, rhs_bigint);
    const result_limbs = result_bigint.limbs[0..result_bigint.len];

    if (result_bigint.positive) {
        return Value.Tag.int_big_positive.create(allocator, result_limbs);
    } else {
        return Value.Tag.int_big_negative.create(allocator, result_limbs);
    }
}

pub fn intDiv(allocator: *Allocator, lhs: Value, rhs: Value) !Value {
    // TODO is this a performance issue? maybe we should try the operation without
    // resorting to BigInt first.
    var lhs_space: Value.BigIntSpace = undefined;
    var rhs_space: Value.BigIntSpace = undefined;
    const lhs_bigint = lhs.toBigInt(&lhs_space);
    const rhs_bigint = rhs.toBigInt(&rhs_space);
    const limbs_q = try allocator.alloc(
        std.math.big.Limb,
        lhs_bigint.limbs.len + rhs_bigint.limbs.len + 1,
    );
    const limbs_r = try allocator.alloc(
        std.math.big.Limb,
        lhs_bigint.limbs.len,
    );
    const limbs_buffer = try allocator.alloc(
        std.math.big.Limb,
        std.math.big.int.calcDivLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len),
    );
    var result_q = BigIntMutable{ .limbs = limbs_q, .positive = undefined, .len = undefined };
    var result_r = BigIntMutable{ .limbs = limbs_r, .positive = undefined, .len = undefined };
    result_q.divTrunc(&result_r, lhs_bigint, rhs_bigint, limbs_buffer, null);
    const result_limbs = result_q.limbs[0..result_q.len];

    if (result_q.positive) {
        return Value.Tag.int_big_positive.create(allocator, result_limbs);
    } else {
        return Value.Tag.int_big_negative.create(allocator, result_limbs);
    }
}

pub fn intMul(allocator: *Allocator, lhs: Value, rhs: Value) !Value {
    // TODO is this a performance issue? maybe we should try the operation without
    // resorting to BigInt first.
    var lhs_space: Value.BigIntSpace = undefined;
    var rhs_space: Value.BigIntSpace = undefined;
    const lhs_bigint = lhs.toBigInt(&lhs_space);
    const rhs_bigint = rhs.toBigInt(&rhs_space);
    const limbs = try allocator.alloc(
        std.math.big.Limb,
        lhs_bigint.limbs.len + rhs_bigint.limbs.len + 1,
    );
    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
    var limbs_buffer = try allocator.alloc(
        std.math.big.Limb,
        std.math.big.int.calcMulLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len, 1),
    );
    defer allocator.free(limbs_buffer);
    result_bigint.mul(lhs_bigint, rhs_bigint, limbs_buffer, allocator);
    const result_limbs = result_bigint.limbs[0..result_bigint.len];

    if (result_bigint.positive) {
        return Value.Tag.int_big_positive.create(allocator, result_limbs);
    } else {
        return Value.Tag.int_big_negative.create(allocator, result_limbs);
    }
}

pub fn floatAdd(
    arena: *Allocator,
    float_type: Type,
    src: LazySrcLoc,
    lhs: Value,
    rhs: Value,
) !Value {
    _ = src;
    switch (float_type.tag()) {
        .f16 => {
            @panic("TODO add __trunctfhf2 to compiler-rt");
            //const lhs_val = lhs.toFloat(f16);
            //const rhs_val = rhs.toFloat(f16);
            //return Value.Tag.float_16.create(arena, lhs_val + rhs_val);
        },
        .f32 => {
            const lhs_val = lhs.toFloat(f32);
            const rhs_val = rhs.toFloat(f32);
            return Value.Tag.float_32.create(arena, lhs_val + rhs_val);
        },
        .f64 => {
            const lhs_val = lhs.toFloat(f64);
            const rhs_val = rhs.toFloat(f64);
            return Value.Tag.float_64.create(arena, lhs_val + rhs_val);
        },
        .f128, .comptime_float, .c_longdouble => {
            const lhs_val = lhs.toFloat(f128);
            const rhs_val = rhs.toFloat(f128);
            return Value.Tag.float_128.create(arena, lhs_val + rhs_val);
        },
        else => unreachable,
    }
}

pub fn floatSub(
    arena: *Allocator,
    float_type: Type,
    src: LazySrcLoc,
    lhs: Value,
    rhs: Value,
) !Value {
    _ = src;
    switch (float_type.tag()) {
        .f16 => {
            @panic("TODO add __trunctfhf2 to compiler-rt");
            //const lhs_val = lhs.toFloat(f16);
            //const rhs_val = rhs.toFloat(f16);
            //return Value.Tag.float_16.create(arena, lhs_val - rhs_val);
        },
        .f32 => {
            const lhs_val = lhs.toFloat(f32);
            const rhs_val = rhs.toFloat(f32);
            return Value.Tag.float_32.create(arena, lhs_val - rhs_val);
        },
        .f64 => {
            const lhs_val = lhs.toFloat(f64);
            const rhs_val = rhs.toFloat(f64);
            return Value.Tag.float_64.create(arena, lhs_val - rhs_val);
        },
        .f128, .comptime_float, .c_longdouble => {
            const lhs_val = lhs.toFloat(f128);
            const rhs_val = rhs.toFloat(f128);
            return Value.Tag.float_128.create(arena, lhs_val - rhs_val);
        },
        else => unreachable,
    }
}

pub fn floatDiv(
    arena: *Allocator,
    float_type: Type,
    src: LazySrcLoc,
    lhs: Value,
    rhs: Value,
) !Value {
    _ = src;
    switch (float_type.tag()) {
        .f16 => {
            @panic("TODO add __trunctfhf2 to compiler-rt");
            //const lhs_val = lhs.toFloat(f16);
            //const rhs_val = rhs.toFloat(f16);
            //return Value.Tag.float_16.create(arena, lhs_val / rhs_val);
        },
        .f32 => {
            const lhs_val = lhs.toFloat(f32);
            const rhs_val = rhs.toFloat(f32);
            return Value.Tag.float_32.create(arena, lhs_val / rhs_val);
        },
        .f64 => {
            const lhs_val = lhs.toFloat(f64);
            const rhs_val = rhs.toFloat(f64);
            return Value.Tag.float_64.create(arena, lhs_val / rhs_val);
        },
        .f128, .comptime_float, .c_longdouble => {
            const lhs_val = lhs.toFloat(f128);
            const rhs_val = rhs.toFloat(f128);
            return Value.Tag.float_128.create(arena, lhs_val / rhs_val);
        },
        else => unreachable,
    }
}

pub fn floatMul(
    arena: *Allocator,
    float_type: Type,
    src: LazySrcLoc,
    lhs: Value,
    rhs: Value,
) !Value {
    _ = src;
    switch (float_type.tag()) {
        .f16 => {
            @panic("TODO add __trunctfhf2 to compiler-rt");
            //const lhs_val = lhs.toFloat(f16);
            //const rhs_val = rhs.toFloat(f16);
            //return Value.Tag.float_16.create(arena, lhs_val * rhs_val);
        },
        .f32 => {
            const lhs_val = lhs.toFloat(f32);
            const rhs_val = rhs.toFloat(f32);
            return Value.Tag.float_32.create(arena, lhs_val * rhs_val);
        },
        .f64 => {
            const lhs_val = lhs.toFloat(f64);
            const rhs_val = rhs.toFloat(f64);
            return Value.Tag.float_64.create(arena, lhs_val * rhs_val);
        },
        .f128, .comptime_float, .c_longdouble => {
            const lhs_val = lhs.toFloat(f128);
            const rhs_val = rhs.toFloat(f128);
            return Value.Tag.float_128.create(arena, lhs_val * rhs_val);
        },
        else => unreachable,
    }
}

pub fn simplePtrType(
    mod: *Module,
    arena: *Allocator,
    elem_ty: Type,
    mutable: bool,
    size: std.builtin.TypeInfo.Pointer.Size,
) Allocator.Error!Type {
    _ = mod;
    if (!mutable and size == .Slice and elem_ty.eql(Type.initTag(.u8))) {
        return Type.initTag(.const_slice_u8);
    }
    // TODO stage1 type inference bug
    const T = Type.Tag;

    const type_payload = try arena.create(Type.Payload.ElemType);
    type_payload.* = .{
        .base = .{
            .tag = switch (size) {
                .One => if (mutable) T.single_mut_pointer else T.single_const_pointer,
                .Many => if (mutable) T.many_mut_pointer else T.many_const_pointer,
                .C => if (mutable) T.c_mut_pointer else T.c_const_pointer,
                .Slice => if (mutable) T.mut_slice else T.const_slice,
            },
        },
        .data = elem_ty,
    };
    return Type.initPayload(&type_payload.base);
}

pub fn ptrType(
    mod: *Module,
    arena: *Allocator,
    elem_ty: Type,
    sentinel: ?Value,
    @"align": u32,
    bit_offset: u16,
    host_size: u16,
    mutable: bool,
    @"allowzero": bool,
    @"volatile": bool,
    size: std.builtin.TypeInfo.Pointer.Size,
) Allocator.Error!Type {
    _ = mod;
    assert(host_size == 0 or bit_offset < host_size * 8);

    // TODO check if type can be represented by simplePtrType
    return Type.Tag.pointer.create(arena, .{
        .pointee_type = elem_ty,
        .sentinel = sentinel,
        .@"align" = @"align",
        .bit_offset = bit_offset,
        .host_size = host_size,
        .@"allowzero" = @"allowzero",
        .mutable = mutable,
        .@"volatile" = @"volatile",
        .size = size,
    });
}

pub fn optionalType(mod: *Module, arena: *Allocator, child_type: Type) Allocator.Error!Type {
    _ = mod;
    switch (child_type.tag()) {
        .single_const_pointer => return Type.Tag.optional_single_const_pointer.create(
            arena,
            child_type.elemType(),
        ),
        .single_mut_pointer => return Type.Tag.optional_single_mut_pointer.create(
            arena,
            child_type.elemType(),
        ),
        else => return Type.Tag.optional.create(arena, child_type),
    }
}

pub fn arrayType(
    mod: *Module,
    arena: *Allocator,
    len: u64,
    sentinel: ?Value,
    elem_type: Type,
) Allocator.Error!Type {
    _ = mod;
    if (elem_type.eql(Type.initTag(.u8))) {
        if (sentinel) |some| {
            if (some.eql(Value.initTag(.zero))) {
                return Type.Tag.array_u8_sentinel_0.create(arena, len);
            }
        } else {
            return Type.Tag.array_u8.create(arena, len);
        }
    }

    if (sentinel) |some| {
        return Type.Tag.array_sentinel.create(arena, .{
            .len = len,
            .sentinel = some,
            .elem_type = elem_type,
        });
    }

    return Type.Tag.array.create(arena, .{
        .len = len,
        .elem_type = elem_type,
    });
}

pub fn errorUnionType(
    mod: *Module,
    arena: *Allocator,
    error_set: Type,
    payload: Type,
) Allocator.Error!Type {
    _ = mod;
    assert(error_set.zigTypeTag() == .ErrorSet);
    if (error_set.eql(Type.initTag(.anyerror)) and payload.eql(Type.initTag(.void))) {
        return Type.initTag(.anyerror_void_error_union);
    }

    return Type.Tag.error_union.create(arena, .{
        .error_set = error_set,
        .payload = payload,
    });
}

pub fn dumpInst(mod: *Module, scope: *Scope, inst: *ir.Inst) void {
    const zir_module = scope.namespace();
    const source = zir_module.getSource(mod) catch @panic("dumpInst failed to get source");
    const loc = std.zig.findLineColumn(source, inst.src);
    if (inst.tag == .constant) {
        std.debug.print("constant ty={} val={} src={s}:{d}:{d}\n", .{
            inst.ty,
            inst.castTag(.constant).?.val,
            zir_module.subFilePath(),
            loc.line + 1,
            loc.column + 1,
        });
    } else if (inst.deaths == 0) {
        std.debug.print("{s} ty={} src={s}:{d}:{d}\n", .{
            @tagName(inst.tag),
            inst.ty,
            zir_module.subFilePath(),
            loc.line + 1,
            loc.column + 1,
        });
    } else {
        std.debug.print("{s} ty={} deaths={b} src={s}:{d}:{d}\n", .{
            @tagName(inst.tag),
            inst.ty,
            inst.deaths,
            zir_module.subFilePath(),
            loc.line + 1,
            loc.column + 1,
        });
    }
}

pub fn getTarget(mod: Module) Target {
    return mod.comp.bin_file.options.target;
}

pub fn optimizeMode(mod: Module) std.builtin.Mode {
    return mod.comp.bin_file.options.optimize_mode;
}

fn lockAndClearFileCompileError(mod: *Module, file: *Scope.File) void {
    switch (file.status) {
        .success_zir, .retryable_failure => {},
        .never_loaded, .parse_failure, .astgen_failure => {
            const lock = mod.comp.mutex.acquire();
            defer lock.release();
            if (mod.failed_files.fetchSwapRemove(file)) |kv| {
                if (kv.value) |msg| msg.destroy(mod.gpa); // Delete previous error message.
            }
        },
    }
}

pub const SwitchProngSrc = union(enum) {
    scalar: u32,
    multi: Multi,
    range: Multi,

    pub const Multi = struct {
        prong: u32,
        item: u32,
    };

    pub const RangeExpand = enum { none, first, last };

    /// This function is intended to be called only when it is certain that we need
    /// the LazySrcLoc in order to emit a compile error.
    pub fn resolve(
        prong_src: SwitchProngSrc,
        gpa: *Allocator,
        decl: *Decl,
        switch_node_offset: i32,
        range_expand: RangeExpand,
    ) LazySrcLoc {
        @setCold(true);
        const tree = decl.namespace.file_scope.getTree(gpa) catch |err| {
            // In this case we emit a warning + a less precise source location.
            log.warn("unable to load {s}: {s}", .{
                decl.namespace.file_scope.sub_file_path, @errorName(err),
            });
            return LazySrcLoc{ .node_offset = 0 };
        };
        const switch_node = decl.relativeToNodeIndex(switch_node_offset);
        const main_tokens = tree.nodes.items(.main_token);
        const node_datas = tree.nodes.items(.data);
        const node_tags = tree.nodes.items(.tag);
        const extra = tree.extraData(node_datas[switch_node].rhs, ast.Node.SubRange);
        const case_nodes = tree.extra_data[extra.start..extra.end];

        var multi_i: u32 = 0;
        var scalar_i: u32 = 0;
        for (case_nodes) |case_node| {
            const case = switch (node_tags[case_node]) {
                .switch_case_one => tree.switchCaseOne(case_node),
                .switch_case => tree.switchCase(case_node),
                else => unreachable,
            };
            if (case.ast.values.len == 0)
                continue;
            if (case.ast.values.len == 1 and
                node_tags[case.ast.values[0]] == .identifier and
                mem.eql(u8, tree.tokenSlice(main_tokens[case.ast.values[0]]), "_"))
            {
                continue;
            }
            const is_multi = case.ast.values.len != 1 or
                node_tags[case.ast.values[0]] == .switch_range;

            switch (prong_src) {
                .scalar => |i| if (!is_multi and i == scalar_i) return LazySrcLoc{
                    .node_offset = decl.nodeIndexToRelative(case.ast.values[0]),
                },
                .multi => |s| if (is_multi and s.prong == multi_i) {
                    var item_i: u32 = 0;
                    for (case.ast.values) |item_node| {
                        if (node_tags[item_node] == .switch_range) continue;

                        if (item_i == s.item) return LazySrcLoc{
                            .node_offset = decl.nodeIndexToRelative(item_node),
                        };
                        item_i += 1;
                    } else unreachable;
                },
                .range => |s| if (is_multi and s.prong == multi_i) {
                    var range_i: u32 = 0;
                    for (case.ast.values) |range| {
                        if (node_tags[range] != .switch_range) continue;

                        if (range_i == s.item) switch (range_expand) {
                            .none => return LazySrcLoc{
                                .node_offset = decl.nodeIndexToRelative(range),
                            },
                            .first => return LazySrcLoc{
                                .node_offset = decl.nodeIndexToRelative(node_datas[range].lhs),
                            },
                            .last => return LazySrcLoc{
                                .node_offset = decl.nodeIndexToRelative(node_datas[range].rhs),
                            },
                        };
                        range_i += 1;
                    } else unreachable;
                },
            }
            if (is_multi) {
                multi_i += 1;
            } else {
                scalar_i += 1;
            }
        } else unreachable;
    }
};

pub const PeerTypeCandidateSrc = union(enum) {
    /// Use the .src field of the canidate Inst
    infer: void,
    /// When we want to know the the src of candidate i, look up at
    /// index i in this slice
    override: []LazySrcLoc,
    /// resolvePeerTypes originates from a @TypeOf(...) call
    typeof_builtin_call_node_offset: i32,

    pub fn resolve(
        self: PeerTypeCandidateSrc,
        gpa: *Allocator,
        decl: *Decl,
        candidates: usize,
        candidate_i: usize,
        candidate_src: LazySrcLoc,
    ) LazySrcLoc {
        @setCold(true);

        switch (self) {
            .infer => {
                return candidate_src;
            },
            .override => |candidate_srcs| {
                return candidate_srcs[candidate_i];
            },
            .typeof_builtin_call_node_offset => |node_offset| {
                if (candidates <= 2) {
                    switch (candidate_i) {
                        0 => return LazySrcLoc{ .node_offset_builtin_call_arg0 = node_offset },
                        1 => return LazySrcLoc{ .node_offset_builtin_call_arg1 = node_offset },
                        else => unreachable,
                    }
                }

                const tree = decl.namespace.file_scope.getTree(gpa) catch |err| {
                    // In this case we emit a warning + a less precise source location.
                    log.warn("unable to load {s}: {s}", .{
                        decl.namespace.file_scope.sub_file_path, @errorName(err),
                    });
                    return LazySrcLoc{ .node_offset = 0 };
                };
                const node = decl.relativeToNodeIndex(node_offset);
                const node_datas = tree.nodes.items(.data);
                const params = tree.extra_data[node_datas[node].lhs..node_datas[node].rhs];

                return LazySrcLoc{ .node_abs = params[candidate_i] };
            },
        }
    }
};

pub fn analyzeStructFields(mod: *Module, struct_obj: *Struct) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = mod.gpa;
    const zir = struct_obj.owner_decl.namespace.file_scope.zir;
    const extended = zir.instructions.items(.data)[struct_obj.zir_index].extended;
    assert(extended.opcode == .struct_decl);
    const small = @bitCast(Zir.Inst.StructDecl.Small, extended.small);
    var extra_index: usize = extended.operand;

    const src: LazySrcLoc = .{ .node_offset = struct_obj.node_offset };
    extra_index += @boolToInt(small.has_src_node);

    const body_len = if (small.has_body_len) blk: {
        const body_len = zir.extra[extra_index];
        extra_index += 1;
        break :blk body_len;
    } else 0;

    const fields_len = if (small.has_fields_len) blk: {
        const fields_len = zir.extra[extra_index];
        extra_index += 1;
        break :blk fields_len;
    } else 0;

    const decls_len = if (small.has_decls_len) decls_len: {
        const decls_len = zir.extra[extra_index];
        extra_index += 1;
        break :decls_len decls_len;
    } else 0;

    // Skip over decls.
    var decls_it = zir.declIteratorInner(extra_index, decls_len);
    while (decls_it.next()) |_| {}
    extra_index = decls_it.extra_index;

    const body = zir.extra[extra_index..][0..body_len];
    if (fields_len == 0) {
        assert(body.len == 0);
        return;
    }
    extra_index += body.len;

    var decl_arena = struct_obj.owner_decl.value_arena.?.promote(gpa);
    defer struct_obj.owner_decl.value_arena.?.* = decl_arena.state;

    try struct_obj.fields.ensureCapacity(&decl_arena.allocator, fields_len);

    // We create a block for the field type instructions because they
    // may need to reference Decls from inside the struct namespace.
    // Within the field type, default value, and alignment expressions, the "owner decl"
    // should be the struct itself. Thus we need a new Sema.
    var sema: Sema = .{
        .mod = mod,
        .gpa = gpa,
        .arena = &decl_arena.allocator,
        .code = zir,
        .owner_decl = struct_obj.owner_decl,
        .namespace = &struct_obj.namespace,
        .owner_func = null,
        .func = null,
        .param_inst_list = &.{},
    };
    defer sema.deinit();

    var block: Scope.Block = .{
        .parent = null,
        .sema = &sema,
        .src_decl = struct_obj.owner_decl,
        .instructions = .{},
        .inlining = null,
        .is_comptime = true,
    };
    defer assert(block.instructions.items.len == 0); // should all be comptime instructions

    if (body.len != 0) {
        _ = try sema.analyzeBody(&block, body);
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
            cur_bit_bag = zir.extra[bit_bag_index];
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

        const field_name_zir = zir.nullTerminatedString(zir.extra[extra_index]);
        extra_index += 1;
        const field_type_ref = @intToEnum(Zir.Inst.Ref, zir.extra[extra_index]);
        extra_index += 1;

        // This string needs to outlive the ZIR code.
        const field_name = try decl_arena.allocator.dupe(u8, field_name_zir);
        if (field_type_ref == .none) {
            return mod.fail(&block.base, src, "TODO: implement anytype struct field", .{});
        }
        const field_ty: Type = if (field_type_ref == .none)
            Type.initTag(.noreturn)
        else
            // TODO: if we need to report an error here, use a source location
            // that points to this type expression rather than the struct.
            // But only resolve the source location if we need to emit a compile error.
            try sema.resolveType(&block, src, field_type_ref);

        const gop = struct_obj.fields.getOrPutAssumeCapacity(field_name);
        assert(!gop.found_existing);
        gop.value_ptr.* = .{
            .ty = field_ty,
            .abi_align = Value.initTag(.abi_align_default),
            .default_val = Value.initTag(.unreachable_value),
            .is_comptime = is_comptime,
            .offset = undefined,
        };

        if (has_align) {
            const align_ref = @intToEnum(Zir.Inst.Ref, zir.extra[extra_index]);
            extra_index += 1;
            // TODO: if we need to report an error here, use a source location
            // that points to this alignment expression rather than the struct.
            // But only resolve the source location if we need to emit a compile error.
            gop.value_ptr.abi_align = (try sema.resolveInstConst(&block, src, align_ref)).val;
        }
        if (has_default) {
            const default_ref = @intToEnum(Zir.Inst.Ref, zir.extra[extra_index]);
            extra_index += 1;
            // TODO: if we need to report an error here, use a source location
            // that points to this default value expression rather than the struct.
            // But only resolve the source location if we need to emit a compile error.
            gop.value_ptr.default_val = (try sema.resolveInstConst(&block, src, default_ref)).val;
        }
    }
}

pub fn analyzeUnionFields(mod: *Module, union_obj: *Union) InnerError!void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = mod.gpa;
    const zir = union_obj.owner_decl.namespace.file_scope.zir;
    const extended = zir.instructions.items(.data)[union_obj.zir_index].extended;
    assert(extended.opcode == .union_decl);
    const small = @bitCast(Zir.Inst.UnionDecl.Small, extended.small);
    var extra_index: usize = extended.operand;

    const src: LazySrcLoc = .{ .node_offset = union_obj.node_offset };
    extra_index += @boolToInt(small.has_src_node);

    if (small.has_tag_type) {
        extra_index += 1;
    }

    const body_len = if (small.has_body_len) blk: {
        const body_len = zir.extra[extra_index];
        extra_index += 1;
        break :blk body_len;
    } else 0;

    const fields_len = if (small.has_fields_len) blk: {
        const fields_len = zir.extra[extra_index];
        extra_index += 1;
        break :blk fields_len;
    } else 0;

    const decls_len = if (small.has_decls_len) decls_len: {
        const decls_len = zir.extra[extra_index];
        extra_index += 1;
        break :decls_len decls_len;
    } else 0;

    // Skip over decls.
    var decls_it = zir.declIteratorInner(extra_index, decls_len);
    while (decls_it.next()) |_| {}
    extra_index = decls_it.extra_index;

    const body = zir.extra[extra_index..][0..body_len];
    if (fields_len == 0) {
        assert(body.len == 0);
        return;
    }
    extra_index += body.len;

    var decl_arena = union_obj.owner_decl.value_arena.?.promote(gpa);
    defer union_obj.owner_decl.value_arena.?.* = decl_arena.state;

    try union_obj.fields.ensureCapacity(&decl_arena.allocator, fields_len);

    // We create a block for the field type instructions because they
    // may need to reference Decls from inside the struct namespace.
    // Within the field type, default value, and alignment expressions, the "owner decl"
    // should be the struct itself. Thus we need a new Sema.
    var sema: Sema = .{
        .mod = mod,
        .gpa = gpa,
        .arena = &decl_arena.allocator,
        .code = zir,
        .owner_decl = union_obj.owner_decl,
        .namespace = &union_obj.namespace,
        .owner_func = null,
        .func = null,
        .param_inst_list = &.{},
    };
    defer sema.deinit();

    var block: Scope.Block = .{
        .parent = null,
        .sema = &sema,
        .src_decl = union_obj.owner_decl,
        .instructions = .{},
        .inlining = null,
        .is_comptime = true,
    };
    defer assert(block.instructions.items.len == 0); // should all be comptime instructions

    if (body.len != 0) {
        _ = try sema.analyzeBody(&block, body);
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
            cur_bit_bag = zir.extra[bit_bag_index];
            bit_bag_index += 1;
        }
        const has_type = @truncate(u1, cur_bit_bag) != 0;
        cur_bit_bag >>= 1;
        const has_align = @truncate(u1, cur_bit_bag) != 0;
        cur_bit_bag >>= 1;
        const has_tag = @truncate(u1, cur_bit_bag) != 0;
        cur_bit_bag >>= 1;
        const unused = @truncate(u1, cur_bit_bag) != 0;
        cur_bit_bag >>= 1;
        _ = unused;

        const field_name_zir = zir.nullTerminatedString(zir.extra[extra_index]);
        extra_index += 1;

        const field_type_ref: Zir.Inst.Ref = if (has_type) blk: {
            const field_type_ref = @intToEnum(Zir.Inst.Ref, zir.extra[extra_index]);
            extra_index += 1;
            break :blk field_type_ref;
        } else .none;

        const align_ref: Zir.Inst.Ref = if (has_align) blk: {
            const align_ref = @intToEnum(Zir.Inst.Ref, zir.extra[extra_index]);
            extra_index += 1;
            break :blk align_ref;
        } else .none;

        if (has_tag) {
            extra_index += 1;
        }

        // This string needs to outlive the ZIR code.
        const field_name = try decl_arena.allocator.dupe(u8, field_name_zir);
        const field_ty: Type = if (field_type_ref == .none)
            Type.initTag(.void)
        else
            // TODO: if we need to report an error here, use a source location
            // that points to this type expression rather than the union.
            // But only resolve the source location if we need to emit a compile error.
            try sema.resolveType(&block, src, field_type_ref);

        const gop = union_obj.fields.getOrPutAssumeCapacity(field_name);
        assert(!gop.found_existing);
        gop.value_ptr.* = .{
            .ty = field_ty,
            .abi_align = Value.initTag(.abi_align_default),
        };

        if (align_ref != .none) {
            // TODO: if we need to report an error here, use a source location
            // that points to this alignment expression rather than the struct.
            // But only resolve the source location if we need to emit a compile error.
            gop.value_ptr.abi_align = (try sema.resolveInstConst(&block, src, align_ref)).val;
        }
    }

    // TODO resolve the union tag_type_ref
}

/// Called from `performAllTheWork`, after all AstGen workers have finished,
/// and before the main semantic analysis loop begins.
pub fn processOutdatedAndDeletedDecls(mod: *Module) !void {
    // Ultimately, the goal is to queue up `analyze_decl` tasks in the work queue
    // for the outdated decls, but we cannot queue up the tasks until after
    // we find out which ones have been deleted, otherwise there would be
    // deleted Decl pointers in the work queue.
    var outdated_decls = std.AutoArrayHashMap(*Decl, void).init(mod.gpa);
    defer outdated_decls.deinit();
    for (mod.import_table.values()) |file| {
        try outdated_decls.ensureUnusedCapacity(file.outdated_decls.items.len);
        for (file.outdated_decls.items) |decl| {
            outdated_decls.putAssumeCapacity(decl, {});
        }
        file.outdated_decls.clearRetainingCapacity();

        // Handle explicitly deleted decls from the source code. This is one of two
        // places that Decl deletions happen. The other is in `Compilation`, after
        // `performAllTheWork`, where we iterate over `Module.deletion_set` and
        // delete Decls which are no longer referenced.
        // If a Decl is explicitly deleted from source, and also no longer referenced,
        // it may be both in this `deleted_decls` set, as well as in the
        // `Module.deletion_set`. To avoid deleting it twice, we remove it from the
        // deletion set at this time.
        for (file.deleted_decls.items) |decl| {
            log.debug("deleted from source: {*} ({s})", .{ decl, decl.name });

            // Remove from the namespace it resides in, preserving declaration order.
            assert(decl.zir_decl_index != 0);
            _ = decl.namespace.decls.orderedRemove(mem.spanZ(decl.name));

            try mod.clearDecl(decl, &outdated_decls);
            decl.destroy(mod);
        }
        file.deleted_decls.clearRetainingCapacity();
    }
    // Finally we can queue up re-analysis tasks after we have processed
    // the deleted decls.
    for (outdated_decls.keys()) |key| {
        try mod.markOutdatedDecl(key);
    }
}

/// Called from `Compilation.update`, after everything is done, just before
/// reporting compile errors. In this function we emit exported symbol collision
/// errors and communicate exported symbols to the linker backend.
pub fn processExports(mod: *Module) !void {
    const gpa = mod.gpa;
    // Map symbol names to `Export` for name collision detection.
    var symbol_exports: std.StringArrayHashMapUnmanaged(*Export) = .{};
    defer symbol_exports.deinit(gpa);

    var it = mod.decl_exports.iterator();
    while (it.next()) |entry| {
        const exported_decl = entry.key_ptr.*;
        const exports = entry.value_ptr.*;
        for (exports) |new_export| {
            const gop = try symbol_exports.getOrPut(gpa, new_export.options.name);
            if (gop.found_existing) {
                new_export.status = .failed_retryable;
                try mod.failed_exports.ensureUnusedCapacity(gpa, 1);
                const src_loc = new_export.getSrcLoc();
                const msg = try ErrorMsg.create(gpa, src_loc, "exported symbol collision: {s}", .{
                    new_export.options.name,
                });
                errdefer msg.destroy(gpa);
                const other_export = gop.value_ptr.*;
                const other_src_loc = other_export.getSrcLoc();
                try mod.errNoteNonLazy(other_src_loc, msg, "other symbol here", .{});
                mod.failed_exports.putAssumeCapacityNoClobber(new_export, msg);
                new_export.status = .failed;
            } else {
                gop.value_ptr.* = new_export;
            }
        }
        mod.comp.bin_file.updateDeclExports(mod, exported_decl, exports) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const new_export = exports[0];
                new_export.status = .failed_retryable;
                try mod.failed_exports.ensureUnusedCapacity(gpa, 1);
                const src_loc = new_export.getSrcLoc();
                const msg = try ErrorMsg.create(gpa, src_loc, "unable to export: {s}", .{
                    @errorName(err),
                });
                mod.failed_exports.putAssumeCapacityNoClobber(new_export, msg);
            },
        };
    }
}
