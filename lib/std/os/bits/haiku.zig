// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("../../std.zig");
const maxInt = std.math.maxInt;

pub const fd_t = c_int;
pub const pid_t = c_int;
pub const uid_t = u32;
pub const gid_t = u32;
pub const mode_t = c_uint;

pub const socklen_t = u32;

/// Renamed from `kevent` to `Kevent` to avoid conflict with function name.
pub const Kevent = extern struct {
    ident: usize,
    filter: i16,
    flags: u16,
    fflags: u32,
    data: i64,
    udata: usize,
    // TODO ext
};

// Modes and flags for dlopen()
// include/dlfcn.h

pub const POLLIN = 0x0001;
pub const POLLERR = 0x0004;
pub const POLLNVAL = 0x1000;
pub const POLLHUP = 0x0080;

/// Bind function calls lazily.
pub const RTLD_LAZY = 1;

/// Bind function calls immediately.
pub const RTLD_NOW = 2;

pub const RTLD_MODEMASK = 0x3;

/// Make symbols globally available.
pub const RTLD_GLOBAL = 0x100;

/// Opposite of RTLD_GLOBAL, and the default.
pub const RTLD_LOCAL = 0;

/// Trace loaded objects and exit.
pub const RTLD_TRACE = 0x200;

/// Do not remove members.
pub const RTLD_NODELETE = 0x01000;

/// Do not load if not already loaded.
pub const RTLD_NOLOAD = 0x02000;

pub const dl_phdr_info = extern struct {
    dlpi_addr: usize,
    dlpi_name: ?[*:0]const u8,
    dlpi_phdr: [*]std.elf.Phdr,
    dlpi_phnum: u16,
};

pub const Flock = extern struct {
    l_start: off_t,
    l_len: off_t,
    l_pid: pid_t,
    l_type: i16,
    l_whence: i16,
    l_sysid: i32,
    __unused: [4]u8,
};

pub const msghdr = extern struct {
    /// optional address
    msg_name: ?*sockaddr,

    /// size of address
    msg_namelen: socklen_t,

    /// scatter/gather array
    msg_iov: [*]iovec,

    /// # elements in msg_iov
    msg_iovlen: i32,

    /// ancillary data
    msg_control: ?*c_void,

    /// ancillary data buffer len
    msg_controllen: socklen_t,

    /// flags on received message
    msg_flags: i32,
};

pub const msghdr_const = extern struct {
    /// optional address
    msg_name: ?*const sockaddr,

    /// size of address
    msg_namelen: socklen_t,

    /// scatter/gather array
    msg_iov: [*]iovec_const,

    /// # elements in msg_iov
    msg_iovlen: i32,

    /// ancillary data
    msg_control: ?*c_void,

    /// ancillary data buffer len
    msg_controllen: socklen_t,

    /// flags on received message
    msg_flags: i32,
};

pub const off_t = i64;
pub const ino_t = u64;

pub const nfds_t = u32;

pub const pollfd = extern struct {
    fd: i32,
    events: i16,
    revents: i16,
};

pub const libc_stat = extern struct {
    dev: i32,
    ino: u64,
    mode: u32,
    nlink: i32,
    uid: i32,
    gid: i32,
    size: i64,
    rdev: i32,
    blksize: i32,
    atim: timespec,
    mtim: timespec,
    ctim: timespec,
    crtim: timespec,
    st_type: u32,
    blocks: i64,

    pub fn atime(self: @This()) timespec {
        return self.atim;
    }
    pub fn mtime(self: @This()) timespec {
        return self.mtim;
    }
    pub fn ctime(self: @This()) timespec {
        return self.ctim;
    }
    pub fn crtime(self: @This()) timespec {
        return self.crtim;
    }
};

pub const timespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

pub const dirent = extern struct {
    d_dev: i32,
    d_pdev: i32,
    d_ino: i64,
    d_pino: i64,
    d_reclen: u16,
    d_name: [256]u8,

    pub fn reclen(self: dirent) u16 {
        return self.d_reclen;
    }
};

pub const area_info = extern struct {
    area: u32,
    name: [32]u8,
    size: usize,
    lock: u32,
    protection: u32,
    team_id: i32,
    ram_size: u32,
    copy_count: u32,
    in_count: u32,
    out_count: u32,
    address: *c_void,
};

pub const image_info = extern struct {
    id: u32,
    image_type: u32,
    sequence: i32,
    init_order: i32,
    init_routine: *c_void,
    term_routine: *c_void,
    device: i32,
    node: i64,
    name: [1024]u8,
    text: *c_void,
    data: *c_void,
    text_size: i32,
    data_size: i32,
    api_version: i32,
    abi: i32,
};

pub const system_info = extern struct {
    boot_time: i64,
    cpu_count: u32,
    max_pages: u64,
    used_pages: u64,
    cached_pages: u64,
    block_cache_pages: u64,
    ignored_pages: u64,
    needed_memory: u64,
    free_memory: u64,
    max_swap_pages: u64,
    free_swap_pages: u64,
    page_faults: u32,
    max_sems: u32,
    used_sems: u32,
    max_ports: u32,
    used_ports: u32,
    max_threads: u32,
    used_threads: u32,
    max_teams: u32,
    used_teams: u32,
    kernel_name: [256]u8,
    kernel_build_date: [32]u8,
    kernel_build_time: [32]u8,
    kernel_version: i64,
    abi: u32,
};

