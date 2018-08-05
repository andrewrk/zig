const Color = enum(u1) {
    Black,
    Red,
};
const Red = Color.Red;
const Black = Color.Black;

pub const Node = struct {
    left: ?*Node,
    right: ?*Node,
    parent_and_color: usize,

    pub fn next(node: *Node) ?*Node {
        return node.right;
    }

    pub fn prev(node: *Node) ?*Node {
        return node.left;
    }

    pub fn is_root(node: *Node) bool {
        return node.get_parent() == null;
    }

    fn is_red(node: *Node) bool {
        return node.get_color() == Red;
    }

    fn is_black(node: *Node) bool {
        return node.get_color() == Black;
    }

    fn set_parent(node: *Node, parent: ?*Node) void {
        node.parent_and_color = @ptrToInt(parent) | (node.parent_and_color & 1);
    }

    fn get_parent(node: *Node) ?*Node {
        const mask: usize = 1;
        return @intToPtr(*Node, node.parent_and_color & ~mask);
    }

    fn set_color(node: *Node, color: Color) void {
        const mask: usize = 1;
        node.parent_and_color = (node.parent_and_color & ~mask) | @enumToInt(color);
    }

    fn get_color(node: *Node) Color {
        return @intToEnum(Color, @intCast(u1, node.parent_and_color & 1));
    }

    fn set_child(node: *Node, child: ?*Node, is_left: bool) void {
        if (is_left) {
            node.left = child;
        } else {
            node.right = child;
        }
    }

    fn get_first(nodeconst: *Node) *Node {
        var node = nodeconst;
        while (node.left) |left| {
            node = left;
        }
        return node;
    }

    fn get_last(node: *Node) *Node {
        while (node.right) |right| {
            node = right;
        }
        return node;
    }
};

