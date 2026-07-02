//! INI for Zig: dialect-aware parser, typed codec, lossless document model,
//! streaming, diagnostics. See README for the public surface.

const std = @import("std");

pub const dialect = @import("dialect.zig");
pub const Dialect = dialect.Dialect;

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const Section = value.Section;
pub const Span = value.Span;
pub const Spans = value.Spans;

pub const tokenizer = @import("tokenizer.zig");
pub const Tokenizer = tokenizer.Tokenizer;
pub const Token = tokenizer.Token;
pub const LineKind = tokenizer.LineKind;

pub const escape = @import("escape.zig");
pub const unescapeGit = escape.unescapeGit;

pub const parser = @import("parser.zig");
pub const ParseOptions = parser.ParseOptions;
pub const Error = parser.Error;
pub const Diagnostic = parser.Diagnostic;
pub const ReaderError = parser.ReaderError;

pub const encoder = @import("encoder.zig");
pub const EncodeError = encoder.EncodeError;
pub const TypedEncodeError = encoder.TypedEncodeError;
pub const EmitOptions = encoder.EmitOptions;

const decode_mod = @import("decode.zig");
pub const DecodeError = decode_mod.DecodeError;
const annotations = @import("annotations.zig");

pub const document = @import("document.zig");
pub const Document = document.Document;
pub const DocumentError = document.DocumentError;

pub const stream = @import("stream.zig");
pub const Event = stream.Event;
pub const EventReader = stream.EventReader;
pub const ValueStream = stream.ValueStream;
pub const StreamError = stream.StreamError;

const levenshtein = @import("levenshtein.zig");

/// Look up `path` from a `Value` and decode the result into T.
///
/// Decode failures (type mismatch, overflow, missing path) collapse to null;
/// only `error.OutOfMemory` propagates. Use this for convenience lookups
/// where a missing or wrong-typed entry should be treated the same as absent.
pub const getT = decode_mod.getT;

/// Segment-based typed lookup. Resolves a name containing `.` (e.g. a gitconfig
/// subsection `[branch "feature.x"]`) that the dotted `getT` cannot address.
pub const getTSegments = decode_mod.getTSegments;

pub fn parse(arena: std.mem.Allocator, src: []const u8, options: ParseOptions) Error!Value {
    return parser.parse(arena, src, options);
}

pub fn parseReader(arena: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) ReaderError!Value {
    return parser.parseReader(arena, reader, options);
}

pub fn encode(w: *std.Io.Writer, val: Value, options: EmitOptions) EncodeError!void {
    return encoder.encode(w, val, options);
}

pub fn encodeTyped(w: *std.Io.Writer, val: anytype, arena: std.mem.Allocator, options: EmitOptions) TypedEncodeError!void {
    return encoder.encodeTyped(w, val, arena, options);
}

pub fn decode(comptime T: type, arena: std.mem.Allocator, val: Value, options: ParseOptions) DecodeError!T {
    return decode_mod.decode(T, arena, val, options);
}

pub fn parseInto(comptime T: type, arena: std.mem.Allocator, src: []const u8, options: ParseOptions) (Error || DecodeError)!T {
    return decode_mod.parseInto(T, arena, src, options);
}

pub fn parseIntoReader(comptime T: type, arena: std.mem.Allocator, reader: *std.Io.Reader, options: ParseOptions) (ReaderError || DecodeError)!T {
    return decode_mod.parseIntoReader(T, arena, reader, options);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("dialect.zig");
    _ = @import("value.zig");
    _ = @import("tokenizer.zig");
    _ = @import("parser.zig");
    _ = @import("escape.zig");
    _ = @import("encoder.zig");
    _ = @import("decode.zig");
    _ = @import("annotations.zig");
    _ = @import("document.zig");
    _ = @import("stream.zig");
    _ = @import("levenshtein.zig");
}
