//! Typed decoding from a `Value` tree into native Zig types, with per-dialect coercion.
//!
//! Maps a parsed INI `Value` tree onto a target Zig struct via comptime reflection.
//! Scalars are coerced from raw strings: booleans use per-dialect truth tables;
//! integers honor gitconfig k/m/g suffixes; multi-value lists decode to slices.
//!
//! Annotations recognized on struct declarations:
//!   `ini_rename` - struct literal mapping field names to alternate INI keys
//!   `ini_skip`   - tuple of field names to exclude from decode
//!   `ini_flatten` - tuple of struct field names to merge into the parent level
//!
//! Custom hooks:
//!   `fromIni(arena, value, options) DecodeError!T` - bypasses built-in dispatch

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Section = value_mod.Section;
const Entry = value_mod.Entry;
const parser_mod = @import("parser.zig");
const ParseOptions = parser_mod.ParseOptions;
const Error = parser_mod.Error;
const Diagnostic = parser_mod.Diagnostic;
const Dialect = @import("dialect.zig").Dialect;
const ann = @import("annotations.zig");
const lev = @import("levenshtein.zig");

pub const DecodeError = error{
    TypeMismatch,
    MissingField,
    UnknownField,
    InvalidEnumValue,
    Overflow,
    OutOfMemory,
};

pub const renamedKey = ann.renamedKey;
pub const isSkipped = ann.isSkipped;
pub const isFlattened = ann.isFlattened;
pub const expectedKeys = ann.expectedKeys;

/// Coerce a raw INI string to bool per the active dialect.
///
/// gitconfig (allow_no_value): empty -> true; true/yes/on/1 -> true; false/no/off/0 -> false.
/// generic (configparser): 1/yes/true/on -> true; 0/no/false/off -> false.
/// Returns null for unrecognized input.
pub fn coerceBool(dialect: Dialect, raw: []const u8) ?bool {
    if (raw.len == 0) return if (dialect.allow_no_value) true else null;
    if (std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "on") or
        std.mem.eql(u8, raw, "1")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no") or
        std.ascii.eqlIgnoreCase(raw, "off") or
        std.mem.eql(u8, raw, "0")) return false;
    return null;
}

/// Coerce a raw INI string to integer type I per the active dialect.
///
/// When `dialect.int_suffixes` is true, recognizes k/m/g suffixes
/// (case-insensitive, 1024-based multipliers). Returns Overflow when
/// the numeric result cannot be represented in I, and TypeMismatch for
/// non-numeric input, a leading '+', or a '_' digit separator.
pub fn coerceInt(comptime I: type, dialect: Dialect, raw: []const u8) DecodeError!I {
    if (raw.len == 0) return error.TypeMismatch;
    // Leading '+' is rejected by git-config and configparser; match that behavior.
    if (raw[0] == '+') return error.TypeMismatch;
    // '_' digit separators are a Zig-only extension not accepted by any INI reference.
    if (std.mem.indexOfScalar(u8, raw, '_') != null) return error.TypeMismatch;
    var num_part = raw;
    var multiplier: u64 = 1;
    if (dialect.int_suffixes and raw.len > 1) {
        switch (raw[raw.len - 1]) {
            'k', 'K' => {
                num_part = raw[0 .. raw.len - 1];
                multiplier = 1024;
            },
            'm', 'M' => {
                num_part = raw[0 .. raw.len - 1];
                multiplier = 1024 * 1024;
            },
            'g', 'G' => {
                num_part = raw[0 .. raw.len - 1];
                multiplier = 1024 * 1024 * 1024;
            },
            else => {},
        }
    }
    // Unsigned targets: parse through u128 so values in (i128.max, u128.max] are handled.
    // Signed targets (or a negative value headed into an unsigned target): use i128.
    const is_negative = num_part.len > 0 and num_part[0] == '-';
    if (@typeInfo(I).int.signedness == .unsigned and !is_negative) {
        const n = std.fmt.parseInt(u128, num_part, 10) catch |e| switch (e) {
            error.Overflow => return error.Overflow,
            error.InvalidCharacter => return error.TypeMismatch,
        };
        const result = std.math.mul(u128, n, @as(u128, multiplier)) catch return error.Overflow;
        return std.math.cast(I, result) orelse error.Overflow;
    } else {
        const n = std.fmt.parseInt(i128, num_part, 10) catch |e| switch (e) {
            error.Overflow => return error.Overflow,
            error.InvalidCharacter => return error.TypeMismatch,
        };
        const result = std.math.mul(i128, n, @as(i128, @intCast(multiplier))) catch return error.Overflow;
        return std.math.cast(I, result) orelse error.Overflow;
    }
}

