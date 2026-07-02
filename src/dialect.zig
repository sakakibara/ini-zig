//! INI dialect: runtime configuration for the parser's lexing and semantic rules.
//!
//! Five named presets cover the most common real-world families. Callers may
//! construct a custom Dialect by starting from any preset and overriding fields.

const std = @import("std");

/// Whether sections support dot-delimited subsection names.
pub const SubsectionStyle = enum {
    /// No subsection syntax; section names are opaque strings.
    none,
    /// Git-style: [section "subsection"] where the quoted part is literal.
    quoted,
};

/// How duplicate keys within the same section are resolved.
pub const DuplicatePolicy = enum {
    /// Later occurrence replaces the earlier one.
    last_wins,
    /// First occurrence is kept; subsequent ones ignored.
    first_wins,
    /// All values are kept; the key maps to a list.
    accumulate,
    /// A duplicate key is a parse error.
    err,
};

/// How sections with the same name are handled.
pub const SectionPolicy = enum {
    /// Entries from all same-named sections are merged into one.
    merge,
    /// Each occurrence is kept as a distinct section.
    accumulate,
    /// A repeated section header is a parse error.
    err,
};

/// Whether and how a backslash or indented continuation extends a value across lines.
pub const ContinuationStyle = enum {
    /// No line continuation; each line is a standalone value.
    none,
    /// A trailing backslash joins the next line into the current value.
    backslash,
    /// A line that begins with whitespace continues the previous value.
    indent,
};

/// String quoting rules inside values.
pub const QuoteStyle = enum {
    /// Values are taken verbatim; no escape processing.
    none,
    /// Git quoting: double-quoted strings with C-style escapes.
    git,
};

/// Runtime configuration that controls every branching decision in the parser.
pub const Dialect = struct {
    /// Characters that begin a line comment (any char in the string starts a comment).
    comment_chars: []const u8 = ";#",
    /// Strip a trailing inline comment (e.g. ` ; remark`) from a parsed value.
    inline_comments: bool = false,
    /// Characters accepted as key/value separator (first match wins).
    assign_chars: []const u8 = "=",
    /// Subsection syntax supported by this dialect.
    subsections: SubsectionStyle = .none,
    /// Resolution when the same key appears more than once in a section.
    duplicate_keys: DuplicatePolicy = .last_wins,
    /// Resolution when the same section header appears more than once.
    duplicate_sections: SectionPolicy = .merge,
    /// Whether keys may appear before any section header.
    global_keys: bool = false,
    /// Section names are matched case-insensitively.
    case_insensitive_sections: bool = false,
    /// Key names are matched case-insensitively.
    case_insensitive_keys: bool = false,
    /// Line-continuation style.
    line_continuation: ContinuationStyle = .none,
    /// String quoting and escape rules.
    quoting: QuoteStyle = .none,
    /// A key without `=` (bare key on its own line) is accepted as a
    /// boolean-true entry rather than an error.
    allow_no_value: bool = false,
    /// Trim leading/trailing whitespace around the key and the value.
    trim_whitespace: bool = true,
    /// Trim leading/trailing whitespace around a section header name. Distinct
    /// from `trim_whitespace` because configparser trims keys/values but keeps
    /// section-name whitespace, making `[ s ]` and `[s]` separate sections.
    trim_section_names: bool = true,
    /// Strip a single surrounding pair of double quotes from a value, matching
    /// Win32 GetPrivateProfileString (`key="x"` -> `x`). Only a balanced outer
    /// pair is removed; an unbalanced quote is kept verbatim.
    strip_value_quotes: bool = false,
    /// Accept git-style k/m/g integer multipliers in typed int coercion.
    int_suffixes: bool = false,


    /// Python configparser defaults: `=` or `:` separator, indent continuation, global keys.
    pub const generic: Dialect = .{
        .comment_chars = ";#",
        .assign_chars = "=:",
        .subsections = .none,
        .duplicate_keys = .last_wins,
        .duplicate_sections = .merge,
        .global_keys = true,
        .case_insensitive_sections = true,
        .case_insensitive_keys = true,
        .line_continuation = .indent,
        .quoting = .none,
        .allow_no_value = false,
        .trim_section_names = false,
    };

    /// Git config: quoted subsections, accumulate duplicates, backslash continuation, git quoting.
    pub const gitconfig: Dialect = .{
        .comment_chars = ";#",
        .inline_comments = true,
        .assign_chars = "=",
        .subsections = .quoted,
        .duplicate_keys = .accumulate,
        .duplicate_sections = .merge,
        .global_keys = false,
        .case_insensitive_sections = true,
        .case_insensitive_keys = true,
        .line_continuation = .backslash,
        .quoting = .git,
        .allow_no_value = true,
        .int_suffixes = true,
    };

    /// systemd unit files: accumulate duplicates, backslash continuation, no global keys.
    pub const systemd: Dialect = .{
        .comment_chars = ";#",
        .assign_chars = "=",
        .subsections = .none,
        .duplicate_keys = .accumulate,
        .duplicate_sections = .merge,
        .global_keys = false,
        .case_insensitive_sections = false,
        .case_insensitive_keys = false,
        .line_continuation = .backslash,
        .quoting = .none,
        .allow_no_value = false,
    };

    /// Windows INI: semicolon-only comments, case-insensitive names, last-wins.
    pub const windows: Dialect = .{
        .comment_chars = ";",
        .assign_chars = "=",
        .subsections = .none,
        .duplicate_keys = .last_wins,
        .duplicate_sections = .merge,
        .global_keys = false,
        .case_insensitive_sections = true,
        // GetPrivateProfileString matches both section and key names
        // case-insensitively.
        .case_insensitive_keys = true,
        .line_continuation = .none,
        .quoting = .none,
        .allow_no_value = false,
        .strip_value_quotes = true,
    };

    /// Strict minimal: `=` only, no subsections, no continuation, no quoting, no bare keys.
    pub const strict: Dialect = .{
        .comment_chars = ";#",
        .assign_chars = "=",
        .subsections = .none,
        .duplicate_keys = .last_wins,
        .duplicate_sections = .merge,
        .global_keys = false,
        .case_insensitive_sections = false,
        .case_insensitive_keys = false,
        .line_continuation = .none,
        .quoting = .none,
        .allow_no_value = false,
    };
};


