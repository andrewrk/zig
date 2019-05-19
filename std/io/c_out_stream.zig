const std = @import("../std.zig");
const OutStream = std.io.OutStream;
const builtin = @import("builtin");
const posix = std.os.posix;

/// TODO make std.os.FILE use *FILE when linking libc and this just becomes
/// std.io.FileOutStream because std.os.File.write would do this when linking
/// libc.
pub const COutStream = struct {

    c_file: *std.c.FILE,

    pub fn init(c_file: *std.c.FILE) COutStream {
        return COutStream{
            .c_file = c_file,
        };
    }
    
    pub const WriteError = std.os.File.WriteError;

    fn writeFn(self: *COutStream, bytes: []const u8) WriteError!void {
        const amt_written = std.c.fwrite(bytes.ptr, 1, bytes.len, self.c_file);
        if (amt_written == bytes.len) return;
        // TODO errno on windows. should we have a posix layer for windows?
        if (builtin.os == .windows) {
            return error.InputOutput;
        }
        const errno = std.c._errno().*;
        switch (errno) {
            0 => unreachable,
            posix.EINVAL => unreachable,
            posix.EFAULT => unreachable,
            posix.EAGAIN => unreachable, // this is a blocking API
            posix.EBADF => unreachable, // always a race condition
            posix.EDESTADDRREQ => unreachable, // connect was never called
            posix.EDQUOT => return error.DiskQuota,
            posix.EFBIG => return error.FileTooBig,
            posix.EIO => return error.InputOutput,
            posix.ENOSPC => return error.NoSpaceLeft,
            posix.EPERM => return error.AccessDenied,
            posix.EPIPE => return error.BrokenPipe,
            else => return std.os.unexpectedErrorPosix(@intCast(usize, errno)),
        }
    }
    
    const OutStreamImpl = OutStream(*COutStream, @typeOf(writeFn));
    pub fn outStream(self: *COutStream) OutStreamImpl {
        return OutStreamImpl {
            .impl = self,
            .writeFn = writeFn,
        };
    }
};