/// Decode a `Value` into an instance of T using reflection and per-dialect coercion.
///
/// `options` is the shared `ParseOptions` type so parse and decode call sites
/// stay uniform, but decode consumes only three of its fields: `dialect`
/// (scalar coercion tables), `ignore_unknown_fields`, and `errors`. The
/// remaining fields drive parsing and are ignored here. Diagnostics appended
/// by decode carry a zero-width span (0..0): a `Value` tree has no source
/// offsets, so decode diagnostics have no source location.
pub fn decode(comptime T: type, arena: Allocator, value: Value, options: ParseOptions) DecodeError!T {
    return decodeInner(T, arena, value, options);
}

/// Parse `src` and decode the result into T in one step.
pub fn parseInto(comptime T: type, arena: Allocator, src: []const u8, options: ParseOptions) (Error || DecodeError)!T {
    const value = try parser_mod.parse(arena, src, options);
    return decode(T, arena, value, options);
}

/// Reader-input variant: pulls the whole stream into the arena, then parses and decodes into T.
pub fn parseIntoReader(comptime T: type, arena: Allocator, reader: *std.Io.Reader, options: ParseOptions) (parser_mod.ReaderError || DecodeError)!T {
    const input = try reader.allocRemaining(arena, .unlimited);
    return parseInto(T, arena, input, options);
}

/// Look up `path` from `value` and decode the result into T.
///
/// Returns null when the path is missing, `value` is not a section, or the
/// resolved value cannot be decoded as T; allocation failure propagates as
/// `error.OutOfMemory`. This is a free function to avoid an import cycle
/// (value.zig -> decode.zig -> value.zig).
pub fn getT(comptime T: type, arena: Allocator, value: Value, path: []const u8, options: ParseOptions) error{OutOfMemory}!?T {
    const v = value.get(path) orelse return null;
    return decode(T, arena, v, options) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// Segment-path counterpart of `getT`: resolves a name containing `.` verbatim
/// (see `Value.getSegments`). Same null-on-lookup-or-decode-failure contract
/// as `getT`, with `error.OutOfMemory` propagated.
pub fn getTSegments(comptime T: type, arena: Allocator, value: Value, segments: []const []const u8, options: ParseOptions) error{OutOfMemory}!?T {
    const v = value.getSegments(segments) orelse return null;
    return decode(T, arena, v, options) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn decodeInner(comptime T: type, arena: Allocator, value: Value, options: ParseOptions) DecodeError!T {
    // A field of type `Value` captures the raw subtree as-is (scalar, list,
    // or section), letting a typed struct keep a dynamic region.
    if (comptime T == Value) return value;
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "fromIni")) {
        return T.fromIni(arena, value, options);
    }
    return switch (@typeInfo(T)) {
        .bool => decodeBool(value, options),
        .int => decodeInt(T, value, options),
        .float => decodeFloat(T, value),
        .pointer => |p| decodePointer(T, p, arena, value, options),
        .array => |a| decodeArray(T, a, arena, value, options),
        .optional => |o| decodeOptional(o.child, arena, value, options),
        .@"struct" => decodeStruct(T, arena, value, options),
        .@"enum" => decodeEnum(T, value),
        else => @compileError("ini decode: unsupported type " ++ @typeName(T)),
    };
}

fn decodeBool(value: Value, options: ParseOptions) DecodeError!bool {
    if (value != .string) return error.TypeMismatch;
    return coerceBool(options.dialect, value.string) orelse error.TypeMismatch;
}

fn decodeInt(comptime T: type, value: Value, options: ParseOptions) DecodeError!T {
    if (value != .string) return error.TypeMismatch;
    return coerceInt(T, options.dialect, value.string);
}

fn decodeFloat(comptime T: type, value: Value) DecodeError!T {
    if (value != .string) return error.TypeMismatch;
    const s = value.string;
    // Explicit inf/nan literals are valid float values; pass through to any float type.
    const is_inf_nan_literal = std.ascii.eqlIgnoreCase(s, "inf") or
        std.ascii.eqlIgnoreCase(s, "+inf") or
        std.ascii.eqlIgnoreCase(s, "-inf") or
        std.ascii.eqlIgnoreCase(s, "nan") or
        std.ascii.eqlIgnoreCase(s, "+nan") or
        std.ascii.eqlIgnoreCase(s, "-nan");
    const f = std.fmt.parseFloat(f64, s) catch return error.TypeMismatch;
    // A numeric string that overflows the target type is an error, not a silent inf.
    // Explicit inf/nan literals are exempt -- they are valid float values.
    if (!is_inf_nan_literal) {
        // Overflow at f64 itself (e.g. "1e309"): parseFloat returns +/-Inf.
        if (std.math.isInf(f)) return error.Overflow;
        // Overflow for types narrower than f64: a finite f64 value that exceeds the
        // target's representable range would silently saturate to inf on floatCast.
        if (@bitSizeOf(T) < @bitSizeOf(f64) and @abs(f) > @as(f64, @floatCast(std.math.floatMax(T)))) {
            return error.Overflow;
        }
    }
    return @floatCast(f);
}