pub const team_info = extern struct {
    team_id: i32,
    thread_count: i32,
    image_count: i32,
    area_count: i32,
    debugger_nub_thread: i32,
    debugger_nub_port: i32,
    argc: i32,
    args: [64]u8,
    uid: uid_t,
    gid: gid_t,
};

pub const in_port_t = u16;
pub const sa_family_t = u8;

pub const sockaddr = extern struct {
    /// total length
    len: u8,

    /// address family
    family: sa_family_t,

    /// actually longer; address value
    data: [14]u8,
};

pub const sockaddr_storage = std.x.os.Socket.Address.Native.Storage;

pub const sockaddr_in = extern struct {
    len: u8 = @sizeOf(sockaddr_in),
    family: sa_family_t = AF_INET,
    port: in_port_t,
    addr: u32,
    zero: [8]u8 = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
};

pub const sockaddr_in6 = extern struct {
    len: u8 = @sizeOf(sockaddr_in6),
    family: sa_family_t = AF_INET6,
    port: in_port_t,
    flowinfo: u32,
    addr: [16]u8,
    scope_id: u32,
};

pub const sockaddr_un = extern struct {
    len: u8 = @sizeOf(sockaddr_un),
    family: sa_family_t = AF_UNIX,
    path: [104]u8,
};

pub const CTL_KERN = 1;
pub const CTL_DEBUG = 5;

pub const KERN_PROC = 14; // struct: process entries
pub const KERN_PROC_PATHNAME = 12; // path to executable

pub const PATH_MAX = 1024;

pub const STDIN_FILENO = 0;
pub const STDOUT_FILENO = 1;
pub const STDERR_FILENO = 2;

pub const PROT_NONE = 0;
pub const PROT_READ = 1;
pub const PROT_WRITE = 2;
pub const PROT_EXEC = 4;

pub const CLOCK_MONOTONIC = 0;
pub const CLOCK_REALTIME = -1;
pub const CLOCK_PROCESS_CPUTIME_ID = -2;
pub const CLOCK_THREAD_CPUTIME_ID = -3;

pub const MAP_FAILED = @intToPtr(*c_void, maxInt(usize));
pub const MAP_SHARED = 0x0001;
pub const MAP_PRIVATE = 0x0002;
pub const MAP_FIXED = 0x0004;
pub const MAP_STACK = 0x0400;
pub const MAP_NOSYNC = 0x0800;
pub const MAP_ANON = 0x0008;
pub const MAP_ANONYMOUS = MAP_ANON;
pub const MAP_FILE = 0;

pub const MAP_GUARD = 0x00002000;
pub const MAP_EXCL = 0x00004000;
pub const MAP_NOCORE = 0x00020000;
pub const MAP_PREFAULT_READ = 0x00040000;
pub const MAP_32BIT = 0x00080000;

pub const WNOHANG = 0x1;
pub const WUNTRACED = 0x2;
pub const WSTOPPED = 0x10;
pub const WCONTINUED = 0x4;
pub const WNOWAIT = 0x20;
pub const WEXITED = 0x08;

pub const SA_ONSTACK = 0x20;
pub const SA_RESTART = 0x10;
pub const SA_RESETHAND = 0x04;
pub const SA_NOCLDSTOP = 0x01;
pub const SA_NODEFER = 0x08;
pub const SA_NOCLDWAIT = 0x02;
pub const SA_SIGINFO = 0x40;
pub const SA_NOMASK = SA_NODEFER;
pub const SA_STACK = SA_ONSTACK;
pub const SA_ONESHOT = SA_RESETHAND;

pub const SIGHUP = 1;
pub const SIGINT = 2;
pub const SIGQUIT = 3;
pub const SIGILL = 4;
pub const SIGCHLD = 5;
pub const SIGABRT = 6;
pub const SIGIOT = SIGABRT;
pub const SIGPIPE = 7;
pub const SIGFPE = 8;
pub const SIGKILL = 9;
pub const SIGSTOP = 10;
pub const SIGSEGV = 11;
pub const SIGCONT = 12;
pub const SIGTSTP = 13;
pub const SIGALRM = 14;
pub const SIGTERM = 15;
pub const SIGTTIN = 16;
pub const SIGTTOU = 17;
pub const SIGUSR1 = 18;
pub const SIGUSR2 = 19;
pub const SIGWINCH = 20;
pub const SIGKILLTHR = 21;
pub const SIGTRAP = 22;
pub const SIGPOLL = 23;
pub const SIGPROF = 24;
pub const SIGSYS = 25;
pub const SIGURG = 26;
pub const SIGVTALRM = 27;
pub const SIGXCPU = 28;
pub const SIGXFSZ = 29;
pub const SIGBUS = 30;
pub const SIGRESERVED1 = 31;
pub const SIGRESERVED2 = 32;

// TODO: check
pub const SIGRTMIN = 65;
pub const SIGRTMAX = 126;

// access function
pub const F_OK = 0; // test for existence of file
pub const X_OK = 1; // test for execute or search permission
pub const W_OK = 2; // test for write permission
pub const R_OK = 4; // test for read permission

pub const O_RDONLY = 0x0000;
pub const O_WRONLY = 0x0001;
pub const O_RDWR = 0x0002;
pub const O_ACCMODE = 0x0003;

pub const O_CREAT = 0x0200;
pub const O_EXCL = 0x0800;
pub const O_NOCTTY = 0x8000;
pub const O_TRUNC = 0x0400;
pub const O_APPEND = 0x0008;
pub const O_NONBLOCK = 0x0004;
pub const O_DSYNC = 0o10000;
pub const O_SYNC = 0x0080;
pub const O_RSYNC = 0o4010000;
pub const O_DIRECTORY = 0x20000;
pub const O_NOFOLLOW = 0x0100;
pub const O_CLOEXEC = 0x00000040;

