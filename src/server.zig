//! Handles the connection between the server (this)
//! and its peer (client). Initially, it performs a handshake,
//! which if succesful will send all data encrypted to the client.
const std = @import("std");
const tls = @import("tls.zig");
const handshake = @import("handshake.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const crypto = std.crypto;
const Sha256 = crypto.hash.sha2.Sha256;
const HkdfSha256 = crypto.kdf.hkdf.HkdfSha256;
const Curve25519 = crypto.ecc.Curve25519;

/// Server is a data object, containing the
/// private and public key for the TLS 1.3 connection.
///
/// This construct can then be used to connect to new clients.
pub const Server = struct {
    private_key: []const u8,
    public_key: []const u8,
    gpa: *Allocator,

    const Error = error{
        /// We expected a certain message from the client,
        /// but instead received a different one.
        UnexpectedMessage,
        /// The client does not support TLS 1.3
        UnsupportedVersion,
        /// When the named groups supported by the client,
        /// or part of the given key_share are not supported by
        /// the server.
        UnsupportedNamedGroup,
        /// None of the cipher suites provided by the client are
        /// currently supported by the server.
        UnsupportedCipherSuite,
        /// The signate algorithms provided by the client
        /// are not supported by the server.
        UnsupportedSignatureAlgorithm,
        /// The client has sent a record whose length exceeds 2^14-1 bytes
        IllegalLength,
        /// Client has sent an unexpected record type
        UnexpectedRecordType,
        /// Host ran out of memory
        OutOfMemory,
    } || crypto.errors.IdentityElementError;

    /// Initializes a new `Server` instance for a given public/private key pair.
    pub fn init(gpa: *Allocator, private_key: []const u8, public_key: []const u8) Server {
        return .{ .gpa = gpa, .private_key = private_key, .public_key = public_key };
    }

    /// Connects the server with a new client and performs its handshake.
    /// After succesfull handshake, a new reader and writer are returned which
    /// automatically decrypt, and encrypt the data before reading/writing.
    pub fn connect(
        self: Server,
        /// Reader 'interface' to the client's connection
        reader: anytype,
        /// Writer 'interface' to the client's connection
        writer: anytype,
    ) (handshake.ReadWriteError(@TypeOf(reader), (@TypeOf(writer))) || Error)!void {
        var hasher = Sha256.init(.{});
        var handshake_reader = handshake.handshakeReader(reader, hasher);
        var handshake_writer = handshake.handshakeWriter(writer, hasher);

        var client_key_share: tls.KeyShare = undefined;
        var server_key_share: tls.KeyShare = undefined;
        var signature: tls.SignatureAlgorithm = undefined;
        var server_exchange: tls.KeyExchange = undefined;

        const record = try tls.Record.readFrom(reader);
        if (record.len > 1 << 14) {
            try writeAlert(.fatal, .record_overflow, writer);
            return error.IllegalLength;
        }
        if (record.record_type != .handshake) {
            try writeAlert(.fatal, .unexpected_message, writer);
            return error.UnexpectedRecordType;
        }

        // A client requested to connect with the server,
        // verify a client hello message.
        //
        // We're using a while loop here as we may send a HelloRetryRequest
        // in which the client will send a new helloClient.
        // When a succesful hello reply was sent, we continue the regular path.
        while (true) {
            const hello_result = try handshake_reader.decode();
            switch (hello_result) {
                .client_hello => |client_result| {
                    const suite = for (client_result.cipher_suites) |suite| {
                        if (tls.supported_cipher_suites.isSupported(suite)) {
                            break suite;
                        }
                    } else {
                        try writeAlert(.fatal, .handshake_failure, writer);
                        return error.UnsupportedCipherSuite;
                    };

                    var version_verified = false;
                    var chosen_signature: ?tls.SignatureAlgorithm = null;
                    var chosen_group: ?tls.NamedGroup = null;
                    var key_share: ?tls.KeyShare = null;

                    var it = tls.Extension.Iterator.init(client_result.extensions);
                    loop: while (true) {
                        it_loop: while (it.next(self.gpa)) |maybe_extension| {
                            const extension = maybe_extension orelse break :loop; // reached end of iterator so break out of outer loop
                            switch (extension) {
                                .supported_versions => |versions| for (versions) |version| {
                                    // Check for TLS 1.3, when found continue
                                    // else we return an error.
                                    if (version == 0x0304) {
                                        version_verified = true;
                                        continue :it_loop;
                                    }
                                } else return error.UnsupportedVersion,
                                .supported_groups => |groups| for (groups) |group| {
                                    if (tls.supported_named_groups.isSupported(group)) {
                                        chosen_group = group;
                                        continue :it_loop;
                                    }
                                },
                                .signature_algorithms => |algs| for (algs) |alg| {
                                    if (tls.supported_signature_algorithms.isSupported(alg)) {
                                        chosen_signature = alg;
                                        continue :it_loop;
                                    }
                                },
                                .key_share => |keys| {
                                    defer self.gpa.free(keys);
                                    for (keys) |key| {
                                        if (tls.supported_named_groups.isSupported(key.named_group)) {
                                            key_share = .{
                                                .named_group = key.named_group,
                                                .key_exchange = key.key_exchange,
                                            };
                                            continue :it_loop;
                                        }
                                    }
                                },
                                else => {},
                            }
                        } else |err| switch (err) {
                            error.UnsupportedExtension => {
                                // try writeAlert(.warning, .unsupported_extension, writer);
                                // unsupported extensions are a warning, we do not need to support
                                // them all. Simply continue the loop when we find one.
                                continue :loop;
                            },
                            else => |e| return e,
                        }
                    }

                    if (!version_verified) {
                        try writeAlert(.fatal, .protocol_version, writer);
                        return error.UnsupportedVersion;
                    }

                    client_key_share = key_share orelse {
                        try writeAlert(.fatal, .handshake_failure, writer);
                        return error.UnsupportedNamedGroup;
                    };

                    signature = chosen_signature orelse {
                        try writeAlert(.fatal, .handshake_failure, writer);
                        return error.UnsupportedSignatureAlgorithm;
                    };

                    server_key_share = blk: {
                        const group = chosen_group orelse {
                            try writeAlert(.fatal, .handshake_failure, writer);
                            return error.UnsupportedNamedGroup;
                        };

                        server_exchange = try tls.KeyExchange.fromCurve(tls.curves.x25519);
                        break :blk tls.KeyShare{
                            .named_group = group,
                            .key_exchange = server_exchange.public_key,
                        };
                    };

                    // Non-hashed write to send the record header with length
                    // 122 bytes.
                    // TODO: Not hardcore the length
                    try (tls.Record.init(.handshake, 0x007a)).writeTo(writer);

                    // hash and write the server hello
                    try handshake_writer.serverHello(
                        .server_hello,
                        client_result.session_id,
                        suite,
                        server_key_share,
                    );

                    // We sent our hello server, meaning we can continue
                    // the regular path.
                    break;
                },
                // else => return error.UnexpectedMessage,
            }
        }

        // generate handshake key, which is constructed by multiplying
        // the client's public key with the server's private key using the negotiated
        // named group.
        const curve = std.crypto.ecc.Curve25519.fromBytes(client_key_share.key_exchange);
        const shared_key = try curve.clampedMul(server_exchange.private_key);

        // Calculate the handshake keys
        // Since we do not yet support PSK resumation,
        // we first build an early secret which we use to
        // expand our keys later on.
        var empty_hash: [32]u8 = undefined;
        const early_secret = HkdfSha256.extract("", &[_]u8{0} ** 32);
        Sha256.hash("", &empty_hash, .{});
        const derived_secret = tls.hkdfExpandLabel(early_secret, "derived", &empty_hash, 32);
        const handshake_secret = HkdfSha256.extract(&derived_secret, &shared_key.toBytes());

        const current_hash: [32]u8 = blk: {
            var temp_hasher = hasher;
            var buf: [32]u8 = undefined;
            temp_hasher.final(&buf);
            break :blk buf;
        };
        const client_secret = tls.hkdfExpandLabel(handshake_secret, "c hs traffic", &current_hash, 32);
        const server_secret = tls.hkdfExpandLabel(handshake_secret, "s hs traffic", &current_hash, 32);

        const client_handshake_key = tls.hkdfExpandLabel(client_secret, "key", "", 16);
        const server_handshake_key = tls.hkdfExpandLabel(server_secret, "key", "", 16);

        const client_handshake_iv = blk: {
            var buf: [32]u8 = undefined;
            std.mem.copy(u8, &buf, &client_secret);
            break :blk tls.hkdfExpandLabel(buf, "iv", "", 12);
        };

        const server_handshake_iv = blk: {
            var buf: [32]u8 = undefined;
            std.mem.copy(u8, &buf, &server_secret);
            break :blk tls.hkdfExpandLabel(buf, "iv", "", 12);
        };

        _ = client_handshake_iv;
        _ = server_handshake_iv;
        _ = client_handshake_key;
        _ = server_handshake_key;

        // -- Write the encrypted message that wraps multiple handshake headers -- //
        try handshake_writer.handshakeFinish();
    }

    /// Constructs an alert record and writes it to the client's connection.
    /// When an alert is fatal, it is illegal to write any more data to the `writer`.
    fn writeAlert(severity: tls.AlertLevel, alert: tls.Alert, writer: anytype) @TypeOf(writer).Error!void {
        const record = tls.Record.init(.alert, 2); // 2 bytes for level and description.
        try record.writeTo(writer);
        try writer.writeAll(&.{ severity.int(), alert.int() });
    }
};

test "Shared key generation" {
    const client_public_key: [32]u8 = .{
        0x35, 0x80, 0x72, 0xd6, 0x36, 0x58, 0x80, 0xd1,
        0xae, 0xea, 0x32, 0x9a, 0xdf, 0x91, 0x21, 0x38,
        0x38, 0x51, 0xed, 0x21, 0xa2, 0x8e, 0x3b, 0x75,
        0xe9, 0x65, 0xd0, 0xd2, 0xcd, 0x16, 0x62, 0x54,
    };
    const server_private_key: [32]u8 = .{
        0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
        0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
        0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf,
    };
    const curve = Curve25519.fromBytes(client_public_key);
    const shared = try curve.clampedMul(server_private_key);

    try std.testing.expectEqualSlices(u8, &.{
        0xdf, 0x4a, 0x29, 0x1b, 0xaa, 0x1e, 0xb7,
        0xcf, 0xa6, 0x93, 0x4b, 0x29, 0xb4, 0x74,
        0xba, 0xad, 0x26, 0x97, 0xe2, 0x9f, 0x1f,
        0x92, 0x0d, 0xcc, 0x77, 0xc8, 0xa0, 0xa0,
        0x88, 0x44, 0x76, 0x24,
    }, &shared.toBytes());
}

// Uses example data from https://tls13.ulfheim.net/ to verify
// its output
test "Handshake keys calculation" {
    const hello_hash: [32]u8 = [_]u8{
        0xda, 0x75, 0xce, 0x11, 0x39, 0xac, 0x80, 0xda,
        0xe4, 0x04, 0x4d, 0xa9, 0x32, 0x35, 0x0c, 0xf6,
        0x5c, 0x97, 0xcc, 0xc9, 0xe3, 0x3f, 0x1e, 0x6f,
        0x7d, 0x2d, 0x4b, 0x18, 0xb7, 0x36, 0xff, 0xd5,
    };
    const shared_secret: [32]u8 = [_]u8{
        0xdf, 0x4a, 0x29, 0x1b, 0xaa, 0x1e, 0xb7, 0xcf,
        0xa6, 0x93, 0x4b, 0x29, 0xb4, 0x74, 0xba, 0xad,
        0x26, 0x97, 0xe2, 0x9f, 0x1f, 0x92, 0x0d, 0xcc,
        0x77, 0xc8, 0xa0, 0xa0, 0x88, 0x44, 0x76, 0x24,
    };
    const early_secret = HkdfSha256.extract(&.{}, &[_]u8{0} ** 32);
    var empty_hash: [32]u8 = undefined;
    Sha256.hash("", &empty_hash, .{});
    const derived_secret = tls.hkdfExpandLabel(early_secret, "derived", &empty_hash, 32);
    try std.testing.expectEqualSlices(u8, &.{
        0x6f, 0x26, 0x15, 0xa1, 0x08, 0xc7, 0x02,
        0xc5, 0x67, 0x8f, 0x54, 0xfc, 0x9d, 0xba,
        0xb6, 0x97, 0x16, 0xc0, 0x76, 0x18, 0x9c,
        0x48, 0x25, 0x0c, 0xeb, 0xea, 0xc3, 0x57,
        0x6c, 0x36, 0x11, 0xba,
    }, &derived_secret);

    const handshake_secret = HkdfSha256.extract(&derived_secret, &shared_secret);
    try std.testing.expectEqualSlices(u8, &.{
        0xfb, 0x9f, 0xc8, 0x06, 0x89, 0xb3, 0xa5, 0xd0,
        0x2c, 0x33, 0x24, 0x3b, 0xf6, 0x9a, 0x1b, 0x1b,
        0x20, 0x70, 0x55, 0x88, 0xa7, 0x94, 0x30, 0x4a,
        0x6e, 0x71, 0x20, 0x15, 0x5e, 0xdf, 0x14, 0x9a,
    }, &handshake_secret);

    const client_secret = tls.hkdfExpandLabel(handshake_secret, "c hs traffic", &hello_hash, 32);
    const server_secret = tls.hkdfExpandLabel(handshake_secret, "s hs traffic", &hello_hash, 32);

    try std.testing.expectEqualSlices(u8, &.{
        0xff, 0x0e, 0x5b, 0x96, 0x52, 0x91, 0xc6, 0x08,
        0xc1, 0xe8, 0xcd, 0x26, 0x7e, 0xef, 0xc0, 0xaf,
        0xcc, 0x5e, 0x98, 0xa2, 0x78, 0x63, 0x73, 0xf0,
        0xdb, 0x47, 0xb0, 0x47, 0x86, 0xd7, 0x2a, 0xea,
    }, &client_secret);
    try std.testing.expectEqualSlices(u8, &.{
        0xa2, 0x06, 0x72, 0x65, 0xe7, 0xf0, 0x65, 0x2a,
        0x92, 0x3d, 0x5d, 0x72, 0xab, 0x04, 0x67, 0xc4,
        0x61, 0x32, 0xee, 0xb9, 0x68, 0xb6, 0xa3, 0x2d,
        0x31, 0x1c, 0x80, 0x58, 0x68, 0x54, 0x88, 0x14,
    }, &server_secret);

    const client_handshake_key = tls.hkdfExpandLabel(client_secret, "key", "", 16);
    const server_handshake_key = tls.hkdfExpandLabel(server_secret, "key", "", 16);

    try std.testing.expectEqualSlices(u8, &.{
        0x71, 0x54, 0xf3, 0x14, 0xe6, 0xbe, 0x7d, 0xc0,
        0x08, 0xdf, 0x2c, 0x83, 0x2b, 0xaa, 0x1d, 0x39,
    }, &client_handshake_key);
    try std.testing.expectEqualSlices(u8, &.{
        0x84, 0x47, 0x80, 0xa7, 0xac, 0xad, 0x9f, 0x98,
        0x0f, 0xa2, 0x5c, 0x11, 0x4e, 0x43, 0x40, 0x2a,
    }, &server_handshake_key);

    var temp: [32]u8 = undefined;
    std.mem.copy(u8, &temp, &client_secret);
    const client_handshake_iv = tls.hkdfExpandLabel(temp, "iv", "", 12);

    try std.testing.expectEqualSlices(u8, &.{
        0x71, 0xab, 0xc2, 0xca, 0xe4, 0xc6, 0x99, 0xd4, 0x7c, 0x60, 0x02, 0x68,
    }, &client_handshake_iv);

    std.mem.copy(u8, &temp, &server_secret);
    const server_handshake_iv = tls.hkdfExpandLabel(temp, "iv", "", 12);

    try std.testing.expectEqualSlices(u8, &.{
        0x4c, 0x04, 0x2d, 0xdc, 0x12, 0x0a, 0x38, 0xd1, 0x41, 0x7f, 0xc8, 0x15,
    }, &server_handshake_iv);
}

test "Encrypt initial wrapper" {
    const server_handshake_key: [16]u8 = .{
        0x84, 0x47, 0x80, 0xa7, 0xac, 0xad, 0x9f, 0x98,
        0x0f, 0xa2, 0x5c, 0x11, 0x4e, 0x43, 0x40, 0x2a,
    };

    const server_iv: [12]u8 = .{
        0x4c, 0x04, 0x2d, 0xdc, 0x12, 0x0a, 0x38, 0xd1, 0x41, 0x7f, 0xc8, 0x15,
    };

    const encrypted_extensions = [_]u8{
        0x08, 0x00, 0x00, 0x02,
        0x00, 0x00,
    };

    const certificate_bytes = [_]u8{
        0x0b, 0x00, 0x03, 0x2e, 0x00, 0x00, 0x03, 0x2a, 0x00, 0x03, 0x25, 0x30, 0x82, 0x03, 0x21, 0x30,
        0x82, 0x02, 0x09, 0xa0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x08, 0x15, 0x5a, 0x92, 0xad, 0xc2, 0x04,
        0x8f, 0x90, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b, 0x05,
        0x00, 0x30, 0x22, 0x31, 0x0b, 0x30, 0x09, 0x06, 0x03, 0x55, 0x04, 0x06, 0x13, 0x02, 0x55, 0x53,
        0x31, 0x13, 0x30, 0x11, 0x06, 0x03, 0x55, 0x04, 0x0a, 0x13, 0x0a, 0x45, 0x78, 0x61, 0x6d, 0x70,
        0x6c, 0x65, 0x20, 0x43, 0x41, 0x30, 0x1e, 0x17, 0x0d, 0x31, 0x38, 0x31, 0x30, 0x30, 0x35, 0x30,
        0x31, 0x33, 0x38, 0x31, 0x37, 0x5a, 0x17, 0x0d, 0x31, 0x39, 0x31, 0x30, 0x30, 0x35, 0x30, 0x31,
        0x33, 0x38, 0x31, 0x37, 0x5a, 0x30, 0x2b, 0x31, 0x0b, 0x30, 0x09, 0x06, 0x03, 0x55, 0x04, 0x06,
        0x13, 0x02, 0x55, 0x53, 0x31, 0x1c, 0x30, 0x1a, 0x06, 0x03, 0x55, 0x04, 0x03, 0x13, 0x13, 0x65,
        0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x75, 0x6c, 0x66, 0x68, 0x65, 0x69, 0x6d, 0x2e, 0x6e,
        0x65, 0x74, 0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d,
        0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00, 0x30, 0x82, 0x01, 0x0a, 0x02, 0x82,
        0x01, 0x01, 0x00, 0xc4, 0x80, 0x36, 0x06, 0xba, 0xe7, 0x47, 0x6b, 0x08, 0x94, 0x04, 0xec, 0xa7,
        0xb6, 0x91, 0x04, 0x3f, 0xf7, 0x92, 0xbc, 0x19, 0xee, 0xfb, 0x7d, 0x74, 0xd7, 0xa8, 0x0d, 0x00,
        0x1e, 0x7b, 0x4b, 0x3a, 0x4a, 0xe6, 0x0f, 0xe8, 0xc0, 0x71, 0xfc, 0x73, 0xe7, 0x02, 0x4c, 0x0d,
        0xbc, 0xf4, 0xbd, 0xd1, 0x1d, 0x39, 0x6b, 0xba, 0x70, 0x46, 0x4a, 0x13, 0xe9, 0x4a, 0xf8, 0x3d,
        0xf3, 0xe1, 0x09, 0x59, 0x54, 0x7b, 0xc9, 0x55, 0xfb, 0x41, 0x2d, 0xa3, 0x76, 0x52, 0x11, 0xe1,
        0xf3, 0xdc, 0x77, 0x6c, 0xaa, 0x53, 0x37, 0x6e, 0xca, 0x3a, 0xec, 0xbe, 0xc3, 0xaa, 0xb7, 0x3b,
        0x31, 0xd5, 0x6c, 0xb6, 0x52, 0x9c, 0x80, 0x98, 0xbc, 0xc9, 0xe0, 0x28, 0x18, 0xe2, 0x0b, 0xf7,
        0xf8, 0xa0, 0x3a, 0xfd, 0x17, 0x04, 0x50, 0x9e, 0xce, 0x79, 0xbd, 0x9f, 0x39, 0xf1, 0xea, 0x69,
        0xec, 0x47, 0x97, 0x2e, 0x83, 0x0f, 0xb5, 0xca, 0x95, 0xde, 0x95, 0xa1, 0xe6, 0x04, 0x22, 0xd5,
        0xee, 0xbe, 0x52, 0x79, 0x54, 0xa1, 0xe7, 0xbf, 0x8a, 0x86, 0xf6, 0x46, 0x6d, 0x0d, 0x9f, 0x16,
        0x95, 0x1a, 0x4c, 0xf7, 0xa0, 0x46, 0x92, 0x59, 0x5c, 0x13, 0x52, 0xf2, 0x54, 0x9e, 0x5a, 0xfb,
        0x4e, 0xbf, 0xd7, 0x7a, 0x37, 0x95, 0x01, 0x44, 0xe4, 0xc0, 0x26, 0x87, 0x4c, 0x65, 0x3e, 0x40,
        0x7d, 0x7d, 0x23, 0x07, 0x44, 0x01, 0xf4, 0x84, 0xff, 0xd0, 0x8f, 0x7a, 0x1f, 0xa0, 0x52, 0x10,
        0xd1, 0xf4, 0xf0, 0xd5, 0xce, 0x79, 0x70, 0x29, 0x32, 0xe2, 0xca, 0xbe, 0x70, 0x1f, 0xdf, 0xad,
        0x6b, 0x4b, 0xb7, 0x11, 0x01, 0xf4, 0x4b, 0xad, 0x66, 0x6a, 0x11, 0x13, 0x0f, 0xe2, 0xee, 0x82,
        0x9e, 0x4d, 0x02, 0x9d, 0xc9, 0x1c, 0xdd, 0x67, 0x16, 0xdb, 0xb9, 0x06, 0x18, 0x86, 0xed, 0xc1,
        0xba, 0x94, 0x21, 0x02, 0x03, 0x01, 0x00, 0x01, 0xa3, 0x52, 0x30, 0x50, 0x30, 0x0e, 0x06, 0x03,
        0x55, 0x1d, 0x0f, 0x01, 0x01, 0xff, 0x04, 0x04, 0x03, 0x02, 0x05, 0xa0, 0x30, 0x1d, 0x06, 0x03,
        0x55, 0x1d, 0x25, 0x04, 0x16, 0x30, 0x14, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03,
        0x02, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01, 0x30, 0x1f, 0x06, 0x03, 0x55,
        0x1d, 0x23, 0x04, 0x18, 0x30, 0x16, 0x80, 0x14, 0x89, 0x4f, 0xde, 0x5b, 0xcc, 0x69, 0xe2, 0x52,
        0xcf, 0x3e, 0xa3, 0x00, 0xdf, 0xb1, 0x97, 0xb8, 0x1d, 0xe1, 0xc1, 0x46, 0x30, 0x0d, 0x06, 0x09,
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b, 0x05, 0x00, 0x03, 0x82, 0x01, 0x01, 0x00,
        0x59, 0x16, 0x45, 0xa6, 0x9a, 0x2e, 0x37, 0x79, 0xe4, 0xf6, 0xdd, 0x27, 0x1a, 0xba, 0x1c, 0x0b,
        0xfd, 0x6c, 0xd7, 0x55, 0x99, 0xb5, 0xe7, 0xc3, 0x6e, 0x53, 0x3e, 0xff, 0x36, 0x59, 0x08, 0x43,
        0x24, 0xc9, 0xe7, 0xa5, 0x04, 0x07, 0x9d, 0x39, 0xe0, 0xd4, 0x29, 0x87, 0xff, 0xe3, 0xeb, 0xdd,
        0x09, 0xc1, 0xcf, 0x1d, 0x91, 0x44, 0x55, 0x87, 0x0b, 0x57, 0x1d, 0xd1, 0x9b, 0xdf, 0x1d, 0x24,
        0xf8, 0xbb, 0x9a, 0x11, 0xfe, 0x80, 0xfd, 0x59, 0x2b, 0xa0, 0x39, 0x8c, 0xde, 0x11, 0xe2, 0x65,
        0x1e, 0x61, 0x8c, 0xe5, 0x98, 0xfa, 0x96, 0xe5, 0x37, 0x2e, 0xef, 0x3d, 0x24, 0x8a, 0xfd, 0xe1,
        0x74, 0x63, 0xeb, 0xbf, 0xab, 0xb8, 0xe4, 0xd1, 0xab, 0x50, 0x2a, 0x54, 0xec, 0x00, 0x64, 0xe9,
        0x2f, 0x78, 0x19, 0x66, 0x0d, 0x3f, 0x27, 0xcf, 0x20, 0x9e, 0x66, 0x7f, 0xce, 0x5a, 0xe2, 0xe4,
        0xac, 0x99, 0xc7, 0xc9, 0x38, 0x18, 0xf8, 0xb2, 0x51, 0x07, 0x22, 0xdf, 0xed, 0x97, 0xf3, 0x2e,
        0x3e, 0x93, 0x49, 0xd4, 0xc6, 0x6c, 0x9e, 0xa6, 0x39, 0x6d, 0x74, 0x44, 0x62, 0xa0, 0x6b, 0x42,
        0xc6, 0xd5, 0xba, 0x68, 0x8e, 0xac, 0x3a, 0x01, 0x7b, 0xdd, 0xfc, 0x8e, 0x2c, 0xfc, 0xad, 0x27,
        0xcb, 0x69, 0xd3, 0xcc, 0xdc, 0xa2, 0x80, 0x41, 0x44, 0x65, 0xd3, 0xae, 0x34, 0x8c, 0xe0, 0xf3,
        0x4a, 0xb2, 0xfb, 0x9c, 0x61, 0x83, 0x71, 0x31, 0x2b, 0x19, 0x10, 0x41, 0x64, 0x1c, 0x23, 0x7f,
        0x11, 0xa5, 0xd6, 0x5c, 0x84, 0x4f, 0x04, 0x04, 0x84, 0x99, 0x38, 0x71, 0x2b, 0x95, 0x9e, 0xd6,
        0x85, 0xbc, 0x5c, 0x5d, 0xd6, 0x45, 0xed, 0x19, 0x90, 0x94, 0x73, 0x40, 0x29, 0x26, 0xdc, 0xb4,
        0x0e, 0x34, 0x69, 0xa1, 0x59, 0x41, 0xe8, 0xe2, 0xcc, 0xa8, 0x4b, 0xb6, 0x08, 0x46, 0x36, 0xa0,
        0x00, 0x00,
    };

    const server_certificate_verify = [_]u8{
        0x0f, 0x00, 0x01, 0x04, 0x08, 0x04, 0x01, 0x00, 0x17, 0xfe, 0xb5, 0x33, 0xca, 0x6d, 0x00, 0x7d,
        0x00, 0x58, 0x25, 0x79, 0x68, 0x42, 0x4b, 0xbc, 0x3a, 0xa6, 0x90, 0x9e, 0x9d, 0x49, 0x55, 0x75,
        0x76, 0xa5, 0x20, 0xe0, 0x4a, 0x5e, 0xf0, 0x5f, 0x0e, 0x86, 0xd2, 0x4f, 0xf4, 0x3f, 0x8e, 0xb8,
        0x61, 0xee, 0xf5, 0x95, 0x22, 0x8d, 0x70, 0x32, 0xaa, 0x36, 0x0f, 0x71, 0x4e, 0x66, 0x74, 0x13,
        0x92, 0x6e, 0xf4, 0xf8, 0xb5, 0x80, 0x3b, 0x69, 0xe3, 0x55, 0x19, 0xe3, 0xb2, 0x3f, 0x43, 0x73,
        0xdf, 0xac, 0x67, 0x87, 0x06, 0x6d, 0xcb, 0x47, 0x56, 0xb5, 0x45, 0x60, 0xe0, 0x88, 0x6e, 0x9b,
        0x96, 0x2c, 0x4a, 0xd2, 0x8d, 0xab, 0x26, 0xba, 0xd1, 0xab, 0xc2, 0x59, 0x16, 0xb0, 0x9a, 0xf2,
        0x86, 0x53, 0x7f, 0x68, 0x4f, 0x80, 0x8a, 0xef, 0xee, 0x73, 0x04, 0x6c, 0xb7, 0xdf, 0x0a, 0x84,
        0xfb, 0xb5, 0x96, 0x7a, 0xca, 0x13, 0x1f, 0x4b, 0x1c, 0xf3, 0x89, 0x79, 0x94, 0x03, 0xa3, 0x0c,
        0x02, 0xd2, 0x9c, 0xbd, 0xad, 0xb7, 0x25, 0x12, 0xdb, 0x9c, 0xec, 0x2e, 0x5e, 0x1d, 0x00, 0xe5,
        0x0c, 0xaf, 0xcf, 0x6f, 0x21, 0x09, 0x1e, 0xbc, 0x4f, 0x25, 0x3c, 0x5e, 0xab, 0x01, 0xa6, 0x79,
        0xba, 0xea, 0xbe, 0xed, 0xb9, 0xc9, 0x61, 0x8f, 0x66, 0x00, 0x6b, 0x82, 0x44, 0xd6, 0x62, 0x2a,
        0xaa, 0x56, 0x88, 0x7c, 0xcf, 0xc6, 0x6a, 0x0f, 0x38, 0x51, 0xdf, 0xa1, 0x3a, 0x78, 0xcf, 0xf7,
        0x99, 0x1e, 0x03, 0xcb, 0x2c, 0x3a, 0x0e, 0xd8, 0x7d, 0x73, 0x67, 0x36, 0x2e, 0xb7, 0x80, 0x5b,
        0x00, 0xb2, 0x52, 0x4f, 0xf2, 0x98, 0xa4, 0xda, 0x48, 0x7c, 0xac, 0xde, 0xaf, 0x8a, 0x23, 0x36,
        0xc5, 0x63, 0x1b, 0x3e, 0xfa, 0x93, 0x5b, 0xb4, 0x11, 0xe7, 0x53, 0xca, 0x13, 0xb0, 0x15, 0xfe,
        0xc7, 0xe4, 0xa7, 0x30, 0xf1, 0x36, 0x9f, 0x9e,
    };

    const handshake_finished = [_]u8{
        0x14, 0x00, 0x00, 0x20, 0xea, 0x6e, 0xe1, 0x76, 0xdc, 0xcc, 0x4a, 0xf1, 0x85, 0x9e, 0x9e, 0x4e,
        0x93, 0xf7, 0x97, 0xea, 0xc9, 0xa7, 0x8c, 0xe4, 0x39, 0x30, 0x1e, 0x35, 0x27, 0x5a, 0xd4, 0x3f,
        0x3c, 0xdd, 0xbd, 0xe3,
    };

    var auth_tag: [16]u8 = .{
        0xe0, 0x8b, 0x0e, 0x45, 0x5a, 0x35, 0x0a, 0xe5, 0x4d, 0x76, 0x34, 0x9a, 0xa6, 0x8c, 0x71, 0xae,
    };

    const message = encrypted_extensions ++ certificate_bytes ++ server_certificate_verify ++ handshake_finished ++ [_]u8{0x16};
    var buf: [message.len]u8 = undefined;
    crypto.aead.aes_gcm.Aes128Gcm.encrypt(&buf, &auth_tag, &message, &.{
        // record header
        0x17, 0x03, 0x03, 0x04, 0x75,
    }, server_iv, server_handshake_key);

    try std.testing.expectEqualSlices(u8, &.{
        0xda, 0x1e, 0xc2, 0xd7, 0xbd, 0xa8, 0xeb, 0xf7, 0x3e, 0xdd, 0x50, 0x10, 0xfb, 0xa8, 0x08, 0x9f,
        0xd4, 0x26, 0xb0, 0xea, 0x1e, 0xa4, 0xd8, 0x8d, 0x07, 0x4f, 0xfe, 0xa8, 0xa9, 0x87, 0x3a, 0xf5,
        0xf5, 0x02, 0x26, 0x1e, 0x34, 0xb1, 0x56, 0x33, 0x43, 0xe9, 0xbe, 0xb6, 0x13, 0x2e, 0x7e, 0x83,
        0x6d, 0x65, 0xdb, 0x6d, 0xcf, 0x00, 0xbc, 0x40, 0x19, 0x35, 0xae, 0x36, 0x9c, 0x44, 0x0d, 0x67,
        0xaf, 0x71, 0x9e, 0xc0, 0x3b, 0x98, 0x4c, 0x45, 0x21, 0xb9, 0x05, 0xd5, 0x8b, 0xa2, 0x19, 0x7c,
        0x45, 0xc4, 0xf7, 0x73, 0xbd, 0x9d, 0xd1, 0x21, 0xb4, 0xd2, 0xd4, 0xe6, 0xad, 0xff, 0xfa, 0x27,
        0xc2, 0xa8, 0x1a, 0x99, 0xa8, 0xef, 0xe8, 0x56, 0xc3, 0x5e, 0xe0, 0x8b, 0x71, 0xb3, 0xe4, 0x41,
        0xbb, 0xec, 0xaa, 0x65, 0xfe, 0x72, 0x08, 0x15, 0xca, 0xb5, 0x8d, 0xb3, 0xef, 0xa8, 0xd1, 0xe5,
        0xb7, 0x1c, 0x58, 0xe8, 0xd1, 0xfd, 0xb6, 0xb2, 0x1b, 0xfc, 0x66, 0xa9, 0x86, 0x5f, 0x85, 0x2c,
        0x1b, 0x4b, 0x64, 0x0e, 0x94, 0xbd, 0x90, 0x84, 0x69, 0xe7, 0x15, 0x1f, 0x9b, 0xbc, 0xa3, 0xce,
        0x53, 0x22, 0x4a, 0x27, 0x06, 0x2c, 0xeb, 0x24, 0x0a, 0x10, 0x5b, 0xd3, 0x13, 0x2d, 0xc1, 0x85,
        0x44, 0x47, 0x77, 0x94, 0xc3, 0x73, 0xbc, 0x0f, 0xb5, 0xa2, 0x67, 0x88, 0x5c, 0x85, 0x7d, 0x4c,
        0xcb, 0x4d, 0x31, 0x74, 0x2b, 0x7a, 0x29, 0x62, 0x40, 0x29, 0xfd, 0x05, 0x94, 0x0d, 0xe3, 0xf9,
        0xf9, 0xb6, 0xe0, 0xa9, 0xa2, 0x37, 0x67, 0x2b, 0xc6, 0x24, 0xba, 0x28, 0x93, 0xa2, 0x17, 0x09,
        0x83, 0x3c, 0x52, 0x76, 0xd4, 0x13, 0x63, 0x1b, 0xdd, 0xe6, 0xae, 0x70, 0x08, 0xc6, 0x97, 0xa8,
        0xef, 0x42, 0x8a, 0x79, 0xdb, 0xf6, 0xe8, 0xbb, 0xeb, 0x47, 0xc4, 0xe4, 0x08, 0xef, 0x65, 0x6d,
        0x9d, 0xc1, 0x9b, 0x8b, 0x5d, 0x49, 0xbc, 0x09, 0x1e, 0x21, 0x77, 0x35, 0x75, 0x94, 0xc8, 0xac,
        0xd4, 0x1c, 0x10, 0x1c, 0x77, 0x50, 0xcb, 0x11, 0xb5, 0xbe, 0x6a, 0x19, 0x4b, 0x8f, 0x87, 0x70,
        0x88, 0xc9, 0x82, 0x8e, 0x35, 0x07, 0xda, 0xda, 0x17, 0xbb, 0x14, 0xbb, 0x2c, 0x73, 0x89, 0x03,
        0xc7, 0xaa, 0xb4, 0x0c, 0x54, 0x5c, 0x46, 0xaa, 0x53, 0x82, 0x3b, 0x12, 0x01, 0x81, 0xa1, 0x6c,
        0xe9, 0x28, 0x76, 0x28, 0x8c, 0x4a, 0xcd, 0x81, 0x5b, 0x23, 0x3d, 0x96, 0xbb, 0x57, 0x2b, 0x16,
        0x2e, 0xc1, 0xb9, 0xd7, 0x12, 0xf2, 0xc3, 0x96, 0x6c, 0xaa, 0xc9, 0xcf, 0x17, 0x4f, 0x3a, 0xed,
        0xfe, 0xc4, 0xd1, 0x9f, 0xf9, 0xa8, 0x7f, 0x8e, 0x21, 0xe8, 0xe1, 0xa9, 0x78, 0x9b, 0x49, 0x0b,
        0xa0, 0x5f, 0x1d, 0xeb, 0xd2, 0x17, 0x32, 0xfb, 0x2e, 0x15, 0xa0, 0x17, 0xc4, 0x75, 0xc4, 0xfd,
        0x00, 0xbe, 0x04, 0x21, 0x86, 0xdc, 0x29, 0xe6, 0x8b, 0xb7, 0xec, 0xe1, 0x92, 0x43, 0x8f, 0x3b,
        0x0c, 0x5e, 0xf8, 0xe4, 0xa5, 0x35, 0x83, 0xa0, 0x19, 0x43, 0xcf, 0x84, 0xbb, 0xa5, 0x84, 0x21,
        0x73, 0xa6, 0xb3, 0xa7, 0x28, 0x95, 0x66, 0x68, 0x7c, 0x30, 0x18, 0xf7, 0x64, 0xab, 0x18, 0x10,
        0x31, 0x69, 0x91, 0x93, 0x28, 0x71, 0x3c, 0x3b, 0xd4, 0x63, 0xd3, 0x39, 0x8a, 0x1f, 0xeb, 0x8e,
        0x68, 0xe4, 0x4c, 0xfe, 0x48, 0x2f, 0x72, 0x84, 0x7f, 0x46, 0xc8, 0x0e, 0x6c, 0xc7, 0xf6, 0xcc,
        0xf1, 0x79, 0xf4, 0x82, 0xc8, 0x88, 0x59, 0x4e, 0x76, 0x27, 0x66, 0x53, 0xb4, 0x83, 0x98, 0xa2,
        0x6c, 0x7c, 0x9e, 0x42, 0x0c, 0xb6, 0xc1, 0xd3, 0xbc, 0x76, 0x46, 0xf3, 0x3b, 0xb8, 0x32, 0xbf,
        0xba, 0x98, 0x48, 0x9c, 0xad, 0xfb, 0xd5, 0x5d, 0xd8, 0xb2, 0xc5, 0x76, 0x87, 0xa4, 0x7a, 0xcb,
        0xa4, 0xab, 0x39, 0x01, 0x52, 0xd8, 0xfb, 0xb3, 0xf2, 0x03, 0x27, 0xd8, 0x24, 0xb2, 0x84, 0xd2,
        0x88, 0xfb, 0x01, 0x52, 0xe4, 0x9f, 0xc4, 0x46, 0x78, 0xae, 0xd4, 0xd3, 0xf0, 0x85, 0xb7, 0xc5,
        0x5d, 0xe7, 0x7b, 0xd4, 0x5a, 0xf8, 0x12, 0xfc, 0x37, 0x94, 0x4a, 0xd2, 0x45, 0x4f, 0x99, 0xfb,
        0xb3, 0x4a, 0x58, 0x3b, 0xf1, 0x6b, 0x67, 0x65, 0x9e, 0x6f, 0x21, 0x6d, 0x34, 0xb1, 0xd7, 0x9b,
        0x1b, 0x4d, 0xec, 0xc0, 0x98, 0xa4, 0x42, 0x07, 0xe1, 0xc5, 0xfe, 0xeb, 0x6c, 0xe3, 0x0a, 0xcc,
        0x2c, 0xf7, 0xe2, 0xb1, 0x34, 0x49, 0x0b, 0x44, 0x27, 0x44, 0x77, 0x2d, 0x18, 0x4e, 0x59, 0x03,
        0x8a, 0xa5, 0x17, 0xa9, 0x71, 0x54, 0x18, 0x1e, 0x4d, 0xfd, 0x94, 0xfe, 0x72, 0xa5, 0xa4, 0xca,
        0x2e, 0x7e, 0x22, 0xbc, 0xe7, 0x33, 0xd0, 0x3e, 0x7d, 0x93, 0x19, 0x71, 0x0b, 0xef, 0xbc, 0x30,
        0xd7, 0x82, 0x6b, 0x72, 0x85, 0x19, 0xba, 0x74, 0x69, 0x0e, 0x4f, 0x90, 0x65, 0x87, 0xa0, 0x38,
        0x28, 0x95, 0xb9, 0x0d, 0x82, 0xed, 0x3e, 0x35, 0x7f, 0xaf, 0x8e, 0x59, 0xac, 0xa8, 0x5f, 0xd2,
        0x06, 0x3a, 0xb5, 0x92, 0xd8, 0x3d, 0x24, 0x5a, 0x91, 0x9e, 0xa5, 0x3c, 0x50, 0x1b, 0x9a, 0xcc,
        0xd2, 0xa1, 0xed, 0x95, 0x1f, 0x43, 0xc0, 0x49, 0xab, 0x9d, 0x25, 0xc7, 0xf1, 0xb7, 0x0a, 0xe4,
        0xf9, 0x42, 0xed, 0xb1, 0xf3, 0x11, 0xf7, 0x41, 0x78, 0x33, 0x06, 0x22, 0x45, 0xb4, 0x29, 0xd4,
        0xf0, 0x13, 0xae, 0x90, 0x19, 0xff, 0x52, 0x04, 0x4c, 0x97, 0xc7, 0x3b, 0x88, 0x82, 0xcf, 0x03,
        0x95, 0x5c, 0x73, 0x9f, 0x87, 0x4a, 0x02, 0x96, 0x37, 0xc0, 0xf0, 0x60, 0x71, 0x00, 0xe3, 0x07,
        0x0f, 0x40, 0x8d, 0x08, 0x2a, 0xa7, 0xa2, 0xab, 0xf1, 0x3e, 0x73, 0xbd, 0x1e, 0x25, 0x2c, 0x22,
        0x8a, 0xba, 0x7a, 0x9c, 0x1f, 0x07, 0x5b, 0xc4, 0x39, 0x57, 0x1b, 0x35, 0x93, 0x2f, 0x5c, 0x91,
        0x2c, 0xb0, 0xb3, 0x8d, 0xa1, 0xc9, 0x5e, 0x64, 0xfc, 0xf9, 0xbf, 0xec, 0x0b, 0x9b, 0x0d, 0xd8,
        0xf0, 0x42, 0xfd, 0xf0, 0x5e, 0x50, 0x58, 0x29, 0x9e, 0x96, 0xe4, 0x18, 0x50, 0x74, 0x91, 0x9d,
        0x90, 0xb7, 0xb3, 0xb0, 0xa9, 0x7e, 0x22, 0x42, 0xca, 0x08, 0xcd, 0x99, 0xc9, 0xec, 0xb1, 0x2f,
        0xc4, 0x9a, 0xdb, 0x2b, 0x25, 0x72, 0x40, 0xcc, 0x38, 0x78, 0x02, 0xf0, 0x0e, 0x0e, 0x49, 0x95,
        0x26, 0x63, 0xea, 0x27, 0x84, 0x08, 0x70, 0x9b, 0xce, 0x5b, 0x36, 0x3c, 0x03, 0x60, 0x93, 0xd7,
        0xa0, 0x5d, 0x44, 0x0c, 0x9e, 0x7a, 0x7a, 0xbb, 0x3d, 0x71, 0xeb, 0xb4, 0xd1, 0x0b, 0xfc, 0x77,
        0x81, 0xbc, 0xd6, 0x6f, 0x79, 0x32, 0x2c, 0x18, 0x26, 0x2d, 0xfc, 0x2d, 0xcc, 0xf3, 0xe5, 0xf1,
        0xea, 0x98, 0xbe, 0xa3, 0xca, 0xae, 0x8a, 0x83, 0x70, 0x63, 0x12, 0x76, 0x44, 0x23, 0xa6, 0x92,
        0xae, 0x0c, 0x1e, 0x2e, 0x23, 0xb0, 0x16, 0x86, 0x5f, 0xfb, 0x12, 0x5b, 0x22, 0x38, 0x57, 0x54,
        0x7a, 0xc7, 0xe2, 0x46, 0x84, 0x33, 0xb5, 0x26, 0x98, 0x43, 0xab, 0xba, 0xbb, 0xe9, 0xf6, 0xf4,
        0x38, 0xd7, 0xe3, 0x87, 0xe3, 0x61, 0x7a, 0x21, 0x9f, 0x62, 0x54, 0x0e, 0x73, 0x43, 0xe1, 0xbb,
        0xf4, 0x93, 0x55, 0xfb, 0x5a, 0x19, 0x38, 0x04, 0x84, 0x39, 0xcb, 0xa5, 0xce, 0xe8, 0x19, 0x19,
        0x9b, 0x2b, 0x5c, 0x39, 0xfd, 0x35, 0x1a, 0xa2, 0x74, 0x53, 0x6a, 0xad, 0xb6, 0x82, 0xb5, 0x78,
        0x94, 0x3f, 0x0c, 0xcf, 0x48, 0xe4, 0xec, 0x7d, 0xdc, 0x93, 0x8e, 0x2f, 0xd0, 0x1a, 0xcf, 0xaa,
        0x1e, 0x72, 0x17, 0xf7, 0xb3, 0x89, 0x28, 0x5c, 0x0d, 0xfd, 0x31, 0xa1, 0x54, 0x5e, 0xd3, 0xa8,
        0x5f, 0xac, 0x8e, 0xb9, 0xda, 0xb6, 0xee, 0x82, 0x6a, 0xf9, 0x0f, 0x9e, 0x1e, 0xe5, 0xd5, 0x55,
        0xdd, 0x1c, 0x05, 0xae, 0xc0, 0x77, 0xf7, 0xc8, 0x03, 0xcb, 0xc2, 0xf1, 0xcf, 0x98, 0x39, 0x3f,
        0x0f, 0x37, 0x83, 0x8f, 0xfe, 0xa3, 0x72, 0xff, 0x70, 0x88, 0x86, 0xb0, 0x59, 0x34, 0xe1, 0xa6,
        0x45, 0x12, 0xde, 0x14, 0x46, 0x08, 0x86, 0x4a, 0x88, 0xa5, 0xc3, 0xa1, 0x73, 0xfd, 0xcf, 0xdf,
        0x57, 0x25, 0xda, 0x91, 0x6e, 0xd5, 0x07, 0xe4, 0xca, 0xec, 0x87, 0x87, 0xbe, 0xfb, 0x91, 0xe3,
        0xec, 0x9b, 0x22, 0x2f, 0xa0, 0x9f, 0x37, 0x4b, 0xd9, 0x68, 0x81, 0xac, 0x2d, 0xdd, 0x1f, 0x88,
        0x5d, 0x42, 0xea, 0x58, 0x4c,
    }, &buf);
}