fn decodePointer(
    comptime T: type,
    comptime p: std.builtin.Type.Pointer,
    arena: Allocator,
    value: Value,
    options: ParseOptions,
) DecodeError!T {
    if (p.size != .slice) @compileError("ini decode: only slice pointers supported, got " ++ @typeName(T));
    if (p.child == u8 and p.is_const) {
        if (value != .string) return error.TypeMismatch;
        return value.string;
    }
    switch (value) {
        .string => |s| {
            const out = try arena.alloc(p.child, 1);
            out[0] = try decodeInner(p.child, arena, .{ .string = s }, options);
            return out;
        },
        .list => |items| {
            const out = try arena.alloc(p.child, items.len);
            for (items, 0..) |item, i| {
                out[i] = try decodeInner(p.child, arena, .{ .string = item }, options);
            }
            return out;
        },
        else => return error.TypeMismatch,
    }
}

/// Decode into a fixed-size array [N]T. Element sources mirror the slice
/// path: a scalar string is one occurrence, a list is N occurrences. Unlike
/// slices, the occurrence count must equal the array length exactly;
/// any other count is `error.TypeMismatch`.
fn decodeArray(
    comptime T: type,
    comptime a: std.builtin.Type.Array,
    arena: Allocator,
    value: Value,
    options: ParseOptions,
) DecodeError!T {
    if (comptime a.len == 0) {
        // [0]T has a single value; only a zero-occurrence source matches.
        return switch (value) {
            .list => |items| if (items.len == 0) .{} else error.TypeMismatch,
            else => error.TypeMismatch,
        };
    }
    var out: T = undefined;
    switch (value) {
        .string => |s| {
            if (comptime a.len != 1) return error.TypeMismatch;
            out[0] = try decodeInner(a.child, arena, .{ .string = s }, options);
        },
        .list => |items| {
            if (items.len != a.len) return error.TypeMismatch;
            for (items, 0..) |item, i| {
                out[i] = try decodeInner(a.child, arena, .{ .string = item }, options);
            }
        },
        else => return error.TypeMismatch,
    }
    return out;
}

fn decodeOptional(
    comptime Child: type,
    arena: Allocator,
    value: Value,
    options: ParseOptions,
) DecodeError!?Child {
    return try decodeInner(Child, arena, value, options);
}

fn decodeEnum(comptime T: type, value: Value) DecodeError!T {
    if (value != .string) return error.TypeMismatch;
    return std.meta.stringToEnum(T, value.string) orelse error.InvalidEnumValue;
}

