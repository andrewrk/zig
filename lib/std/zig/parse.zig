// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("../std.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ast = std.zig.ast;
const Node = ast.Node;
const Tree = ast.Tree;
const AstError = ast.Error;
const TokenIndex = ast.TokenIndex;
const Token = std.zig.Token;

pub const Error = error{ParseError} || Allocator.Error;

/// Result should be freed with tree.deinit() when there are
/// no more references to any of the tokens or nodes.
pub fn parse(gpa: *Allocator, source: [:0]const u8) Allocator.Error!Tree {
    var tokens = ast.TokenList{};
    defer tokens.deinit(gpa);

    // Empirically, the zig std lib has an 8:1 ratio of source bytes to token count.
    const estimated_token_count = source.len / 8;
    try tokens.ensureCapacity(gpa, estimated_token_count);

    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(gpa, .{
            .tag = token.tag,
            .start = @intCast(u32, token.loc.start),
        });
        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .source = source,
        .gpa = gpa,
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .errors = .{},
        .nodes = .{},
        .extra_data = .{},
        .scratch = .{},
        .tok_i = 0,
    };
    defer parser.errors.deinit(gpa);
    defer parser.nodes.deinit(gpa);
    defer parser.extra_data.deinit(gpa);
    defer parser.scratch.deinit(gpa);

    // Empirically, Zig source code has a 2:1 ratio of tokens to AST nodes.
    // Make sure at least 1 so we can use appendAssumeCapacity on the root node below.
    const estimated_node_count = (tokens.len + 2) / 2;
    try parser.nodes.ensureCapacity(gpa, estimated_node_count);

    // Root node must be index 0.
    // Root <- skip ContainerMembers eof
    parser.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });
    const root_members = try parser.parseContainerMembers();
    const root_decls = try root_members.toSpan(&parser);
    if (parser.token_tags[parser.tok_i] != .eof) {
        try parser.warnExpected(.eof);
    }
    parser.nodes.items(.data)[0] = .{
        .lhs = root_decls.start,
        .rhs = root_decls.end,
    };

    // TODO experiment with compacting the MultiArrayList slices here
    return Tree{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = parser.extra_data.toOwnedSlice(gpa),
        .errors = parser.errors.toOwnedSlice(gpa),
    };
}

const null_node: Node.Index = 0;