pub const Tree = struct {
    root: ?*Node,
    compare_fn: fn(*Node, *Node) i32,

    pub fn first(tree: *Tree) ?*Node {
        var node: *Node = tree.root orelse return null;

        while (node.left) |left| {
            node = left;
        }

        return node;
    }

    pub fn last(tree: *Tree) ?*Node {
        var node: *Node = tree.root orelse return null;

        while (node.right) |right| {
            node = right;
        }

        return node;
    }

    // Duplicate keys are not allowed. The item with the same key already in the
    // tree will be returned.
    pub fn insert(tree: *Tree, node_const: *Node) ?*Node {
        var node = node_const;
        var maybe_key: ?*Node = undefined;
        var maybe_parent: ?*Node = undefined;
        var is_left: bool = undefined;

        maybe_key = do_lookup(node, tree, &maybe_parent, &is_left);
        if (maybe_key) |key| {
            return key;
        }

        node.left = null;
        node.right = null;
        node.set_color(Red);
        node.set_parent(maybe_parent);

        if (maybe_parent) |parent| {
            parent.set_child(node, is_left);
        } else {
            tree.root = node;
        }

        while (node.get_parent()) |*parent| {
            if (parent.*.is_black())
                break;
                                              // the root is always black
            var grandpa = parent.*.get_parent() orelse unreachable;

            if (parent.* == grandpa.left) {
                var maybe_uncle = grandpa.right;

                if (maybe_uncle) |*uncle| {
                    if (uncle.*.is_black())
                        break;

                    parent.*.set_color(Black);
                    uncle.*.set_color(Black);
                    grandpa.set_color(Red);
                    node = grandpa;
                } else {
                    if (node == parent.*.right) {
                        rotate_left(parent.*, tree);
                        node = parent.*;
                        parent.* = node.get_parent().?; // Just rotated
                    }
                    parent.*.set_color(Black);
                    grandpa.set_color(Red);
                    rotate_right(grandpa, tree);
                }
            } else {
                var maybe_uncle = grandpa.left;
                
                if (maybe_uncle) |*uncle| {
                    if (uncle.*.is_black())
                        break;

                    parent.*.set_color(Black);
                    uncle.*.set_color(Black);
                    grandpa.set_color(Red);
                    node = grandpa;
                } else {
                    if (node == parent.*.left) {
                        rotate_right(parent.*, tree);
                        node = parent.*;
                        parent.* = node.get_parent().?; // Just rotated
                    }
                    parent.*.set_color(Black);
                    grandpa.set_color(Red);
                    rotate_left(grandpa, tree);
                }
            }
        }
        // This was an insert, there is at least one node.
        tree.root.?.set_color(Black);
        return null;
    }

    pub fn lookup(tree: *Tree, key: *Node) ?*Node {
        var parent: *Node = undefined;
        var is_left: bool = undefined;

        return do_lookup(key, tree, &parent, &is_left);
    }

    pub fn remove(tree: *Tree, nodeconst: *Node) void {
        var node = nodeconst;
        // as this has the same value as node, it is unsafe to access node after newnode
        var newnode: ?*Node = nodeconst;
        var maybe_parent: ?*Node = node.get_parent();
        var color: Color = undefined;
        var next: *Node = undefined;

        // This clause is to avoid optionals
        if (node.left == null and node.right == null) {
            if (maybe_parent) |parent| {
                parent.set_child(null, parent.left == node);
            } else
                tree.root = null;
            color = node.get_color();
            newnode = null;
        } else {
            if (node.left == null) {
                next = node.right.?; // Not both null as per above
            } else if (node.right == null) {
                next = node.left.?;  // Not both null as per above
            } else
                next = node.right.?.get_first(); // Just checked for null above

            if (maybe_parent) |parent| {
                parent.set_child(next, parent.left == node);
            } else
                tree.root = next;

            var else_token: bool = true;
            if (node.left) |left| {
                if (node.right) |right| {
                    color = next.get_color();
                    next.set_color(node.get_color());

                    next.left = left;
                    left.set_parent(next);
                    
                    if (next != right) {
                        var parent = next.get_parent().?; // Was traversed via child node (right/left)
                        next.set_parent(node.get_parent());

                        newnode = next.right;
                        parent.left = node;
                        
                        next.right = right;
                        right.set_parent(next);
                    } else {
                        next.set_parent(maybe_parent);
                        maybe_parent = next;
                        newnode = next.right;
                    }
                }
                else_token = false;
            }
            if (else_token) {
                color = node.get_color();
                newnode = next;
            }
        }

        if (newnode) |n|
            n.set_parent(maybe_parent);

        if (color == Red)
            return;
        if (newnode) |n| {
            n.set_color(Black);
            return;
        }

        while (true) {
            if (node == tree.root)
                break;
            // If not root, there must be parent
            var parent = maybe_parent.?;
            if (node == parent.left) {
                var sibling = parent.right.?; // Same number of black nodes.
                
                if (sibling.is_red()) {
                    sibling.set_color(Black);
                    parent.set_color(Red);
                    rotate_left(parent, tree);
                }
                if ((sibling.left == null or sibling.left.?.is_black()) and
                    (sibling.right == null or sibling.right.?.is_black())) {
                    sibling.set_color(Red);
                    node = parent;
                    maybe_parent = parent.get_parent();
                    continue;
                }
                if (sibling.right == null or sibling.right.?.is_black()) {
                    sibling.left.?.set_color(Black); // Same number of black nodes.
                    sibling.set_color(Red);
                    rotate_right(sibling, tree);
                    sibling = parent.right.?; // Just rotated
                }
                sibling.set_color(parent.get_color());
                parent.set_color(Black);
                sibling.right.?.set_color(Black); // Same number of black nodes.
                rotate_left(parent, tree);
                newnode = tree.root;
                break;
            } else {
                var sibling = parent.left.?; // Same number of black nodes.
                
                if (sibling.is_red()) {
                    sibling.set_color(Black);
                    parent.set_color(Red);
                    rotate_right(parent, tree);
                    sibling = parent.left.?; // Just rotated
                }
                if ((sibling.left == null or sibling.left.?.is_black()) and
                    (sibling.right == null or sibling.right.?.is_black())) {
                    sibling.set_color(Red);
                    node = parent;
                    maybe_parent = parent.get_parent();
                    continue;
                }
                if (sibling.left == null or sibling.left.?.is_black()) {
                    sibling.right.?.set_color(Black); // Same number of black nodes
                    sibling.set_color(Red);
                    rotate_left(sibling, tree);
                    sibling = parent.left.?; // Just rotated
                }
                sibling.set_color(parent.get_color());
                parent.set_color(Black);
                sibling.left.?.set_color(Black); // Same number of black nodes
                rotate_right(parent, tree);
                newnode = tree.root;
                break;
            }

            if (node.is_black())
                break;
        }

        if (newnode) |n|
            n.set_color(Black);
    }

    // This is a shortcut to avoid removing and re-inserting an item with the same key.
    // Tree.compare_fn(old, new) MUST return 0
    pub fn replace(tree: *Tree, oldconst: *Node, newconst: *Node) void {
        var old = oldconst;
        var new = newconst;

        if (old.get_parent()) |parent| {
            parent.set_child(new, parent.left == old);
        } else
            tree.root = new;

        if (old.left) |left|
            left.set_parent(new);
        if (old.right) |right|
            right.set_parent(new);

        new.* = old.*;
    }

    pub fn init(tree: *Tree, f: Tree.compare_fn) void {
        tree.root = null;
        tree.compare_fn = f;
    }
};