fn decodeStruct(
    comptime T: type,
    arena: Allocator,
    value: Value,
    options: ParseOptions,
) DecodeError!T {
    if (value != .section) return error.TypeMismatch;
    const sec = value.section;

    if (!options.ignore_unknown_fields) {
        entry_loop: for (sec.entries) |entry| {
            inline for (comptime expectedKeys(T)) |ek| {
                if (std.mem.eql(u8, entry.key, ek)) continue :entry_loop;
            }
            if (options.errors) |errs| {
                const known_keys = comptime expectedKeys(T);
                const suggestion = lev.closest(known_keys, entry.key);
                const msg = std.fmt.allocPrint(arena, "unknown field `{s}`", .{entry.key}) catch entry.key;
                // A Value tree has no source offsets, so the diagnostic gets a
                // zero-width span; renderRich renders it locationless.
                try errs.append(arena, Diagnostic{
                    .message = msg,
                    .span = .{ .start = 0, .end = 0 },
                    .suggestion = suggestion,
                });
            }
            return error.UnknownField;
        }
    }

    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isSkipped(T, field.name)) {
            const dv = comptime field.defaultValue() orelse
                @compileError("ini_skip field `" ++ field.name ++ "` on " ++ @typeName(T) ++ " has no default value");
            @field(out, field.name) = dv;
            continue;
        }
        if (comptime isFlattened(T, field.name)) {
            var flat_opts = options;
            flat_opts.ignore_unknown_fields = true;
            @field(out, field.name) = try decodeInner(field.type, arena, value, flat_opts);
            continue;
        }
        const eff_key = comptime renamedKey(T, field.name);
        if (sec.findValue(eff_key)) |fv| {
            @field(out, field.name) = try decodeInner(field.type, arena, fv, options);
        } else if (field.defaultValue()) |dv| {
            @field(out, field.name) = dv;
        } else if (@typeInfo(field.type) == .optional) {
            @field(out, field.name) = null;
        } else if (comptime blk: {
            // A key absent from the section is zero occurrences of a multi-value
            // list. Byte slices ([]const u8 / []u8) are string values, not lists,
            // so they are excluded and still return MissingField. A fixed-size
            // array shares the rule only at length 0 (the one length zero
            // occurrences can satisfy); a longer array stays MissingField.
            const ti = @typeInfo(field.type);
            if (ti == .array) break :blk ti.array.len == 0;
            if (ti != .pointer) break :blk false;
            if (ti.pointer.size != .slice) break :blk false;
            break :blk ti.pointer.child != u8;
        }) {
            @field(out, field.name) = try decodeInner(field.type, arena, .{ .list = &.{} }, options);
        } else {
            return error.MissingField;
        }
    }
    return out;
}

const testing = std.testing;

test "parseInto a struct with nested subsection and coercion" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Origin = struct { url: []const u8, mirror: bool };
    const Remote = struct { origin: Origin };
    const Config = struct { remote: Remote };
    const src = "[remote \"origin\"]\n\turl = u\n\tmirror = yes\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseInto(Config, arena.allocator(), src, .{ .dialect = G });
    try std.testing.expectEqualStrings("u", cfg.remote.origin.url);
    try std.testing.expect(cfg.remote.origin.mirror);
}

test "gitconfig int coercion honors k/m/g suffix" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    try std.testing.expectEqual(@as(i64, 1024), try coerceInt(i64, G, "1k"));
    try std.testing.expectEqual(@as(i64, 2 * 1024 * 1024), try coerceInt(i64, G, "2m"));
}

test "multi-valued key decodes into a slice field" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Sec = struct { push: []const []const u8 };
    const Root = struct { s: Sec };
    const src = "[s]\n\tpush = a\n\tpush = b\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseInto(Root, arena.allocator(), src, .{ .dialect = G });
    try std.testing.expectEqual(@as(usize, 2), r.s.push.len);
}

test "coerceBool gitconfig truth table" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    try testing.expect(coerceBool(G, "yes").?);
    try testing.expect(coerceBool(G, "true").?);
    try testing.expect(coerceBool(G, "on").?);
    try testing.expect(coerceBool(G, "1").?);
    try testing.expect(coerceBool(G, "").?);
    try testing.expect(!coerceBool(G, "no").?);
    try testing.expect(!coerceBool(G, "false").?);
    try testing.expect(!coerceBool(G, "off").?);
    try testing.expect(!coerceBool(G, "0").?);
    try testing.expect(coerceBool(G, "bogus") == null);
}

test "coerceBool generic configparser truth table" {
    const D = @import("dialect.zig").Dialect.generic;
    try testing.expect(coerceBool(D, "1").?);
    try testing.expect(coerceBool(D, "yes").?);
    try testing.expect(coerceBool(D, "true").?);
    try testing.expect(coerceBool(D, "on").?);
    try testing.expect(!coerceBool(D, "0").?);
    try testing.expect(!coerceBool(D, "no").?);
    try testing.expect(!coerceBool(D, "false").?);
    try testing.expect(!coerceBool(D, "off").?);
    try testing.expect(coerceBool(D, "") == null);
}

test "coerceInt overflow is an error" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    try testing.expectError(error.Overflow, coerceInt(u8, G, "256"));
}

test "decode missing required field returns MissingField" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Config = struct { required: struct { name: []const u8 } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Empty source -> empty root section -> "required" section not found
    try testing.expectError(error.MissingField, parseInto(Config, arena.allocator(), "", .{ .dialect = G }));
}

test "decode unknown field returns UnknownField" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Config = struct { remote: struct { url: []const u8 } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // "extra" section is not in Config -> UnknownField
    const src = "[remote]\nurl = x\n[extra]\nk = v\n";
    try testing.expectError(error.UnknownField, parseInto(Config, arena.allocator(), src, .{ .dialect = G }));
}