pub const O_ASYNC = 0x0040;
pub const O_DIRECT = 0x00010000;
pub const O_NOATIME = 0o1000000;
pub const O_PATH = 0o10000000;
pub const O_TMPFILE = 0o20200000;
pub const O_NDELAY = O_NONBLOCK;

pub const F_DUPFD = 0;
pub const F_GETFD = 1;
pub const F_SETFD = 2;
pub const F_GETFL = 3;
pub const F_SETFL = 4;

pub const F_GETOWN = 5;
pub const F_SETOWN = 6;

pub const F_GETLK = 11;
pub const F_SETLK = 12;
pub const F_SETLKW = 13;

pub const F_RDLCK = 1;
pub const F_WRLCK = 3;
pub const F_UNLCK = 2;

pub const LOCK_SH = 1;
pub const LOCK_EX = 2;
pub const LOCK_UN = 8;
pub const LOCK_NB = 4;

pub const F_SETOWN_EX = 15;
pub const F_GETOWN_EX = 16;

pub const F_GETOWNER_UIDS = 17;

pub const FD_CLOEXEC = 1;

pub const SEEK_SET = 0;
pub const SEEK_CUR = 1;
pub const SEEK_END = 2;

pub const SIG_BLOCK = 1;
pub const SIG_UNBLOCK = 2;
pub const SIG_SETMASK = 3;

pub const SOCK_STREAM = 1;
pub const SOCK_DGRAM = 2;
pub const SOCK_RAW = 3;
pub const SOCK_RDM = 4;
pub const SOCK_SEQPACKET = 5;

pub const SOCK_CLOEXEC = 0x10000000;
pub const SOCK_NONBLOCK = 0x20000000;

pub const SO_DEBUG = 0x00000001;
pub const SO_ACCEPTCONN = 0x00000002;
pub const SO_REUSEADDR = 0x00000004;
pub const SO_KEEPALIVE = 0x00000008;
pub const SO_DONTROUTE = 0x00000010;
pub const SO_BROADCAST = 0x00000020;
pub const SO_USELOOPBACK = 0x00000040;
pub const SO_LINGER = 0x00000080;
pub const SO_OOBINLINE = 0x00000100;
pub const SO_REUSEPORT = 0x00000200;
pub const SO_TIMESTAMP = 0x00000400;
pub const SO_NOSIGPIPE = 0x00000800;
pub const SO_ACCEPTFILTER = 0x00001000;
pub const SO_BINTIME = 0x00002000;
pub const SO_NO_OFFLOAD = 0x00004000;
pub const SO_NO_DDP = 0x00008000;
pub const SO_REUSEPORT_LB = 0x00010000;

pub const SO_SNDBUF = 0x1001;
pub const SO_RCVBUF = 0x1002;
pub const SO_SNDLOWAT = 0x1003;
pub const SO_RCVLOWAT = 0x1004;
pub const SO_SNDTIMEO = 0x1005;
pub const SO_RCVTIMEO = 0x1006;
pub const SO_ERROR = 0x1007;
pub const SO_TYPE = 0x1008;
pub const SO_LABEL = 0x1009;
pub const SO_PEERLABEL = 0x1010;
pub const SO_LISTENQLIMIT = 0x1011;
pub const SO_LISTENQLEN = 0x1012;
pub const SO_LISTENINCQLEN = 0x1013;
pub const SO_SETFIB = 0x1014;
pub const SO_USER_COOKIE = 0x1015;
pub const SO_PROTOCOL = 0x1016;
pub const SO_PROTOTYPE = SO_PROTOCOL;
pub const SO_TS_CLOCK = 0x1017;
pub const SO_MAX_PACING_RATE = 0x1018;
pub const SO_DOMAIN = 0x1019;

pub const SOL_SOCKET = 0xffff;

pub const PF_UNSPEC = AF_UNSPEC;
pub const PF_LOCAL = AF_LOCAL;
pub const PF_UNIX = PF_LOCAL;
pub const PF_INET = AF_INET;
pub const PF_IMPLINK = AF_IMPLINK;
pub const PF_PUP = AF_PUP;
pub const PF_CHAOS = AF_CHAOS;
pub const PF_NETBIOS = AF_NETBIOS;
pub const PF_ISO = AF_ISO;
pub const PF_OSI = AF_ISO;
pub const PF_ECMA = AF_ECMA;
pub const PF_DATAKIT = AF_DATAKIT;
pub const PF_CCITT = AF_CCITT;
pub const PF_DECnet = AF_DECnet;
pub const PF_DLI = AF_DLI;
pub const PF_LAT = AF_LAT;
pub const PF_HYLINK = AF_HYLINK;
pub const PF_APPLETALK = AF_APPLETALK;
pub const PF_ROUTE = AF_ROUTE;
pub const PF_LINK = AF_LINK;
pub const PF_XTP = pseudo_AF_XTP;
pub const PF_COIP = AF_COIP;
pub const PF_CNT = AF_CNT;
pub const PF_SIP = AF_SIP;
pub const PF_IPX = AF_IPX;
pub const PF_RTIP = pseudo_AF_RTIP;
pub const PF_PIP = psuedo_AF_PIP;
pub const PF_ISDN = AF_ISDN;
pub const PF_KEY = pseudo_AF_KEY;
pub const PF_INET6 = pseudo_AF_INET6;
pub const PF_NATM = AF_NATM;
pub const PF_ATM = AF_ATM;
pub const PF_NETGRAPH = AF_NETGRAPH;
pub const PF_SLOW = AF_SLOW;
pub const PF_SCLUSTER = AF_SCLUSTER;
pub const PF_ARP = AF_ARP;
pub const PF_BLUETOOTH = AF_BLUETOOTH;
pub const PF_IEEE80211 = AF_IEEE80211;
pub const PF_INET_SDP = AF_INET_SDP;
pub const PF_INET6_SDP = AF_INET6_SDP;
pub const PF_MAX = AF_MAX;