/// Represents in-progress parsing, will be converted to an ast.Tree after completion.
const Parser = struct {
    gpa: *Allocator,
    source: []const u8,
    token_tags: []const Token.Tag,
    token_starts: []const ast.ByteOffset,
    tok_i: TokenIndex,
    errors: std.ArrayListUnmanaged(AstError),
    nodes: ast.NodeList,
    extra_data: std.ArrayListUnmanaged(Node.Index),
    scratch: std.ArrayListUnmanaged(Node.Index),

    const SmallSpan = union(enum) {
        zero_or_one: Node.Index,
        multi: Node.SubRange,
    };

    const Members = struct {
        len: usize,
        lhs: Node.Index,
        rhs: Node.Index,
        trailing: bool,

        fn toSpan(self: Members, p: *Parser) !Node.SubRange {
            if (self.len <= 2) {
                const nodes = [2]Node.Index{ self.lhs, self.rhs };
                return p.listToSpan(nodes[0..self.len]);
            } else {
                return Node.SubRange{ .start = self.lhs, .end = self.rhs };
            }
        }
    };

    fn listToSpan(p: *Parser, list: []const Node.Index) !Node.SubRange {
        try p.extra_data.appendSlice(p.gpa, list);
        return Node.SubRange{
            .start = @intCast(Node.Index, p.extra_data.items.len - list.len),
            .end = @intCast(Node.Index, p.extra_data.items.len),
        };
    }

    fn addNode(p: *Parser, elem: ast.NodeList.Elem) Allocator.Error!Node.Index {
        const result = @intCast(Node.Index, p.nodes.len);
        try p.nodes.append(p.gpa, elem);
        return result;
    }

    fn setNode(p: *Parser, i: usize, elem: ast.NodeList.Elem) Node.Index {
        p.nodes.set(i, elem);
        return @intCast(Node.Index, i);
    }

    fn reserveNode(p: *Parser) !usize {
        try p.nodes.resize(p.gpa, p.nodes.len + 1);
        return p.nodes.len - 1;
    }

    fn addExtra(p: *Parser, extra: anytype) Allocator.Error!Node.Index {
        const fields = std.meta.fields(@TypeOf(extra));
        try p.extra_data.ensureCapacity(p.gpa, p.extra_data.items.len + fields.len);
        const result = @intCast(u32, p.extra_data.items.len);
        inline for (fields) |field| {
            comptime assert(field.field_type == Node.Index);
            p.extra_data.appendAssumeCapacity(@field(extra, field.name));
        }
        return result;
    }

    fn warn(p: *Parser, tag: ast.Error.Tag) error{OutOfMemory}!void {
        @setCold(true);
        try p.warnMsg(.{ .tag = tag, .token = p.tok_i });
    }

    fn warnExpected(p: *Parser, expected_token: Token.Tag) error{OutOfMemory}!void {
        @setCold(true);
        try p.warnMsg(.{
            .tag = .expected_token,
            .token = p.tok_i,
            .extra = .{ .expected_tag = expected_token },
        });
    }
    fn warnMsg(p: *Parser, msg: ast.Error) error{OutOfMemory}!void {
        @setCold(true);
        try p.errors.append(p.gpa, msg);
    }

    fn fail(p: *Parser, tag: ast.Error.Tag) error{ ParseError, OutOfMemory } {
        @setCold(true);
        return p.failMsg(.{ .tag = tag, .token = p.tok_i });
    }

    fn failExpected(p: *Parser, expected_token: Token.Tag) error{ ParseError, OutOfMemory } {
        @setCold(true);
        return p.failMsg(.{
            .tag = .expected_token,
            .token = p.tok_i,
            .extra = .{ .expected_tag = expected_token },
        });
    }

    fn failMsg(p: *Parser, msg: ast.Error) error{ ParseError, OutOfMemory } {
        @setCold(true);
        try p.warnMsg(msg);
        return error.ParseError;
    }

    /// ContainerMembers <- ContainerDeclarations (ContainerField COMMA)* (ContainerField / ContainerDeclarations)
    /// ContainerDeclarations
    ///     <- TestDecl ContainerDeclarations
    ///      / TopLevelComptime ContainerDeclarations
    ///      / KEYWORD_pub? TopLevelDecl ContainerDeclarations
    ///      /
    /// TopLevelComptime <- KEYWORD_comptime BlockExpr
    fn parseContainerMembers(p: *Parser) !Members {
        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);

        var field_state: union(enum) {
            /// No fields have been seen.
            none,
            /// Currently parsing fields.
            seen,
            /// Saw fields and then a declaration after them.
            /// Payload is first token of previous declaration.
            end: Node.Index,
            /// There was a declaration between fields, don't report more errors.
            err,
        } = .none;

        // Skip container doc comments.
        while (p.eatToken(.container_doc_comment)) |_| {}

        var trailing = false;
        while (true) {
            const doc_comment = try p.eatDocComments();

            switch (p.token_tags[p.tok_i]) {
                .keyword_test => {
                    const test_decl_node = try p.expectTestDeclRecoverable();
                    if (test_decl_node != 0) {
                        if (field_state == .seen) {
                            field_state = .{ .end = test_decl_node };
                        }
                        try p.scratch.append(p.gpa, test_decl_node);
                    }
                    trailing = false;
                },
                .keyword_comptime => switch (p.token_tags[p.tok_i + 1]) {
                    .identifier => {
                        p.tok_i += 1;
                        const container_field = try p.expectContainerFieldRecoverable();
                        if (container_field != 0) {
                            switch (field_state) {
                                .none => field_state = .seen,
                                .err, .seen => {},
                                .end => |node| {
                                    try p.warnMsg(.{
                                        .tag = .decl_between_fields,
                                        .token = p.nodes.items(.main_token)[node],
                                    });
                                    // Continue parsing; error will be reported later.
                                    field_state = .err;
                                },
                            }
                            try p.scratch.append(p.gpa, container_field);
                            switch (p.token_tags[p.tok_i]) {
                                .comma => {
                                    p.tok_i += 1;
                                    trailing = true;
                                    continue;
                                },
                                .r_brace, .eof => {
                                    trailing = false;
                                    break;
                                },
                                else => {},
                            }
                            // There is not allowed to be a decl after a field with no comma.
                            // Report error but recover parser.
                            try p.warnExpected(.comma);
                            p.findNextContainerMember();
                        }
                    },
                    .l_brace => {
                        const comptime_token = p.nextToken();
                        const block = p.parseBlock() catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.ParseError => blk: {
                                p.findNextContainerMember();
                                break :blk null_node;
                            },
                        };
                        if (block != 0) {
                            const comptime_node = try p.addNode(.{
                                .tag = .@"comptime",
                                .main_token = comptime_token,
                                .data = .{
                                    .lhs = block,
                                    .rhs = undefined,
                                },
                            });
                            if (field_state == .seen) {
                                field_state = .{ .end = comptime_node };
                            }
                            try p.scratch.append(p.gpa, comptime_node);
                        }
                        trailing = false;
                    },
                    else => {
                        p.tok_i += 1;
                        try p.warn(.expected_block_or_field);
                    },
                },
                .keyword_pub => {
                    p.tok_i += 1;
                    const top_level_decl = try p.expectTopLevelDeclRecoverable();
                    if (top_level_decl != 0) {
                        if (field_state == .seen) {
                            field_state = .{ .end = top_level_decl };
                        }
                        try p.scratch.append(p.gpa, top_level_decl);
                    }
                    trailing = p.token_tags[p.tok_i - 1] == .semicolon;
                },
                .keyword_usingnamespace => {
                    const node = try p.expectUsingNamespaceRecoverable();
                    if (node != 0) {
                        if (field_state == .seen) {
                            field_state = .{ .end = node };
                        }
                        try p.scratch.append(p.gpa, node);
                    }
                    trailing = p.token_tags[p.tok_i - 1] == .semicolon;
                },
                .keyword_const,
                .keyword_var,
                .keyword_threadlocal,
                .keyword_export,
                .keyword_extern,
                .keyword_inline,
                .keyword_noinline,
                .keyword_fn,
                => {
                    const top_level_decl = try p.expectTopLevelDeclRecoverable();
                    if (top_level_decl != 0) {
                        if (field_state == .seen) {
                            field_state = .{ .end = top_level_decl };
                        }
                        try p.scratch.append(p.gpa, top_level_decl);
                    }
                    trailing = p.token_tags[p.tok_i - 1] == .semicolon;
                },
                .identifier => {
                    const container_field = try p.expectContainerFieldRecoverable();
                    if (container_field != 0) {
                        switch (field_state) {
                            .none => field_state = .seen,
                            .err, .seen => {},
                            .end => |node| {
                                try p.warnMsg(.{
                                    .tag = .decl_between_fields,
                                    .token = p.nodes.items(.main_token)[node],
                                });
                                // Continue parsing; error will be reported later.
                                field_state = .err;
                            },
                        }
                        try p.scratch.append(p.gpa, container_field);
                        switch (p.token_tags[p.tok_i]) {
                            .comma => {
                                p.tok_i += 1;
                                trailing = true;
                                continue;
                            },
                            .r_brace, .eof => {
                                trailing = false;
                                break;
                            },
                            else => {},
                        }
                        // There is not allowed to be a decl after a field with no comma.
                        // Report error but recover parser.
                        try p.warnExpected(.comma);
                        p.findNextContainerMember();
                    }
                },
                .eof, .r_brace => {
                    if (doc_comment) |tok| {
                        try p.warnMsg(.{
                            .tag = .unattached_doc_comment,
                            .token = tok,
                        });
                    }
                    break;
                },
                else => {
                    try p.warn(.expected_container_members);
                    // This was likely not supposed to end yet; try to find the next declaration.
                    p.findNextContainerMember();
                },
            }
        }

        const items = p.scratch.items[scratch_top..];
        switch (items.len) {
            0 => return Members{
                .len = 0,
                .lhs = 0,
                .rhs = 0,
                .trailing = trailing,
            },
            1 => return Members{
                .len = 1,
                .lhs = items[0],
                .rhs = 0,
                .trailing = trailing,
            },
            2 => return Members{
                .len = 2,
                .lhs = items[0],
                .rhs = items[1],
                .trailing = trailing,
            },
            else => {
                const span = try p.listToSpan(items);
                return Members{
                    .len = items.len,
                    .lhs = span.start,
                    .rhs = span.end,
                    .trailing = trailing,
                };
            },
        }
    }

    /// Attempts to find next container member by searching for certain tokens
    fn findNextContainerMember(p: *Parser) void {
        var level: u32 = 0;
        while (true) {
            const tok = p.nextToken();
            switch (p.token_tags[tok]) {
                // Any of these can start a new top level declaration.
                .keyword_test,
                .keyword_comptime,
                .keyword_pub,
                .keyword_export,
                .keyword_extern,
                .keyword_inline,
                .keyword_noinline,
                .keyword_usingnamespace,
                .keyword_threadlocal,
                .keyword_const,
                .keyword_var,
                .keyword_fn,
                => {
                    if (level == 0) {
                        p.tok_i -= 1;
                        return;
                    }
                },
                .identifier => {
                    if (p.token_tags[tok + 1] == .comma and level == 0) {
                        p.tok_i -= 1;
                        return;
                    }
                },
                .comma, .semicolon => {
                    // this decl was likely meant to end here
                    if (level == 0) {
                        return;
                    }
                },
                .l_paren, .l_bracket, .l_brace => level += 1,
                .r_paren, .r_bracket => {
                    if (level != 0) level -= 1;
                },
                .r_brace => {
                    if (level == 0) {
                        // end of container, exit
                        p.tok_i -= 1;
                        return;
                    }
                    level -= 1;
                },
                .eof => {
                    p.tok_i -= 1;
                    return;
                },
                else => {},
            }
        }
    }

    /// Attempts to find the next statement by searching for a semicolon
    fn findNextStmt(p: *Parser) void {
        var level: u32 = 0;
        while (true) {
            const tok = p.nextToken();
            switch (p.token_tags[tok]) {
                .l_brace => level += 1,
                .r_brace => {
                    if (level == 0) {
                        p.tok_i -= 1;
                        return;
                    }
                    level -= 1;
                },
                .semicolon => {
                    if (level == 0) {
                        return;
                    }
                },
                .eof => {
                    p.tok_i -= 1;
                    return;
                },
                else => {},
            }
        }
    }

    /// TestDecl <- KEYWORD_test STRINGLITERALSINGLE? Block
    fn expectTestDecl(p: *Parser) !Node.Index {
        const test_token = p.assertToken(.keyword_test);
        const name_token = p.eatToken(.string_literal);
        const block_node = try p.parseBlock();
        if (block_node == 0) return p.fail(.expected_block);
        return p.addNode(.{
            .tag = .test_decl,
            .main_token = test_token,
            .data = .{
                .lhs = name_token orelse 0,
                .rhs = block_node,
            },
        });
    }

    fn expectTestDeclRecoverable(p: *Parser) error{OutOfMemory}!Node.Index {
        return p.expectTestDecl() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => {
                p.findNextContainerMember();
                return null_node;
            },
        };
    }

    /// TopLevelDecl
    ///     <- (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE? / (KEYWORD_inline / KEYWORD_noinline))? FnProto (SEMICOLON / Block)
    ///      / (KEYWORD_export / KEYWORD_extern STRINGLITERALSINGLE?)? KEYWORD_threadlocal? VarDecl
    ///      / KEYWORD_usingnamespace Expr SEMICOLON
    fn expectTopLevelDecl(p: *Parser) !Node.Index {
        const extern_export_inline_token = p.nextToken();
        var expect_fn: bool = false;
        var expect_var_or_fn: bool = false;
        switch (p.token_tags[extern_export_inline_token]) {
            .keyword_extern => {
                _ = p.eatToken(.string_literal);
                expect_var_or_fn = true;
            },
            .keyword_export => expect_var_or_fn = true,
            .keyword_inline, .keyword_noinline => expect_fn = true,
            else => p.tok_i -= 1,
        }
        const fn_proto = try p.parseFnProto();
        if (fn_proto != 0) {
            switch (p.token_tags[p.tok_i]) {
                .semicolon => {
                    p.tok_i += 1;
                    return fn_proto;
                },
                .l_brace => {
                    const fn_decl_index = try p.reserveNode();
                    const body_block = try p.parseBlock();
                    assert(body_block != 0);
                    return p.setNode(fn_decl_index, .{
                        .tag = .fn_decl,
                        .main_token = p.nodes.items(.main_token)[fn_proto],
                        .data = .{
                            .lhs = fn_proto,
                            .rhs = body_block,
                        },
                    });
                },
                else => {
                    // Since parseBlock only return error.ParseError on
                    // a missing '}' we can assume this function was
                    // supposed to end here.
                    try p.warn(.expected_semi_or_lbrace);
                    return null_node;
                },
            }
        }
        if (expect_fn) {
            try p.warn(.expected_fn);
            return error.ParseError;
        }

        const thread_local_token = p.eatToken(.keyword_threadlocal);
        const var_decl = try p.parseVarDecl();
        if (var_decl != 0) {
            _ = try p.expectToken(.semicolon);
            return var_decl;
        }
        if (thread_local_token != null) {
            return p.fail(.expected_var_decl);
        }
        if (expect_var_or_fn) {
            return p.fail(.expected_var_decl_or_fn);
        }
        if (p.token_tags[p.tok_i] != .keyword_usingnamespace) {
            return p.fail(.expected_pub_item);
        }
        return p.expectUsingNamespace();
    }

    fn expectTopLevelDeclRecoverable(p: *Parser) error{OutOfMemory}!Node.Index {
        return p.expectTopLevelDecl() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => {
                p.findNextContainerMember();
                return null_node;
            },
        };
    }

    fn expectUsingNamespace(p: *Parser) !Node.Index {
        const usingnamespace_token = p.assertToken(.keyword_usingnamespace);
        const expr = try p.expectExpr();
        _ = try p.expectToken(.semicolon);
        return p.addNode(.{
            .tag = .@"usingnamespace",
            .main_token = usingnamespace_token,
            .data = .{
                .lhs = expr,
                .rhs = undefined,
            },
        });
    }

    fn expectUsingNamespaceRecoverable(p: *Parser) error{OutOfMemory}!Node.Index {
        return p.expectUsingNamespace() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => {
                p.findNextContainerMember();
                return null_node;
            },
        };
    }

    /// FnProto <- KEYWORD_fn IDENTIFIER? LPAREN ParamDeclList RPAREN ByteAlign? LinkSection? CallConv? EXCLAMATIONMARK? TypeExpr
    fn parseFnProto(p: *Parser) !Node.Index {
        const fn_token = p.eatToken(.keyword_fn) orelse return null_node;

        // We want the fn proto node to be before its children in the array.
        const fn_proto_index = try p.reserveNode();

        _ = p.eatToken(.identifier);
        const params = try p.parseParamDeclList();
        const align_expr = try p.parseByteAlign();
        const section_expr = try p.parseLinkSection();
        const callconv_expr = try p.parseCallconv();
        _ = p.eatToken(.bang);

        const return_type_expr = try p.parseTypeExpr();
        if (return_type_expr == 0) {
            // most likely the user forgot to specify the return type.
            // Mark return type as invalid and try to continue.
            try p.warn(.expected_return_type);
        }

        if (align_expr == 0 and section_expr == 0 and callconv_expr == 0) {
            switch (params) {
                .zero_or_one => |param| return p.setNode(fn_proto_index, .{
                    .tag = .fn_proto_simple,
                    .main_token = fn_token,
                    .data = .{
                        .lhs = param,
                        .rhs = return_type_expr,
                    },
                }),
                .multi => |span| {
                    return p.setNode(fn_proto_index, .{
                        .tag = .fn_proto_multi,
                        .main_token = fn_token,
                        .data = .{
                            .lhs = try p.addExtra(Node.SubRange{
                                .start = span.start,
                                .end = span.end,
                            }),
                            .rhs = return_type_expr,
                        },
                    });
                },
            }
        }
        switch (params) {
            .zero_or_one => |param| return p.setNode(fn_proto_index, .{
                .tag = .fn_proto_one,
                .main_token = fn_token,
                .data = .{
                    .lhs = try p.addExtra(Node.FnProtoOne{
                        .param = param,
                        .align_expr = align_expr,
                        .section_expr = section_expr,
                        .callconv_expr = callconv_expr,
                    }),
                    .rhs = return_type_expr,
                },
            }),
            .multi => |span| {
                return p.setNode(fn_proto_index, .{
                    .tag = .fn_proto,
                    .main_token = fn_token,
                    .data = .{
                        .lhs = try p.addExtra(Node.FnProto{
                            .params_start = span.start,
                            .params_end = span.end,
                            .align_expr = align_expr,
                            .section_expr = section_expr,
                            .callconv_expr = callconv_expr,
                        }),
                        .rhs = return_type_expr,
                    },
                });
            },
        }
    }

    /// VarDecl <- (KEYWORD_const / KEYWORD_var) IDENTIFIER (COLON TypeExpr)? ByteAlign? LinkSection? (EQUAL Expr)? SEMICOLON
    fn parseVarDecl(p: *Parser) !Node.Index {
        const mut_token = p.eatToken(.keyword_const) orelse
            p.eatToken(.keyword_var) orelse
            return null_node;

        _ = try p.expectToken(.identifier);
        const type_node: Node.Index = if (p.eatToken(.colon) == null) 0 else try p.expectTypeExpr();
        const align_node = try p.parseByteAlign();
        const section_node = try p.parseLinkSection();
        const init_node: Node.Index = if (p.eatToken(.equal) == null) 0 else try p.expectExpr();
        if (section_node == 0) {
            if (align_node == 0) {
                return p.addNode(.{
                    .tag = .simple_var_decl,
                    .main_token = mut_token,
                    .data = .{
                        .lhs = type_node,
                        .rhs = init_node,
                    },
                });
            } else if (type_node == 0) {
                return p.addNode(.{
                    .tag = .aligned_var_decl,
                    .main_token = mut_token,
                    .data = .{
                        .lhs = align_node,
                        .rhs = init_node,
                    },
                });
            } else {
                return p.addNode(.{
                    .tag = .local_var_decl,
                    .main_token = mut_token,
                    .data = .{
                        .lhs = try p.addExtra(Node.LocalVarDecl{
                            .type_node = type_node,
                            .align_node = align_node,
                        }),
                        .rhs = init_node,
                    },
                });
            }
        } else {
            return p.addNode(.{
                .tag = .global_var_decl,
                .main_token = mut_token,
                .data = .{
                    .lhs = try p.addExtra(Node.GlobalVarDecl{
                        .type_node = type_node,
                        .align_node = align_node,
                        .section_node = section_node,
                    }),
                    .rhs = init_node,
                },
            });
        }
    }

    /// ContainerField <- KEYWORD_comptime? IDENTIFIER (COLON (KEYWORD_anytype / TypeExpr) ByteAlign?)? (EQUAL Expr)?
    fn expectContainerField(p: *Parser) !Node.Index {
        _ = p.eatToken(.keyword_comptime);
        const name_token = p.assertToken(.identifier);

        var align_expr: Node.Index = 0;
        var type_expr: Node.Index = 0;
        if (p.eatToken(.colon)) |_| {
            if (p.eatToken(.keyword_anytype)) |anytype_tok| {
                type_expr = try p.addNode(.{
                    .tag = .@"anytype",
                    .main_token = anytype_tok,
                    .data = .{
                        .lhs = undefined,
                        .rhs = undefined,
                    },
                });
            } else {
                type_expr = try p.expectTypeExpr();
                align_expr = try p.parseByteAlign();
            }
        }

        const value_expr: Node.Index = if (p.eatToken(.equal) == null) 0 else try p.expectExpr();

        if (align_expr == 0) {
            return p.addNode(.{
                .tag = .container_field_init,
                .main_token = name_token,
                .data = .{
                    .lhs = type_expr,
                    .rhs = value_expr,
                },
            });
        } else if (value_expr == 0) {
            return p.addNode(.{
                .tag = .container_field_align,
                .main_token = name_token,
                .data = .{
                    .lhs = type_expr,
                    .rhs = align_expr,
                },
            });
        } else {
            return p.addNode(.{
                .tag = .container_field,
                .main_token = name_token,
                .data = .{
                    .lhs = type_expr,
                    .rhs = try p.addExtra(Node.ContainerField{
                        .value_expr = value_expr,
                        .align_expr = align_expr,
                    }),
                },
            });
        }
    }

    fn expectContainerFieldRecoverable(p: *Parser) error{OutOfMemory}!Node.Index {
        return p.expectContainerField() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => {
                p.findNextContainerMember();
                return null_node;
            },
        };
    }

    /// Statement
    ///     <- KEYWORD_comptime? VarDecl
    ///      / KEYWORD_comptime BlockExprStatement
    ///      / KEYWORD_nosuspend BlockExprStatement
    ///      / KEYWORD_suspend BlockExprStatement
    ///      / KEYWORD_defer BlockExprStatement
    ///      / KEYWORD_errdefer Payload? BlockExprStatement
    ///      / IfStatement
    ///      / LabeledStatement
    ///      / SwitchExpr
    ///      / AssignExpr SEMICOLON
    fn parseStatement(p: *Parser) Error!Node.Index {
        const comptime_token = p.eatToken(.keyword_comptime);

        const var_decl = try p.parseVarDecl();
        if (var_decl != 0) {
            _ = try p.expectTokenRecoverable(.semicolon);
            return var_decl;
        }

        if (comptime_token) |token| {
            return p.addNode(.{
                .tag = .@"comptime",
                .main_token = token,
                .data = .{
                    .lhs = try p.expectBlockExprStatement(),
                    .rhs = undefined,
                },
            });
        }

        switch (p.token_tags[p.tok_i]) {
            .keyword_nosuspend => {
                return p.addNode(.{
                    .tag = .@"nosuspend",
                    .main_token = p.nextToken(),
                    .data = .{
                        .lhs = try p.expectBlockExprStatement(),
                        .rhs = undefined,
                    },
                });
            },
            .keyword_suspend => {
                const token = p.nextToken();
                const block_expr = try p.expectBlockExprStatement();
                return p.addNode(.{
                    .tag = .@"suspend",
                    .main_token = token,
                    .data = .{
                        .lhs = block_expr,
                        .rhs = undefined,
                    },
                });
            },
            .keyword_defer => return p.addNode(.{
                .tag = .@"defer",
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = undefined,
                    .rhs = try p.expectBlockExprStatement(),
                },
            }),
            .keyword_errdefer => return p.addNode(.{
                .tag = .@"errdefer",
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = try p.parsePayload(),
                    .rhs = try p.expectBlockExprStatement(),
                },
            }),
            .keyword_switch => return p.expectSwitchExpr(),
            .keyword_if => return p.expectIfStatement(),
            else => {},
        }

        const labeled_statement = try p.parseLabeledStatement();
        if (labeled_statement != 0) return labeled_statement;

        const assign_expr = try p.parseAssignExpr();
        if (assign_expr != 0) {
            _ = try p.expectTokenRecoverable(.semicolon);
            return assign_expr;
        }

        return null_node;
    }

    fn expectStatement(p: *Parser) !Node.Index {
        const statement = try p.parseStatement();
        if (statement == 0) {
            return p.fail(.expected_statement);
        }
        return statement;
    }

    /// If a parse error occurs, reports an error, but then finds the next statement
    /// and returns that one instead. If a parse error occurs but there is no following
    /// statement, returns 0.
    fn expectStatementRecoverable(p: *Parser) Error!Node.Index {
        while (true) {
            return p.expectStatement() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseError => {
                    p.findNextStmt(); // Try to skip to the next statement.
                    switch (p.token_tags[p.tok_i]) {
                        .r_brace => return null_node,
                        .eof => return error.ParseError,
                        else => continue,
                    }
                },
            };
        }
    }

    /// IfStatement
    ///     <- IfPrefix BlockExpr ( KEYWORD_else Payload? Statement )?
    ///      / IfPrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
    fn expectIfStatement(p: *Parser) !Node.Index {
        const if_token = p.assertToken(.keyword_if);
        _ = try p.expectToken(.l_paren);
        const condition = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        _ = try p.parsePtrPayload();

        // TODO propose to change the syntax so that semicolons are always required
        // inside if statements, even if there is an `else`.
        var else_required = false;
        const then_expr = blk: {
            const block_expr = try p.parseBlockExpr();
            if (block_expr != 0) break :blk block_expr;
            const assign_expr = try p.parseAssignExpr();
            if (assign_expr == 0) {
                return p.fail(.expected_block_or_assignment);
            }
            if (p.eatToken(.semicolon)) |_| {
                return p.addNode(.{
                    .tag = .if_simple,
                    .main_token = if_token,
                    .data = .{
                        .lhs = condition,
                        .rhs = assign_expr,
                    },
                });
            }
            else_required = true;
            break :blk assign_expr;
        };
        _ = p.eatToken(.keyword_else) orelse {
            if (else_required) {
                try p.warn(.expected_semi_or_else);
            }
            return p.addNode(.{
                .tag = .if_simple,
                .main_token = if_token,
                .data = .{
                    .lhs = condition,
                    .rhs = then_expr,
                },
            });
        };
        _ = try p.parsePayload();
        const else_expr = try p.expectStatement();
        return p.addNode(.{
            .tag = .@"if",
            .main_token = if_token,
            .data = .{
                .lhs = condition,
                .rhs = try p.addExtra(Node.If{
                    .then_expr = then_expr,
                    .else_expr = else_expr,
                }),
            },
        });
    }

    /// LabeledStatement <- BlockLabel? (Block / LoopStatement)
    fn parseLabeledStatement(p: *Parser) !Node.Index {
        const label_token = p.parseBlockLabel();
        const block = try p.parseBlock();
        if (block != 0) return block;

        const loop_stmt = try p.parseLoopStatement();
        if (loop_stmt != 0) return loop_stmt;

        if (label_token != 0) {
            return p.fail(.expected_labelable);
        }

        return null_node;
    }

    /// LoopStatement <- KEYWORD_inline? (ForStatement / WhileStatement)
    fn parseLoopStatement(p: *Parser) !Node.Index {
        const inline_token = p.eatToken(.keyword_inline);

        const for_statement = try p.parseForStatement();
        if (for_statement != 0) return for_statement;

        const while_statement = try p.parseWhileStatement();
        if (while_statement != 0) return while_statement;

        if (inline_token == null) return null_node;

        // If we've seen "inline", there should have been a "for" or "while"
        return p.fail(.expected_inlinable);
    }

    /// ForPrefix <- KEYWORD_for LPAREN Expr RPAREN PtrIndexPayload
    /// ForStatement
    ///     <- ForPrefix BlockExpr ( KEYWORD_else Statement )?
    ///      / ForPrefix AssignExpr ( SEMICOLON / KEYWORD_else Statement )
    fn parseForStatement(p: *Parser) !Node.Index {
        const for_token = p.eatToken(.keyword_for) orelse return null_node;
        _ = try p.expectToken(.l_paren);
        const array_expr = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        const found_payload = try p.parsePtrIndexPayload();
        if (found_payload == 0) try p.warn(.expected_loop_payload);

        // TODO propose to change the syntax so that semicolons are always required
        // inside while statements, even if there is an `else`.
        var else_required = false;
        const then_expr = blk: {
            const block_expr = try p.parseBlockExpr();
            if (block_expr != 0) break :blk block_expr;
            const assign_expr = try p.parseAssignExpr();
            if (assign_expr == 0) {
                return p.fail(.expected_block_or_assignment);
            }
            if (p.eatToken(.semicolon)) |_| {
                return p.addNode(.{
                    .tag = .for_simple,
                    .main_token = for_token,
                    .data = .{
                        .lhs = array_expr,
                        .rhs = assign_expr,
                    },
                });
            }
            else_required = true;
            break :blk assign_expr;
        };
        _ = p.eatToken(.keyword_else) orelse {
            if (else_required) {
                try p.warn(.expected_semi_or_else);
            }
            return p.addNode(.{
                .tag = .for_simple,
                .main_token = for_token,
                .data = .{
                    .lhs = array_expr,
                    .rhs = then_expr,
                },
            });
        };
        return p.addNode(.{
            .tag = .@"for",
            .main_token = for_token,
            .data = .{
                .lhs = array_expr,
                .rhs = try p.addExtra(Node.If{
                    .then_expr = then_expr,
                    .else_expr = try p.expectStatement(),
                }),
            },
        });
    }

    /// WhilePrefix <- KEYWORD_while LPAREN Expr RPAREN PtrPayload? WhileContinueExpr?
    /// WhileStatement
    ///     <- WhilePrefix BlockExpr ( KEYWORD_else Payload? Statement )?
    ///      / WhilePrefix AssignExpr ( SEMICOLON / KEYWORD_else Payload? Statement )
    fn parseWhileStatement(p: *Parser) !Node.Index {
        const while_token = p.eatToken(.keyword_while) orelse return null_node;
        _ = try p.expectToken(.l_paren);
        const condition = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        _ = try p.parsePtrPayload();
        const cont_expr = try p.parseWhileContinueExpr();

        // TODO propose to change the syntax so that semicolons are always required
        // inside while statements, even if there is an `else`.
        var else_required = false;
        const then_expr = blk: {
            const block_expr = try p.parseBlockExpr();
            if (block_expr != 0) break :blk block_expr;
            const assign_expr = try p.parseAssignExpr();
            if (assign_expr == 0) {
                return p.fail(.expected_block_or_assignment);
            }
            if (p.eatToken(.semicolon)) |_| {
                if (cont_expr == 0) {
                    return p.addNode(.{
                        .tag = .while_simple,
                        .main_token = while_token,
                        .data = .{
                            .lhs = condition,
                            .rhs = assign_expr,
                        },
                    });
                } else {
                    return p.addNode(.{
                        .tag = .while_cont,
                        .main_token = while_token,
                        .data = .{
                            .lhs = condition,
                            .rhs = try p.addExtra(Node.WhileCont{
                                .cont_expr = cont_expr,
                                .then_expr = assign_expr,
                            }),
                        },
                    });
                }
            }
            else_required = true;
            break :blk assign_expr;
        };
        _ = p.eatToken(.keyword_else) orelse {
            if (else_required) {
                try p.warn(.expected_semi_or_else);
            }
            if (cont_expr == 0) {
                return p.addNode(.{
                    .tag = .while_simple,
                    .main_token = while_token,
                    .data = .{
                        .lhs = condition,
                        .rhs = then_expr,
                    },
                });
            } else {
                return p.addNode(.{
                    .tag = .while_cont,
                    .main_token = while_token,
                    .data = .{
                        .lhs = condition,
                        .rhs = try p.addExtra(Node.WhileCont{
                            .cont_expr = cont_expr,
                            .then_expr = then_expr,
                        }),
                    },
                });
            }
        };
        _ = try p.parsePayload();
        const else_expr = try p.expectStatement();
        return p.addNode(.{
            .tag = .@"while",
            .main_token = while_token,
            .data = .{
                .lhs = condition,
                .rhs = try p.addExtra(Node.While{
                    .cont_expr = cont_expr,
                    .then_expr = then_expr,
                    .else_expr = else_expr,
                }),
            },
        });
    }

    /// BlockExprStatement
    ///     <- BlockExpr
    ///      / AssignExpr SEMICOLON
    fn parseBlockExprStatement(p: *Parser) !Node.Index {
        const block_expr = try p.parseBlockExpr();
        if (block_expr != 0) {
            return block_expr;
        }
        const assign_expr = try p.parseAssignExpr();
        if (assign_expr != 0) {
            _ = try p.expectTokenRecoverable(.semicolon);
            return assign_expr;
        }
        return null_node;
    }

    fn expectBlockExprStatement(p: *Parser) !Node.Index {
        const node = try p.parseBlockExprStatement();
        if (node == 0) {
            return p.fail(.expected_block_or_expr);
        }
        return node;
    }

    /// BlockExpr <- BlockLabel? Block
    fn parseBlockExpr(p: *Parser) Error!Node.Index {
        switch (p.token_tags[p.tok_i]) {
            .identifier => {
                if (p.token_tags[p.tok_i + 1] == .colon and
                    p.token_tags[p.tok_i + 2] == .l_brace)
                {
                    p.tok_i += 2;
                    return p.parseBlock();
                } else {
                    return null_node;
                }
            },
            .l_brace => return p.parseBlock(),
            else => return null_node,
        }
    }

    /// AssignExpr <- Expr (AssignOp Expr)?
    /// AssignOp
    ///     <- ASTERISKEQUAL
    ///      / SLASHEQUAL
    ///      / PERCENTEQUAL
    ///      / PLUSEQUAL
    ///      / MINUSEQUAL
    ///      / LARROW2EQUAL
    ///      / RARROW2EQUAL
    ///      / AMPERSANDEQUAL
    ///      / CARETEQUAL
    ///      / PIPEEQUAL
    ///      / ASTERISKPERCENTEQUAL
    ///      / PLUSPERCENTEQUAL
    ///      / MINUSPERCENTEQUAL
    ///      / EQUAL
    fn parseAssignExpr(p: *Parser) !Node.Index {
        const expr = try p.parseExpr();
        if (expr == 0) return null_node;

        const tag: Node.Tag = switch (p.token_tags[p.tok_i]) {
            .asterisk_equal => .assign_mul,
            .slash_equal => .assign_div,
            .percent_equal => .assign_mod,
            .plus_equal => .assign_add,
            .minus_equal => .assign_sub,
            .angle_bracket_angle_bracket_left_equal => .assign_bit_shift_left,
            .angle_bracket_angle_bracket_right_equal => .assign_bit_shift_right,
            .ampersand_equal => .assign_bit_and,
            .caret_equal => .assign_bit_xor,
            .pipe_equal => .assign_bit_or,
            .asterisk_percent_equal => .assign_mul_wrap,
            .plus_percent_equal => .assign_add_wrap,
            .minus_percent_equal => .assign_sub_wrap,
            .equal => .assign,
            else => return expr,
        };
        return p.addNode(.{
            .tag = tag,
            .main_token = p.nextToken(),
            .data = .{
                .lhs = expr,
                .rhs = try p.expectExpr(),
            },
        });
    }

    fn expectAssignExpr(p: *Parser) !Node.Index {
        const expr = try p.parseAssignExpr();
        if (expr == 0) {
            return p.fail(.expected_expr_or_assignment);
        }
        return expr;
    }

    fn parseExpr(p: *Parser) Error!Node.Index {
        return p.parseExprPrecedence(0);
    }

    fn expectExpr(p: *Parser) Error!Node.Index {
        const node = try p.parseExpr();
        if (node == 0) {
            return p.fail(.expected_expr);
        } else {
            return node;
        }
    }

    const Assoc = enum {
        left,
        none,
    };

    const OperInfo = struct {
        prec: i8,
        tag: Node.Tag,
        assoc: Assoc = Assoc.left,
    };

    // A table of binary operator information. Higher precedence numbers are
    // stickier. All operators at the same precedence level should have the same
    // associativity.
    const operTable = std.enums.directEnumArrayDefault(Token.Tag, OperInfo, .{ .prec = -1, .tag = Node.Tag.root }, 0, .{
        .keyword_or = .{ .prec = 10, .tag = .bool_or },

        .keyword_and = .{ .prec = 20, .tag = .bool_and },

        .equal_equal = .{ .prec = 30, .tag = .equal_equal, .assoc = Assoc.none },
        .bang_equal = .{ .prec = 30, .tag = .bang_equal, .assoc = Assoc.none },
        .angle_bracket_left = .{ .prec = 30, .tag = .less_than, .assoc = Assoc.none },
        .angle_bracket_right = .{ .prec = 30, .tag = .greater_than, .assoc = Assoc.none },
        .angle_bracket_left_equal = .{ .prec = 30, .tag = .less_or_equal, .assoc = Assoc.none },
        .angle_bracket_right_equal = .{ .prec = 30, .tag = .greater_or_equal, .assoc = Assoc.none },

        .ampersand = .{ .prec = 40, .tag = .bit_and },
        .caret = .{ .prec = 40, .tag = .bit_xor },
        .pipe = .{ .prec = 40, .tag = .bit_or },
        .keyword_orelse = .{ .prec = 40, .tag = .@"orelse" },
        .keyword_catch = .{ .prec = 40, .tag = .@"catch" },

        .angle_bracket_angle_bracket_left = .{ .prec = 50, .tag = .bit_shift_left },
        .angle_bracket_angle_bracket_right = .{ .prec = 50, .tag = .bit_shift_right },

        .plus = .{ .prec = 60, .tag = .add },
        .minus = .{ .prec = 60, .tag = .sub },
        .plus_plus = .{ .prec = 60, .tag = .array_cat },
        .plus_percent = .{ .prec = 60, .tag = .add_wrap },
        .minus_percent = .{ .prec = 60, .tag = .sub_wrap },

        .pipe_pipe = .{ .prec = 70, .tag = .merge_error_sets },
        .asterisk = .{ .prec = 70, .tag = .mul },
        .slash = .{ .prec = 70, .tag = .div },
        .percent = .{ .prec = 70, .tag = .mod },
        .asterisk_asterisk = .{ .prec = 70, .tag = .array_mult },
        .asterisk_percent = .{ .prec = 70, .tag = .mul_wrap },
    });

    fn parseExprPrecedence(p: *Parser, min_prec: i32) Error!Node.Index {
        var node = try p.parsePrefixExpr();
        if (node == 0) {
            return null_node;
        }

        var banned_prec: i8 = -1;

        while (true) {
            const tok_tag = p.token_tags[p.tok_i];
            const info = operTable[@intCast(usize, @enumToInt(tok_tag))];
            if (info.prec < min_prec or info.prec == banned_prec) {
                break;
            }
            const oper_token = p.nextToken();
            // Special-case handling for "catch" and "&&".
            switch (tok_tag) {
                .keyword_catch => {
                    _ = try p.parsePayload();
                },
                else => {},
            }
            const rhs = try p.parseExprPrecedence(info.prec + 1);
            if (rhs == 0) {
                return p.fail(.invalid_token);
            }

            node = try p.addNode(.{
                .tag = info.tag,
                .main_token = oper_token,
                .data = .{
                    .lhs = node,
                    .rhs = rhs,
                },
            });

            if (info.assoc == Assoc.none) {
                banned_prec = info.prec;
            }
        }

        return node;
    }

    /// PrefixExpr <- PrefixOp* PrimaryExpr
    /// PrefixOp
    ///     <- EXCLAMATIONMARK
    ///      / MINUS
    ///      / TILDE
    ///      / MINUSPERCENT
    ///      / AMPERSAND
    ///      / KEYWORD_try
    ///      / KEYWORD_await
    fn parsePrefixExpr(p: *Parser) Error!Node.Index {
        const tag: Node.Tag = switch (p.token_tags[p.tok_i]) {
            .bang => .bool_not,
            .minus => .negation,
            .tilde => .bit_not,
            .minus_percent => .negation_wrap,
            .ampersand => .address_of,
            .keyword_try => .@"try",
            .keyword_await => .@"await",
            else => return p.parsePrimaryExpr(),
        };
        return p.addNode(.{
            .tag = tag,
            .main_token = p.nextToken(),
            .data = .{
                .lhs = try p.expectPrefixExpr(),
                .rhs = undefined,
            },
        });
    }

    fn expectPrefixExpr(p: *Parser) Error!Node.Index {
        const node = try p.parsePrefixExpr();
        if (node == 0) {
            return p.fail(.expected_prefix_expr);
        }
        return node;
    }

    /// TypeExpr <- PrefixTypeOp* ErrorUnionExpr
    /// PrefixTypeOp
    ///     <- QUESTIONMARK
    ///      / KEYWORD_anyframe MINUSRARROW
    ///      / SliceTypeStart (ByteAlign / KEYWORD_const / KEYWORD_volatile / KEYWORD_allowzero)*
    ///      / PtrTypeStart (KEYWORD_align LPAREN Expr (COLON INTEGER COLON INTEGER)? RPAREN / KEYWORD_const / KEYWORD_volatile / KEYWORD_allowzero)*
    ///      / ArrayTypeStart
    /// SliceTypeStart <- LBRACKET (COLON Expr)? RBRACKET
    /// PtrTypeStart
    ///     <- ASTERISK
    ///      / ASTERISK2
    ///      / LBRACKET ASTERISK (LETTERC / COLON Expr)? RBRACKET
    /// ArrayTypeStart <- LBRACKET Expr (COLON Expr)? RBRACKET
    fn parseTypeExpr(p: *Parser) Error!Node.Index {
        switch (p.token_tags[p.tok_i]) {
            .question_mark => return p.addNode(.{
                .tag = .optional_type,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = try p.expectTypeExpr(),
                    .rhs = undefined,
                },
            }),
            .keyword_anyframe => switch (p.token_tags[p.tok_i + 1]) {
                .arrow => return p.addNode(.{
                    .tag = .anyframe_type,
                    .main_token = p.nextToken(),
                    .data = .{
                        .lhs = p.nextToken(),
                        .rhs = try p.expectTypeExpr(),
                    },
                }),
                else => return p.parseErrorUnionExpr(),
            },
            .asterisk => {
                const asterisk = p.nextToken();
                const mods = try p.parsePtrModifiers();
                const elem_type = try p.expectTypeExpr();
                if (mods.bit_range_start == 0) {
                    return p.addNode(.{
                        .tag = .ptr_type_aligned,
                        .main_token = asterisk,
                        .data = .{
                            .lhs = mods.align_node,
                            .rhs = elem_type,
                        },
                    });
                } else {
                    return p.addNode(.{
                        .tag = .ptr_type_bit_range,
                        .main_token = asterisk,
                        .data = .{
                            .lhs = try p.addExtra(Node.PtrTypeBitRange{
                                .sentinel = 0,
                                .align_node = mods.align_node,
                                .bit_range_start = mods.bit_range_start,
                                .bit_range_end = mods.bit_range_end,
                            }),
                            .rhs = elem_type,
                        },
                    });
                }
            },
            .asterisk_asterisk => {
                const asterisk = p.nextToken();
                const mods = try p.parsePtrModifiers();
                const elem_type = try p.expectTypeExpr();
                const inner: Node.Index = inner: {
                    if (mods.bit_range_start == 0) {
                        break :inner try p.addNode(.{
                            .tag = .ptr_type_aligned,
                            .main_token = asterisk,
                            .data = .{
                                .lhs = mods.align_node,
                                .rhs = elem_type,
                            },
                        });
                    } else {
                        break :inner try p.addNode(.{
                            .tag = .ptr_type_bit_range,
                            .main_token = asterisk,
                            .data = .{
                                .lhs = try p.addExtra(Node.PtrTypeBitRange{
                                    .sentinel = 0,
                                    .align_node = mods.align_node,
                                    .bit_range_start = mods.bit_range_start,
                                    .bit_range_end = mods.bit_range_end,
                                }),
                                .rhs = elem_type,
                            },
                        });
                    }
                };
                return p.addNode(.{
                    .tag = .ptr_type_aligned,
                    .main_token = asterisk,
                    .data = .{
                        .lhs = 0,
                        .rhs = inner,
                    },
                });
            },
            .l_bracket => switch (p.token_tags[p.tok_i + 1]) {
                .asterisk => {
                    _ = p.nextToken();
                    const asterisk = p.nextToken();
                    var sentinel: Node.Index = 0;
                    prefix: {
                        if (p.eatToken(.identifier)) |ident| {
                            const token_slice = p.source[p.token_starts[ident]..][0..2];
                            if (!std.mem.eql(u8, token_slice, "c]")) {
                                p.tok_i -= 1;
                            } else {
                                break :prefix;
                            }
                        }
                        if (p.eatToken(.colon)) |_| {
                            sentinel = try p.expectExpr();
                        }
                    }
                    _ = try p.expectToken(.r_bracket);
                    const mods = try p.parsePtrModifiers();
                    const elem_type = try p.expectTypeExpr();
                    if (mods.bit_range_start == 0) {
                        if (sentinel == 0) {
                            return p.addNode(.{
                                .tag = .ptr_type_aligned,
                                .main_token = asterisk,
                                .data = .{
                                    .lhs = mods.align_node,
                                    .rhs = elem_type,
                                },
                            });
                        } else if (mods.align_node == 0) {
                            return p.addNode(.{
                                .tag = .ptr_type_sentinel,
                                .main_token = asterisk,
                                .data = .{
                                    .lhs = sentinel,
                                    .rhs = elem_type,
                                },
                            });
                        } else {
                            return p.addNode(.{
                                .tag = .ptr_type,
                                .main_token = asterisk,
                                .data = .{
                                    .lhs = try p.addExtra(Node.PtrType{
                                        .sentinel = sentinel,
                                        .align_node = mods.align_node,
                                    }),
                                    .rhs = elem_type,
                                },
                            });
                        }
                    } else {
                        return p.addNode(.{
                            .tag = .ptr_type_bit_range,
                            .main_token = asterisk,
                            .data = .{
                                .lhs = try p.addExtra(Node.PtrTypeBitRange{
                                    .sentinel = sentinel,
                                    .align_node = mods.align_node,
                                    .bit_range_start = mods.bit_range_start,
                                    .bit_range_end = mods.bit_range_end,
                                }),
                                .rhs = elem_type,
                            },
                        });
                    }
                },
                else => {
                    const lbracket = p.nextToken();
                    const len_expr = try p.parseExpr();
                    const sentinel: Node.Index = if (p.eatToken(.colon)) |_|
                        try p.expectExpr()
                    else
                        0;
                    _ = try p.expectToken(.r_bracket);
                    if (len_expr == 0) {
                        const mods = try p.parsePtrModifiers();
                        const elem_type = try p.expectTypeExpr();
                        if (mods.bit_range_start != 0) {
                            try p.warnMsg(.{
                                .tag = .invalid_bit_range,
                                .token = p.nodes.items(.main_token)[mods.bit_range_start],
                            });
                        }
                        if (sentinel == 0) {
                            return p.addNode(.{
                                .tag = .ptr_type_aligned,
                                .main_token = lbracket,
                                .data = .{
                                    .lhs = mods.align_node,
                                    .rhs = elem_type,
                                },
                            });
                        } else if (mods.align_node == 0) {
                            return p.addNode(.{
                                .tag = .ptr_type_sentinel,
                                .main_token = lbracket,
                                .data = .{
                                    .lhs = sentinel,
                                    .rhs = elem_type,
                                },
                            });
                        } else {
                            return p.addNode(.{
                                .tag = .ptr_type,
                                .main_token = lbracket,
                                .data = .{
                                    .lhs = try p.addExtra(Node.PtrType{
                                        .sentinel = sentinel,
                                        .align_node = mods.align_node,
                                    }),
                                    .rhs = elem_type,
                                },
                            });
                        }
                    } else {
                        switch (p.token_tags[p.tok_i]) {
                            .keyword_align,
                            .keyword_const,
                            .keyword_volatile,
                            .keyword_allowzero,
                            => return p.fail(.ptr_mod_on_array_child_type),
                            else => {},
                        }
                        const elem_type = try p.expectTypeExpr();
                        if (sentinel == 0) {
                            return p.addNode(.{
                                .tag = .array_type,
                                .main_token = lbracket,
                                .data = .{
                                    .lhs = len_expr,
                                    .rhs = elem_type,
                                },
                            });
                        } else {
                            return p.addNode(.{
                                .tag = .array_type_sentinel,
                                .main_token = lbracket,
                                .data = .{
                                    .lhs = len_expr,
                                    .rhs = try p.addExtra(.{
                                        .elem_type = elem_type,
                                        .sentinel = sentinel,
                                    }),
                                },
                            });
                        }
                    }
                },
            },
            else => return p.parseErrorUnionExpr(),
        }
    }

    fn expectTypeExpr(p: *Parser) Error!Node.Index {
        const node = try p.parseTypeExpr();
        if (node == 0) {
            return p.fail(.expected_type_expr);
        }
        return node;
    }

    /// PrimaryExpr
    ///     <- AsmExpr
    ///      / IfExpr
    ///      / KEYWORD_break BreakLabel? Expr?
    ///      / KEYWORD_comptime Expr
    ///      / KEYWORD_nosuspend Expr
    ///      / KEYWORD_continue BreakLabel?
    ///      / KEYWORD_resume Expr
    ///      / KEYWORD_return Expr?
    ///      / BlockLabel? LoopExpr
    ///      / Block
    ///      / CurlySuffixExpr
    fn parsePrimaryExpr(p: *Parser) !Node.Index {
        switch (p.token_tags[p.tok_i]) {
            .keyword_asm => return p.expectAsmExpr(),
            .keyword_if => return p.parseIfExpr(),
            .keyword_break => {
                p.tok_i += 1;
                return p.addNode(.{
                    .tag = .@"break",
                    .main_token = p.tok_i - 1,
                    .data = .{
                        .lhs = try p.parseBreakLabel(),
                        .rhs = try p.parseExpr(),
                    },
                });
            },
            .keyword_continue => {
                p.tok_i += 1;
                return p.addNode(.{
                    .tag = .@"continue",
                    .main_token = p.tok_i - 1,
                    .data = .{
                        .lhs = try p.parseBreakLabel(),
                        .rhs = undefined,
                    },
                });
            },
            .keyword_comptime => {
                p.tok_i += 1;
                return p.addNode(.{
                    .tag = .@"comptime",
                    .main_token = p.tok_i - 1,
                    .data = .{
                        .lhs = try p.expectExpr(),
                        .rhs = undefined,
                    },
                });
            },
            .keyword_nosuspend => {
                p.tok_i += 1;
                return p.addNode(.{
                    .tag = .@"nosuspend",
                    .main_token = p.tok_i - 1,
                    .data = .{
                        .lhs = try p.expectExpr(),
                        .rhs = undefined,
                    },
                });
            },
            .keyword_resume => {
                p.tok_i += 1;
                return p.addNode(.{
                    .tag = .@"resume",
                    .main_token = p.tok_i - 1,
                    .data = .{
                        .lhs = try p.expectExpr(),
                        .rhs = undefined,
                    },
                });
            },
            .keyword_return => {
                p.tok_i += 1;
                return p.addNode(.{
                    .tag = .@"return",
                    .main_token = p.tok_i - 1,
                    .data = .{
                        .lhs = try p.parseExpr(),
                        .rhs = undefined,
                    },
                });
            },
            .identifier => {
                if (p.token_tags[p.tok_i + 1] == .colon) {
                    switch (p.token_tags[p.tok_i + 2]) {
                        .keyword_inline => {
                            p.tok_i += 3;
                            switch (p.token_tags[p.tok_i]) {
                                .keyword_for => return p.parseForExpr(),
                                .keyword_while => return p.parseWhileExpr(),
                                else => return p.fail(.expected_inlinable),
                            }
                        },
                        .keyword_for => {
                            p.tok_i += 2;
                            return p.parseForExpr();
                        },
                        .keyword_while => {
                            p.tok_i += 2;
                            return p.parseWhileExpr();
                        },
                        .l_brace => {
                            p.tok_i += 2;
                            return p.parseBlock();
                        },
                        else => return p.parseCurlySuffixExpr(),
                    }
                } else {
                    return p.parseCurlySuffixExpr();
                }
            },
            .keyword_inline => {
                p.tok_i += 1;
                switch (p.token_tags[p.tok_i]) {
                    .keyword_for => return p.parseForExpr(),
                    .keyword_while => return p.parseWhileExpr(),
                    else => return p.fail(.expected_inlinable),
                }
            },
            .keyword_for => return p.parseForExpr(),
            .keyword_while => return p.parseWhileExpr(),
            .l_brace => return p.parseBlock(),
            else => return p.parseCurlySuffixExpr(),
        }
    }

    /// IfExpr <- IfPrefix Expr (KEYWORD_else Payload? Expr)?
    fn parseIfExpr(p: *Parser) !Node.Index {
        return p.parseIf(parseExpr);
    }

    /// Block <- LBRACE Statement* RBRACE
    fn parseBlock(p: *Parser) !Node.Index {
        const lbrace = p.eatToken(.l_brace) orelse return null_node;
        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);
        while (true) {
            if (p.token_tags[p.tok_i] == .r_brace) break;
            const statement = try p.expectStatementRecoverable();
            if (statement == 0) break;
            try p.scratch.append(p.gpa, statement);
        }
        _ = try p.expectToken(.r_brace);
        const semicolon = (p.token_tags[p.tok_i - 2] == .semicolon);
        const statements = p.scratch.items[scratch_top..];
        switch (statements.len) {
            0 => return p.addNode(.{
                .tag = .block_two,
                .main_token = lbrace,
                .data = .{
                    .lhs = 0,
                    .rhs = 0,
                },
            }),
            1 => return p.addNode(.{
                .tag = if (semicolon) .block_two_semicolon else .block_two,
                .main_token = lbrace,
                .data = .{
                    .lhs = statements[0],
                    .rhs = 0,
                },
            }),
            2 => return p.addNode(.{
                .tag = if (semicolon) .block_two_semicolon else .block_two,
                .main_token = lbrace,
                .data = .{
                    .lhs = statements[0],
                    .rhs = statements[1],
                },
            }),
            else => {
                const span = try p.listToSpan(statements);
                return p.addNode(.{
                    .tag = if (semicolon) .block_semicolon else .block,
                    .main_token = lbrace,
                    .data = .{
                        .lhs = span.start,
                        .rhs = span.end,
                    },
                });
            },
        }
    }

    /// ForPrefix <- KEYWORD_for LPAREN Expr RPAREN PtrIndexPayload
    /// ForExpr <- ForPrefix Expr (KEYWORD_else Expr)?
    fn parseForExpr(p: *Parser) !Node.Index {
        const for_token = p.eatToken(.keyword_for) orelse return null_node;
        _ = try p.expectToken(.l_paren);
        const array_expr = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        const found_payload = try p.parsePtrIndexPayload();
        if (found_payload == 0) try p.warn(.expected_loop_payload);

        const then_expr = try p.expectExpr();
        _ = p.eatToken(.keyword_else) orelse {
            return p.addNode(.{
                .tag = .for_simple,
                .main_token = for_token,
                .data = .{
                    .lhs = array_expr,
                    .rhs = then_expr,
                },
            });
        };
        const else_expr = try p.expectExpr();
        return p.addNode(.{
            .tag = .@"for",
            .main_token = for_token,
            .data = .{
                .lhs = array_expr,
                .rhs = try p.addExtra(Node.If{
                    .then_expr = then_expr,
                    .else_expr = else_expr,
                }),
            },
        });
    }

    /// WhilePrefix <- KEYWORD_while LPAREN Expr RPAREN PtrPayload? WhileContinueExpr?
    /// WhileExpr <- WhilePrefix Expr (KEYWORD_else Payload? Expr)?
    fn parseWhileExpr(p: *Parser) !Node.Index {
        const while_token = p.eatToken(.keyword_while) orelse return null_node;
        _ = try p.expectToken(.l_paren);
        const condition = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        _ = try p.parsePtrPayload();
        const cont_expr = try p.parseWhileContinueExpr();

        const then_expr = try p.expectExpr();
        _ = p.eatToken(.keyword_else) orelse {
            if (cont_expr == 0) {
                return p.addNode(.{
                    .tag = .while_simple,
                    .main_token = while_token,
                    .data = .{
                        .lhs = condition,
                        .rhs = then_expr,
                    },
                });
            } else {
                return p.addNode(.{
                    .tag = .while_cont,
                    .main_token = while_token,
                    .data = .{
                        .lhs = condition,
                        .rhs = try p.addExtra(Node.WhileCont{
                            .cont_expr = cont_expr,
                            .then_expr = then_expr,
                        }),
                    },
                });
            }
        };
        _ = try p.parsePayload();
        const else_expr = try p.expectExpr();
        return p.addNode(.{
            .tag = .@"while",
            .main_token = while_token,
            .data = .{
                .lhs = condition,
                .rhs = try p.addExtra(Node.While{
                    .cont_expr = cont_expr,
                    .then_expr = then_expr,
                    .else_expr = else_expr,
                }),
            },
        });
    }

    /// CurlySuffixExpr <- TypeExpr InitList?
    /// InitList
    ///     <- LBRACE FieldInit (COMMA FieldInit)* COMMA? RBRACE
    ///      / LBRACE Expr (COMMA Expr)* COMMA? RBRACE
    ///      / LBRACE RBRACE
    fn parseCurlySuffixExpr(p: *Parser) !Node.Index {
        const lhs = try p.parseTypeExpr();
        if (lhs == 0) return null_node;
        const lbrace = p.eatToken(.l_brace) orelse return lhs;

        // If there are 0 or 1 items, we can use ArrayInitOne/StructInitOne;
        // otherwise we use the full ArrayInit/StructInit.

        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);
        const field_init = try p.parseFieldInit();
        if (field_init != 0) {
            try p.scratch.append(p.gpa, field_init);
            while (true) {
                switch (p.token_tags[p.tok_i]) {
                    .comma => p.tok_i += 1,
                    .r_brace => {
                        p.tok_i += 1;
                        break;
                    },
                    .colon, .r_paren, .r_bracket => return p.failExpected(.r_brace),
                    // Likely just a missing comma; give error but continue parsing.
                    else => try p.warnExpected(.comma),
                }
                if (p.eatToken(.r_brace)) |_| break;
                const next = try p.expectFieldInit();
                try p.scratch.append(p.gpa, next);
            }
            const comma = (p.token_tags[p.tok_i - 2] == .comma);
            const inits = p.scratch.items[scratch_top..];
            switch (inits.len) {
                0 => unreachable,
                1 => return p.addNode(.{
                    .tag = if (comma) .struct_init_one_comma else .struct_init_one,
                    .main_token = lbrace,
                    .data = .{
                        .lhs = lhs,
                        .rhs = inits[0],
                    },
                }),
                else => return p.addNode(.{
                    .tag = if (comma) .struct_init_comma else .struct_init,
                    .main_token = lbrace,
                    .data = .{
                        .lhs = lhs,
                        .rhs = try p.addExtra(try p.listToSpan(inits)),
                    },
                }),
            }
        }

        while (true) {
            if (p.eatToken(.r_brace)) |_| break;
            const elem_init = try p.expectExpr();
            try p.scratch.append(p.gpa, elem_init);
            switch (p.token_tags[p.tok_i]) {
                .comma => p.tok_i += 1,
                .r_brace => {
                    p.tok_i += 1;
                    break;
                },
                .colon, .r_paren, .r_bracket => return p.failExpected(.r_brace),
                // Likely just a missing comma; give error but continue parsing.
                else => try p.warnExpected(.comma),
            }
        }
        const comma = (p.token_tags[p.tok_i - 2] == .comma);
        const inits = p.scratch.items[scratch_top..];
        switch (inits.len) {
            0 => return p.addNode(.{
                .tag = .struct_init_one,
                .main_token = lbrace,
                .data = .{
                    .lhs = lhs,
                    .rhs = 0,
                },
            }),
            1 => return p.addNode(.{
                .tag = if (comma) .array_init_one_comma else .array_init_one,
                .main_token = lbrace,
                .data = .{
                    .lhs = lhs,
                    .rhs = inits[0],
                },
            }),
            else => return p.addNode(.{
                .tag = if (comma) .array_init_comma else .array_init,
                .main_token = lbrace,
                .data = .{
                    .lhs = lhs,
                    .rhs = try p.addExtra(try p.listToSpan(inits)),
                },
            }),
        }
    }

    /// ErrorUnionExpr <- SuffixExpr (EXCLAMATIONMARK TypeExpr)?
    fn parseErrorUnionExpr(p: *Parser) !Node.Index {
        const suffix_expr = try p.parseSuffixExpr();
        if (suffix_expr == 0) return null_node;
        const bang = p.eatToken(.bang) orelse return suffix_expr;
        return p.addNode(.{
            .tag = .error_union,
            .main_token = bang,
            .data = .{
                .lhs = suffix_expr,
                .rhs = try p.expectTypeExpr(),
            },
        });
    }

    /// SuffixExpr
    ///     <- KEYWORD_async PrimaryTypeExpr SuffixOp* FnCallArguments
    ///      / PrimaryTypeExpr (SuffixOp / FnCallArguments)*
    /// FnCallArguments <- LPAREN ExprList RPAREN
    /// ExprList <- (Expr COMMA)* Expr?
    fn parseSuffixExpr(p: *Parser) !Node.Index {
        if (p.eatToken(.keyword_async)) |_| {
            var res = try p.expectPrimaryTypeExpr();
            while (true) {
                const node = try p.parseSuffixOp(res);
                if (node == 0) break;
                res = node;
            }
            const lparen = p.eatToken(.l_paren) orelse {
                try p.warn(.expected_param_list);
                return res;
            };
            const scratch_top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(scratch_top);
            while (true) {
                if (p.eatToken(.r_paren)) |_| break;
                const param = try p.expectExpr();
                try p.scratch.append(p.gpa, param);
                switch (p.token_tags[p.tok_i]) {
                    .comma => p.tok_i += 1,
                    .r_paren => {
                        p.tok_i += 1;
                        break;
                    },
                    .colon, .r_brace, .r_bracket => return p.failExpected(.r_paren),
                    // Likely just a missing comma; give error but continue parsing.
                    else => try p.warnExpected(.comma),
                }
            }
            const comma = (p.token_tags[p.tok_i - 2] == .comma);
            const params = p.scratch.items[scratch_top..];
            switch (params.len) {
                0 => return p.addNode(.{
                    .tag = if (comma) .async_call_one_comma else .async_call_one,
                    .main_token = lparen,
                    .data = .{
                        .lhs = res,
                        .rhs = 0,
                    },
                }),
                1 => return p.addNode(.{
                    .tag = if (comma) .async_call_one_comma else .async_call_one,
                    .main_token = lparen,
                    .data = .{
                        .lhs = res,
                        .rhs = params[0],
                    },
                }),
                else => return p.addNode(.{
                    .tag = if (comma) .async_call_comma else .async_call,
                    .main_token = lparen,
                    .data = .{
                        .lhs = res,
                        .rhs = try p.addExtra(try p.listToSpan(params)),
                    },
                }),
            }
        }

        var res = try p.parsePrimaryTypeExpr();
        if (res == 0) return res;
        while (true) {
            const suffix_op = try p.parseSuffixOp(res);
            if (suffix_op != 0) {
                res = suffix_op;
                continue;
            }
            const lparen = p.eatToken(.l_paren) orelse return res;
            const scratch_top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(scratch_top);
            while (true) {
                if (p.eatToken(.r_paren)) |_| break;
                const param = try p.expectExpr();
                try p.scratch.append(p.gpa, param);
                switch (p.token_tags[p.tok_i]) {
                    .comma => p.tok_i += 1,
                    .r_paren => {
                        p.tok_i += 1;
                        break;
                    },
                    .colon, .r_brace, .r_bracket => return p.failExpected(.r_paren),
                    // Likely just a missing comma; give error but continue parsing.
                    else => try p.warnExpected(.comma),
                }
            }
            const comma = (p.token_tags[p.tok_i - 2] == .comma);
            const params = p.scratch.items[scratch_top..];
            res = switch (params.len) {
                0 => try p.addNode(.{
                    .tag = if (comma) .call_one_comma else .call_one,
                    .main_token = lparen,
                    .data = .{
                        .lhs = res,
                        .rhs = 0,
                    },
                }),
                1 => try p.addNode(.{
                    .tag = if (comma) .call_one_comma else .call_one,
                    .main_token = lparen,
                    .data = .{
                        .lhs = res,
                        .rhs = params[0],
                    },
                }),
                else => try p.addNode(.{
                    .tag = if (comma) .call_comma else .call,
                    .main_token = lparen,
                    .data = .{
                        .lhs = res,
                        .rhs = try p.addExtra(try p.listToSpan(params)),
                    },
                }),
            };
        }
    }

    /// PrimaryTypeExpr
    ///     <- BUILTINIDENTIFIER FnCallArguments
    ///      / CHAR_LITERAL
    ///      / ContainerDecl
    ///      / DOT IDENTIFIER
    ///      / DOT InitList
    ///      / ErrorSetDecl
    ///      / FLOAT
    ///      / FnProto
    ///      / GroupedExpr
    ///      / LabeledTypeExpr
    ///      / IDENTIFIER
    ///      / IfTypeExpr
    ///      / INTEGER
    ///      / KEYWORD_comptime TypeExpr
    ///      / KEYWORD_error DOT IDENTIFIER
    ///      / KEYWORD_false
    ///      / KEYWORD_null
    ///      / KEYWORD_anyframe
    ///      / KEYWORD_true
    ///      / KEYWORD_undefined
    ///      / KEYWORD_unreachable
    ///      / STRINGLITERAL
    ///      / SwitchExpr
    /// ContainerDecl <- (KEYWORD_extern / KEYWORD_packed)? ContainerDeclAuto
    /// ContainerDeclAuto <- ContainerDeclType LBRACE ContainerMembers RBRACE
    /// InitList
    ///     <- LBRACE FieldInit (COMMA FieldInit)* COMMA? RBRACE
    ///      / LBRACE Expr (COMMA Expr)* COMMA? RBRACE
    ///      / LBRACE RBRACE
    /// ErrorSetDecl <- KEYWORD_error LBRACE IdentifierList RBRACE
    /// GroupedExpr <- LPAREN Expr RPAREN
    /// IfTypeExpr <- IfPrefix TypeExpr (KEYWORD_else Payload? TypeExpr)?
    /// LabeledTypeExpr
    ///     <- BlockLabel Block
    ///      / BlockLabel? LoopTypeExpr
    /// LoopTypeExpr <- KEYWORD_inline? (ForTypeExpr / WhileTypeExpr)
    fn parsePrimaryTypeExpr(p: *Parser) !Node.Index {
        switch (p.token_tags[p.tok_i]) {
            .char_literal => return p.addNode(.{
                .tag = .char_literal,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = undefined,
                    .rhs = undefined,
                },
            }),
            .integer_literal => return p.addNode(.{
                .tag = .integer_literal,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = undefined,
                    .rhs = undefined,
                },
            }),
            .float_literal => return p.addNode(.{
                .tag = .float_literal,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = undefined,
                    .rhs = undefined,
                },
            }),
            .keyword_false => return p.addNode(.{
                .tag = .false_literal,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = undefined,
                    .rhs = undefined,
                },
            }),
            .keyword_true => return p.addNode(.{
                .tag = .true_literal,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = undefined,
                    .rhs = undefined,
                },
            }),
            .keyword_null => return p.addNode(.{
                .tag = .null_literal,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = undefined,
                    .rhs = undefined,
                },
            }),
            .keyword_undefined => return p.addNode(.{
                .tag = .undefined_literal,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = undefined,
                    .rhs = undefined,
                },
            }),
            .keyword_unreachable => return p.addNode(.{
                .tag = .unreachable_literal,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = undefined,
                    .rhs = undefined,
                },
            }),
            .keyword_anyframe => return p.addNode(.{
                .tag = .anyframe_literal,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = undefined,
                    .rhs = undefined,
                },
            }),
            .string_literal => {
                const main_token = p.nextToken();
                return p.addNode(.{
                    .tag = .string_literal,
                    .main_token = main_token,
                    .data = .{
                        .lhs = undefined,
                        .rhs = undefined,
                    },
                });
            },

            .builtin => return p.parseBuiltinCall(),
            .keyword_fn => return p.parseFnProto(),
            .keyword_if => return p.parseIf(parseTypeExpr),
            .keyword_switch => return p.expectSwitchExpr(),

            .keyword_extern,
            .keyword_packed,
            => {
                p.tok_i += 1;
                return p.parseContainerDeclAuto();
            },

            .keyword_struct,
            .keyword_opaque,
            .keyword_enum,
            .keyword_union,
            => return p.parseContainerDeclAuto(),

            .keyword_comptime => return p.addNode(.{
                .tag = .@"comptime",
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = try p.expectTypeExpr(),
                    .rhs = undefined,
                },
            }),
            .multiline_string_literal_line => {
                const first_line = p.nextToken();
                while (p.token_tags[p.tok_i] == .multiline_string_literal_line) {
                    p.tok_i += 1;
                }
                return p.addNode(.{
                    .tag = .multiline_string_literal,
                    .main_token = first_line,
                    .data = .{
                        .lhs = first_line,
                        .rhs = p.tok_i - 1,
                    },
                });
            },
            .identifier => switch (p.token_tags[p.tok_i + 1]) {
                .colon => switch (p.token_tags[p.tok_i + 2]) {
                    .keyword_inline => {
                        p.tok_i += 3;
                        switch (p.token_tags[p.tok_i]) {
                            .keyword_for => return p.parseForTypeExpr(),
                            .keyword_while => return p.parseWhileTypeExpr(),
                            else => return p.fail(.expected_inlinable),
                        }
                    },
                    .keyword_for => {
                        p.tok_i += 2;
                        return p.parseForTypeExpr();
                    },
                    .keyword_while => {
                        p.tok_i += 2;
                        return p.parseWhileTypeExpr();
                    },
                    .l_brace => {
                        p.tok_i += 2;
                        return p.parseBlock();
                    },
                    else => return p.addNode(.{
                        .tag = .identifier,
                        .main_token = p.nextToken(),
                        .data = .{
                            .lhs = undefined,
                            .rhs = undefined,
                        },
                    }),
                },
                else => return p.addNode(.{
                    .tag = .identifier,
                    .main_token = p.nextToken(),
                    .data = .{
                        .lhs = undefined,
                        .rhs = undefined,
                    },
                }),
            },
            .keyword_inline => {
                p.tok_i += 1;
                switch (p.token_tags[p.tok_i]) {
                    .keyword_for => return p.parseForTypeExpr(),
                    .keyword_while => return p.parseWhileTypeExpr(),
                    else => return p.fail(.expected_inlinable),
                }
            },
            .keyword_for => return p.parseForTypeExpr(),
            .keyword_while => return p.parseWhileTypeExpr(),
            .period => switch (p.token_tags[p.tok_i + 1]) {
                .identifier => return p.addNode(.{
                    .tag = .enum_literal,
                    .data = .{
                        .lhs = p.nextToken(), // dot
                        .rhs = undefined,
                    },
                    .main_token = p.nextToken(), // identifier
                }),
                .l_brace => {
                    const lbrace = p.tok_i + 1;
                    p.tok_i = lbrace + 1;

                    // If there are 0, 1, or 2 items, we can use ArrayInitDotTwo/StructInitDotTwo;
                    // otherwise we use the full ArrayInitDot/StructInitDot.

                    const scratch_top = p.scratch.items.len;
                    defer p.scratch.shrinkRetainingCapacity(scratch_top);
                    const field_init = try p.parseFieldInit();
                    if (field_init != 0) {
                        try p.scratch.append(p.gpa, field_init);
                        while (true) {
                            switch (p.token_tags[p.tok_i]) {
                                .comma => p.tok_i += 1,
                                .r_brace => {
                                    p.tok_i += 1;
                                    break;
                                },
                                .colon, .r_paren, .r_bracket => return p.failExpected(.r_brace),
                                // Likely just a missing comma; give error but continue parsing.
                                else => try p.warnExpected(.comma),
                            }
                            if (p.eatToken(.r_brace)) |_| break;
                            const next = try p.expectFieldInit();
                            try p.scratch.append(p.gpa, next);
                        }
                        const comma = (p.token_tags[p.tok_i - 2] == .comma);
                        const inits = p.scratch.items[scratch_top..];
                        switch (inits.len) {
                            0 => unreachable,
                            1 => return p.addNode(.{
                                .tag = if (comma) .struct_init_dot_two_comma else .struct_init_dot_two,
                                .main_token = lbrace,
                                .data = .{
                                    .lhs = inits[0],
                                    .rhs = 0,
                                },
                            }),
                            2 => return p.addNode(.{
                                .tag = if (comma) .struct_init_dot_two_comma else .struct_init_dot_two,
                                .main_token = lbrace,
                                .data = .{
                                    .lhs = inits[0],
                                    .rhs = inits[1],
                                },
                            }),
                            else => {
                                const span = try p.listToSpan(inits);
                                return p.addNode(.{
                                    .tag = if (comma) .struct_init_dot_comma else .struct_init_dot,
                                    .main_token = lbrace,
                                    .data = .{
                                        .lhs = span.start,
                                        .rhs = span.end,
                                    },
                                });
                            },
                        }
                    }

                    while (true) {
                        if (p.eatToken(.r_brace)) |_| break;
                        const elem_init = try p.expectExpr();
                        try p.scratch.append(p.gpa, elem_init);
                        switch (p.token_tags[p.tok_i]) {
                            .comma => p.tok_i += 1,
                            .r_brace => {
                                p.tok_i += 1;
                                break;
                            },
                            .colon, .r_paren, .r_bracket => return p.failExpected(.r_brace),
                            // Likely just a missing comma; give error but continue parsing.
                            else => try p.warnExpected(.comma),
                        }
                    }
                    const comma = (p.token_tags[p.tok_i - 2] == .comma);
                    const inits = p.scratch.items[scratch_top..];
                    switch (inits.len) {
                        0 => return p.addNode(.{
                            .tag = .struct_init_dot_two,
                            .main_token = lbrace,
                            .data = .{
                                .lhs = 0,
                                .rhs = 0,
                            },
                        }),
                        1 => return p.addNode(.{
                            .tag = if (comma) .array_init_dot_two_comma else .array_init_dot_two,
                            .main_token = lbrace,
                            .data = .{
                                .lhs = inits[0],
                                .rhs = 0,
                            },
                        }),
                        2 => return p.addNode(.{
                            .tag = if (comma) .array_init_dot_two_comma else .array_init_dot_two,
                            .main_token = lbrace,
                            .data = .{
                                .lhs = inits[0],
                                .rhs = inits[1],
                            },
                        }),
                        else => {
                            const span = try p.listToSpan(inits);
                            return p.addNode(.{
                                .tag = if (comma) .array_init_dot_comma else .array_init_dot,
                                .main_token = lbrace,
                                .data = .{
                                    .lhs = span.start,
                                    .rhs = span.end,
                                },
                            });
                        },
                    }
                },
                else => return null_node,
            },
            .keyword_error => switch (p.token_tags[p.tok_i + 1]) {
                .l_brace => {
                    const error_token = p.tok_i;
                    p.tok_i += 2;
                    while (true) {
                        if (p.eatToken(.r_brace)) |_| break;
                        _ = try p.eatDocComments();
                        _ = try p.expectToken(.identifier);
                        switch (p.token_tags[p.tok_i]) {
                            .comma => p.tok_i += 1,
                            .r_brace => {
                                p.tok_i += 1;
                                break;
                            },
                            .colon, .r_paren, .r_bracket => return p.failExpected(.r_brace),
                            // Likely just a missing comma; give error but continue parsing.
                            else => try p.warnExpected(.comma),
                        }
                    }
                    return p.addNode(.{
                        .tag = .error_set_decl,
                        .main_token = error_token,
                        .data = .{
                            .lhs = undefined,
                            .rhs = p.tok_i - 1, // rbrace
                        },
                    });
                },
                else => {
                    const main_token = p.nextToken();
                    const period = p.eatToken(.period);
                    if (period == null) try p.warnExpected(.period);
                    const identifier = p.eatToken(.identifier);
                    if (identifier == null) try p.warnExpected(.identifier);
                    return p.addNode(.{
                        .tag = .error_value,
                        .main_token = main_token,
                        .data = .{
                            .lhs = period orelse 0,
                            .rhs = identifier orelse 0,
                        },
                    });
                },
            },
            .l_paren => return p.addNode(.{
                .tag = .grouped_expression,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = try p.expectExpr(),
                    .rhs = try p.expectToken(.r_paren),
                },
            }),
            else => return null_node,
        }
    }

    fn expectPrimaryTypeExpr(p: *Parser) !Node.Index {
        const node = try p.parsePrimaryTypeExpr();
        if (node == 0) {
            return p.fail(.expected_primary_type_expr);
        }
        return node;
    }

    /// ForPrefix <- KEYWORD_for LPAREN Expr RPAREN PtrIndexPayload
    /// ForTypeExpr <- ForPrefix TypeExpr (KEYWORD_else TypeExpr)?
    fn parseForTypeExpr(p: *Parser) !Node.Index {
        const for_token = p.eatToken(.keyword_for) orelse return null_node;
        _ = try p.expectToken(.l_paren);
        const array_expr = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        const found_payload = try p.parsePtrIndexPayload();
        if (found_payload == 0) try p.warn(.expected_loop_payload);

        const then_expr = try p.expectTypeExpr();
        _ = p.eatToken(.keyword_else) orelse {
            return p.addNode(.{
                .tag = .for_simple,
                .main_token = for_token,
                .data = .{
                    .lhs = array_expr,
                    .rhs = then_expr,
                },
            });
        };
        const else_expr = try p.expectTypeExpr();
        return p.addNode(.{
            .tag = .@"for",
            .main_token = for_token,
            .data = .{
                .lhs = array_expr,
                .rhs = try p.addExtra(Node.If{
                    .then_expr = then_expr,
                    .else_expr = else_expr,
                }),
            },
        });
    }

    /// WhilePrefix <- KEYWORD_while LPAREN Expr RPAREN PtrPayload? WhileContinueExpr?
    /// WhileTypeExpr <- WhilePrefix TypeExpr (KEYWORD_else Payload? TypeExpr)?
    fn parseWhileTypeExpr(p: *Parser) !Node.Index {
        const while_token = p.eatToken(.keyword_while) orelse return null_node;
        _ = try p.expectToken(.l_paren);
        const condition = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        _ = try p.parsePtrPayload();
        const cont_expr = try p.parseWhileContinueExpr();

        const then_expr = try p.expectTypeExpr();
        _ = p.eatToken(.keyword_else) orelse {
            if (cont_expr == 0) {
                return p.addNode(.{
                    .tag = .while_simple,
                    .main_token = while_token,
                    .data = .{
                        .lhs = condition,
                        .rhs = then_expr,
                    },
                });
            } else {
                return p.addNode(.{
                    .tag = .while_cont,
                    .main_token = while_token,
                    .data = .{
                        .lhs = condition,
                        .rhs = try p.addExtra(Node.WhileCont{
                            .cont_expr = cont_expr,
                            .then_expr = then_expr,
                        }),
                    },
                });
            }
        };
        _ = try p.parsePayload();
        const else_expr = try p.expectTypeExpr();
        return p.addNode(.{
            .tag = .@"while",
            .main_token = while_token,
            .data = .{
                .lhs = condition,
                .rhs = try p.addExtra(Node.While{
                    .cont_expr = cont_expr,
                    .then_expr = then_expr,
                    .else_expr = else_expr,
                }),
            },
        });
    }

    /// SwitchExpr <- KEYWORD_switch LPAREN Expr RPAREN LBRACE SwitchProngList RBRACE
    fn expectSwitchExpr(p: *Parser) !Node.Index {
        const switch_token = p.assertToken(.keyword_switch);
        _ = try p.expectToken(.l_paren);
        const expr_node = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        _ = try p.expectToken(.l_brace);
        const cases = try p.parseSwitchProngList();
        const trailing_comma = p.token_tags[p.tok_i - 1] == .comma;
        _ = try p.expectToken(.r_brace);

        return p.addNode(.{
            .tag = if (trailing_comma) .switch_comma else .@"switch",
            .main_token = switch_token,
            .data = .{
                .lhs = expr_node,
                .rhs = try p.addExtra(Node.SubRange{
                    .start = cases.start,
                    .end = cases.end,
                }),
            },
        });
    }

    /// AsmExpr <- KEYWORD_asm KEYWORD_volatile? LPAREN Expr AsmOutput? RPAREN
    /// AsmOutput <- COLON AsmOutputList AsmInput?
    /// AsmInput <- COLON AsmInputList AsmClobbers?
    /// AsmClobbers <- COLON StringList
    /// StringList <- (STRINGLITERAL COMMA)* STRINGLITERAL?
    /// AsmOutputList <- (AsmOutputItem COMMA)* AsmOutputItem?
    /// AsmInputList <- (AsmInputItem COMMA)* AsmInputItem?
    fn expectAsmExpr(p: *Parser) !Node.Index {
        const asm_token = p.assertToken(.keyword_asm);
        _ = p.eatToken(.keyword_volatile);
        _ = try p.expectToken(.l_paren);
        const template = try p.expectExpr();

        if (p.eatToken(.r_paren)) |rparen| {
            return p.addNode(.{
                .tag = .asm_simple,
                .main_token = asm_token,
                .data = .{
                    .lhs = template,
                    .rhs = rparen,
                },
            });
        }

        _ = try p.expectToken(.colon);

        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);

        while (true) {
            const output_item = try p.parseAsmOutputItem();
            if (output_item == 0) break;
            try p.scratch.append(p.gpa, output_item);
            switch (p.token_tags[p.tok_i]) {
                .comma => p.tok_i += 1,
                // All possible delimiters.
                .colon, .r_paren, .r_brace, .r_bracket => break,
                // Likely just a missing comma; give error but continue parsing.
                else => try p.warnExpected(.comma),
            }
        }
        if (p.eatToken(.colon)) |_| {
            while (true) {
                const input_item = try p.parseAsmInputItem();
                if (input_item == 0) break;
                try p.scratch.append(p.gpa, input_item);
                switch (p.token_tags[p.tok_i]) {
                    .comma => p.tok_i += 1,
                    // All possible delimiters.
                    .colon, .r_paren, .r_brace, .r_bracket => break,
                    // Likely just a missing comma; give error but continue parsing.
                    else => try p.warnExpected(.comma),
                }
            }
            if (p.eatToken(.colon)) |_| {
                while (p.eatToken(.string_literal)) |_| {
                    switch (p.token_tags[p.tok_i]) {
                        .comma => p.tok_i += 1,
                        .colon, .r_paren, .r_brace, .r_bracket => break,
                        // Likely just a missing comma; give error but continue parsing.
                        else => try p.warnExpected(.comma),
                    }
                }
            }
        }
        const rparen = try p.expectToken(.r_paren);
        const span = try p.listToSpan(p.scratch.items[scratch_top..]);
        return p.addNode(.{
            .tag = .@"asm",
            .main_token = asm_token,
            .data = .{
                .lhs = template,
                .rhs = try p.addExtra(Node.Asm{
                    .items_start = span.start,
                    .items_end = span.end,
                    .rparen = rparen,
                }),
            },
        });
    }

    /// AsmOutputItem <- LBRACKET IDENTIFIER RBRACKET STRINGLITERAL LPAREN (MINUSRARROW TypeExpr / IDENTIFIER) RPAREN
    fn parseAsmOutputItem(p: *Parser) !Node.Index {
        _ = p.eatToken(.l_bracket) orelse return null_node;
        const identifier = try p.expectToken(.identifier);
        _ = try p.expectToken(.r_bracket);
        _ = try p.expectToken(.string_literal);
        _ = try p.expectToken(.l_paren);
        const type_expr: Node.Index = blk: {
            if (p.eatToken(.arrow)) |_| {
                break :blk try p.expectTypeExpr();
            } else {
                _ = try p.expectToken(.identifier);
                break :blk null_node;
            }
        };
        const rparen = try p.expectToken(.r_paren);
        return p.addNode(.{
            .tag = .asm_output,
            .main_token = identifier,
            .data = .{
                .lhs = type_expr,
                .rhs = rparen,
            },
        });
    }

    /// AsmInputItem <- LBRACKET IDENTIFIER RBRACKET STRINGLITERAL LPAREN Expr RPAREN
    fn parseAsmInputItem(p: *Parser) !Node.Index {
        _ = p.eatToken(.l_bracket) orelse return null_node;
        const identifier = try p.expectToken(.identifier);
        _ = try p.expectToken(.r_bracket);
        _ = try p.expectToken(.string_literal);
        _ = try p.expectToken(.l_paren);
        const expr = try p.expectExpr();
        const rparen = try p.expectToken(.r_paren);
        return p.addNode(.{
            .tag = .asm_input,
            .main_token = identifier,
            .data = .{
                .lhs = expr,
                .rhs = rparen,
            },
        });
    }

    /// BreakLabel <- COLON IDENTIFIER
    fn parseBreakLabel(p: *Parser) !TokenIndex {
        _ = p.eatToken(.colon) orelse return @as(TokenIndex, 0);
        return p.expectToken(.identifier);
    }

    /// BlockLabel <- IDENTIFIER COLON
    fn parseBlockLabel(p: *Parser) TokenIndex {
        if (p.token_tags[p.tok_i] == .identifier and
            p.token_tags[p.tok_i + 1] == .colon)
        {
            const identifier = p.tok_i;
            p.tok_i += 2;
            return identifier;
        }
        return 0;
    }

    /// FieldInit <- DOT IDENTIFIER EQUAL Expr
    fn parseFieldInit(p: *Parser) !Node.Index {
        if (p.token_tags[p.tok_i + 0] == .period and
            p.token_tags[p.tok_i + 1] == .identifier and
            p.token_tags[p.tok_i + 2] == .equal)
        {
            p.tok_i += 3;
            return p.expectExpr();
        } else {
            return null_node;
        }
    }

    fn expectFieldInit(p: *Parser) !Node.Index {
        _ = try p.expectToken(.period);
        _ = try p.expectToken(.identifier);
        _ = try p.expectToken(.equal);
        return p.expectExpr();
    }

    /// WhileContinueExpr <- COLON LPAREN AssignExpr RPAREN
    fn parseWhileContinueExpr(p: *Parser) !Node.Index {
        _ = p.eatToken(.colon) orelse return null_node;
        _ = try p.expectToken(.l_paren);
        const node = try p.parseAssignExpr();
        if (node == 0) return p.fail(.expected_expr_or_assignment);
        _ = try p.expectToken(.r_paren);
        return node;
    }

    /// LinkSection <- KEYWORD_linksection LPAREN Expr RPAREN
    fn parseLinkSection(p: *Parser) !Node.Index {
        _ = p.eatToken(.keyword_linksection) orelse return null_node;
        _ = try p.expectToken(.l_paren);
        const expr_node = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        return expr_node;
    }

    /// CallConv <- KEYWORD_callconv LPAREN Expr RPAREN
    fn parseCallconv(p: *Parser) !Node.Index {
        _ = p.eatToken(.keyword_callconv) orelse return null_node;
        _ = try p.expectToken(.l_paren);
        const expr_node = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        return expr_node;
    }

    /// ParamDecl
    ///     <- (KEYWORD_noalias / KEYWORD_comptime)? (IDENTIFIER COLON)? ParamType
    ///     / DOT3
    /// ParamType
    ///     <- Keyword_anytype
    ///      / TypeExpr
    /// This function can return null nodes and then still return nodes afterwards,
    /// such as in the case of anytype and `...`. Caller must look for rparen to find
    /// out when there are no more param decls left.
    fn expectParamDecl(p: *Parser) !Node.Index {
        _ = try p.eatDocComments();
        switch (p.token_tags[p.tok_i]) {
            .keyword_noalias, .keyword_comptime => p.tok_i += 1,
            .ellipsis3 => {
                p.tok_i += 1;
                return null_node;
            },
            else => {},
        }
        if (p.token_tags[p.tok_i] == .identifier and
            p.token_tags[p.tok_i + 1] == .colon)
        {
            p.tok_i += 2;
        }
        switch (p.token_tags[p.tok_i]) {
            .keyword_anytype => {
                p.tok_i += 1;
                return null_node;
            },
            else => return p.expectTypeExpr(),
        }
    }

    /// Payload <- PIPE IDENTIFIER PIPE
    fn parsePayload(p: *Parser) !TokenIndex {
        _ = p.eatToken(.pipe) orelse return @as(TokenIndex, 0);
        const identifier = try p.expectToken(.identifier);
        _ = try p.expectToken(.pipe);
        return identifier;
    }

    /// PtrPayload <- PIPE ASTERISK? IDENTIFIER PIPE
    fn parsePtrPayload(p: *Parser) !TokenIndex {
        _ = p.eatToken(.pipe) orelse return @as(TokenIndex, 0);
        _ = p.eatToken(.asterisk);
        const identifier = try p.expectToken(.identifier);
        _ = try p.expectToken(.pipe);
        return identifier;
    }

    /// PtrIndexPayload <- PIPE ASTERISK? IDENTIFIER (COMMA IDENTIFIER)? PIPE
    /// Returns the first identifier token, if any.
    fn parsePtrIndexPayload(p: *Parser) !TokenIndex {
        _ = p.eatToken(.pipe) orelse return @as(TokenIndex, 0);
        _ = p.eatToken(.asterisk);
        const identifier = try p.expectToken(.identifier);
        if (p.eatToken(.comma) != null) {
            _ = try p.expectToken(.identifier);
        }
        _ = try p.expectToken(.pipe);
        return identifier;
    }

    /// SwitchProng <- SwitchCase EQUALRARROW PtrPayload? AssignExpr
    /// SwitchCase
    ///     <- SwitchItem (COMMA SwitchItem)* COMMA?
    ///      / KEYWORD_else
    fn parseSwitchProng(p: *Parser) !Node.Index {
        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);

        if (p.eatToken(.keyword_else) == null) {
            while (true) {
                const item = try p.parseSwitchItem();
                if (item == 0) break;
                try p.scratch.append(p.gpa, item);
                if (p.eatToken(.comma) == null) break;
            }
            if (scratch_top == p.scratch.items.len) return null_node;
        }
        const arrow_token = try p.expectToken(.equal_angle_bracket_right);
        _ = try p.parsePtrPayload();

        const items = p.scratch.items[scratch_top..];
        switch (items.len) {
            0 => return p.addNode(.{
                .tag = .switch_case_one,
                .main_token = arrow_token,
                .data = .{
                    .lhs = 0,
                    .rhs = try p.expectAssignExpr(),
                },
            }),
            1 => return p.addNode(.{
                .tag = .switch_case_one,
                .main_token = arrow_token,
                .data = .{
                    .lhs = items[0],
                    .rhs = try p.expectAssignExpr(),
                },
            }),
            else => return p.addNode(.{
                .tag = .switch_case,
                .main_token = arrow_token,
                .data = .{
                    .lhs = try p.addExtra(try p.listToSpan(items)),
                    .rhs = try p.expectAssignExpr(),
                },
            }),
        }
    }

    /// SwitchItem <- Expr (DOT3 Expr)?
    fn parseSwitchItem(p: *Parser) !Node.Index {
        const expr = try p.parseExpr();
        if (expr == 0) return null_node;

        if (p.eatToken(.ellipsis3)) |token| {
            return p.addNode(.{
                .tag = .switch_range,
                .main_token = token,
                .data = .{
                    .lhs = expr,
                    .rhs = try p.expectExpr(),
                },
            });
        }
        return expr;
    }

    const PtrModifiers = struct {
        align_node: Node.Index,
        bit_range_start: Node.Index,
        bit_range_end: Node.Index,
    };

    fn parsePtrModifiers(p: *Parser) !PtrModifiers {
        var result: PtrModifiers = .{
            .align_node = 0,
            .bit_range_start = 0,
            .bit_range_end = 0,
        };
        var saw_const = false;
        var saw_volatile = false;
        var saw_allowzero = false;
        while (true) {
            switch (p.token_tags[p.tok_i]) {
                .keyword_align => {
                    if (result.align_node != 0) {
                        try p.warn(.extra_align_qualifier);
                    }
                    p.tok_i += 1;
                    _ = try p.expectToken(.l_paren);
                    result.align_node = try p.expectExpr();

                    if (p.eatToken(.colon)) |_| {
                        result.bit_range_start = try p.expectExpr();
                        _ = try p.expectToken(.colon);
                        result.bit_range_end = try p.expectExpr();
                    }

                    _ = try p.expectToken(.r_paren);
                },
                .keyword_const => {
                    if (saw_const) {
                        try p.warn(.extra_const_qualifier);
                    }
                    p.tok_i += 1;
                    saw_const = true;
                },
                .keyword_volatile => {
                    if (saw_volatile) {
                        try p.warn(.extra_volatile_qualifier);
                    }
                    p.tok_i += 1;
                    saw_volatile = true;
                },
                .keyword_allowzero => {
                    if (saw_allowzero) {
                        try p.warn(.extra_allowzero_qualifier);
                    }
                    p.tok_i += 1;
                    saw_allowzero = true;
                },
                else => return result,
            }
        }
    }

    /// SuffixOp
    ///     <- LBRACKET Expr (DOT2 (Expr? (COLON Expr)?)?)? RBRACKET
    ///      / DOT IDENTIFIER
    ///      / DOTASTERISK
    ///      / DOTQUESTIONMARK
    fn parseSuffixOp(p: *Parser, lhs: Node.Index) !Node.Index {
        switch (p.token_tags[p.tok_i]) {
            .l_bracket => {
                const lbracket = p.nextToken();
                const index_expr = try p.expectExpr();

                if (p.eatToken(.ellipsis2)) |_| {
                    const end_expr = try p.parseExpr();
                    if (p.eatToken(.colon)) |_| {
                        const sentinel = try p.parseExpr();
                        _ = try p.expectToken(.r_bracket);
                        return p.addNode(.{
                            .tag = .slice_sentinel,
                            .main_token = lbracket,
                            .data = .{
                                .lhs = lhs,
                                .rhs = try p.addExtra(Node.SliceSentinel{
                                    .start = index_expr,
                                    .end = end_expr,
                                    .sentinel = sentinel,
                                }),
                            },
                        });
                    }
                    _ = try p.expectToken(.r_bracket);
                    if (end_expr == 0) {
                        return p.addNode(.{
                            .tag = .slice_open,
                            .main_token = lbracket,
                            .data = .{
                                .lhs = lhs,
                                .rhs = index_expr,
                            },
                        });
                    }
                    return p.addNode(.{
                        .tag = .slice,
                        .main_token = lbracket,
                        .data = .{
                            .lhs = lhs,
                            .rhs = try p.addExtra(Node.Slice{
                                .start = index_expr,
                                .end = end_expr,
                            }),
                        },
                    });
                }
                _ = try p.expectToken(.r_bracket);
                return p.addNode(.{
                    .tag = .array_access,
                    .main_token = lbracket,
                    .data = .{
                        .lhs = lhs,
                        .rhs = index_expr,
                    },
                });
            },
            .period_asterisk => return p.addNode(.{
                .tag = .deref,
                .main_token = p.nextToken(),
                .data = .{
                    .lhs = lhs,
                    .rhs = undefined,
                },
            }),
            .invalid_periodasterisks => {
                try p.warn(.asterisk_after_ptr_deref);
                return p.addNode(.{
                    .tag = .deref,
                    .main_token = p.nextToken(),
                    .data = .{
                        .lhs = lhs,
                        .rhs = undefined,
                    },
                });
            },
            .period => switch (p.token_tags[p.tok_i + 1]) {
                .identifier => return p.addNode(.{
                    .tag = .field_access,
                    .main_token = p.nextToken(),
                    .data = .{
                        .lhs = lhs,
                        .rhs = p.nextToken(),
                    },
                }),
                .question_mark => return p.addNode(.{
                    .tag = .unwrap_optional,
                    .main_token = p.nextToken(),
                    .data = .{
                        .lhs = lhs,
                        .rhs = p.nextToken(),
                    },
                }),
                else => {
                    p.tok_i += 1;
                    try p.warn(.expected_suffix_op);
                    return null_node;
                },
            },
            else => return null_node,
        }
    }

    /// Caller must have already verified the first token.
    /// ContainerDeclType
    ///     <- KEYWORD_struct
    ///      / KEYWORD_enum (LPAREN Expr RPAREN)?
    ///      / KEYWORD_union (LPAREN (KEYWORD_enum (LPAREN Expr RPAREN)? / Expr) RPAREN)?
    ///      / KEYWORD_opaque
    fn parseContainerDeclAuto(p: *Parser) !Node.Index {
        const main_token = p.nextToken();
        const arg_expr = switch (p.token_tags[main_token]) {
            .keyword_struct, .keyword_opaque => null_node,
            .keyword_enum => blk: {
                if (p.eatToken(.l_paren)) |_| {
                    const expr = try p.expectExpr();
                    _ = try p.expectToken(.r_paren);
                    break :blk expr;
                } else {
                    break :blk null_node;
                }
            },
            .keyword_union => blk: {
                if (p.eatToken(.l_paren)) |_| {
                    if (p.eatToken(.keyword_enum)) |_| {
                        if (p.eatToken(.l_paren)) |_| {
                            const enum_tag_expr = try p.expectExpr();
                            _ = try p.expectToken(.r_paren);
                            _ = try p.expectToken(.r_paren);

                            _ = try p.expectToken(.l_brace);
                            const members = try p.parseContainerMembers();
                            const members_span = try members.toSpan(p);
                            _ = try p.expectToken(.r_brace);
                            return p.addNode(.{
                                .tag = switch (members.trailing) {
                                    true => .tagged_union_enum_tag_trailing,
                                    false => .tagged_union_enum_tag,
                                },
                                .main_token = main_token,
                                .data = .{
                                    .lhs = enum_tag_expr,
                                    .rhs = try p.addExtra(members_span),
                                },
                            });
                        } else {
                            _ = try p.expectToken(.r_paren);

                            _ = try p.expectToken(.l_brace);
                            const members = try p.parseContainerMembers();
                            _ = try p.expectToken(.r_brace);
                            if (members.len <= 2) {
                                return p.addNode(.{
                                    .tag = switch (members.trailing) {
                                        true => .tagged_union_two_trailing,
                                        false => .tagged_union_two,
                                    },
                                    .main_token = main_token,
                                    .data = .{
                                        .lhs = members.lhs,
                                        .rhs = members.rhs,
                                    },
                                });
                            } else {
                                const span = try members.toSpan(p);
                                return p.addNode(.{
                                    .tag = switch (members.trailing) {
                                        true => .tagged_union_trailing,
                                        false => .tagged_union,
                                    },
                                    .main_token = main_token,
                                    .data = .{
                                        .lhs = span.start,
                                        .rhs = span.end,
                                    },
                                });
                            }
                        }
                    } else {
                        const expr = try p.expectExpr();
                        _ = try p.expectToken(.r_paren);
                        break :blk expr;
                    }
                } else {
                    break :blk null_node;
                }
            },
            else => {
                p.tok_i -= 1;
                return p.fail(.expected_container);
            },
        };
        _ = try p.expectToken(.l_brace);
        const members = try p.parseContainerMembers();
        _ = try p.expectToken(.r_brace);
        if (arg_expr == 0) {
            if (members.len <= 2) {
                return p.addNode(.{
                    .tag = switch (members.trailing) {
                        true => .container_decl_two_trailing,
                        false => .container_decl_two,
                    },
                    .main_token = main_token,
                    .data = .{
                        .lhs = members.lhs,
                        .rhs = members.rhs,
                    },
                });
            } else {
                const span = try members.toSpan(p);
                return p.addNode(.{
                    .tag = switch (members.trailing) {
                        true => .container_decl_trailing,
                        false => .container_decl,
                    },
                    .main_token = main_token,
                    .data = .{
                        .lhs = span.start,
                        .rhs = span.end,
                    },
                });
            }
        } else {
            const span = try members.toSpan(p);
            return p.addNode(.{
                .tag = switch (members.trailing) {
                    true => .container_decl_arg_trailing,
                    false => .container_decl_arg,
                },
                .main_token = main_token,
                .data = .{
                    .lhs = arg_expr,
                    .rhs = try p.addExtra(Node.SubRange{
                        .start = span.start,
                        .end = span.end,
                    }),
                },
            });
        }
    }

    /// Holds temporary data until we are ready to construct the full ContainerDecl AST node.
    /// ByteAlign <- KEYWORD_align LPAREN Expr RPAREN
    fn parseByteAlign(p: *Parser) !Node.Index {
        _ = p.eatToken(.keyword_align) orelse return null_node;
        _ = try p.expectToken(.l_paren);
        const expr = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        return expr;
    }

    /// SwitchProngList <- (SwitchProng COMMA)* SwitchProng?
    fn parseSwitchProngList(p: *Parser) !Node.SubRange {
        return ListParseFn(parseSwitchProng)(p);
    }

    /// ParamDeclList <- (ParamDecl COMMA)* ParamDecl?
    fn parseParamDeclList(p: *Parser) !SmallSpan {
        _ = try p.expectToken(.l_paren);
        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);
        var varargs: union(enum) { none, seen, nonfinal: TokenIndex } = .none;
        while (true) {
            if (p.eatToken(.r_paren)) |_| break;
            if (varargs == .seen) varargs = .{ .nonfinal = p.tok_i };
            const param = try p.expectParamDecl();
            if (param != 0) {
                try p.scratch.append(p.gpa, param);
            } else if (p.token_tags[p.tok_i - 1] == .ellipsis3) {
                if (varargs == .none) varargs = .seen;
            }
            switch (p.token_tags[p.tok_i]) {
                .comma => p.tok_i += 1,
                .r_paren => {
                    p.tok_i += 1;
                    break;
                },
                .colon, .r_brace, .r_bracket => return p.failExpected(.r_paren),
                // Likely just a missing comma; give error but continue parsing.
                else => try p.warnExpected(.comma),
            }
        }
        if (varargs == .nonfinal) {
            try p.warnMsg(.{ .tag = .varargs_nonfinal, .token = varargs.nonfinal });
        }
        const params = p.scratch.items[scratch_top..];
        return switch (params.len) {
            0 => SmallSpan{ .zero_or_one = 0 },
            1 => SmallSpan{ .zero_or_one = params[0] },
            else => SmallSpan{ .multi = try p.listToSpan(params) },
        };
    }

    const NodeParseFn = fn (p: *Parser) Error!Node.Index;

    fn ListParseFn(comptime nodeParseFn: anytype) (fn (p: *Parser) Error!Node.SubRange) {
        return struct {
            pub fn parse(p: *Parser) Error!Node.SubRange {
                const scratch_top = p.scratch.items.len;
                defer p.scratch.shrinkRetainingCapacity(scratch_top);

                while (true) {
                    const item = try nodeParseFn(p);
                    if (item == 0) break;

                    try p.scratch.append(p.gpa, item);

                    switch (p.token_tags[p.tok_i]) {
                        .comma => p.tok_i += 1,
                        // All possible delimiters.
                        .colon, .r_paren, .r_brace, .r_bracket => break,
                        // Likely just a missing comma; give error but continue parsing.
                        else => try p.warnExpected(.comma),
                    }
                }
                return p.listToSpan(p.scratch.items[scratch_top..]);
            }
        }.parse;
    }

    /// FnCallArguments <- LPAREN ExprList RPAREN
    /// ExprList <- (Expr COMMA)* Expr?
    fn parseBuiltinCall(p: *Parser) !Node.Index {
        const builtin_token = p.assertToken(.builtin);
        if (p.token_tags[p.nextToken()] != .l_paren) {
            p.tok_i -= 1;
            try p.warn(.expected_param_list);
            // Pretend this was an identifier so we can continue parsing.
            return p.addNode(.{
                .tag = .identifier,
                .main_token = builtin_token,
                .data = .{
                    .lhs = undefined,
                    .rhs = undefined,
                },
            });
        }
        const scratch_top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(scratch_top);
        while (true) {
            if (p.eatToken(.r_paren)) |_| break;
            const param = try p.expectExpr();
            try p.scratch.append(p.gpa, param);
            switch (p.token_tags[p.tok_i]) {
                .comma => p.tok_i += 1,
                .r_paren => {
                    p.tok_i += 1;
                    break;
                },
                // Likely just a missing comma; give error but continue parsing.
                else => try p.warnExpected(.comma),
            }
        }
        const comma = (p.token_tags[p.tok_i - 2] == .comma);
        const params = p.scratch.items[scratch_top..];
        switch (params.len) {
            0 => return p.addNode(.{
                .tag = .builtin_call_two,
                .main_token = builtin_token,
                .data = .{
                    .lhs = 0,
                    .rhs = 0,
                },
            }),
            1 => return p.addNode(.{
                .tag = if (comma) .builtin_call_two_comma else .builtin_call_two,
                .main_token = builtin_token,
                .data = .{
                    .lhs = params[0],
                    .rhs = 0,
                },
            }),
            2 => return p.addNode(.{
                .tag = if (comma) .builtin_call_two_comma else .builtin_call_two,
                .main_token = builtin_token,
                .data = .{
                    .lhs = params[0],
                    .rhs = params[1],
                },
            }),
            else => {
                const span = try p.listToSpan(params);
                return p.addNode(.{
                    .tag = if (comma) .builtin_call_comma else .builtin_call,
                    .main_token = builtin_token,
                    .data = .{
                        .lhs = span.start,
                        .rhs = span.end,
                    },
                });
            },
        }
    }

    // string literal or multiline string literal
    fn parseStringLiteral(p: *Parser) !Node.Index {
        switch (p.token_tags[p.tok_i]) {
            .string_literal => {
                const main_token = p.nextToken();
                return p.addNode(.{
                    .tag = .string_literal,
                    .main_token = main_token,
                    .data = .{
                        .lhs = undefined,
                        .rhs = undefined,
                    },
                });
            },
            .multiline_string_literal_line => {
                const first_line = p.nextToken();
                while (p.token_tags[p.tok_i] == .multiline_string_literal_line) {
                    p.tok_i += 1;
                }
                return p.addNode(.{
                    .tag = .multiline_string_literal,
                    .main_token = first_line,
                    .data = .{
                        .lhs = first_line,
                        .rhs = p.tok_i - 1,
                    },
                });
            },
            else => return null_node,
        }
    }

    fn expectStringLiteral(p: *Parser) !Node.Index {
        const node = try p.parseStringLiteral();
        if (node == 0) {
            return p.fail(.expected_string_literal);
        }
        return node;
    }

    fn expectIntegerLiteral(p: *Parser) !Node.Index {
        return p.addNode(.{
            .tag = .integer_literal,
            .main_token = try p.expectToken(.integer_literal),
            .data = .{
                .lhs = undefined,
                .rhs = undefined,
            },
        });
    }

    /// KEYWORD_if LPAREN Expr RPAREN PtrPayload? Body (KEYWORD_else Payload? Body)?
    fn parseIf(p: *Parser, bodyParseFn: NodeParseFn) !Node.Index {
        const if_token = p.eatToken(.keyword_if) orelse return null_node;
        _ = try p.expectToken(.l_paren);
        const condition = try p.expectExpr();
        _ = try p.expectToken(.r_paren);
        _ = try p.parsePtrPayload();

        const then_expr = try bodyParseFn(p);
        if (then_expr == 0) return p.fail(.invalid_token);

        _ = p.eatToken(.keyword_else) orelse return p.addNode(.{
            .tag = .if_simple,
            .main_token = if_token,
            .data = .{
                .lhs = condition,
                .rhs = then_expr,
            },
        });
        _ = try p.parsePayload();
        const else_expr = try bodyParseFn(p);
        if (else_expr == 0) return p.fail(.invalid_token);

        return p.addNode(.{
            .tag = .@"if",
            .main_token = if_token,
            .data = .{
                .lhs = condition,
                .rhs = try p.addExtra(Node.If{
                    .then_expr = then_expr,
                    .else_expr = else_expr,
                }),
            },
        });
    }

    /// Skips over doc comment tokens. Returns the first one, if any.
    fn eatDocComments(p: *Parser) !?TokenIndex {
        if (p.eatToken(.doc_comment)) |tok| {
            var first_line = tok;
            if (tok > 0 and tokensOnSameLine(p, tok - 1, tok)) {
                try p.warnMsg(.{
                    .tag = .same_line_doc_comment,
                    .token = tok,
                });
                first_line = p.eatToken(.doc_comment) orelse return null;
            }
            while (p.eatToken(.doc_comment)) |_| {}
            return first_line;
        }
        return null;
    }

    fn tokensOnSameLine(p: *Parser, token1: TokenIndex, token2: TokenIndex) bool {
        return std.mem.indexOfScalar(u8, p.source[p.token_starts[token1]..p.token_starts[token2]], '\n') == null;
    }

    fn eatToken(p: *Parser, tag: Token.Tag) ?TokenIndex {
        return if (p.token_tags[p.tok_i] == tag) p.nextToken() else null;
    }

    fn assertToken(p: *Parser, tag: Token.Tag) TokenIndex {
        const token = p.nextToken();
        assert(p.token_tags[token] == tag);
        return token;
    }

    fn expectToken(p: *Parser, tag: Token.Tag) Error!TokenIndex {
        const token = p.nextToken();
        if (p.token_tags[token] != tag) {
            p.tok_i -= 1; // Go back so that we can recover properly.
            return p.failMsg(.{
                .tag = .expected_token,
                .token = token,
                .extra = .{ .expected_tag = tag },
            });
        }
        return token;
    }

    fn expectTokenRecoverable(p: *Parser, tag: Token.Tag) !?TokenIndex {
        if (p.token_tags[p.tok_i] != tag) {
            try p.warnExpected(tag);
            return null;
        } else {
            return p.nextToken();
        }
    }

    fn nextToken(p: *Parser) TokenIndex {
        const result = p.tok_i;
        p.tok_i += 1;
        return result;
    }
};

test {
    _ = @import("parser_test.zig");
}