test "decode unknown field allowed with ignore_unknown_fields" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Config = struct { remote: struct { url: []const u8 } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "[remote]\nurl = x\n[extra]\nk = v\n";
    const r = try parseInto(Config, arena.allocator(), src, .{ .dialect = G, .ignore_unknown_fields = true });
    try testing.expectEqualStrings("x", r.remote.url);
}

test "decode optional field absent becomes null" {
    // generic dialect supports global keys at root level
    const D = @import("dialect.zig").Dialect.generic;
    const Config = struct { url: []const u8, branch: ?[]const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseInto(Config, arena.allocator(), "url = x\n", .{ .dialect = D });
    try testing.expectEqualStrings("x", cfg.url);
    try testing.expect(cfg.branch == null);
}

test "decode ini_rename maps alternate key to struct field" {
    // generic dialect supports global keys
    const D = @import("dialect.zig").Dialect.generic;
    const Config = struct {
        pub const ini_rename = .{ .fetch_url = "fetchurl" };
        fetch_url: []const u8,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseInto(Config, arena.allocator(), "fetchurl = git@example.com\n", .{ .dialect = D });
    try testing.expectEqualStrings("git@example.com", cfg.fetch_url);
}

test "decode ini_skip excludes field from decode" {
    const D = @import("dialect.zig").Dialect.generic;
    const Config = struct {
        pub const ini_skip = .{"internal"};
        name: []const u8,
        internal: u32 = 7,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseInto(Config, arena.allocator(), "name = foo\n", .{ .dialect = D });
    try testing.expectEqualStrings("foo", cfg.name);
    try testing.expectEqual(@as(u32, 7), cfg.internal);
}

test "decode fromIni hook short-circuits built-in dispatch" {
    const D = @import("dialect.zig").Dialect.generic;
    const SemVer = struct {
        major: u32,
        minor: u32,

        pub fn fromIni(_: Allocator, value: Value, _: ParseOptions) DecodeError!@This() {
            if (value != .string) return error.TypeMismatch;
            var it = std.mem.tokenizeAny(u8, value.string, ".");
            const maj_s = it.next() orelse return error.TypeMismatch;
            const min_s = it.next() orelse return error.TypeMismatch;
            return .{
                .major = std.fmt.parseInt(u32, maj_s, 10) catch return error.TypeMismatch,
                .minor = std.fmt.parseInt(u32, min_s, 10) catch return error.TypeMismatch,
            };
        }
    };
    const Config = struct { version: SemVer };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseInto(Config, arena.allocator(), "version = 2.1\n", .{ .dialect = D });
    try testing.expectEqual(@as(u32, 2), cfg.version.major);
    try testing.expectEqual(@as(u32, 1), cfg.version.minor);
}

test "getT returns decoded value or null" {
    var entries = [_]Entry{.{ .key = "n", .value = .{ .string = "42" } }};
    var sec = Section{ .entries = &entries };
    const root = Value{ .section = &sec };
    const D = @import("dialect.zig").Dialect.strict;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = try getT(i32, arena.allocator(), root, "n", .{ .dialect = D });
    try testing.expectEqual(@as(?i32, 42), n);
    try testing.expect(try getT(i32, arena.allocator(), root, "missing", .{ .dialect = D }) == null);
    // A non-section Value has no children, so any path resolves to null.
    try testing.expect(try getT(i32, arena.allocator(), .{ .string = "42" }, "n", .{ .dialect = D }) == null);
}

test "getTSegments decodes a dotted-name subsection reachable only by segments" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    // [branch "feature.x"] merge = refs/heads/main -- git config addresses this
    // as branch.feature.x.merge; the value is decoded via explicit segments.
    const src = "[branch \"feature.x\"]\n\tmerge = refs/heads/main\n\tahead = 3\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try parser_mod.parse(a, src, .{ .dialect = G });
    try testing.expectEqualStrings(
        "refs/heads/main",
        (try getTSegments([]const u8, a, root, &.{ "branch", "feature.x", "merge" }, .{ .dialect = G })).?,
    );
    try testing.expectEqual(
        @as(?u32, 3),
        try getTSegments(u32, a, root, &.{ "branch", "feature.x", "ahead" }, .{ .dialect = G }),
    );
    // The dotted getT cannot reach it (split on '.').
    try testing.expect(try getT([]const u8, a, root, "branch.feature.x.merge", .{ .dialect = G }) == null);
    // Missing segment path -> null.
    try testing.expect(try getTSegments([]const u8, a, root, &.{ "branch", "nope" }, .{ .dialect = G }) == null);
}

test "coerceInt overflow: huge suffixed value returns Overflow not panic" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    // 10^30 * 1024^3 overflows i128 -- must return error.Overflow, never panic
    try testing.expectError(error.Overflow, coerceInt(i64, G, "1000000000000000000000000000000g"));
    // parse of a 39-digit number exceeds i128 max -- must also be Overflow, not TypeMismatch
    try testing.expectError(error.Overflow, coerceInt(i64, G, "170141183460469231731687303715884105728"));
    // value just over i64 max with no suffix
    try testing.expectError(error.Overflow, coerceInt(i64, G, "9223372036854775808"));
}

test "decode ini_flatten merges child keys into parent section" {
    const D = @import("dialect.zig").Dialect.generic;
    const Extra = struct { debug: bool };
    const Config = struct {
        pub const ini_flatten = .{"extra"};
        name: []const u8,
        extra: Extra,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // "debug" lives at the same level as "name" because extra is flattened
    const cfg = try parseInto(Config, arena.allocator(), "name = foo\ndebug = true\n", .{ .dialect = D });
    try testing.expectEqualStrings("foo", cfg.name);
    try testing.expect(cfg.extra.debug);
}

test "decode enum field: valid string maps to enum value" {
    const D = @import("dialect.zig").Dialect.generic;
    const Color = enum { red, green, blue };
    const Config = struct { color: Color };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseInto(Config, arena.allocator(), "color = green\n", .{ .dialect = D });
    try testing.expectEqual(Color.green, cfg.color);
}

test "decode enum field: invalid string returns InvalidEnumValue" {
    const D = @import("dialect.zig").Dialect.generic;
    const Color = enum { red, green, blue };
    const Config = struct { color: Color };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidEnumValue, parseInto(Config, arena.allocator(), "color = purple\n", .{ .dialect = D }));
}

test "parseIntoReader decodes a struct from a reader" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Origin = struct { url: []const u8, mirror: bool };
    const Remote = struct { origin: Origin };
    const Config = struct { remote: Remote };
    const src = "[remote \"origin\"]\n\turl = git@example.com\n\tmirror = yes\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed(src);
    const cfg = try parseIntoReader(Config, arena.allocator(), &reader, .{ .dialect = G });
    try testing.expectEqualStrings("git@example.com", cfg.remote.origin.url);
    try testing.expect(cfg.remote.origin.mirror);
}