const testing = std.testing;

test "strict preset is minimal" {
    const d = Dialect.strict;
    try testing.expectEqualStrings(";#", d.comment_chars);
    try testing.expectEqualStrings("=", d.assign_chars);
    try testing.expectEqual(SubsectionStyle.none, d.subsections);
    try testing.expectEqual(DuplicatePolicy.last_wins, d.duplicate_keys);
    try testing.expectEqual(ContinuationStyle.none, d.line_continuation);
    try testing.expectEqual(QuoteStyle.none, d.quoting);
    try testing.expect(!d.allow_no_value);
    try testing.expect(!d.inline_comments);
    try testing.expect(d.trim_whitespace);
    try testing.expect(d.trim_section_names);
    try testing.expect(!d.strip_value_quotes);
}

test "gitconfig preset matches git semantics" {
    const d = Dialect.gitconfig;
    try testing.expectEqual(SubsectionStyle.quoted, d.subsections);
    try testing.expectEqual(DuplicatePolicy.accumulate, d.duplicate_keys);
    try testing.expect(!d.global_keys);
    try testing.expect(d.case_insensitive_sections);
    try testing.expect(d.case_insensitive_keys);
    try testing.expectEqual(ContinuationStyle.backslash, d.line_continuation);
    try testing.expectEqual(QuoteStyle.git, d.quoting);
    try testing.expect(d.allow_no_value);
    try testing.expect(d.inline_comments);
    try testing.expect(d.trim_whitespace);
    try testing.expect(d.int_suffixes);
}

test "int_suffixes is false for all non-gitconfig presets" {
    try testing.expect(!Dialect.generic.int_suffixes);
    try testing.expect(!Dialect.strict.int_suffixes);
    try testing.expect(!Dialect.systemd.int_suffixes);
    try testing.expect(!Dialect.windows.int_suffixes);
}

test "generic preset is configparser-like" {
    const d = Dialect.generic;
    try testing.expectEqualStrings("=:", d.assign_chars);
    try testing.expectEqual(ContinuationStyle.indent, d.line_continuation);
    try testing.expect(d.global_keys);
    try testing.expect(d.case_insensitive_keys);
    // configparser keeps section-name whitespace; keys/values are still trimmed.
    try testing.expect(!d.trim_section_names);
    try testing.expect(d.trim_whitespace);
}

test "windows preset is last-wins ;-comment" {
    const d = Dialect.windows;
    try testing.expectEqualStrings(";", d.comment_chars);
    try testing.expectEqual(DuplicatePolicy.last_wins, d.duplicate_keys);
    // GetPrivateProfileString matches section AND key names case-insensitively.
    try testing.expect(d.case_insensitive_sections);
    try testing.expect(d.case_insensitive_keys);
    // GetPrivateProfileString strips one surrounding double-quote pair.
    try testing.expect(d.strip_value_quotes);
}

test "systemd preset accumulates, backslash continuation" {
    const d = Dialect.systemd;
    try testing.expectEqual(DuplicatePolicy.accumulate, d.duplicate_keys);
    try testing.expectEqual(ContinuationStyle.backslash, d.line_continuation);
    try testing.expect(!d.global_keys);
}
