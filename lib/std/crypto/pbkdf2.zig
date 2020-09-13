// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("std");
const crypto = std.crypto;
const debug = std.debug;
const assert = debug.assert;
const mem = std.mem;

// Exports
comptime {
    _ = crypto.kdf.pbkdf2;
}

// RFC 2898 Section 5.2
//
// FromSpec:
//
// PBKDF2 applies a pseudorandom function (see Appendix B.1 for an
// example) to derive keys. The length of the derived key is essentially
// unbounded. (However, the maximum effective search space for the
// derived key may be limited by the structure of the underlying
// pseudorandom function. See Appendix B.1 for further discussion.)
// PBKDF2 is recommended for new applications.
//
// PBKDF2 (P, S, c, dkLen)
//
// Options:        PRF        underlying pseudorandom function (hLen
//                            denotes the length in octets of the
//                            pseudorandom function output)
//
// Input:          P          password, an octet string
//                 S          salt, an octet string
//                 c          iteration count, a positive integer
//                 dkLen      intended length in octets of the derived
//                            key, a positive integer, at most
//                            (2^32 - 1) * hLen
//
// Output:         DK         derived key, a dkLen-octet string

// Based on Apple's CommonKeyDerivation, based originally on code by Damien Bergamini.

/// Apply PBKDF2 to generate a key from a password.
///
/// PBKDF2 is defined in RFC 2898, and is a recommendation of NIST SP 800-132.
///
/// The length of `derivedKey` determines thesize for the generated key. Generally 16 or 32 bytes
/// in length. May be uninitialized. All bytes will be written. Maximum size is
/// `(2^32 - 1) * Hash.digest_length`.
///
/// `password` and `salt` are arbitrary sequence of bytes of any length, including empty.
///
/// `rounds` must be greater than 0.
///
/// Example with deterministic salt:
/// ```
/// // Global salt, used across system
/// const appSalt = "com.example.mygreatapp";
///
/// // Unique user id, used in salt
/// const user = "user@example.com";
///
/// // User's password.
/// const password = "password";
///
/// // Compute per-use-salt using appSalt and user identifier.
/// const salt = appSalt ++ ":" ++ user;
///
/// // Common values are between 1,000 and 100,000. Most systems target 100ms computation time.
/// const rounds = 10_000;
///
/// // Pseudo-random function. Common choice is HmacSha256
/// const prf = std.crypto.auth.hmac.sha2.HmacSha256;

/// // Stretch weak password into strong AES-256 key
/// var derivedKey: [256 / 8]u8 = undefined;
/// pbkdf2(&derivedKey, password, salt, rounds, prf);
/// ```
///
/// Example with random salt:
/// ```
/// // User's password.
/// const password = "password";
///
/// // Random salt
/// var salt: [8]u8 = undefined;
/// try std.crypto.randomBytes(&salt);
///
///  // Common values are between 1,000 and 100,000. Most systems target 100ms computation time.
/// const rounds = 10_000;
///
/// // Pseudo-random function. Common choice is HmacSha256
/// const prf = std.crypto.auth.hmac.sha2.HmacSha256;
///
/// // Stretch weak password into hash to store in database
/// var hash: [32]u8 = undefined;
/// pbkdf2(&hash, password, &salt, rounds, prf);
///
/// // Combine salt and hash in base64 to store
/// const base64 = std.base64;
/// const encoder = base64.standard_encoder;
///
/// var saltB64: [base64.Base64Encoder.calcSize(salt.len)]u8 = undefined;
/// encoder.encode(&saltB64, &salt);
///
/// var hashB64: [base64.Base64Encoder.calcSize(hash.len)]u8 = undefined;
/// encoder.encode(&hashB64, &hash);
/// 
/// const allocator = std.heap.page_allocator;
/// const output = try mem.concat(allocator, u8, &[_][]const u8{&saltB64, ":", &hashB64});
///
/// // ... Store output in database ...
///
/// allocator.free(output);
/// ```
pub fn pbkdf2(derivedKey: []u8, password: []const u8, salt: []const u8, rounds: u32, comptime Prf: type) void {
    assert(rounds >= 1);

    const dkLen: u64 = derivedKey.len;
    const hLen: u32 = Prf.mac_length; // Force type to ensure multiplications can't overflow

    // FromSpec:
    //
    //   1. If dkLen > (2^32 - 1) * hLen, output "derived key too long" and
    //      stop.
    //
    assert(dkLen > 0 and dkLen <= @as(u64, 1 << 32 - 1) * hLen);

    // FromSpec:
    //
    //   2. Let l be the number of hLen-octet blocks in the derived key,
    //      rounding up, and let r be the number of octets in the last
    //      block
    //
    const l = (dkLen + hLen - 1) / hLen;
    var r = dkLen % hLen;
    r = if (r != 0) r else hLen;

    // FromSpec:
    //
    //   3. For each block of the derived key apply the function F defined
    //      below to the password P, the salt S, the iteration count c, and
    //      the block index to compute the block:
    //
    //                T_1 = F (P, S, c, 1) ,
    //                T_2 = F (P, S, c, 2) ,
    //                ...
    //                T_l = F (P, S, c, l) ,
    //
    //      where the function F is defined as the exclusive-or sum of the
    //      first c iterates of the underlying pseudorandom function PRF
    //      applied to the password P and the concatenation of the salt S
    //      and the block index i:
    //
    //                F (P, S, c, i) = U_1 \xor U_2 \xor ... \xor U_c
    //
    //  where
    //
    //            U_1 = PRF (P, S || INT (i)) ,
    //            U_2 = PRF (P, U_1) ,
    //            ...
    //            U_c = PRF (P, U_{c-1}) .
    //
    //  Here, INT (i) is a four-octet encoding of the integer i, most
    //  significant octet first.
    //
    //  4. Concatenate the blocks and extract the first dkLen octets to
    //  produce a derived key DK:
    //
    //            DK = T_1 || T_2 ||  ...  || T_l<0..r-1>

    var block: u32 = 0; // Spec limits to u32
    while (block < l) : (block += 1) {
        var prevBlock: [hLen]u8 = undefined;
        var newBlock: [hLen]u8 = undefined;

        // U_1 = PRF (P, S || INT (i))
        const blockIndex = mem.toBytes(mem.nativeToBig(u32, block + 1)); // Block index starts at 0001
        var ctx = Prf.init(password);
        ctx.update(salt);
        ctx.update(blockIndex[0..]);
        ctx.final(prevBlock[0..]);

        // Choose portion of DK to write into (T_n) and initialize
        const offset: usize = @as(usize, block) * hLen;
        const blockLen = if (block != l - 1) hLen else r;
        var dkBlock = derivedKey[offset..(offset + blockLen)];
        mem.copy(u8, dkBlock, prevBlock[0..dkBlock.len]);

        var i: u32 = 1;
        while (i < rounds) : (i += 1) {
            // U_c = PRF (P, U_{c-1})
            Prf.create(&newBlock, prevBlock[0..], password);
            mem.copy(u8, prevBlock[0..], newBlock[0..]);

            // F (P, S, c, i) = U_1 \xor U_2 \xor ... \xor U_c
            for (dkBlock) |_, j| {
                dkBlock[j] ^= newBlock[j];
            }
        }
    }
}

