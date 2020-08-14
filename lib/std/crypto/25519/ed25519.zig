const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Sha512 = std.crypto.Sha512;

/// Ed25519 (EdDSA) signatures.
pub const Ed25519 = struct {
    /// The underlying elliptic curve.
    pub const Curve = @import("edwards25519.zig").Edwards25519;
    /// Length (in bytes) of a seed required to create a key pair.
    pub const seed_length = 32;
    /// Length (in bytes) of a compressed key pair.
    pub const keypair_length = 64;
    /// Length (in bytes) of a compressed public key.
    pub const public_length = 32;
    /// Length (in bytes) of a signature.
    pub const signature_length = 64;
    /// Length (in bytes) of optional random bytes, for non-deterministic signatures.
    pub const noise_length = 32;

    /// Derive a key pair from a secret seed.
    pub fn createKeyPair(seed: [seed_length]u8) ![keypair_length]u8 {
        var az: [Sha512.digest_length]u8 = undefined;
        var h = Sha512.init();
        h.update(&seed);
        h.final(&az);
        const p = try Curve.basePoint().clampedMul(az[0..32].*);
        var keypair: [keypair_length]u8 = undefined;
        mem.copy(u8, &keypair, &seed);
        mem.copy(u8, keypair[seed_length..], &p.toBytes());
        return keypair;
    }

    /// Return the public key for a given key pair.
    pub fn publicKey(key_pair: [keypair_length]u8) [public_length]u8 {
        var public_key: [public_length]u8 = undefined;
        mem.copy(u8, public_key[0..], key_pair[seed_length..]);
        return public_key;
    }

    /// Sign a message using a key pair, and optional random noise.
    /// Having noise creates non-standard, non-deterministic signatures,
    /// but has been proven to increase resilience against fault attacks.
    pub fn sign(msg: []const u8, key_pair: [keypair_length]u8, noise: ?[noise_length]u8) ![signature_length]u8 {
        const public_key = key_pair[32..];
        var az: [Sha512.digest_length]u8 = undefined;
        var h = Sha512.init();
        h.update(key_pair[0..seed_length]);
        h.final(&az);

        h = Sha512.init();
        if (noise) |*z| {
            h.update(z);
        }
        h.update(az[32..]);
        h.update(msg);
        var nonce64: [64]u8 = undefined;
        h.final(&nonce64);
        const nonce = Curve.scalar.reduce64(nonce64);
        const r = try Curve.basePoint().mul(nonce);

        var sig: [signature_length]u8 = undefined;
        mem.copy(u8, sig[0..32], &r.toBytes());
        mem.copy(u8, sig[32..], public_key);
        h = Sha512.init();
        h.update(&sig);
        h.update(msg);
        var hram64: [Sha512.digest_length]u8 = undefined;
        h.final(&hram64);
        const hram = Curve.scalar.reduce64(hram64);

        var x = az[0..32];
        Curve.scalar.clamp(x);
        const s = Curve.scalar.mulAdd(hram, x.*, nonce);
        mem.copy(u8, sig[32..], s[0..]);
        return sig;
    }

    /// Verify an Ed25519 signature given a message and a public key.
    /// Returns error.InvalidSignature is the signature verification failed.
    pub fn verify(sig: [signature_length]u8, msg: []const u8, public_key: [public_length]u8) !void {
        const r = sig[0..32];
        const s = sig[32..64];
        try Curve.scalar.rejectNonCanonical(s.*);
        try Curve.rejectNonCanonical(public_key);
        const a = try Curve.fromBytes(public_key);
        try a.rejectIdentity();

        var h = Sha512.init();
        h.update(r);
        h.update(&public_key);
        h.update(msg);
        var hram64: [Sha512.digest_length]u8 = undefined;
        h.final(&hram64);
        const hram = Curve.scalar.reduce64(hram64);

        const p = try a.neg().mul(hram);
        const check = (try Curve.basePoint().mul(s.*)).add(p).toBytes();
        if (mem.timingSafeEqual(u8, &check, r) == false) {
            return error.InvalidSignature;
        }
    }
};

test "ed25519 key pair creation" {
    var seed: [32]u8 = undefined;
    try fmt.hexToBytes(seed[0..], "8052030376d47112be7f73ed7a019293dd12ad910b654455798b4667d73de166");
    const key_pair = try Ed25519.createKeyPair(seed);
    var buf: [256]u8 = undefined;
    const alloc = &std.heap.FixedBufferAllocator.init(&buf).allocator;
    std.testing.expectEqualStrings(try std.fmt.allocPrint(alloc, "{X}", .{key_pair}), "8052030376D47112BE7F73ED7A019293DD12AD910B654455798B4667D73DE1662D6F7455D97B4A3A10D7293909D1A4F2058CB9A370E43FA8154BB280DB839083");

    const public_key = Ed25519.publicKey(key_pair);
    std.testing.expectEqualStrings(try std.fmt.allocPrint(alloc, "{X}", .{public_key}), "2D6F7455D97B4A3A10D7293909D1A4F2058CB9A370E43FA8154BB280DB839083");
}

test "ed25519 signature" {
    var seed: [32]u8 = undefined;
    try fmt.hexToBytes(seed[0..], "8052030376d47112be7f73ed7a019293dd12ad910b654455798b4667d73de166");
    const key_pair = try Ed25519.createKeyPair(seed);

    const sig = try Ed25519.sign("test", key_pair, null);
    var buf: [128]u8 = undefined;
    const alloc = &std.heap.FixedBufferAllocator.init(&buf).allocator;
    std.testing.expectEqualStrings(try std.fmt.allocPrint(alloc, "{X}", .{sig}), "10A442B4A80CC4225B154F43BEF28D2472CA80221951262EB8E0DF9091575E2687CC486E77263C3418C757522D54F84B0359236ABBBD4ACD20DC297FDCA66808");
    const public_key = Ed25519.publicKey(key_pair);
    try Ed25519.verify(sig, "test", public_key);
    std.testing.expectError(error.InvalidSignature, Ed25519.verify(sig, "TEST", public_key));
}