test "parseIntoReader: missing required field returns MissingField via reader path" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Config = struct { required: struct { name: []const u8 } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed("");
    try testing.expectError(error.MissingField, parseIntoReader(Config, arena.allocator(), &reader, .{ .dialect = G }));
}

test "D1: coerceInt u128 handles values above i128.max" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    // i128.max + 1 = 2^127; fits in u128 but not i128
    try testing.expectEqual(
        @as(u128, 170141183460469231731687303715884105728),
        try coerceInt(u128, G, "170141183460469231731687303715884105728"),
    );
    // u128.max
    try testing.expectEqual(
        @as(u128, 340282366920938463463374607431768211455),
        try coerceInt(u128, G, "340282366920938463463374607431768211455"),
    );
    // i128 still works up to its max
    try testing.expectEqual(
        @as(i128, 170141183460469231731687303715884105727),
        try coerceInt(i128, G, "170141183460469231731687303715884105727"),
    );
    // negative value into unsigned returns Overflow (not panic)
    try testing.expectError(error.Overflow, coerceInt(u32, G, "-1"));
}

test "D2: decodeFloat rejects f32 overflow but accepts f64 and inf/nan literals" {
    const strVal = struct {
        fn v(s: []const u8) Value {
            return .{ .string = s };
        }
    };
    // 1e40 > f32.max (~3.4e38) -> Overflow for f32
    try testing.expectError(error.Overflow, decodeFloat(f32, strVal.v("1e40")));
    // 1e40 fits f64 -> ok
    const big: f64 = try decodeFloat(f64, strVal.v("1e40"));
    try testing.expect(big == 1e40);
    // 3e38 < f32.max -> ok
    const ok32: f32 = try decodeFloat(f32, strVal.v("3.0e38"));
    try testing.expect(ok32 == @as(f32, 3.0e38));
    // explicit "inf" literal -> +inf for f32 (not Overflow)
    const inf32: f32 = try decodeFloat(f32, strVal.v("inf"));
    try testing.expect(std.math.isInf(inf32));
    // explicit "nan" literal -> nan for f32
    const nan32: f32 = try decodeFloat(f32, strVal.v("nan"));
    try testing.expect(std.math.isNan(nan32));
    // "1e309" overflows f64 itself -> Overflow (not silent +Inf)
    try testing.expectError(error.Overflow, decodeFloat(f64, strVal.v("1e309")));
    // explicit "inf" into f64 -> ok
    const inf64: f64 = try decodeFloat(f64, strVal.v("inf"));
    try testing.expect(std.math.isInf(inf64));
    // normal value into f64 -> ok
    const norm64: f64 = try decodeFloat(f64, strVal.v("1.5"));
    try testing.expect(norm64 == 1.5);
}

