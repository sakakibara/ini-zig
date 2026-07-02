//! Comptime annotation helpers for struct-level INI customization.
//!
//! Recognized declarations on struct types:
//!   `ini_rename`  - struct literal mapping field names to alternate INI keys
//!   `ini_skip`    - tuple of field names to exclude from encode/decode
//!   `ini_flatten` - tuple of struct field names to merge into the parent level

const std = @import("std");

pub fn renamedKey(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (!@hasDecl(T, "ini_rename")) return field_name;
    const renames = T.ini_rename;
    if (@hasField(@TypeOf(renames), field_name)) return @field(renames, field_name);
    return field_name;
}

pub fn isSkipped(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "ini_skip")) return false;
    inline for (T.ini_skip) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

pub fn isFlattened(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "ini_flatten")) return false;
    inline for (T.ini_flatten) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

/// Comptime-computed slice of effective INI keys expected by T at its own level.
/// Flattened fields are expanded to their child keys. Skipped fields ARE included
/// (under their effective/renamed key) so their presence in source doesn't trigger
/// UnknownField; they are simply not populated at fill time.
pub fn expectedKeys(comptime T: type) []const []const u8 {
    comptime {
        const s = @typeInfo(T).@"struct";
        var keys: []const []const u8 = &.{};
        for (s.fields) |field| {
            if (isSkipped(T, field.name)) {
                keys = keys ++ &[_][]const u8{renamedKey(T, field.name)};
                continue;
            }
            if (isFlattened(T, field.name)) {
                keys = keys ++ expectedKeys(field.type);
            } else {
                keys = keys ++ &[_][]const u8{renamedKey(T, field.name)};
            }
        }
        return keys;
    }
}