fn rotate_left(node: *Node, tree: *Tree) void {
    var p: *Node = node;
    var q: *Node = node.right orelse unreachable;
    var parent: *Node = undefined;

    if (!p.is_root()) {
        parent = node.get_parent() orelse unreachable;
        if (parent.left == p) {
            parent.left = q;
        } else {
            parent.right = q;
        }
        q.set_parent(parent);
    } else {
        tree.root = q;
        q.set_parent(null);
    }
    p.set_parent(q);

    p.right = q.left;
    if (p.right) |right| {
        right.set_parent(p);
    }
    q.left = p;
}

fn rotate_right(node: *Node, tree: *Tree) void {
    var p: *Node = node;
    var q: *Node = node.left orelse unreachable;
    var parent: *Node = undefined;

    if (!p.is_root()) {
        parent = p.get_parent().?;
        if (parent.left == p) {
            parent.left = q;
        } else {
            parent.right = q;
        }
        q.set_parent(parent);
    } else {
        tree.root = q;
        q.set_parent(null);
    }
    p.set_parent(q);

    p.right = q.left;
    if (p.left) |left| {
        left.set_parent(p);
    }
    q.right = p;
}

fn do_lookup(key: *Node, tree: *Tree, pparentconst: *?*Node, is_left: *bool) ?*Node {
    var pparent = pparentconst;
    var maybe_node: ?*Node = tree.root;

    pparent.* = null;
    is_left.* = false;
    
    while (maybe_node) |node| {
        var res: i32 = tree.compare_fn(node, key);
        if (res == 0) {
            return node;
        }
        pparent.* = node;
        is_left.* = (res < 0);
        if (is_left.*) {
            maybe_node = node.left;
        } else {
            maybe_node = node.right;
        }
    }
    return null;
}

const testNumber = struct {
    node: Node,
    value: i32,
};

fn testCompare(l: *Node, r: *Node) i32 {
    var left = @fieldParentPtr(testNumber, "node", l);
    var right = @fieldParentPtr(testNumber, "node", r);

    if (left.value < right.value) {
        return -1;
    } else if (left.value == right.value) {
        return 0;
    } else if (left.value > right.value) {
        return 1;
    }
    unreachable;
}

test "populate, remove, and replace, depulicate keys" {
    const assert = @import("std").debug.assert;

    var tree: Tree = undefined;
    var ns: [10]testNumber = undefined;
    ns[0].value = 42;
    ns[1].value = 41;
    ns[2].value = 40;
    ns[3].value = 39;
    ns[4].value = 38;
    ns[5].value = 39;
    ns[6].value = 3453;
    ns[7].value = 32345;
    ns[8].value = 392345;
    ns[9].value = 4;

    var dup: testNumber = undefined;
    dup.value = 32345;

    tree.compare_fn = testCompare;
    _ = tree.insert(&ns[0].node);
    _ = tree.insert(&ns[1].node);
    _ = tree.insert(&ns[2].node);
    _ = tree.insert(&ns[3].node);
    _ = tree.insert(&ns[4].node);
    _ = tree.insert(&ns[6].node);
    _ = tree.insert(&ns[7].node);
    _ = tree.insert(&ns[8].node);
    tree.remove(&ns[3].node);
    tree.remove(&ns[8].node);
    tree.replace(&ns[3].node, &ns[5].node);
    assert(tree.insert(&dup.node) == &ns[7].node);

    var num: *testNumber = undefined;
    num = @fieldParentPtr(testNumber, "node", tree.first().?);
    while (num.node.next() != null) {
        assert(@fieldParentPtr(testNumber, "node", num.node.next().?).value < num.value);
        num = @fieldParentPtr(testNumber, "node", num.node.next().?);
    }
}