test "D4: ini_skip field present in source is silently ignored" {
    const D = @import("dialect.zig").Dialect.generic;
    const Config = struct {
        pub const ini_skip = .{"internal"};
        name: []const u8,
        internal: u32 = 7,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // "internal" appears in the source; with the fix it must not trigger UnknownField.
    const cfg = try parseInto(Config, arena.allocator(), "name = foo\ninternal = 5\n", .{ .dialect = D });
    try testing.expectEqualStrings("foo", cfg.name);
    // field keeps its Zig default; the INI value is ignored
    try testing.expectEqual(@as(u32, 7), cfg.internal);
}

test "behavioral: coerceInt rejects leading '+' as TypeMismatch" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const D = @import("dialect.zig").Dialect.generic;
    try testing.expectError(error.TypeMismatch, coerceInt(i32, G, "+42"));
    try testing.expectError(error.TypeMismatch, coerceInt(i32, D, "+42"));
    try testing.expectError(error.TypeMismatch, coerceInt(u32, G, "+0"));
}

test "behavioral: coerceInt rejects '_' digit separators as TypeMismatch" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const D = @import("dialect.zig").Dialect.generic;
    try testing.expectError(error.TypeMismatch, coerceInt(i32, G, "1_000"));
    try testing.expectError(error.TypeMismatch, coerceInt(i32, D, "1_000"));
    try testing.expectError(error.TypeMismatch, coerceInt(u64, G, "1_000_000"));
}

test "behavioral: enum matching is case-sensitive" {
    // Enum values are typed content, not INI keys; case folding is NOT applied
    // even when the dialect has case_insensitive_keys=true (e.g. generic, gitconfig).
    const D = @import("dialect.zig").Dialect.generic;
    const Color = enum { red, green, blue };
    const Config = struct { color: Color };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Exact lowercase match works.
    const ok = try parseInto(Config, arena.allocator(), "color = green\n", .{ .dialect = D });
    try testing.expectEqual(Color.green, ok.color);
    // Wrong case fails cleanly with InvalidEnumValue, never panics.
    try testing.expectError(
        error.InvalidEnumValue,
        parseInto(Config, arena.allocator(), "color = Green\n", .{ .dialect = D }),
    );
}

test "D5: ini_skip + ini_rename combined: renamed key of skipped field is not UnknownField" {
    const D = @import("dialect.zig").Dialect.generic;
    // "internal" is skipped AND renamed to "int-key" in INI.
    // The source contains "int-key"; it must be silently accepted, not trigger UnknownField.
    const Config = struct {
        pub const ini_skip = .{"internal"};
        pub const ini_rename = .{ .internal = "int-key" };
        name: []const u8,
        internal: u32 = 42,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseInto(Config, arena.allocator(), "name = hello\nint-key = 5\n", .{ .dialect = D });
    try testing.expectEqualStrings("hello", cfg.name);
    // skipped field keeps its Zig default; the INI value is ignored
    try testing.expectEqual(@as(u32, 42), cfg.internal);
}

test "E5: missing non-u8 slice field decodes as empty slice" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Sec = struct { push: []const []const u8 };
    const Root = struct { s: Sec };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Empty [s] section: push key absent -> empty slice.
    const r = try parseInto(Root, arena.allocator(), "[s]\n", .{ .dialect = G });
    try testing.expectEqual(@as(usize, 0), r.s.push.len);
    // Key present with one value -> one-element slice.
    const r2 = try parseInto(Root, arena.allocator(), "[s]\n\tpush = a\n", .{ .dialect = G });
    try testing.expectEqual(@as(usize, 1), r2.s.push.len);
    try testing.expectEqualStrings("a", r2.s.push[0]);
    // A non-slice required field still returns MissingField.
    const Root2 = struct { s: struct { url: []const u8 } };
    try testing.expectError(error.MissingField, parseInto(Root2, arena.allocator(), "[s]\n", .{ .dialect = G }));
}