pub const AF_UNSPEC = 0;
pub const AF_UNIX = 1;
pub const AF_LOCAL = AF_UNIX;
pub const AF_FILE = AF_LOCAL;
pub const AF_INET = 2;
pub const AF_IMPLINK = 3;
pub const AF_PUP = 4;
pub const AF_CHAOS = 5;
pub const AF_NETBIOS = 6;
pub const AF_ISO = 7;
pub const AF_OSI = AF_ISO;
pub const AF_ECMA = 8;
pub const AF_DATAKIT = 9;
pub const AF_CCITT = 10;
pub const AF_SNA = 11;
pub const AF_DECnet = 12;
pub const AF_DLI = 13;
pub const AF_LAT = 14;
pub const AF_HYLINK = 15;
pub const AF_APPLETALK = 16;
pub const AF_ROUTE = 17;
pub const AF_LINK = 18;
pub const pseudo_AF_XTP = 19;
pub const AF_COIP = 20;
pub const AF_CNT = 21;
pub const pseudo_AF_RTIP = 22;
pub const AF_IPX = 23;
pub const AF_SIP = 24;
pub const pseudo_AF_PIP = 25;
pub const AF_ISDN = 26;
pub const AF_E164 = AF_ISDN;
pub const pseudo_AF_KEY = 27;
pub const AF_INET6 = 28;
pub const AF_NATM = 29;
pub const AF_ATM = 30;
pub const pseudo_AF_HDRCMPLT = 31;
pub const AF_NETGRAPH = 32;
pub const AF_SLOW = 33;
pub const AF_SCLUSTER = 34;
pub const AF_ARP = 35;
pub const AF_BLUETOOTH = 36;
pub const AF_IEEE80211 = 37;
pub const AF_INET_SDP = 40;
pub const AF_INET6_SDP = 42;
pub const AF_MAX = 42;

pub const DT_UNKNOWN = 0;
pub const DT_FIFO = 1;
pub const DT_CHR = 2;
pub const DT_DIR = 4;
pub const DT_BLK = 6;
pub const DT_REG = 8;
pub const DT_LNK = 10;
pub const DT_SOCK = 12;
pub const DT_WHT = 14;

/// add event to kq (implies enable)
pub const EV_ADD = 0x0001;

/// delete event from kq
pub const EV_DELETE = 0x0002;

/// enable event
pub const EV_ENABLE = 0x0004;

/// disable event (not reported)
pub const EV_DISABLE = 0x0008;

/// only report one occurrence
pub const EV_ONESHOT = 0x0010;

/// clear event state after reporting
pub const EV_CLEAR = 0x0020;

/// force immediate event output
/// ... with or without EV_ERROR
/// ... use KEVENT_FLAG_ERROR_EVENTS
///     on syscalls supporting flags
pub const EV_RECEIPT = 0x0040;

/// disable event after reporting
pub const EV_DISPATCH = 0x0080;

pub const EVFILT_READ = -1;
pub const EVFILT_WRITE = -2;

/// attached to aio requests
pub const EVFILT_AIO = -3;

/// attached to vnodes
pub const EVFILT_VNODE = -4;

/// attached to struct proc
pub const EVFILT_PROC = -5;

/// attached to struct proc
pub const EVFILT_SIGNAL = -6;

/// timers
pub const EVFILT_TIMER = -7;

/// Process descriptors
pub const EVFILT_PROCDESC = -8;

/// Filesystem events
pub const EVFILT_FS = -9;

pub const EVFILT_LIO = -10;

/// User events
pub const EVFILT_USER = -11;

/// Sendfile events
pub const EVFILT_SENDFILE = -12;

pub const EVFILT_EMPTY = -13;

pub const TCGETA = 0x8000;
pub const TCSETA = 0x8001;
pub const TCSETAW = 0x8004;
pub const TCSETAF = 0x8003;
pub const TCSBRK = 08005;
pub const TCXONC = 0x8007;
pub const TCFLSH = 0x8006;

pub const TIOCSCTTY = 0x8017;
pub const TIOCGPGRP = 0x8015;
pub const TIOCSPGRP = 0x8016;
pub const TIOCGWINSZ = 0x8012;
pub const TIOCSWINSZ = 0x8013;
pub const TIOCMGET = 0x8018;
pub const TIOCMBIS = 0x8022;
pub const TIOCMBIC = 0x8023;
pub const TIOCMSET = 0x8019;
pub const FIONREAD = 0xbe000001;
pub const FIONBIO = 0xbe000000;
pub const TIOCSBRK = 0x8020;
pub const TIOCCBRK = 0x8021;
pub const TIOCGSID = 0x8024;

pub fn WEXITSTATUS(s: u32) u8 {
    return @intCast(u8, s & 0xff);
}

