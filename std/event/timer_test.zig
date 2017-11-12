const std = @import("std");
const assert = std.debug.assert;
const event = @import("event.zig");

const TestContext = struct {
    value: usize
};

fn timer_handler(closure: &TestContext) -> void {
    std.debug.warn("timer fired with value {}\n", closure.value);

    closure.value += 1;
}

test "timer" {
    var closure = TestContext {
        .value = 42
    };

    comptime const one_second = 1000 * 1000 * 1000;

    var loop = %%event.Loop.init();
    var timer = %%event.Timer.init(one_second, &closure, &timer_handler);

    %%timer.start(&loop);

    var i: u64 = 0;
    while (i < 5) {
        %%loop.step(event.LoopStepBehavior.Blocking);
        i += 1;

        //if (i >= 3) {
        //    %%timer.stop(&loop);
        //}
    }
}

test "managed" {
    var closure = TestContext {
        .value = 42
    };

    var loop = %%event.Loop.init();
    var managed = %%event.ManagedEvent.init(&closure, &timer_handler);

    %%managed.register(&loop);

    %%loop.step(event.LoopStepBehavior.Nonblocking);

    assert(closure.value == 42);

    %%managed.trigger();

    %%loop.step(event.LoopStepBehavior.Nonblocking);

    assert(closure.value == 43);

    %%managed.trigger();
    %%managed.trigger();

    %%loop.step(event.LoopStepBehavior.Nonblocking);

    assert(closure.value == 44);
}
