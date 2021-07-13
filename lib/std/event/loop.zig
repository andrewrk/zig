// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("../std.zig");
const builtin = std.builtin;
const root = @import("root");
const assert = std.debug.assert;
const testing = std.testing;
const mem = std.mem;
const os = std.os;
const windows = os.windows;
const maxInt = std.math.maxInt;
const Thread = std.Thread;

const is_windows = std.Target.current.os.tag == .windows;

pub const Loop = struct {
    next_tick_queue: std.atomic.Queue(anyframe),
    os_data: OsData,
    final_resume_node: ResumeNode,
    pending_event_count: usize,
    extra_threads: []Thread,
    /// TODO change this to a pool of configurable number of threads
    /// and rename it to be not file-system-specific. it will become
    /// a thread pool for turning non-CPU-bound blocking things into
    /// async things. A fallback for any missing OS-specific API.
    fs_thread: Thread,
    fs_queue: std.atomic.Queue(Request),
    fs_end_request: Request.Node,
    fs_thread_wakeup: std.Thread.Semaphore,

    /// For resources that have the same lifetime as the `Loop`.
    /// This is only used by `Loop` for the thread pool and associated resources.
    arena: std.heap.ArenaAllocator,

    /// State which manages frames that are sleeping on timers
    delay_queue: DelayQueue,

    /// Pre-allocated eventfds. All permanently active.
    /// This is how `Loop` sends promises to be resumed on other threads.
    available_eventfd_resume_nodes: std.atomic.Stack(ResumeNode.EventFd),
    eventfd_resume_nodes: []std.atomic.Stack(ResumeNode.EventFd).Node,

    pub const NextTickNode = std.atomic.Queue(anyframe).Node;

    pub const ResumeNode = struct {
        id: Id,
        handle: anyframe,
        overlapped: Overlapped,

        pub const overlapped_init = switch (builtin.os.tag) {
            .windows => windows.OVERLAPPED{
                .Internal = 0,
                .InternalHigh = 0,
                .DUMMYUNIONNAME = .{
                    .DUMMYSTRUCTNAME = .{
                        .Offset = 0,
                        .OffsetHigh = 0,
                    },
                },
                .hEvent = null,
            },
            else => {},
        };
        pub const Overlapped = @TypeOf(overlapped_init);

        pub const Id = enum {
            Basic,
            Stop,
            EventFd,
        };

        pub const EventFd = switch (builtin.os.tag) {
            .macos, .freebsd, .netbsd, .dragonfly, .openbsd => KEventFd,
            .linux => struct {
                base: ResumeNode,
                epoll_op: u32,
                eventfd: i32,
            },
            .windows => struct {
                base: ResumeNode,
                completion_key: usize,
            },
            else => struct {},
        };

        const KEventFd = struct {
            base: ResumeNode,
            kevent: os.Kevent,
        };

        pub const Basic = switch (builtin.os.tag) {
            .macos, .freebsd, .netbsd, .dragonfly, .openbsd => KEventBasic,
            .linux => struct {
                base: ResumeNode,
            },
            .windows => struct {
                base: ResumeNode,
            },
            else => @compileError("unsupported OS"),
        };

        const KEventBasic = struct {
            base: ResumeNode,
            kev: os.Kevent,
        };
    };

    var global_instance_state: Loop = undefined;
    const default_instance: ?*Loop = switch (std.io.mode) {
        .blocking => null,
        .evented => &global_instance_state,
    };
    pub const instance: ?*Loop = if (@hasDecl(root, "event_loop")) root.event_loop else default_instance;

    /// TODO copy elision / named return values so that the threads referencing *Loop
    /// have the correct pointer value.
    /// https://github.com/ziglang/zig/issues/2761 and https://github.com/ziglang/zig/issues/2765
    pub fn init(self: *Loop) !void {
        if (builtin.single_threaded or
            (@hasDecl(root, "event_loop_mode") and root.event_loop_mode == .single_threaded))
        {
            return self.initSingleThreaded();
        } else {
            return self.initMultiThreaded();
        }
    }

    /// After initialization, call run().
    /// TODO copy elision / named return values so that the threads referencing *Loop
    /// have the correct pointer value.
    /// https://github.com/ziglang/zig/issues/2761 and https://github.com/ziglang/zig/issues/2765
    pub fn initSingleThreaded(self: *Loop) !void {
        return self.initThreadPool(1);
    }

    /// After initialization, call run().
    /// This is the same as `initThreadPool` using `Thread.getCpuCount` to determine the thread
    /// pool size.
    /// TODO copy elision / named return values so that the threads referencing *Loop
    /// have the correct pointer value.
    /// https://github.com/ziglang/zig/issues/2761 and https://github.com/ziglang/zig/issues/2765
    pub fn initMultiThreaded(self: *Loop) !void {
        if (builtin.single_threaded)
            @compileError("initMultiThreaded unavailable when building in single-threaded mode");
        const core_count = try Thread.getCpuCount();
        return self.initThreadPool(core_count);
    }

    /// Thread count is the total thread count. The thread pool size will be
    /// max(thread_count - 1, 0)
    pub fn initThreadPool(self: *Loop, thread_count: usize) !void {
        self.* = Loop{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .pending_event_count = 1,
            .os_data = undefined,
            .next_tick_queue = std.atomic.Queue(anyframe).init(),
            .extra_threads = undefined,
            .available_eventfd_resume_nodes = std.atomic.Stack(ResumeNode.EventFd).init(),
            .eventfd_resume_nodes = undefined,
            .final_resume_node = ResumeNode{
                .id = ResumeNode.Id.Stop,
                .handle = undefined,
                .overlapped = ResumeNode.overlapped_init,
            },
            .fs_end_request = .{ .data = .{ .msg = .end, .finish = .NoAction } },
            .fs_queue = std.atomic.Queue(Request).init(),
            .fs_thread = undefined,
            .fs_thread_wakeup = .{},
            .delay_queue = undefined,
        };
        errdefer self.arena.deinit();

        // We need at least one of these in case the fs thread wants to use onNextTick
        const extra_thread_count = thread_count - 1;
        const resume_node_count = std.math.max(extra_thread_count, 1);
        self.eventfd_resume_nodes = try self.arena.allocator.alloc(
            std.atomic.Stack(ResumeNode.EventFd).Node,
            resume_node_count,
        );

        self.extra_threads = try self.arena.allocator.alloc(Thread, extra_thread_count);

        try self.initOsData(extra_thread_count);
        errdefer self.deinitOsData();

        if (!builtin.single_threaded) {
            self.fs_thread = try Thread.spawn(.{}, posixFsRun, .{self});
        }
        errdefer if (!builtin.single_threaded) {
            self.posixFsRequest(&self.fs_end_request);
            self.fs_thread.join();
        };

        if (!std.builtin.single_threaded)
            try self.delay_queue.init();
    }

    pub fn deinit(self: *Loop) void {
        self.deinitOsData();
        self.arena.deinit();
        self.* = undefined;
    }

    const InitOsDataError = os.EpollCreateError || mem.Allocator.Error || os.EventFdError ||
        Thread.SpawnError || os.EpollCtlError || os.KEventError ||
        windows.CreateIoCompletionPortError;

    const wakeup_bytes = [_]u8{0x1} ** 8;

    fn initOsData(self: *Loop, extra_thread_count: usize) InitOsDataError!void {
        nosuspend switch (builtin.os.tag) {
            .linux => {
                errdefer {
                    while (self.available_eventfd_resume_nodes.pop()) |node| os.close(node.data.eventfd);
                }
                for (self.eventfd_resume_nodes) |*eventfd_node| {
                    eventfd_node.* = std.atomic.Stack(ResumeNode.EventFd).Node{
                        .data = ResumeNode.EventFd{
                            .base = ResumeNode{
                                .id = .EventFd,
                                .handle = undefined,
                                .overlapped = ResumeNode.overlapped_init,
                            },
                            .eventfd = try os.eventfd(1, os.EFD_CLOEXEC | os.EFD_NONBLOCK),
                            .epoll_op = os.EPOLL_CTL_ADD,
                        },
                        .next = undefined,
                    };
                    self.available_eventfd_resume_nodes.push(eventfd_node);
                }

                self.os_data.epollfd = try os.epoll_create1(os.EPOLL_CLOEXEC);
                errdefer os.close(self.os_data.epollfd);

                self.os_data.final_eventfd = try os.eventfd(0, os.EFD_CLOEXEC | os.EFD_NONBLOCK);
                errdefer os.close(self.os_data.final_eventfd);

                self.os_data.final_eventfd_event = os.epoll_event{
                    .events = os.EPOLLIN,
                    .data = os.epoll_data{ .ptr = @ptrToInt(&self.final_resume_node) },
                };
                try os.epoll_ctl(
                    self.os_data.epollfd,
                    os.EPOLL_CTL_ADD,
                    self.os_data.final_eventfd,
                    &self.os_data.final_eventfd_event,
                );

                if (builtin.single_threaded) {
                    assert(extra_thread_count == 0);
                    return;
                }

                var extra_thread_index: usize = 0;
                errdefer {
                    // writing 8 bytes to an eventfd cannot fail
                    const amt = os.write(self.os_data.final_eventfd, &wakeup_bytes) catch unreachable;
                    assert(amt == wakeup_bytes.len);
                    while (extra_thread_index != 0) {
                        extra_thread_index -= 1;
                        self.extra_threads[extra_thread_index].join();
                    }
                }
                while (extra_thread_index < extra_thread_count) : (extra_thread_index += 1) {
                    self.extra_threads[extra_thread_index] = try Thread.spawn(.{}, workerRun, .{self});
                }
            },
            .macos, .freebsd, .netbsd, .dragonfly, .openbsd => {
                self.os_data.kqfd = try os.kqueue();
                errdefer os.close(self.os_data.kqfd);

                const empty_kevs = &[0]os.Kevent{};

                for (self.eventfd_resume_nodes) |*eventfd_node, i| {
                    eventfd_node.* = std.atomic.Stack(ResumeNode.EventFd).Node{
                        .data = ResumeNode.EventFd{
                            .base = ResumeNode{
                                .id = ResumeNode.Id.EventFd,
                                .handle = undefined,
                                .overlapped = ResumeNode.overlapped_init,
                            },
                            // this one is for sending events
                            .kevent = os.Kevent{
                                .ident = i,
                                .filter = os.EVFILT_USER,
                                .flags = os.EV_CLEAR | os.EV_ADD | os.EV_DISABLE,
                                .fflags = 0,
                                .data = 0,
                                .udata = @ptrToInt(&eventfd_node.data.base),
                            },
                        },
                        .next = undefined,
                    };
                    self.available_eventfd_resume_nodes.push(eventfd_node);
                    const kevent_array = @as(*const [1]os.Kevent, &eventfd_node.data.kevent);
                    _ = try os.kevent(self.os_data.kqfd, kevent_array, empty_kevs, null);
                    eventfd_node.data.kevent.flags = os.EV_CLEAR | os.EV_ENABLE;
                    eventfd_node.data.kevent.fflags = os.NOTE_TRIGGER;
                }

                // Pre-add so that we cannot get error.SystemResources
                // later when we try to activate it.
                self.os_data.final_kevent = os.Kevent{
                    .ident = extra_thread_count,
                    .filter = os.EVFILT_USER,
                    .flags = os.EV_ADD | os.EV_DISABLE,
                    .fflags = 0,
                    .data = 0,
                    .udata = @ptrToInt(&self.final_resume_node),
                };
                const final_kev_arr = @as(*const [1]os.Kevent, &self.os_data.final_kevent);
                _ = try os.kevent(self.os_data.kqfd, final_kev_arr, empty_kevs, null);
                self.os_data.final_kevent.flags = os.EV_ENABLE;
                self.os_data.final_kevent.fflags = os.NOTE_TRIGGER;

                if (builtin.single_threaded) {
                    assert(extra_thread_count == 0);
                    return;
                }

                var extra_thread_index: usize = 0;
                errdefer {
                    _ = os.kevent(self.os_data.kqfd, final_kev_arr, empty_kevs, null) catch unreachable;
                    while (extra_thread_index != 0) {
                        extra_thread_index -= 1;
                        self.extra_threads[extra_thread_index].join();
                    }
                }
                while (extra_thread_index < extra_thread_count) : (extra_thread_index += 1) {
                    self.extra_threads[extra_thread_index] = try Thread.spawn(.{}, workerRun, .{self});
                }
            },
            .windows => {
                self.os_data.io_port = try windows.CreateIoCompletionPort(
                    windows.INVALID_HANDLE_VALUE,
                    null,
                    undefined,
                    maxInt(windows.DWORD),
                );
                errdefer windows.CloseHandle(self.os_data.io_port);

                for (self.eventfd_resume_nodes) |*eventfd_node| {
                    eventfd_node.* = std.atomic.Stack(ResumeNode.EventFd).Node{
                        .data = ResumeNode.EventFd{
                            .base = ResumeNode{
                                .id = ResumeNode.Id.EventFd,
                                .handle = undefined,
                                .overlapped = ResumeNode.overlapped_init,
                            },
                            // this one is for sending events
                            .completion_key = @ptrToInt(&eventfd_node.data.base),
                        },
                        .next = undefined,
                    };
                    self.available_eventfd_resume_nodes.push(eventfd_node);
                }

                if (builtin.single_threaded) {
                    assert(extra_thread_count == 0);
                    return;
                }

                var extra_thread_index: usize = 0;
                errdefer {
                    var i: usize = 0;
                    while (i < extra_thread_index) : (i += 1) {
                        while (true) {
                            const overlapped = &self.final_resume_node.overlapped;
                            windows.PostQueuedCompletionStatus(self.os_data.io_port, undefined, undefined, overlapped) catch continue;
                            break;
                        }
                    }
                    while (extra_thread_index != 0) {
                        extra_thread_index -= 1;
                        self.extra_threads[extra_thread_index].join();
                    }
                }
                while (extra_thread_index < extra_thread_count) : (extra_thread_index += 1) {
                    self.extra_threads[extra_thread_index] = try Thread.spawn(.{}, workerRun, .{self});
                }
            },
            else => {},
        };
    }

    fn deinitOsData(self: *Loop) void {
        nosuspend switch (builtin.os.tag) {
            .linux => {
                os.close(self.os_data.final_eventfd);
                while (self.available_eventfd_resume_nodes.pop()) |node| os.close(node.data.eventfd);
                os.close(self.os_data.epollfd);
            },
            .macos, .freebsd, .netbsd, .dragonfly, .openbsd => {
                os.close(self.os_data.kqfd);
            },
            .windows => {
                windows.CloseHandle(self.os_data.io_port);
            },
            else => {},
        };
    }

    /// resume_node must live longer than the anyframe that it holds a reference to.
    /// flags must contain EPOLLET
    pub fn linuxAddFd(self: *Loop, fd: i32, resume_node: *ResumeNode, flags: u32) !void {
        assert(flags & os.EPOLLET == os.EPOLLET);
        self.beginOneEvent();
        errdefer self.finishOneEvent();
        try self.linuxModFd(
            fd,
            os.EPOLL_CTL_ADD,
            flags,
            resume_node,
        );
    }

    pub fn linuxModFd(self: *Loop, fd: i32, op: u32, flags: u32, resume_node: *ResumeNode) !void {
        assert(flags & os.EPOLLET == os.EPOLLET);
        var ev = os.linux.epoll_event{
            .events = flags,
            .data = os.linux.epoll_data{ .ptr = @ptrToInt(resume_node) },
        };
        try os.epoll_ctl(self.os_data.epollfd, op, fd, &ev);
    }

    pub fn linuxRemoveFd(self: *Loop, fd: i32) void {
        os.epoll_ctl(self.os_data.epollfd, os.linux.EPOLL_CTL_DEL, fd, null) catch {};
        self.finishOneEvent();
    }

    pub fn linuxWaitFd(self: *Loop, fd: i32, flags: u32) void {
        assert(flags & os.EPOLLET == os.EPOLLET);
        assert(flags & os.EPOLLONESHOT == os.EPOLLONESHOT);
        var resume_node = ResumeNode.Basic{
            .base = ResumeNode{
                .id = .Basic,
                .handle = @frame(),
                .overlapped = ResumeNode.overlapped_init,
            },
        };
        var need_to_delete = true;
        defer if (need_to_delete) self.linuxRemoveFd(fd);

        suspend {
            self.linuxAddFd(fd, &resume_node.base, flags) catch |err| switch (err) {
                error.FileDescriptorNotRegistered => unreachable,
                error.OperationCausesCircularLoop => unreachable,
                error.FileDescriptorIncompatibleWithEpoll => unreachable,
                error.FileDescriptorAlreadyPresentInSet => unreachable, // evented writes to the same fd is not thread-safe

                error.SystemResources,
                error.UserResourceLimitReached,
                error.Unexpected,
                => {
                    need_to_delete = false;
                    // Fall back to a blocking poll(). Ideally this codepath is never hit, since
                    // epoll should be just fine. But this is better than incorrect behavior.
                    var poll_flags: i16 = 0;
                    if ((flags & os.EPOLLIN) != 0) poll_flags |= os.POLLIN;
                    if ((flags & os.EPOLLOUT) != 0) poll_flags |= os.POLLOUT;
                    var pfd = [1]os.pollfd{os.pollfd{
                        .fd = fd,
                        .events = poll_flags,
                        .revents = undefined,
                    }};
                    _ = os.poll(&pfd, -1) catch |poll_err| switch (poll_err) {
                        error.NetworkSubsystemFailed => unreachable, // only possible on windows

                        error.SystemResources,
                        error.Unexpected,
                        => {
                            // Even poll() didn't work. The best we can do now is sleep for a
                            // small duration and then hope that something changed.
                            std.time.sleep(1 * std.time.ns_per_ms);
                        },
                    };
                    resume @frame();
                },
            };
        }
    }

    pub fn waitUntilFdReadable(self: *Loop, fd: os.fd_t) void {
        switch (builtin.os.tag) {
            .linux => {
                self.linuxWaitFd(fd, os.EPOLLET | os.EPOLLONESHOT | os.EPOLLIN);
            },
            .macos, .freebsd, .netbsd, .dragonfly, .openbsd => {
                self.bsdWaitKev(@intCast(usize, fd), os.EVFILT_READ, os.EV_ONESHOT);
            },
            else => @compileError("Unsupported OS"),
        }
    }

    pub fn waitUntilFdWritable(self: *Loop, fd: os.fd_t) void {
        switch (builtin.os.tag) {
            .linux => {
                self.linuxWaitFd(fd, os.EPOLLET | os.EPOLLONESHOT | os.EPOLLOUT);
            },
            .macos, .freebsd, .netbsd, .dragonfly, .openbsd => {
                self.bsdWaitKev(@intCast(usize, fd), os.EVFILT_WRITE, os.EV_ONESHOT);
            },
            else => @compileError("Unsupported OS"),
        }
    }

    pub fn waitUntilFdWritableOrReadable(self: *Loop, fd: os.fd_t) void {
        switch (builtin.os.tag) {
            .linux => {
                self.linuxWaitFd(fd, os.EPOLLET | os.EPOLLONESHOT | os.EPOLLOUT | os.EPOLLIN);
            },
            .macos, .freebsd, .netbsd, .dragonfly, .openbsd => {
                self.bsdWaitKev(@intCast(usize, fd), os.EVFILT_READ, os.EV_ONESHOT);
                self.bsdWaitKev(@intCast(usize, fd), os.EVFILT_WRITE, os.EV_ONESHOT);
            },
            else => @compileError("Unsupported OS"),
        }
    }

    pub fn bsdWaitKev(self: *Loop, ident: usize, filter: i16, flags: u16) void {
        var resume_node = ResumeNode.Basic{
            .base = ResumeNode{
                .id = ResumeNode.Id.Basic,
                .handle = @frame(),
                .overlapped = ResumeNode.overlapped_init,
            },
            .kev = undefined,
        };

        defer {
            // If the kevent was set to be ONESHOT, it doesn't need to be deleted manually.
            if (flags & os.EV_ONESHOT != 0) {
                self.bsdRemoveKev(ident, filter);
            }
        }

        suspend {
            self.bsdAddKev(&resume_node, ident, filter, flags) catch unreachable;
        }
    }

    /// resume_node must live longer than the anyframe that it holds a reference to.
    pub fn bsdAddKev(self: *Loop, resume_node: *ResumeNode.Basic, ident: usize, filter: i16, flags: u16) !void {
        self.beginOneEvent();
        errdefer self.finishOneEvent();
        var kev = [1]os.Kevent{os.Kevent{
            .ident = ident,
            .filter = filter,
            .flags = os.EV_ADD | os.EV_ENABLE | os.EV_CLEAR | flags,
            .fflags = 0,
            .data = 0,
            .udata = @ptrToInt(&resume_node.base),
        }};
        const empty_kevs = &[0]os.Kevent{};
        _ = try os.kevent(self.os_data.kqfd, &kev, empty_kevs, null);
    }

    pub fn bsdRemoveKev(self: *Loop, ident: usize, filter: i16) void {
        var kev = [1]os.Kevent{os.Kevent{
            .ident = ident,
            .filter = filter,
            .flags = os.EV_DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        const empty_kevs = &[0]os.Kevent{};
        _ = os.kevent(self.os_data.kqfd, &kev, empty_kevs, null) catch undefined;
        self.finishOneEvent();
    }

    fn dispatch(self: *Loop) void {
        while (self.available_eventfd_resume_nodes.pop()) |resume_stack_node| {
            const next_tick_node = self.next_tick_queue.get() orelse {
                self.available_eventfd_resume_nodes.push(resume_stack_node);
                return;
            };
            const eventfd_node = &resume_stack_node.data;
            eventfd_node.base.handle = next_tick_node.data;
            switch (builtin.os.tag) {
                .macos, .freebsd, .netbsd, .dragonfly, .openbsd => {
                    const kevent_array = @as(*const [1]os.Kevent, &eventfd_node.kevent);
                    const empty_kevs = &[0]os.Kevent{};
                    _ = os.kevent(self.os_data.kqfd, kevent_array, empty_kevs, null) catch {
                        self.next_tick_queue.unget(next_tick_node);
                        self.available_eventfd_resume_nodes.push(resume_stack_node);
                        return;
                    };
                },
                .linux => {
                    // the pending count is already accounted for
                    const epoll_events = os.EPOLLONESHOT | os.linux.EPOLLIN | os.linux.EPOLLOUT |
                        os.linux.EPOLLET;
                    self.linuxModFd(
                        eventfd_node.eventfd,
                        eventfd_node.epoll_op,
                        epoll_events,
                        &eventfd_node.base,
                    ) catch {
                        self.next_tick_queue.unget(next_tick_node);
                        self.available_eventfd_resume_nodes.push(resume_stack_node);
                        return;
                    };
                },
                .windows => {
                    windows.PostQueuedCompletionStatus(
                        self.os_data.io_port,
                        undefined,
                        undefined,
                        &eventfd_node.base.overlapped,
                    ) catch {
                        self.next_tick_queue.unget(next_tick_node);
                        self.available_eventfd_resume_nodes.push(resume_stack_node);
                        return;
                    };
                },
                else => @compileError("unsupported OS"),
            }
        }
    }

    /// Bring your own linked list node. This means it can't fail.
    pub fn onNextTick(self: *Loop, node: *NextTickNode) void {
        self.beginOneEvent(); // finished in dispatch()
        self.next_tick_queue.put(node);
        self.dispatch();
    }

    pub fn cancelOnNextTick(self: *Loop, node: *NextTickNode) void {
        if (self.next_tick_queue.remove(node)) {
            self.finishOneEvent();
        }
    }

    pub fn run(self: *Loop) void {
        self.finishOneEvent(); // the reference we start with

        self.workerRun();

        if (!builtin.single_threaded) {
            switch (builtin.os.tag) {
                .linux,
                .macos,
                .freebsd,
                .netbsd,
                .dragonfly,
                .openbsd,
                => self.fs_thread.join(),
                else => {},
            }
        }

        for (self.extra_threads) |extra_thread| {
            extra_thread.join();
        }

        self.delay_queue.deinit();
    }

    /// Runs the provided function asynchronously. The function's frame is allocated
    /// with `allocator` and freed when the function returns.
    /// `func` must return void and it can be an async function.
    /// Yields to the event loop, running the function on the next tick.
    pub fn runDetached(self: *Loop, alloc: *mem.Allocator, comptime func: anytype, args: anytype) error{OutOfMemory}!void {
        if (!std.io.is_async) @compileError("Can't use runDetached in non-async mode!");
        if (@TypeOf(@call(.{}, func, args)) != void) {
            @compileError("`func` must not have a return value");
        }

        const Wrapper = struct {
            const Args = @TypeOf(args);
            fn run(func_args: Args, loop: *Loop, allocator: *mem.Allocator) void {
                loop.beginOneEvent();
                loop.yield();
                @call(.{}, func, func_args); // compile error when called with non-void ret type
                suspend {
                    loop.finishOneEvent();
                    allocator.destroy(@frame());
                }
            }
        };

        var run_frame = try alloc.create(@Frame(Wrapper.run));
        run_frame.* = async Wrapper.run(args, self, alloc);
    }

    /// Yielding lets the event loop run, starting any unstarted async operations.
    /// Note that async operations automatically start when a function yields for any other reason,
    /// for example, when async I/O is performed. This function is intended to be used only when
    /// CPU bound tasks would be waiting in the event loop but never get started because no async I/O
    /// is performed.
    pub fn yield(self: *Loop) void {
        suspend {
            var my_tick_node = NextTickNode{
                .prev = undefined,
                .next = undefined,
                .data = @frame(),
            };
            self.onNextTick(&my_tick_node);
        }
    }

    /// If the build is multi-threaded and there is an event loop, then it calls `yield`. Otherwise,
    /// does nothing.
    pub fn startCpuBoundOperation() void {
        if (builtin.single_threaded) {
            return;
        } else if (instance) |event_loop| {
            event_loop.yield();
        }
    }

    /// call finishOneEvent when done
    pub fn beginOneEvent(self: *Loop) void {
        _ = @atomicRmw(usize, &self.pending_event_count, .Add, 1, .SeqCst);
    }

    pub fn finishOneEvent(self: *Loop) void {
        nosuspend {
            const prev = @atomicRmw(usize, &self.pending_event_count, .Sub, 1, .SeqCst);
            if (prev != 1) return;

            // cause all the threads to stop
            self.posixFsRequest(&self.fs_end_request);

            switch (builtin.os.tag) {
                .linux => {
                    // writing to the eventfd will only wake up one thread, thus multiple writes
                    // are needed to wakeup all the threads
                    var i: usize = 0;
                    while (i < self.extra_threads.len + 1) : (i += 1) {
                        // writing 8 bytes to an eventfd cannot fail
                        const amt = os.write(self.os_data.final_eventfd, &wakeup_bytes) catch unreachable;
                        assert(amt == wakeup_bytes.len);
                    }
                    return;
                },
                .macos, .freebsd, .netbsd, .dragonfly, .openbsd => {
                    const final_kevent = @as(*const [1]os.Kevent, &self.os_data.final_kevent);
                    const empty_kevs = &[0]os.Kevent{};
                    // cannot fail because we already added it and this just enables it
                    _ = os.kevent(self.os_data.kqfd, final_kevent, empty_kevs, null) catch unreachable;
                    return;
                },
                .windows => {
                    var i: usize = 0;
                    while (i < self.extra_threads.len + 1) : (i += 1) {
                        while (true) {
                            const overlapped = &self.final_resume_node.overlapped;
                            windows.PostQueuedCompletionStatus(self.os_data.io_port, undefined, undefined, overlapped) catch continue;
                            break;
                        }
                    }
                    return;
                },
                else => @compileError("unsupported OS"),
            }
        }
    }

    pub fn sleep(self: *Loop, nanoseconds: u64) void {
        if (std.builtin.single_threaded)
            @compileError("TODO: integrate timers with epoll/kevent/iocp for single-threaded");

        suspend {
            const now = self.delay_queue.timer.read();

            var entry: DelayQueue.Waiters.Entry = undefined;
            entry.init(@frame(), now + nanoseconds);
            self.delay_queue.waiters.insert(&entry);

            // Speculatively wake up the timer thread when we add a new entry.
            // If the timer thread is sleeping on a longer entry, we need to
            // interrupt it so that our entry can be expired in time.
            self.delay_queue.event.set();
        }
    }

    const DelayQueue = struct {
        mutex: std.Thread.Mutex,
        cond: std.Thread.Condvar,
        waiters: Waiters,
        thread: std.Thread,
        is_running: bool,

        /// Initialize the delay queue by spawning the timer thread
        /// and starting any timer resources.
        fn init(self: *DelayQueue) !void {
            self.* = DelayQueue{
                .mutex = .{},
                .cond = .{},
                .waiters = .{ .entries = std.atomic.Queue(anyframe).init() },
                .is_running = true,
                // Must be last so that it can read the other state, such as `is_running`.
                .thread = try std.Thread.spawn(.{}, DelayQueue.run, .{self}),
            };
        }

        fn deinit(self: *DelayQueue) void {
            const held = self.mutex.acquire();
            defer held.release();

            self.is_running = false;
            self.cond.broadcast();
        }

        /// Entry point for the timer thread
        /// which waits for timer entries to expire and reschedules them.
        fn run(self: *DelayQueue) void {
            while (true) {
                const entry = blk: {
                    var held = self.mutex.acquire();
                    defer held.release();

                    while (self.is_running) {
                        const now = std.time.now();
                        break :blk self.waiters.popExpired(now) orelse {
                            if (self.waiters.nextExpire()) |expires| {
                                self.cond.timedWait(&held, expires - now) catch {};
                            } else {
                                self.cond.wait(&held);
                            }
                            continue;
                        };
                    }
                };

                const loop = @fieldParentPtr(Loop, "delay_queue", self);
                loop.onNextTick(&entry.node);
            }
        }

        // TODO: use a tickless heirarchical timer wheel:
        // https://github.com/wahern/timeout/
        const Waiters = struct {
            entries: std.atomic.Queue(anyframe),

            const Entry = struct {
                node: NextTickNode,
                expires: u64,

                fn init(self: *Entry, frame: anyframe, expires: u64) void {
                    self.node.data = frame;
                    self.expires = expires;
                }
            };

            /// Registers the entry into the queue of waiting frames
            fn insert(self: *Waiters, entry: *Entry) void {
                self.entries.put(&entry.node);
            }

            /// Dequeues one expired event relative to `now`
            fn popExpired(self: *Waiters, now: u64) ?*Entry {
                const entry = self.peekExpiringEntry() orelse return null;
                if (entry.expires > now)
                    return null;

                assert(self.entries.remove(&entry.node));
                return entry;
            }

            /// Returns an estimate for the amount of time
            /// to wait until the next waiting entry expires.
            fn nextExpire(self: *Waiters) ?u64 {
                const entry = self.peekExpiringEntry() orelse return null;
                return entry.expires;
            }

            fn peekExpiringEntry(self: *Waiters) ?*Entry {
                const held = self.entries.mutex.acquire();
                defer held.release();

                // starting from the head
                var head = self.entries.head orelse return null;

                // traverse the list of waiting entires to
                // find the Node with the smallest `expires` field
                var min = head;
                while (head.next) |node| {
                    const minEntry = @fieldParentPtr(Entry, "node", min);
                    const nodeEntry = @fieldParentPtr(Entry, "node", node);
                    if (nodeEntry.expires < minEntry.expires)
                        min = node;
                    head = node;
                }

                return @fieldParentPtr(Entry, "node", min);
            }
        };
    };

    /// ------- I/0 APIs -------
    pub fn accept(
        self: *Loop,
        /// This argument is a socket that has been created with `socket`, bound to a local address
        /// with `bind`, and is listening for connections after a `listen`.
        sockfd: os.socket_t,
        /// This argument is a pointer to a sockaddr structure.  This structure is filled in with  the
        /// address  of  the  peer  socket, as known to the communications layer.  The exact format of the
        /// address returned addr is determined by the socket's address  family  (see  `socket`  and  the
        /// respective  protocol  man  pages).
        addr: *os.sockaddr,
        /// This argument is a value-result argument: the caller must initialize it to contain  the
        /// size (in bytes) of the structure pointed to by addr; on return it will contain the actual size
        /// of the peer address.
        ///
        /// The returned address is truncated if the buffer provided is too small; in this  case,  `addr_size`
        /// will return a value greater than was supplied to the call.
        addr_size: *os.socklen_t,
        /// The following values can be bitwise ORed in flags to obtain different behavior:
        /// * `SOCK_CLOEXEC`  - Set the close-on-exec (`FD_CLOEXEC`) flag on the new file descriptor.   See  the
        ///   description  of the `O_CLOEXEC` flag in `open` for reasons why this may be useful.
        flags: u32,
    ) os.AcceptError!os.socket_t {
        while (true) {
            return os.accept(sockfd, addr, addr_size, flags | os.SOCK_NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => {
                    self.waitUntilFdReadable(sockfd);
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn connect(self: *Loop, sockfd: os.socket_t, sock_addr: *const os.sockaddr, len: os.socklen_t) os.ConnectError!void {
        os.connect(sockfd, sock_addr, len) catch |err| switch (err) {
            error.WouldBlock => {
                self.waitUntilFdWritable(sockfd);
                return os.getsockoptError(sockfd);
            },
            else => return err,
        };
    }

    /// Performs an async `os.open` using a separate thread.
    pub fn openZ(self: *Loop, file_path: [*:0]const u8, flags: u32, mode: os.mode_t) os.OpenError!os.fd_t {
        var req_node = Request.Node{
            .data = .{
                .msg = .{
                    .open = .{
                        .path = file_path,
                        .flags = flags,
                        .mode = mode,
                        .result = undefined,
                    },
                },
                .finish = .{ .TickNode = .{ .data = @frame() } },
            },
        };
        suspend {
            self.posixFsRequest(&req_node);
        }
        return req_node.data.msg.open.result;
    }

    /// Performs an async `os.opent` using a separate thread.
    pub fn openatZ(self: *Loop, fd: os.fd_t, file_path: [*:0]const u8, flags: u32, mode: os.mode_t) os.OpenError!os.fd_t {
        var req_node = Request.Node{
            .data = .{
                .msg = .{
                    .openat = .{
                        .fd = fd,
                        .path = file_path,
                        .flags = flags,
                        .mode = mode,
                        .result = undefined,
                    },
                },
                .finish = .{ .TickNode = .{ .data = @frame() } },
            },
        };
        suspend {
            self.posixFsRequest(&req_node);
        }
        return req_node.data.msg.openat.result;
    }

    /// Performs an async `os.close` using a separate thread.
    pub fn close(self: *Loop, fd: os.fd_t) void {
        var req_node = Request.Node{
            .data = .{
                .msg = .{ .close = .{ .fd = fd } },
                .finish = .{ .TickNode = .{ .data = @frame() } },
            },
        };
        suspend {
            self.posixFsRequest(&req_node);
        }
    }

    /// Performs an async `os.read` using a separate thread.
    /// `fd` must block and not return EAGAIN.
    pub fn read(self: *Loop, fd: os.fd_t, buf: []u8, simulate_evented: bool) os.ReadError!usize {
        if (simulate_evented) {
            var req_node = Request.Node{
                .data = .{
                    .msg = .{
                        .read = .{
                            .fd = fd,
                            .buf = buf,
                            .result = undefined,
                        },
                    },
                    .finish = .{ .TickNode = .{ .data = @frame() } },
                },
            };
            suspend {
                self.posixFsRequest(&req_node);
            }
            return req_node.data.msg.read.result;
        } else {
            while (true) {
                return os.read(fd, buf) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.waitUntilFdReadable(fd);
                        continue;
                    },
                    else => return err,
                };
            }
        }
    }

    /// Performs an async `os.readv` using a separate thread.
    /// `fd` must block and not return EAGAIN.
    pub fn readv(self: *Loop, fd: os.fd_t, iov: []const os.iovec, simulate_evented: bool) os.ReadError!usize {
        if (simulate_evented) {
            var req_node = Request.Node{
                .data = .{
                    .msg = .{
                        .readv = .{
                            .fd = fd,
                            .iov = iov,
                            .result = undefined,
                        },
                    },
                    .finish = .{ .TickNode = .{ .data = @frame() } },
                },
            };
            suspend {
                self.posixFsRequest(&req_node);
            }
            return req_node.data.msg.readv.result;
        } else {
            while (true) {
                return os.readv(fd, iov) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.waitUntilFdReadable(fd);
                        continue;
                    },
                    else => return err,
                };
            }
        }
    }

    /// Performs an async `os.pread` using a separate thread.
    /// `fd` must block and not return EAGAIN.
    pub fn pread(self: *Loop, fd: os.fd_t, buf: []u8, offset: u64, simulate_evented: bool) os.PReadError!usize {
        if (simulate_evented) {
            var req_node = Request.Node{
                .data = .{
                    .msg = .{
                        .pread = .{
                            .fd = fd,
                            .buf = buf,
                            .offset = offset,
                            .result = undefined,
                        },
                    },
                    .finish = .{ .TickNode = .{ .data = @frame() } },
                },
            };
            suspend {
                self.posixFsRequest(&req_node);
            }
            return req_node.data.msg.pread.result;
        } else {
            while (true) {
                return os.pread(fd, buf, offset) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.waitUntilFdReadable(fd);
                        continue;
                    },
                    else => return err,
                };
            }
        }
    }

    /// Performs an async `os.preadv` using a separate thread.
    /// `fd` must block and not return EAGAIN.
    pub fn preadv(self: *Loop, fd: os.fd_t, iov: []const os.iovec, offset: u64, simulate_evented: bool) os.ReadError!usize {
        if (simulate_evented) {
            var req_node = Request.Node{
                .data = .{
                    .msg = .{
                        .preadv = .{
                            .fd = fd,
                            .iov = iov,
                            .offset = offset,
                            .result = undefined,
                        },
                    },
                    .finish = .{ .TickNode = .{ .data = @frame() } },
                },
            };
            suspend {
                self.posixFsRequest(&req_node);
            }
            return req_node.data.msg.preadv.result;
        } else {
            while (true) {
                return os.preadv(fd, iov, offset) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.waitUntilFdReadable(fd);
                        continue;
                    },
                    else => return err,
                };
            }
        }
    }

    /// Performs an async `os.write` using a separate thread.
    /// `fd` must block and not return EAGAIN.
    pub fn write(self: *Loop, fd: os.fd_t, bytes: []const u8, simulate_evented: bool) os.WriteError!usize {
        if (simulate_evented) {
            var req_node = Request.Node{
                .data = .{
                    .msg = .{
                        .write = .{
                            .fd = fd,
                            .bytes = bytes,
                            .result = undefined,
                        },
                    },
                    .finish = .{ .TickNode = .{ .data = @frame() } },
                },
            };
            suspend {
                self.posixFsRequest(&req_node);
            }
            return req_node.data.msg.write.result;
        } else {
            while (true) {
                return os.write(fd, bytes) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.waitUntilFdWritable(fd);
                        continue;
                    },
                    else => return err,
                };
            }
        }
    }

    /// Performs an async `os.writev` using a separate thread.
    /// `fd` must block and not return EAGAIN.
    pub fn writev(self: *Loop, fd: os.fd_t, iov: []const os.iovec_const, simulate_evented: bool) os.WriteError!usize {
        if (simulate_evented) {
            var req_node = Request.Node{
                .data = .{
                    .msg = .{
                        .writev = .{
                            .fd = fd,
                            .iov = iov,
                            .result = undefined,
                        },
                    },
                    .finish = .{ .TickNode = .{ .data = @frame() } },
                },
            };
            suspend {
                self.posixFsRequest(&req_node);
            }
            return req_node.data.msg.writev.result;
        } else {
            while (true) {
                return os.writev(fd, iov) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.waitUntilFdWritable(fd);
                        continue;
                    },
                    else => return err,
                };
            }
        }
    }

    /// Performs an async `os.pwrite` using a separate thread.
    /// `fd` must block and not return EAGAIN.
    pub fn pwrite(self: *Loop, fd: os.fd_t, bytes: []const u8, offset: u64, simulate_evented: bool) os.PerformsWriteError!usize {
        if (simulate_evented) {
            var req_node = Request.Node{
                .data = .{
                    .msg = .{
                        .pwrite = .{
                            .fd = fd,
                            .bytes = bytes,
                            .offset = offset,
                            .result = undefined,
                        },
                    },
                    .finish = .{ .TickNode = .{ .data = @frame() } },
                },
            };
            suspend {
                self.posixFsRequest(&req_node);
            }
            return req_node.data.msg.pwrite.result;
        } else {
            while (true) {
                return os.pwrite(fd, bytes, offset) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.waitUntilFdWritable(fd);
                        continue;
                    },
                    else => return err,
                };
            }
        }
    }

    /// Performs an async `os.pwritev` using a separate thread.
    /// `fd` must block and not return EAGAIN.
    pub fn pwritev(self: *Loop, fd: os.fd_t, iov: []const os.iovec_const, offset: u64, simulate_evented: bool) os.PWriteError!usize {
        if (simulate_evented) {
            var req_node = Request.Node{
                .data = .{
                    .msg = .{
                        .pwritev = .{
                            .fd = fd,
                            .iov = iov,
                            .offset = offset,
                            .result = undefined,
                        },
                    },
                    .finish = .{ .TickNode = .{ .data = @frame() } },
                },
            };
            suspend {
                self.posixFsRequest(&req_node);
            }
            return req_node.data.msg.pwritev.result;
        } else {
            while (true) {
                return os.pwritev(fd, iov, offset) catch |err| switch (err) {
                    error.WouldBlock => {
                        self.waitUntilFdWritable(fd);
                        continue;
                    },
                    else => return err,
                };
            }
        }
    }

    pub fn sendto(
        self: *Loop,
        /// The file descriptor of the sending socket.
        sockfd: os.fd_t,
        /// Message to send.
        buf: []const u8,
        flags: u32,
        dest_addr: ?*const os.sockaddr,
        addrlen: os.socklen_t,
    ) os.SendToError!usize {
        while (true) {
            return os.sendto(sockfd, buf, flags, dest_addr, addrlen) catch |err| switch (err) {
                error.WouldBlock => {
                    self.waitUntilFdWritable(sockfd);
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn recvfrom(
        self: *Loop,
        sockfd: os.fd_t,
        buf: []u8,
        flags: u32,
        src_addr: ?*os.sockaddr,
        addrlen: ?*os.socklen_t,
    ) os.RecvFromError!usize {
        while (true) {
            return os.recvfrom(sockfd, buf, flags, src_addr, addrlen) catch |err| switch (err) {
                error.WouldBlock => {
                    self.waitUntilFdReadable(sockfd);
                    continue;
                },
                else => return err,
            };
        }
    }

    /// Performs an async `os.faccessatZ` using a separate thread.
    /// `fd` must block and not return EAGAIN.
    pub fn faccessatZ(
        self: *Loop,
        dirfd: os.fd_t,
        path_z: [*:0]const u8,
        mode: u32,
        flags: u32,
    ) os.AccessError!void {
        var req_node = Request.Node{
            .data = .{
                .msg = .{
                    .faccessat = .{
                        .dirfd = dirfd,
                        .path = path_z,
                        .mode = mode,
                        .flags = flags,
                        .result = undefined,
                    },
                },
                .finish = .{ .TickNode = .{ .data = @frame() } },
            },
        };
        suspend {
            self.posixFsRequest(&req_node);
        }
        return req_node.data.msg.faccessat.result;
    }

    fn workerRun(self: *Loop) void {
        while (true) {
            while (true) {
                const next_tick_node = self.next_tick_queue.get() orelse break;
                self.dispatch();
                resume next_tick_node.data;
                self.finishOneEvent();
            }

            switch (builtin.os.tag) {
                .linux => {
                    // only process 1 event so we don't steal from other threads
                    var events: [1]os.linux.epoll_event = undefined;
                    const count = os.epoll_wait(self.os_data.epollfd, events[0..], -1);
                    for (events[0..count]) |ev| {
                        const resume_node = @intToPtr(*ResumeNode, ev.data.ptr);
                        const handle = resume_node.handle;
                        const resume_node_id = resume_node.id;
                        switch (resume_node_id) {
                            .Basic => {},
                            .Stop => return,
                            .EventFd => {
                                const event_fd_node = @fieldParentPtr(ResumeNode.EventFd, "base", resume_node);
                                event_fd_node.epoll_op = os.EPOLL_CTL_MOD;
                                const stack_node = @fieldParentPtr(std.atomic.Stack(ResumeNode.EventFd).Node, "data", event_fd_node);
                                self.available_eventfd_resume_nodes.push(stack_node);
                            },
                        }
                        resume handle;
                        if (resume_node_id == ResumeNode.Id.EventFd) {
                            self.finishOneEvent();
                        }
                    }
                },
                .macos, .freebsd, .netbsd, .dragonfly, .openbsd => {
                    var eventlist: [1]os.Kevent = undefined;
                    const empty_kevs = &[0]os.Kevent{};
                    const count = os.kevent(self.os_data.kqfd, empty_kevs, eventlist[0..], null) catch unreachable;
                    for (eventlist[0..count]) |ev| {
                        const resume_node = @intToPtr(*ResumeNode, ev.udata);
                        const handle = resume_node.handle;
                        const resume_node_id = resume_node.id;
                        switch (resume_node_id) {
                            .Basic => {
                                const basic_node = @fieldParentPtr(ResumeNode.Basic, "base", resume_node);
                                basic_node.kev = ev;
                            },
                            .Stop => return,
                            .EventFd => {
                                const event_fd_node = @fieldParentPtr(ResumeNode.EventFd, "base", resume_node);
                                const stack_node = @fieldParentPtr(std.atomic.Stack(ResumeNode.EventFd).Node, "data", event_fd_node);
                                self.available_eventfd_resume_nodes.push(stack_node);
                            },
                        }
                        resume handle;
                        if (resume_node_id == ResumeNode.Id.EventFd) {
                            self.finishOneEvent();
                        }
                    }
                },
                .windows => {
                    var completion_key: usize = undefined;
                    const overlapped = while (true) {
                        var nbytes: windows.DWORD = undefined;
                        var overlapped: ?*windows.OVERLAPPED = undefined;
                        switch (windows.GetQueuedCompletionStatus(self.os_data.io_port, &nbytes, &completion_key, &overlapped, windows.INFINITE)) {
                            .Aborted => return,
                            .Normal => {},
                            .EOF => {},
                            .Cancelled => continue,
                        }
                        if (overlapped) |o| break o;
                    } else unreachable; // TODO else unreachable should not be necessary
                    const resume_node = @fieldParentPtr(ResumeNode, "overlapped", overlapped);
                    const handle = resume_node.handle;
                    const resume_node_id = resume_node.id;
                    switch (resume_node_id) {
                        .Basic => {},
                        .Stop => return,
                        .EventFd => {
                            const event_fd_node = @fieldParentPtr(ResumeNode.EventFd, "base", resume_node);
                            const stack_node = @fieldParentPtr(std.atomic.Stack(ResumeNode.EventFd).Node, "data", event_fd_node);
                            self.available_eventfd_resume_nodes.push(stack_node);
                        },
                    }
                    resume handle;
                    self.finishOneEvent();
                },
                else => @compileError("unsupported OS"),
            }
        }
    }

    fn posixFsRequest(self: *Loop, request_node: *Request.Node) void {
        self.beginOneEvent(); // finished in posixFsRun after processing the msg
        self.fs_queue.put(request_node);
        self.fs_thread_wakeup.post();
    }

    fn posixFsCancel(self: *Loop, request_node: *Request.Node) void {
        if (self.fs_queue.remove(request_node)) {
            self.finishOneEvent();
        }
    }

    fn posixFsRun(self: *Loop) void {
        nosuspend while (true) {
            self.fs_thread_wakeup.wait();
            const node = self.fs_queue.get() catch {
                unreachable; // a post should ensure theres an item
            };

            switch (node.data.msg) {
                .end => return,
                .read => |*msg| {
                    msg.result = os.read(msg.fd, msg.buf);
                },
                .readv => |*msg| {
                    msg.result = os.readv(msg.fd, msg.iov);
                },
                .write => |*msg| {
                    msg.result = os.write(msg.fd, msg.bytes);
                },
                .writev => |*msg| {
                    msg.result = os.writev(msg.fd, msg.iov);
                },
                .pwrite => |*msg| {
                    msg.result = os.pwrite(msg.fd, msg.bytes, msg.offset);
                },
                .pwritev => |*msg| {
                    msg.result = os.pwritev(msg.fd, msg.iov, msg.offset);
                },
                .pread => |*msg| {
                    msg.result = os.pread(msg.fd, msg.buf, msg.offset);
                },
                .preadv => |*msg| {
                    msg.result = os.preadv(msg.fd, msg.iov, msg.offset);
                },
                .open => |*msg| {
                    if (is_windows) unreachable; // TODO
                    msg.result = os.openZ(msg.path, msg.flags, msg.mode);
                },
                .openat => |*msg| {
                    if (is_windows) unreachable; // TODO
                    msg.result = os.openatZ(msg.fd, msg.path, msg.flags, msg.mode);
                },
                .faccessat => |*msg| {
                    msg.result = os.faccessatZ(msg.dirfd, msg.path, msg.mode, msg.flags);
                },
                .close => |*msg| os.close(msg.fd),
            }
            switch (node.data.finish) {
                .TickNode => |*tick_node| self.onNextTick(tick_node),
                .NoAction => {},
            }
            self.finishOneEvent();
        };
    }

    const OsData = switch (builtin.os.tag) {
        .linux => LinuxOsData,
        .macos, .freebsd, .netbsd, .dragonfly, .openbsd => KEventData,
        .windows => struct {
            io_port: windows.HANDLE,
            extra_thread_count: usize,
        },
        else => struct {},
    };

    const KEventData = struct {
        kqfd: i32,
        final_kevent: os.Kevent,
    };

    const LinuxOsData = struct {
        epollfd: i32,
        final_eventfd: i32,
        final_eventfd_event: os.linux.epoll_event,
    };

    pub const Request = struct {
        msg: Msg,
        finish: Finish,

        pub const Node = std.atomic.Queue(Request).Node;

        pub const Finish = union(enum) {
            TickNode: Loop.NextTickNode,
            NoAction,
        };

        pub const Msg = union(enum) {
            read: Read,
            readv: ReadV,
            write: Write,
            writev: WriteV,
            pwrite: PWrite,
            pwritev: PWriteV,
            pread: PRead,
            preadv: PReadV,
            open: Open,
            openat: OpenAt,
            close: Close,
            faccessat: FAccessAt,

            /// special - means the fs thread should exit
            end,

            pub const Read = struct {
                fd: os.fd_t,
                buf: []u8,
                result: Error!usize,

                pub const Error = os.ReadError;
            };

            pub const ReadV = struct {
                fd: os.fd_t,
                iov: []const os.iovec,
                result: Error!usize,

                pub const Error = os.ReadError;
            };

            pub const Write = struct {
                fd: os.fd_t,
                bytes: []const u8,
                result: Error!usize,

                pub const Error = os.WriteError;
            };

            pub const WriteV = struct {
                fd: os.fd_t,
                iov: []const os.iovec_const,
                result: Error!usize,

                pub const Error = os.WriteError;
            };

            pub const PWrite = struct {
                fd: os.fd_t,
                bytes: []const u8,
                offset: usize,
                result: Error!usize,

                pub const Error = os.PWriteError;
            };

            pub const PWriteV = struct {
                fd: os.fd_t,
                iov: []const os.iovec_const,
                offset: usize,
                result: Error!usize,

                pub const Error = os.PWriteError;
            };

            pub const PRead = struct {
                fd: os.fd_t,
                buf: []u8,
                offset: usize,
                result: Error!usize,

                pub const Error = os.PReadError;
            };

            pub const PReadV = struct {
                fd: os.fd_t,
                iov: []const os.iovec,
                offset: usize,
                result: Error!usize,

                pub const Error = os.PReadError;
            };

            pub const Open = struct {
                path: [*:0]const u8,
                flags: u32,
                mode: os.mode_t,
                result: Error!os.fd_t,

                pub const Error = os.OpenError;
            };

            pub const OpenAt = struct {
                fd: os.fd_t,
                path: [*:0]const u8,
                flags: u32,
                mode: os.mode_t,
                result: Error!os.fd_t,

                pub const Error = os.OpenError;
            };

            pub const Close = struct {
                fd: os.fd_t,
            };

            pub const FAccessAt = struct {
                dirfd: os.fd_t,
                path: [*:0]const u8,
                mode: u32,
                flags: u32,
                result: Error!void,

                pub const Error = os.AccessError;
            };
        };
    };
};

test "std.event.Loop - basic" {
    // https://github.com/ziglang/zig/issues/1908
    if (builtin.single_threaded) return error.SkipZigTest;

    if (true) {
        // https://github.com/ziglang/zig/issues/4922
        return error.SkipZigTest;
    }

    var loop: Loop = undefined;
    try loop.initMultiThreaded();
    defer loop.deinit();

    loop.run();
}

fn testEventLoop() i32 {
    return 1234;
}

fn testEventLoop2(h: anyframe->i32, did_it: *bool) void {
    const value = await h;
    try testing.expect(value == 1234);
    did_it.* = true;
}

var testRunDetachedData: usize = 0;
test "std.event.Loop - runDetached" {
    // https://github.com/ziglang/zig/issues/1908
    if (builtin.single_threaded) return error.SkipZigTest;
    if (!std.io.is_async) return error.SkipZigTest;
    if (true) {
        // https://github.com/ziglang/zig/issues/4922
        return error.SkipZigTest;
    }

    var loop: Loop = undefined;
    try loop.initMultiThreaded();
    defer loop.deinit();

    // Schedule the execution, won't actually start until we start the
    // event loop.
    try loop.runDetached(std.testing.allocator, testRunDetached, .{});

    // Now we can start the event loop. The function will return only
    // after all tasks have been completed, allowing us to synchonize
    // with the previous runDetached.
    loop.run();

    try testing.expect(testRunDetachedData == 1);
}

fn testRunDetached() void {
    testRunDetachedData += 1;
}

test "std.event.Loop - sleep" {
    // https://github.com/ziglang/zig/issues/1908
    if (builtin.single_threaded) return error.SkipZigTest;
    if (!std.io.is_async) return error.SkipZigTest;

    const frames = try testing.allocator.alloc(@Frame(testSleep), 10);
    defer testing.allocator.free(frames);

    const wait_time = 100 * std.time.ns_per_ms;
    var sleep_count: usize = 0;

    for (frames) |*frame|
        frame.* = async testSleep(wait_time, &sleep_count);
    for (frames) |*frame|
        await frame;

    try testing.expect(sleep_count == frames.len);
}

fn testSleep(wait_ns: u64, sleep_count: *usize) void {
    Loop.instance.?.sleep(wait_ns);
    _ = @atomicRmw(usize, sleep_count, .Add, 1, .SeqCst);
}