pub fn WTERMSIG(s: u32) u32 {
    return (s >> 8) & 0xff;
}

pub fn WSTOPSIG(s: u32) u32 {
    return WEXITSTATUS(s);
}

pub fn WIFEXITED(s: u32) bool {
    return WTERMSIG(s) == 0;
}

pub fn WIFSTOPPED(s: u32) bool {
    return ((s >> 16) & 0xff) != 0;
}

pub fn WIFSIGNALED(s: u32) bool {
    return ((s >> 8) & 0xff) != 0;
}

pub const winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

const NSIG = 32;

pub const SIG_ERR = @intToPtr(fn (i32) callconv(.C) void, maxInt(usize));
pub const SIG_DFL = @intToPtr(fn (i32) callconv(.C) void, 0);
pub const SIG_IGN = @intToPtr(fn (i32) callconv(.C) void, 1);

/// Renamed from `sigaction` to `Sigaction` to avoid conflict with the syscall.
pub const Sigaction = extern struct {
    /// signal handler
    __sigaction_u: extern union {
        __sa_handler: fn (i32) callconv(.C) void,
        __sa_sigaction: fn (i32, *__siginfo, usize) callconv(.C) void,
    },

    /// see signal options
    sa_flags: u32,

    /// signal mask to apply
    sa_mask: sigset_t,
};

pub const _SIG_WORDS = 4;
pub const _SIG_MAXSIG = 128;
pub inline fn _SIG_IDX(sig: usize) usize {
    return sig - 1;
}
pub inline fn _SIG_WORD(sig: usize) usize {
    return_SIG_IDX(sig) >> 5;
}
pub inline fn _SIG_BIT(sig: usize) usize {
    return 1 << (_SIG_IDX(sig) & 31);
}
pub inline fn _SIG_VALID(sig: usize) usize {
    return sig <= _SIG_MAXSIG and sig > 0;
}

pub const sigset_t = extern struct {
    __bits: [_SIG_WORDS]u32,
};

pub const EPERM = -0x7ffffff1; // Operation not permitted
pub const ENOENT = -0x7fff9ffd; // No such file or directory
pub const ESRCH = -0x7fff8ff3; // No such process
pub const EINTR = -0x7ffffff6; // Interrupted system call
pub const EIO = -0x7fffffff; // Input/output error
pub const ENXIO = -0x7fff8ff5; // Device not configured
pub const E2BIG = -0x7fff8fff; // Argument list too long
pub const ENOEXEC = -0x7fffecfe; // Exec format error
pub const ECHILD = -0x7fff8ffe; // No child processes
pub const EDEADLK = -0x7fff8ffd; // Resource deadlock avoided
pub const ENOMEM = -0x80000000; // Cannot allocate memory
pub const EACCES = -0x7ffffffe; // Permission denied
pub const EFAULT = -0x7fffecff; // Bad address
pub const EBUSY = -0x7ffffff2; // Device busy
pub const EEXIST = -0x7fff9ffe; // File exists
pub const EXDEV = -0x7fff9ff5; // Cross-device link
pub const ENODEV = -0x7fff8ff9; // Operation not supported by device
pub const ENOTDIR = -0x7fff9ffb; // Not a directory
pub const EISDIR = -0x7fff9ff7; // Is a directory
pub const EINVAL = -0x7ffffffb; // Invalid argument
pub const ENFILE = -0x7fff8ffa; // Too many open files in system
pub const EMFILE = -0x7fff9ff6; // Too many open files
pub const ENOTTY = -0x7fff8ff6; // Inappropriate ioctl for device
pub const ETXTBSY = -0x7fff8fc5; // Text file busy
pub const EFBIG = -0x7fff8ffc; // File too large
pub const ENOSPC = -0x7fff9ff9; // No space left on device
pub const ESPIPE = -0x7fff8ff4; // Illegal seek
pub const EROFS = -0x7fff9ff8; // Read-only filesystem
pub const EMLINK = -0x7fff8ffb; // Too many links
pub const EPIPE = -0x7fff9ff3; // Broken pipe
pub const EBADF = -0x7fffa000; // Bad file descriptor

// math software
pub const EDOM = 33; // Numerical argument out of domain
pub const ERANGE = 34; // Result too large

// non-blocking and interrupt i/o
pub const EAGAIN = -0x7ffffff5;
pub const EWOULDBLOCK = -0x7ffffff5;
pub const EINPROGRESS = -0x7fff8fdc;
pub const EALREADY = -0x7fff8fdb;

// ipc/network software -- argument errors
pub const ENOTSOCK = 38; // Socket operation on non-socket
pub const EDESTADDRREQ = 39; // Destination address required
pub const EMSGSIZE = 40; // Message too long
pub const EPROTOTYPE = 41; // Protocol wrong type for socket
pub const ENOPROTOOPT = 42; // Protocol not available
pub const EPROTONOSUPPORT = 43; // Protocol not supported
pub const ESOCKTNOSUPPORT = 44; // Socket type not supported
pub const EOPNOTSUPP = 45; // Operation not supported
pub const ENOTSUP = EOPNOTSUPP; // Operation not supported
pub const EPFNOSUPPORT = 46; // Protocol family not supported
pub const EAFNOSUPPORT = 47; // Address family not supported by protocol family
pub const EADDRINUSE = 48; // Address already in use
pub const EADDRNOTAVAIL = 49; // Can't assign requested address