test "decode fixed-size array: exact occurrence count required" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Root = struct { s: struct { push: [2][]const u8 } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Exactly two occurrences fill [2]T elementwise.
    const r = try parseInto(Root, arena.allocator(), "[s]\n\tpush = a\n\tpush = b\n", .{ .dialect = G });
    try testing.expectEqualStrings("a", r.s.push[0]);
    try testing.expectEqualStrings("b", r.s.push[1]);
    // Too few occurrences -> TypeMismatch (one string into [2]T).
    try testing.expectError(
        error.TypeMismatch,
        parseInto(Root, arena.allocator(), "[s]\n\tpush = a\n", .{ .dialect = G }),
    );
    // Too many occurrences -> TypeMismatch (three-element list into [2]T).
    try testing.expectError(
        error.TypeMismatch,
        parseInto(Root, arena.allocator(), "[s]\n\tpush = a\n\tpush = b\n\tpush = c\n", .{ .dialect = G }),
    );
}

test "decode fixed-size array: single occurrence fills [1]T" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Root = struct { s: struct { n: [1]u32 } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseInto(Root, arena.allocator(), "[s]\n\tn = 7\n", .{ .dialect = G });
    try testing.expectEqual(@as(u32, 7), r.s.n[0]);
}

test "decode fixed-size array: [0]T accepts an absent key, longer arrays stay MissingField" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Absent key is zero occurrences, the one count [0]T can hold.
    const Root0 = struct { s: struct { push: [0][]const u8 } };
    const r0 = try parseInto(Root0, arena.allocator(), "[s]\n", .{ .dialect = G });
    try testing.expectEqual(@as(usize, 0), r0.s.push.len);
    // A present occurrence no longer fits [0]T.
    try testing.expectError(
        error.TypeMismatch,
        parseInto(Root0, arena.allocator(), "[s]\n\tpush = a\n", .{ .dialect = G }),
    );
    // An absent key for [2]T is a missing required field, not a length error.
    const Root2 = struct { s: struct { push: [2][]const u8 } };
    try testing.expectError(
        error.MissingField,
        parseInto(Root2, arena.allocator(), "[s]\n", .{ .dialect = G }),
    );
}

test "decode fixed-size array: elementwise coercion applies per dialect" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Root = struct { s: struct { sizes: [2]i64 } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseInto(Root, arena.allocator(), "[s]\n\tsizes = 1k\n\tsizes = 2m\n", .{ .dialect = G });
    try testing.expectEqual(@as(i64, 1024), r.s.sizes[0]);
    try testing.expectEqual(@as(i64, 2 * 1024 * 1024), r.s.sizes[1]);
    // A section where a leaf is expected -> TypeMismatch, not a crash.
    const RootSec = struct {
        pub const ini_rename = .{ .arr = "s" };
        arr: [1][]const u8,
    };
    try testing.expectError(
        error.TypeMismatch,
        parseInto(RootSec, arena.allocator(), "[s]\n\tk = v\n", .{ .dialect = G, .ignore_unknown_fields = true }),
    );
}

test "decode Value field captures a raw scalar, list, and section subtree" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const Config = struct {
        s: struct {
            name: Value,
            push: Value,
            x: Value,
        },
    };
    const src =
        "[s]\n\tname = ada\n\tpush = a\n\tpush = b\n" ++
        "[s \"x\"]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseInto(Config, arena.allocator(), src, .{ .dialect = G });
    try testing.expectEqualStrings("ada", cfg.s.name.string);
    try testing.expectEqual(@as(usize, 2), cfg.s.push.list.len);
    try testing.expectEqualStrings("b", cfg.s.push.list[1]);
    try testing.expectEqualStrings("v", cfg.s.x.section.get("k").?.string);
}

test "decode Value field at top level keeps a whole dynamic section" {
    const D = @import("dialect.zig").Dialect.generic;
    const Config = struct {
        server: struct { host: []const u8 },
        extra: Value,
    };
    const src = "[server]\nhost = h\n[extra]\na = 1\nb = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseInto(Config, arena.allocator(), src, .{ .dialect = D });
    try testing.expectEqualStrings("h", cfg.server.host);
    try testing.expectEqualStrings("1", cfg.extra.section.get("a").?.string);
    try testing.expectEqualStrings("2", cfg.extra.section.get("b").?.string);
    // A missing required Value field is MissingField like any other field.
    try testing.expectError(
        error.MissingField,
        parseInto(Config, arena.allocator(), "[server]\nhost = h\n", .{ .dialect = D }),
    );
}