const htest = @import("test.zig");

// RFC 6070 PBKDF2 HMAC-SHA1 Test Vectors
test "RFC 6070 one iteration" {
    const p = "password";
    const s = "salt";
    const c = 1;
    const dkLen = 20;

    var derivedKey: [dkLen]u8 = undefined;

    pbkdf2(&derivedKey, p, s, c, crypto.auth.hmac.HmacSha1);

    const expected = "0c60c80f961f0e71f3a9b524af6012062fe037a6";

    htest.assertEqual(expected, derivedKey[0..]);
}

test "RFC 6070 two iterations" {
    const p = "password";
    const s = "salt";
    const c = 2;
    const dkLen = 20;

    var derivedKey: [dkLen]u8 = undefined;

    pbkdf2(&derivedKey, p, s, c, crypto.auth.hmac.HmacSha1);

    const expected = "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957";

    htest.assertEqual(expected, derivedKey[0..]);
}

test "RFC 6070 4096 iterations" {
    const p = "password";
    const s = "salt";
    const c = 4096;
    const dkLen = 20;

    var derivedKey: [dkLen]u8 = undefined;

    pbkdf2(&derivedKey, p, s, c, crypto.auth.hmac.HmacSha1);

    const expected = "4b007901b765489abead49d926f721d065a429c1";

    htest.assertEqual(expected, derivedKey[0..]);
}

test "RFC 6070 16,777,216 iterations" {
    // These iteration tests are slow so we always skip them. Results have been verified.
    if (true) {
        return error.SkipZigTest;
    }

    const p = "password";
    const s = "salt";
    const c = 16777216;
    const dkLen = 20;

    var derivedKey = [_]u8{0} ** dkLen;

    pbkdf2(&derivedKey, p, s, c, crypto.auth.hmac.HmacSha1);

    const expected = "eefe3d61cd4da4e4e9945b3d6ba2158c2634e984";

    htest.assertEqual(expected, derivedKey[0..]);
}

test "RFC 6070 multi-block salt and password" {
    const p = "passwordPASSWORDpassword";
    const s = "saltSALTsaltSALTsaltSALTsaltSALTsalt";
    const c = 4096;
    const dkLen = 25;

    var derivedKey: [dkLen]u8 = undefined;

    pbkdf2(&derivedKey, p, s, c, crypto.auth.hmac.HmacSha1);

    const expected = "3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038";

    htest.assertEqual(expected, derivedKey[0..]);
}

test "RFC 6070 embedded NUL" {
    const p = "pass\x00word";
    const s = "sa\x00lt";
    const c = 4096;
    const dkLen = 16;

    var derivedKey: [dkLen]u8 = undefined;

    pbkdf2(&derivedKey, p, s, c, crypto.auth.hmac.HmacSha1);

    const expected = "56fa6aa75548099dcc37d7f03425e0c3";

    htest.assertEqual(expected, derivedKey[0..]);
}

test "Very large dkLen" {
    // This test allocates 8GB of memory and is expected to take several hours to run.
    if (true) {
        return error.SkipZigTest;
    }
    const p = "password";
    const s = "salt";
    const c = 1;
    const dkLen = 1 << 33;

    var derivedKey = try std.testing.allocator.alloc(u8, dkLen);
    defer {
        std.testing.allocator.free(derivedKey);
    }

    pbkdf2(derivedKey, p, s, c, crypto.auth.hmac.HmacSha1);
    // Just verify this doesn't crash with an overflow
}

test "" {
// Global salt, used across system
 const appSalt = "com.example.mygreatapp";

 // Unique user id, used in salt
 const user = "user@example.com";

 // User's password.
 const password = "password";

 // Compute per-use-salt using appSalt and user identifier.
 const salt = appSalt ++ ":" ++ user;

 // Common values are between 1,000 and 100,000. Most systems target 100ms computation time.
 const rounds = 10_000;

 // Pseudo-random function. Common choice is HmacSha256
 const prf = std.crypto.auth.hmac.sha2.HmacSha256;

 // Stretch weak password into strong AES-256 key
 var derivedKey: [256 / 8]u8 = undefined;
 pbkdf2(&derivedKey, password, salt, rounds, prf);

}

test "x" {

}