// ipc/network software -- operational errors
pub const ENETDOWN = 50; // Network is down
pub const ENETUNREACH = 51; // Network is unreachable
pub const ENETRESET = 52; // Network dropped connection on reset
pub const ECONNABORTED = 53; // Software caused connection abort
pub const ECONNRESET = 54; // Connection reset by peer
pub const ENOBUFS = 55; // No buffer space available
pub const EISCONN = 56; // Socket is already connected
pub const ENOTCONN = 57; // Socket is not connected
pub const ESHUTDOWN = 58; // Can't send after socket shutdown
pub const ETOOMANYREFS = 59; // Too many references: can't splice
pub const ETIMEDOUT = 60; // Operation timed out
pub const ECONNREFUSED = 61; // Connection refused

pub const ELOOP = 62; // Too many levels of symbolic links
pub const ENAMETOOLONG = 63; // File name too long

// should be rearranged
pub const EHOSTDOWN = 64; // Host is down
pub const EHOSTUNREACH = 65; // No route to host
pub const ENOTEMPTY = 66; // Directory not empty

// quotas & mush
pub const EPROCLIM = 67; // Too many processes
pub const EUSERS = 68; // Too many users
pub const EDQUOT = 69; // Disc quota exceeded

// Network File System
pub const ESTALE = 70; // Stale NFS file handle
pub const EREMOTE = 71; // Too many levels of remote in path
pub const EBADRPC = 72; // RPC struct is bad
pub const ERPCMISMATCH = 73; // RPC version wrong
pub const EPROGUNAVAIL = 74; // RPC prog. not avail
pub const EPROGMISMATCH = 75; // Program version wrong
pub const EPROCUNAVAIL = 76; // Bad procedure for program

pub const ENOLCK = 77; // No locks available
pub const ENOSYS = 78; // Function not implemented

pub const EFTYPE = 79; // Inappropriate file type or format
pub const EAUTH = 80; // Authentication error
pub const ENEEDAUTH = 81; // Need authenticator
pub const EIDRM = 82; // Identifier removed
pub const ENOMSG = 83; // No message of desired type
pub const EOVERFLOW = 84; // Value too large to be stored in data type
pub const ECANCELED = 85; // Operation canceled
pub const EILSEQ = 86; // Illegal byte sequence
pub const ENOATTR = 87; // Attribute not found

pub const EDOOFUS = 88; // Programming error

pub const EBADMSG = 89; // Bad message
pub const EMULTIHOP = 90; // Multihop attempted
pub const ENOLINK = 91; // Link has been severed
pub const EPROTO = 92; // Protocol error

pub const ENOTCAPABLE = 93; // Capabilities insufficient
pub const ECAPMODE = 94; // Not permitted in capability mode
pub const ENOTRECOVERABLE = 95; // State not recoverable
pub const EOWNERDEAD = 96; // Previous owner died

pub const ELAST = 96; // Must be equal largest errno

pub const MINSIGSTKSZ = switch (builtin.cpu.arch) {
    .i386, .x86_64 => 2048,
    .arm, .aarch64 => 4096,
    else => @compileError("MINSIGSTKSZ not defined for this architecture"),
};
pub const SIGSTKSZ = MINSIGSTKSZ + 32768;

pub const SS_ONSTACK = 1;
pub const SS_DISABLE = 4;

pub const stack_t = extern struct {
    ss_sp: [*]u8,
    ss_size: isize,
    ss_flags: i32,
};

pub const S_IFMT = 0o170000;

pub const S_IFIFO = 0o010000;
pub const S_IFCHR = 0o020000;
pub const S_IFDIR = 0o040000;
pub const S_IFBLK = 0o060000;
pub const S_IFREG = 0o100000;
pub const S_IFLNK = 0o120000;
pub const S_IFSOCK = 0o140000;
pub const S_IFWHT = 0o160000;

pub const S_ISUID = 0o4000;
pub const S_ISGID = 0o2000;
pub const S_ISVTX = 0o1000;
pub const S_IRWXU = 0o700;
pub const S_IRUSR = 0o400;
pub const S_IWUSR = 0o200;
pub const S_IXUSR = 0o100;
pub const S_IRWXG = 0o070;
pub const S_IRGRP = 0o040;
pub const S_IWGRP = 0o020;
pub const S_IXGRP = 0o010;
pub const S_IRWXO = 0o007;
pub const S_IROTH = 0o004;
pub const S_IWOTH = 0o002;
pub const S_IXOTH = 0o001;

pub fn S_ISFIFO(m: u32) bool {
    return m & S_IFMT == S_IFIFO;
}

pub fn S_ISCHR(m: u32) bool {
    return m & S_IFMT == S_IFCHR;
}

pub fn S_ISDIR(m: u32) bool {
    return m & S_IFMT == S_IFDIR;
}

pub fn S_ISBLK(m: u32) bool {
    return m & S_IFMT == S_IFBLK;
}

pub fn S_ISREG(m: u32) bool {
    return m & S_IFMT == S_IFREG;
}

pub fn S_ISLNK(m: u32) bool {
    return m & S_IFMT == S_IFLNK;
}

pub fn S_ISSOCK(m: u32) bool {
    return m & S_IFMT == S_IFSOCK;
}

pub fn S_IWHT(m: u32) bool {
    return m & S_IFMT == S_IFWHT;
}

pub const HOST_NAME_MAX = 255;

/// Magic value that specify the use of the current working directory
/// to determine the target of relative file paths in the openat() and
/// similar syscalls.
pub const AT_FDCWD = -100;

/// Check access using effective user and group ID
pub const AT_EACCESS = 0x0100;

