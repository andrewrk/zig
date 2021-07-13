const expect = @import("std").testing.expect;
const expectEqual = @import("std").testing.expectEqual;

const Node = struct {
    payload: i32,
    children: []Node,
};

const NodeAligned = struct {
    payload: i32,
    children: []align(@alignOf(NodeAligned)) NodeAligned,
};

test "struct contains slice of itself" {
    var other_nodes = [_]Node{
        Node{
            .payload = 31,
            .children = &[_]Node{},
        },
        Node{
            .payload = 32,
            .children = &[_]Node{},
        },
    };
    var nodes = [_]Node{
        Node{
            .payload = 1,
            .children = &[_]Node{},
        },
        Node{
            .payload = 2,
            .children = &[_]Node{},
        },
        Node{
            .payload = 3,
            .children = other_nodes[0..],
        },
    };
    const root = Node{
        .payload = 1234,
        .children = nodes[0..],
    };
    try expectEqual(root.payload, 1234);
    try expectEqual(root.children[0].payload, 1);
    try expectEqual(root.children[1].payload, 2);
    try expectEqual(root.children[2].payload, 3);
    try expectEqual(root.children[2].children[0].payload, 31);
    try expectEqual(root.children[2].children[1].payload, 32);
}

test "struct contains aligned slice of itself" {
    var other_nodes = [_]NodeAligned{
        NodeAligned{
            .payload = 31,
            .children = &[_]NodeAligned{},
        },
        NodeAligned{
            .payload = 32,
            .children = &[_]NodeAligned{},
        },
    };
    var nodes = [_]NodeAligned{
        NodeAligned{
            .payload = 1,
            .children = &[_]NodeAligned{},
        },
        NodeAligned{
            .payload = 2,
            .children = &[_]NodeAligned{},
        },
        NodeAligned{
            .payload = 3,
            .children = other_nodes[0..],
        },
    };
    const root = NodeAligned{
        .payload = 1234,
        .children = nodes[0..],
    };
    try expectEqual(root.payload, 1234);
    try expectEqual(root.children[0].payload, 1);
    try expectEqual(root.children[1].payload, 2);
    try expectEqual(root.children[2].payload, 3);
    try expectEqual(root.children[2].children[0].payload, 31);
    try expectEqual(root.children[2].children[1].payload, 32);
}