/// Do not follow symbolic links
pub const AT_SYMLINK_NOFOLLOW = 0x0200;

/// Follow symbolic link
pub const AT_SYMLINK_FOLLOW = 0x0400;

/// Remove directory instead of file
pub const AT_REMOVEDIR = 0x0800;

pub const addrinfo = extern struct {
    flags: i32,
    family: i32,
    socktype: i32,
    protocol: i32,
    addrlen: socklen_t,
    canonname: ?[*:0]u8,
    addr: ?*sockaddr,
    next: ?*addrinfo,
};

/// Fail if not under dirfd
pub const AT_BENEATH = 0x1000;

/// dummy for IP
pub const IPPROTO_IP = 0;

/// control message protocol
pub const IPPROTO_ICMP = 1;

/// tcp
pub const IPPROTO_TCP = 6;

/// user datagram protocol
pub const IPPROTO_UDP = 17;

/// IP6 header
pub const IPPROTO_IPV6 = 41;

/// raw IP packet
pub const IPPROTO_RAW = 255;

/// IP6 hop-by-hop options
pub const IPPROTO_HOPOPTS = 0;

/// group mgmt protocol
pub const IPPROTO_IGMP = 2;

/// gateway^2 (deprecated)
pub const IPPROTO_GGP = 3;

/// IPv4 encapsulation
pub const IPPROTO_IPV4 = 4;

/// for compatibility
pub const IPPROTO_IPIP = IPPROTO_IPV4;

/// Stream protocol II
pub const IPPROTO_ST = 7;

/// exterior gateway protocol
pub const IPPROTO_EGP = 8;

/// private interior gateway
pub const IPPROTO_PIGP = 9;

/// BBN RCC Monitoring
pub const IPPROTO_RCCMON = 10;

/// network voice protocol
pub const IPPROTO_NVPII = 11;

/// pup
pub const IPPROTO_PUP = 12;

/// Argus
pub const IPPROTO_ARGUS = 13;

/// EMCON
pub const IPPROTO_EMCON = 14;

/// Cross Net Debugger
pub const IPPROTO_XNET = 15;

/// Chaos
pub const IPPROTO_CHAOS = 16;

/// Multiplexing
pub const IPPROTO_MUX = 18;

/// DCN Measurement Subsystems
pub const IPPROTO_MEAS = 19;

/// Host Monitoring
pub const IPPROTO_HMP = 20;

/// Packet Radio Measurement
pub const IPPROTO_PRM = 21;

/// xns idp
pub const IPPROTO_IDP = 22;

/// Trunk-1
pub const IPPROTO_TRUNK1 = 23;

/// Trunk-2
pub const IPPROTO_TRUNK2 = 24;

/// Leaf-1
pub const IPPROTO_LEAF1 = 25;

/// Leaf-2
pub const IPPROTO_LEAF2 = 26;

/// Reliable Data
pub const IPPROTO_RDP = 27;

/// Reliable Transaction
pub const IPPROTO_IRTP = 28;

/// tp-4 w/ class negotiation
pub const IPPROTO_TP = 29;

/// Bulk Data Transfer
pub const IPPROTO_BLT = 30;

/// Network Services
pub const IPPROTO_NSP = 31;

/// Merit Internodal
pub const IPPROTO_INP = 32;

/// Datagram Congestion Control Protocol
pub const IPPROTO_DCCP = 33;

/// Third Party Connect
pub const IPPROTO_3PC = 34;

/// InterDomain Policy Routing
pub const IPPROTO_IDPR = 35;

/// XTP
pub const IPPROTO_XTP = 36;

/// Datagram Delivery
pub const IPPROTO_DDP = 37;

/// Control Message Transport
pub const IPPROTO_CMTP = 38;

/// TP++ Transport
pub const IPPROTO_TPXX = 39;

/// IL transport protocol
pub const IPPROTO_IL = 40;

/// Source Demand Routing
pub const IPPROTO_SDRP = 42;

/// IP6 routing header
pub const IPPROTO_ROUTING = 43;

/// IP6 fragmentation header
pub const IPPROTO_FRAGMENT = 44;

/// InterDomain Routing
pub const IPPROTO_IDRP = 45;

/// resource reservation
pub const IPPROTO_RSVP = 46;

/// General Routing Encap.
pub const IPPROTO_GRE = 47;

/// Mobile Host Routing
pub const IPPROTO_MHRP = 48;

/// BHA
pub const IPPROTO_BHA = 49;

/// IP6 Encap Sec. Payload
pub const IPPROTO_ESP = 50;

/// IP6 Auth Header
pub const IPPROTO_AH = 51;

/// Integ. Net Layer Security
pub const IPPROTO_INLSP = 52;

/// IP with encryption
pub const IPPROTO_SWIPE = 53;

/// Next Hop Resolution
pub const IPPROTO_NHRP = 54;

/// IP Mobility
pub const IPPROTO_MOBILE = 55;

/// Transport Layer Security
pub const IPPROTO_TLSP = 56;

/// SKIP
pub const IPPROTO_SKIP = 57;

/// ICMP6
pub const IPPROTO_ICMPV6 = 58;

/// IP6 no next header
pub const IPPROTO_NONE = 59;

/// IP6 destination option
pub const IPPROTO_DSTOPTS = 60;

/// any host internal protocol
pub const IPPROTO_AHIP = 61;

/// CFTP
pub const IPPROTO_CFTP = 62;

/// "hello" routing protocol
pub const IPPROTO_HELLO = 63;

/// SATNET/Backroom EXPAK
pub const IPPROTO_SATEXPAK = 64;

/// Kryptolan
pub const IPPROTO_KRYPTOLAN = 65;

/// Remote Virtual Disk
pub const IPPROTO_RVD = 66;

/// Pluribus Packet Core
pub const IPPROTO_IPPC = 67;

/// Any distributed FS
pub const IPPROTO_ADFS = 68;

/// Satnet Monitoring
pub const IPPROTO_SATMON = 69;

/// VISA Protocol
pub const IPPROTO_VISA = 70;

/// Packet Core Utility
pub const IPPROTO_IPCV = 71;

/// Comp. Prot. Net. Executive
pub const IPPROTO_CPNX = 72;

/// Comp. Prot. HeartBeat
pub const IPPROTO_CPHB = 73;

/// Wang Span Network
pub const IPPROTO_WSN = 74;

/// Packet Video Protocol
pub const IPPROTO_PVP = 75;

/// BackRoom SATNET Monitoring
pub const IPPROTO_BRSATMON = 76;

/// Sun net disk proto (temp.)
pub const IPPROTO_ND = 77;

/// WIDEBAND Monitoring
pub const IPPROTO_WBMON = 78;

/// WIDEBAND EXPAK
pub const IPPROTO_WBEXPAK = 79;

/// ISO cnlp
pub const IPPROTO_EON = 80;

/// VMTP
pub const IPPROTO_VMTP = 81;

/// Secure VMTP
pub const IPPROTO_SVMTP = 82;

/// Banyon VINES
pub const IPPROTO_VINES = 83;

/// TTP
pub const IPPROTO_TTP = 84;

/// NSFNET-IGP
pub const IPPROTO_IGP = 85;

/// dissimilar gateway prot.
pub const IPPROTO_DGP = 86;

/// TCF
pub const IPPROTO_TCF = 87;

/// Cisco/GXS IGRP
pub const IPPROTO_IGRP = 88;

/// OSPFIGP
pub const IPPROTO_OSPFIGP = 89;

/// Strite RPC protocol
pub const IPPROTO_SRPC = 90;

/// Locus Address Resoloution
pub const IPPROTO_LARP = 91;

/// Multicast Transport
pub const IPPROTO_MTP = 92;

/// AX.25 Frames
pub const IPPROTO_AX25 = 93;

/// IP encapsulated in IP
pub const IPPROTO_IPEIP = 94;

/// Mobile Int.ing control
pub const IPPROTO_MICP = 95;

/// Semaphore Comm. security
pub const IPPROTO_SCCSP = 96;

/// Ethernet IP encapsulation
pub const IPPROTO_ETHERIP = 97;

/// encapsulation header
pub const IPPROTO_ENCAP = 98;

/// any private encr. scheme
pub const IPPROTO_APES = 99;

/// GMTP
pub const IPPROTO_GMTP = 100;

/// payload compression (IPComp)
pub const IPPROTO_IPCOMP = 108;

/// SCTP
pub const IPPROTO_SCTP = 132;

/// IPv6 Mobility Header
pub const IPPROTO_MH = 135;

/// UDP-Lite
pub const IPPROTO_UDPLITE = 136;

/// IP6 Host Identity Protocol
pub const IPPROTO_HIP = 139;

/// IP6 Shim6 Protocol
pub const IPPROTO_SHIM6 = 140;

/// Protocol Independent Mcast
pub const IPPROTO_PIM = 103;

/// CARP
pub const IPPROTO_CARP = 112;

/// PGM
pub const IPPROTO_PGM = 113;

/// MPLS-in-IP
pub const IPPROTO_MPLS = 137;

/// PFSYNC
pub const IPPROTO_PFSYNC = 240;

/// Reserved
pub const IPPROTO_RESERVED_253 = 253;

/// Reserved
pub const IPPROTO_RESERVED_254 = 254;

pub const rlimit_resource = enum(c_int) {
    CPU = 0,
    FSIZE = 1,
    DATA = 2,
    STACK = 3,
    CORE = 4,
    RSS = 5,
    MEMLOCK = 6,
    NPROC = 7,
    NOFILE = 8,
    SBSIZE = 9,
    VMEM = 10,
    NPTS = 11,
    SWAP = 12,
    KQUEUES = 13,
    UMTXP = 14,
    _,

    pub const AS: rlimit_resource = .VMEM;
};

pub const rlim_t = i64;

/// No limit
pub const RLIM_INFINITY: rlim_t = (1 << 63) - 1;

pub const RLIM_SAVED_MAX = RLIM_INFINITY;
pub const RLIM_SAVED_CUR = RLIM_INFINITY;

pub const rlimit = extern struct {
    /// Soft limit
    cur: rlim_t,
    /// Hard limit
    max: rlim_t,
};

pub const SHUT_RD = 0;
pub const SHUT_WR = 1;
pub const SHUT_RDWR = 2;

// TODO fill out if needed
pub const directory_which = enum(c_int) {
    B_USER_SETTINGS_DIRECTORY = 0xbbe,

    _,
};

pub const cc_t = u8;
pub const speed_t = u8;
pub const tcflag_t = u32;

pub const NCCS = 32;

pub const termios = extern struct {
    c_iflag: tcflag_t,
    c_oflag: tcflag_t,
    c_cflag: tcflag_t,
    c_lflag: tcflag_t,
    c_line: cc_t,
    c_ispeed: speed_t,
    c_ospeed: speed_t,
    cc_t: [NCCS]cc_t,
};
