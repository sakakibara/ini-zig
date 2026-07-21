//! Lossless INI document model: parse while retaining the original bytes,
//! edit by recording byte-range splices, and emit byte-identical output when
//! unmodified (or a minimal diff when edited).
//!
//! `Document.parse` keeps the input verbatim and a parse-with-spans index that
//! maps each dotted key path to its value's byte range. An edit validates the
//! path and records a splice (a byte range plus replacement text) without
//! mutating the buffer; `emit` applies the recorded splices to the original
//! buffer in order. With no splices the buffer is written verbatim. A failed
//! edit records nothing and leaves the document unchanged.
//!
//! All allocations go through the arena passed to `parse`; releasing the arena
//! frees everything. There is no `Document.deinit`.
//!
//! Setting a path whose section (or, under a subsection-quoting dialect, its
//! subsection) does not exist creates it: a whole new `[section]` or
//! `[section "subsection"]` header plus the key is appended at the end of
//! the document, separated from prior content by one blank line. Setting a
//! path whose section already exists just appends the key to it.
//! `Document.empty` bootstraps a document with no source bytes at all, so
//! the very first `set` creates the whole path. `setSegments` /
//! `setLiteralSegments` / `removeSegments` take a path as pre-split segments
//! instead of a dotted string, so a section or key name containing a literal
//! `.` (e.g. a gitconfig subsection) is addressed unambiguously;
//! `set`/`setLiteral`/`remove` still take dotted strings and split them into
//! segments the same way before doing the same work, so a dot-free path
//! behaves identically either way. `setValueSegments` sets a path from an
//! `ini.Value` directly, additionally handling a `.list` -- a multi-value
//! key backed by one line per element under a dialect that accumulates
//! duplicate keys (e.g. gitconfig) -- the same way; `removeSegments` deletes
//! every line of such a key, not just one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const value_mod = @import("value.zig");
const parser_mod = @import("parser.zig");
const decode_mod = @import("decode.zig");
const dialect_mod = @import("dialect.zig");
const tok = @import("tokenizer.zig");
const escape = @import("escape.zig");
const escapeGit = escape.escapeGit;

const Value = value_mod.Value;
const Section = value_mod.Section;
const Span = value_mod.Span;
const Spans = value_mod.Spans;
const Dialect = dialect_mod.Dialect;

pub const DocumentError = error{
    PathNotFound,
    /// A create-on-set path collides, in either direction, with a value of
    /// the wrong kind: a container segment (all but the last of a path)
    /// already names a string/list value instead of a section, so it cannot
    /// be descended into or created under; or the leaf key already names a
    /// section/subsection, so creating it as a scalar would silently shadow
    /// that section on read instead.
    InvalidValue,
    /// A value would not survive a re-parse after splicing: a carriage return
    /// (any dialect), an embedded newline or trimmed edge whitespace under a
    /// non-quoting dialect, or a continuation-swallowing trailing backslash.
    /// Reported instead of corrupting or structurally breaking the document.
    UnrepresentableValue,
    /// A comment text held a newline (`\n`/`\r`), which would break out of the
    /// single comment line into injected key/section structure.
    InvalidComment,
    /// `setTrailingComment` was called under a dialect that does not strip
    /// inline comments, so the appended ` # text` would survive re-parse as
    /// value bytes. Reported instead of corrupting the value.
    CommentsNotSupported,
    /// Two range edits (set/setLiteral/remove/setTrailingComment) covered
    /// overlapping byte ranges, so applying both would corrupt the document.
    ConflictingEdit,
} || parser_mod.Error;

/// A pending edit: replace `source[start..end]` with `text` at emit time. A
/// zero-width range (`start == end`) is a pure insertion. `seq` records call
/// order so coincident insertions stay stably ordered.
const Splice = struct {
    start: usize,
    end: usize,
    text: []const u8,
    seq: u32,
    /// A brand-new section block appended at end-of-file (`appendNewSectionList`,
    /// including via `insertSegments`'s single-value wrapper). It anchors at
    /// `source.len`, which equals the `line_end` of the last existing
    /// section's final key when that section
    /// ends the file -- so a key inserted into that last section and a new
    /// appended section collide at the same zero-width offset. A tail append
    /// always emits AFTER any same-offset insertion into existing content
    /// (see `spliceLess`), so such a key stays in its own section instead of
    /// slipping inside the appended one, regardless of edit order.
    tail: bool,
};

/// One `recordSplice` call's arguments, queued up so several can be recorded
/// as one atomic group -- see `Document.recordSpliceGroup`.
const SpliceOp = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

/// Byte anchors of a key/value entry. `value_*`/`content_end`/`line_end` cover
/// the whole LOGICAL line (the value's first physical line through its last
/// continuation line), so edits operate on the entire entry rather than only
/// its first physical line. `line_start`/`indent` are the first physical line.
/// `bare` marks a no-value key (no assign char on the line); `key_end` is the
/// offset just past its key token, where a value or trailing comment is grafted.
const Anchors = struct {
    line_start: usize,
    value_start: usize,
    value_end: usize,
    content_end: usize,
    line_end: usize,
    indent: []const u8,
    bare: bool,
    key_end: usize,
};

/// Value token's byte range within a just-created line's spliced `text` (NOT
/// `source` offsets -- the whole line is freshly injected text, not a range
/// into the original buffer). Returned by the insert* helpers so a create can
/// be recorded precisely enough to overwrite just its value substring later,
/// on a re-`set` to a different value -- see `Document.created`.
const ValueOffset = struct { start: usize, end: usize };

/// Bookkeeping for one path created by an edit in this session -- see
/// `Document.created`. Carries the same `leading`/`indent`/`key` strings
/// `CreatedListEntry` does (rather than just the value's own offset) so a
/// same-session re-set of the OTHER kind (`overwriteCreatedScalarAsList`)
/// can rebuild this splice as an N-line block from scratch, the same way
/// `overwriteCreatedListValue` already rebuilds a list create.
const CreatedEntry = struct {
    /// `Splice.seq` of the zero-width insertion that wrote this line.
    seq: u32,
    /// Prefix (blank-line separator and/or a new section header) before the
    /// line; "" when the line was appended into existing content with no
    /// separator needed.
    leading: []const u8,
    /// Indentation the line uses.
    indent: []const u8,
    /// Key spelling the line uses.
    key: []const u8,
    /// The value token's current byte range within that splice's `text`.
    value: ValueOffset,
    /// Raw bytes last used to create/update this path.
    raw: []const u8,
};

/// `CreatedEntry`'s list counterpart -- see `Document.created_lists`. Unlike
/// a scalar create, a list create's own splice `text` may need to grow or
/// shrink a different number of lines on re-set, so it also keeps the
/// `leading`/`indent`/`key` strings the original create used, letting a
/// later re-set rebuild the whole block (via `buildEntryBlock`) rather than
/// edit a value substring in place.
const CreatedListEntry = struct {
    /// `Splice.seq` of the zero-width insertion that wrote this block.
    seq: u32,
    /// Prefix (blank-line separator and/or a new section header) before the
    /// block's first line; "" when the block was appended into existing
    /// content with no separator needed.
    leading: []const u8,
    /// Indentation mirrored by every line in the block.
    indent: []const u8,
    /// Key spelling used on every line.
    key: []const u8,
    /// Each item's current byte range within that splice's `text`.
    items: []const ValueOffset,
    /// Raw item bytes last used to create/update this path.
    raw: []const []const u8,
};

pub const Document = struct {
    arena: Allocator,
    /// Source bytes with any leading BOM stripped. Spans index into this slice.
    source: []const u8,
    /// Whether the original input began with a UTF-8 BOM (EF BB BF).
    /// emit() re-prepends the BOM so the output is byte-identical to the input.
    bom: bool,
    options: parser_mod.ParseOptions,
    /// Parse snapshot of the ORIGINAL source. `spans` index into it and edits
    /// resolve against it, so it must stay pinned across edits.
    parsed: Value,
    /// Read view reflecting all pending edits: refreshed from the emitted bytes
    /// after every recorded splice, so reads agree with `emit`. Kept separate
    /// from `parsed` because the edit machinery relies on original spans.
    view: Value,
    spans: Spans,
    splices: std.ArrayList(Splice),
    /// Monotonic counter assigning each splice its call-order tiebreaker.
    seq: u32,
    /// Path (folded the same way `joinSectionFolded` keys `spans`) -> the
    /// create edit that wrote it, for every path created by an edit in this
    /// session. `parsed`/`spans` stay pinned to the original source, so a
    /// path an edit created is invisible to `locateSegments` forever after
    /// (it never gains a span); without this cache, repeating the exact same
    /// create-`set` would not recognize its own prior create and would
    /// append a second, duplicate entry instead of being the no-op every
    /// other repeated `set` already is. Genuinely load-bearing beyond that
    /// dedup: a later `set` to the SAME path with a DIFFERENT value looks up
    /// the original splice by `CreatedEntry.seq` and overwrites its value
    /// substring in place (see `overwriteCreatedValue`), so re-setting a
    /// freshly created path to a new value never appends a second line.
    /// Cleared for a path on `removeSegments`. A path present here is never
    /// also present in `created_lists`: a same-session re-set of the OTHER
    /// kind migrates the entry across (see `overwriteCreatedScalarAsList`),
    /// rather than letting a path be tracked under both.
    created: std.StringHashMapUnmanaged(CreatedEntry),
    /// `created`'s counterpart for a path created via `setValueSegments`'
    /// `.list` branch (`setListSegments`/`createListSegments`), keyed and
    /// cleared the same way. Kept separate from `created` (rather than a
    /// tagged union of the two) so the scalar path -- the overwhelmingly
    /// common case -- stays untouched by the list machinery entirely. Same
    /// single-kind-per-path invariant as `created`, migrated the other way
    /// by `overwriteCreatedListAsScalar`.
    created_lists: std.StringHashMapUnmanaged(CreatedListEntry),

    pub fn parse(arena: Allocator, src: []const u8, options: parser_mod.ParseOptions) DocumentError!Document {
        const has_bom = std.mem.startsWith(u8, src, "\xEF\xBB\xBF");
        // Strip the BOM before duplication so spans are relative to the
        // BOM-free content; emit() re-prepends the BOM when present.
        const stripped = if (has_bom) src[3..] else src;
        const source = try arena.dupe(u8, stripped);
        var spans: Spans = .empty;
        var opts = options;
        opts.spans = &spans;
        const parsed = try parser_mod.parse(arena, source, opts);
        return .{
            .arena = arena,
            .source = source,
            .bom = has_bom,
            .options = options,
            .parsed = parsed,
            .view = parsed,
            .spans = spans,
            .splices = .empty,
            .seq = 0,
            .created = .empty,
            .created_lists = .empty,
        };
    }

    /// Bootstrap a document with no source bytes at all, for a config layer
    /// that may not exist on disk yet. Reads see nothing until the first
    /// edit; the first `set`/`setSegments` (etc.) creates the whole
    /// requested section and key in one splice.
    ///
    /// `Document.parse(arena, "", options)` already succeeds for INI (an
    /// empty file is a valid, empty document, unlike a format that requires
    /// a top-level value) and produces an equivalent empty document, so
    /// `empty` is not a special case grafted onto `parse` -- it is a
    /// dedicated, self-documenting entry point for "this file may not exist
    /// yet" that skips invoking the parser entirely.
    pub fn empty(arena: Allocator, options: parser_mod.ParseOptions) Allocator.Error!Document {
        const root = try arena.create(Section);
        root.* = .{ .entries = &.{} };
        return .{
            .arena = arena,
            .source = "",
            .bom = false,
            .options = options,
            .parsed = .{ .section = root },
            .view = .{ .section = root },
            .spans = .empty,
            .splices = .empty,
            .seq = 0,
            .created = .empty,
            .created_lists = .empty,
        };
    }

    /// Look up a value by dotted path, reflecting any pending edits. Returns
    /// null if absent. A name containing `.` (a gitconfig subsection) is not
    /// addressable here; use `getSegments`.
    pub fn get(self: *const Document, path: []const u8) ?Value {
        return self.view.get(path);
    }

    /// Look up a value by explicit path segments (no splitting), reflecting any
    /// pending edits. Addresses a name containing `.`; see `Section.getSegments`.
    pub fn getSegments(self: *const Document, segments: []const []const u8) ?Value {
        return self.view.getSegments(segments);
    }

    /// Typed read by dotted path, reflecting any pending edits. Null on missing
    /// path or decode failure; allocation failure propagates.
    pub fn getT(self: *const Document, comptime T: type, path: []const u8) error{OutOfMemory}!?T {
        return decode_mod.getT(T, self.arena, self.view, path, self.options);
    }

    /// Typed read by explicit path segments, reflecting any pending edits.
    /// Addresses a name containing `.`; null on missing path or decode
    /// failure; allocation failure propagates.
    pub fn getTSegments(self: *const Document, comptime T: type, segments: []const []const u8) error{OutOfMemory}!?T {
        return decode_mod.getTSegments(T, self.arena, self.view, segments, self.options);
    }

    /// Set `path` to `value`, comptime-dispatched on its Zig type. Strings,
    /// bools, integers, and floats are rendered to INI text (escaped per the
    /// dialect) and spliced over the existing value token, or used to create
    /// the key (and its section, if missing) -- see `setLiteralSegments`.
    pub fn set(self: *Document, path: []const u8, value: anytype) DocumentError!void {
        const text = try self.renderTyped(@TypeOf(value), value);
        return self.setLiteral(path, text);
    }

    /// Segment-path counterpart of `set`: addresses a name containing `.`
    /// (e.g. a gitconfig subsection) verbatim, with no splitting.
    pub fn setSegments(self: *Document, segments: []const []const u8, value: anytype) DocumentError!void {
        const text = try self.renderTyped(@TypeOf(value), value);
        return self.setLiteralSegments(segments, text);
    }

    /// Set `segments` from an `ini.Value`, handling both a scalar and a
    /// multi-value (repeated-key) list:
    /// - `.string` behaves exactly like `setSegments` -- dialect-aware
    ///   escaping, single value token. An existing key with several in-source
    ///   occurrences (a multi-value key under an accumulate dialect)
    ///   collapses to exactly that one line, at the first occurrence's
    ///   position; every other occurrence is removed.
    /// - `.list` makes the key a multi-value key: after the call it is
    ///   backed by exactly one `key = item` line per element, in order,
    ///   each rendered the same dialect-aware way a scalar would be. An
    ///   existing key (single- or multi-value, however many physical lines
    ///   it currently has) has ALL of its lines replaced; a missing key is
    ///   created (and its section/subsection, if missing too) the same way
    ///   `setLiteralSegments` creates a scalar. An empty list removes the
    ///   key's lines entirely (matching `removeSegments`) rather than
    ///   leaving a valueless key behind, since a bare/valueless gitconfig
    ///   key already means boolean-true, not "zero values" -- absence is
    ///   the only representation that round-trips as "no values" cleanly.
    ///   Setting an absent key to an empty list is a no-op UNLESS the path
    ///   would not have been creatable anyway (an over-deep path, or one
    ///   already shadowed by an existing section) -- that still fails the
    ///   same way a non-empty list's create would, rather than silently
    ///   leaving the shadowing section untouched and unmentioned.
    /// - `.section` is `error.InvalidValue` (a section is not a leaf value).
    ///
    /// The multi-value line model matches how THIS dialect's parser reads
    /// repeated keys back (`duplicate_keys`): only under `.accumulate` does
    /// `get`/`getSegments` return the written lines as a `.list` again: under
    /// any other policy the dialect itself collapses repeated lines to a
    /// single value on re-parse, same as writing them by hand would.
    pub fn setValueSegments(self: *Document, segments: []const []const u8, value: Value) DocumentError!void {
        return switch (value) {
            .string => |s| self.setSegments(segments, s),
            .list => |items| self.setListSegments(segments, items),
            .section => error.InvalidValue,
        };
    }

    /// Splice `raw` verbatim over the value token at `path`. `raw` is NOT
    /// escaped (use `set` for dialect-aware escaping); a newline or carriage
    /// return is rejected because it would inject a physical line break, and a
    /// literal that would break the surrounding structure (an odd trailing
    /// backslash run under backslash continuation, or an unbalanced git quote)
    /// is rejected too. A value-level non-round-trip remains the caller's
    /// footgun; only document-structure breaks are refused. For a no-value key
    /// the literal is grafted as `<assign> raw`, turning it into a normal entry.
    ///
    /// When `path` is entirely absent, the key (and its section, or section
    /// and subsection, if those are missing too) is created and appended --
    /// see `setLiteralSegments` for the exact placement and formatting rules.
    pub fn setLiteral(self: *Document, path: []const u8, raw: []const u8) DocumentError!void {
        return self.setLiteralSegments(try self.segmentsFromPath(path), raw);
    }

    /// Segment-path counterpart of `setLiteral`: addresses a name containing
    /// `.` verbatim, with no splitting, and is the shared core `set`/`setLiteral`
    /// (and their segment twins) route through.
    ///
    /// An existing path is spliced exactly as `setLiteral` does today. When
    /// the key has several in-source occurrences (a multi-value key under an
    /// accumulate dialect), the first occurrence's value is spliced and every
    /// other occurrence is removed, collapsing the key to that one line. A
    /// missing path is created and appended:
    /// - 1 segment: a root-level key, only when the dialect allows
    ///   `global_keys`; appended after the last existing global key, or at
    ///   the very start of the document if there are none yet.
    /// - 2 segments: `section.key`. An existing `[section]` gets the key
    ///   appended after its last entry (or right after its header, if the
    ///   section is empty); a missing `[section]` is appended as a whole new
    ///   section at the end of the document.
    /// - 3 segments: `section.subsection.key`, only when the dialect quotes
    ///   subsections. A missing subsection is always a whole new
    ///   `[section "subsection"]` header (gitconfig has no header syntax for
    ///   "add a subsection to an existing section block"), appended at the
    ///   end of the document exactly like a missing plain section.
    ///
    /// A brand-new section/subsection is separated from prior content by
    /// exactly one blank line (none if the document is empty). A newly
    /// appended key's indentation mirrors an existing sibling in the same
    /// section; with no sibling to mirror (a fresh or still-empty section),
    /// it mirrors the first indented key anywhere else in the document, or
    /// is unindented if there is none.
    ///
    /// Any other segment count is `error.PathNotFound` (over-deep for this
    /// dialect's section/subsection/key shape). A container segment that
    /// resolves to an existing string/list value (not a section) is
    /// `error.InvalidValue`. `raw` is validated exactly as in `setLiteral`.
    pub fn setLiteralSegments(self: *Document, segments: []const []const u8, raw: []const u8) DocumentError!void {
        if (hasNewline(raw)) return error.UnrepresentableValue;
        if (escape.structureBreakingLiteral(self.options.dialect, raw)) return error.UnrepresentableValue;
        if (try self.locateSegments(segments)) |a| {
            // `locateAllOccurrences` is consulted only to detect a genuine
            // multi-occurrence key (several in-source physical lines): its
            // structural container/key walk assumes `segments` names a real
            // container-plus-key shape, which does not hold for the
            // over-segmented dotted path `locateSegments` alone resolves via
            // a raw dot-join match (see `C3` in the test suite below) -- so a
            // structural miss here (`occurrences.len <= 1`) falls back to the
            // single-splice behavior on `a`, unchanged from before this
            // multi-occurrence handling existed.
            const occurrences = try self.locateAllOccurrences(segments);
            if (occurrences.len > 1) {
                // A multi-occurrence key under an accumulate dialect (e.g. a
                // gitconfig repeated `fetch =` line): a scalar set collapses
                // it to exactly one line, at the FIRST occurrence's
                // position, by reusing the same splice-group machinery
                // `removeSegments` and the list path use to touch every
                // occurrence atomically.
                const first = occurrences[0];
                var ops: std.ArrayList(SpliceOp) = .empty;
                if (first.bare) {
                    const graft = try std.fmt.allocPrint(self.arena, " {c} {s}", .{ self.assignChar(), raw });
                    try ops.append(self.arena, .{ .start = first.key_end, .end = first.key_end, .text = graft });
                } else {
                    try ops.append(self.arena, .{ .start = first.value_start, .end = first.value_end, .text = raw });
                }
                for (occurrences[1..]) |occ| try ops.append(self.arena, .{ .start = occ.line_start, .end = occ.line_end, .text = "" });
                return self.recordSpliceGroup(ops.items);
            }
            if (a.bare) {
                const graft = try std.fmt.allocPrint(self.arena, " {c} {s}", .{ self.assignChar(), raw });
                return self.recordSplice(a.key_end, a.key_end, graft);
            }
            return self.recordSplice(a.value_start, a.value_end, raw);
        }
        // A path an earlier create in this session already added is
        // permanently invisible to `locateSegments` (see `created`'s doc
        // comment), so it is resolved here instead: a byte-identical repeat
        // is a no-op (matching how a repeat set on an originally-existing
        // path is already a no-op via the exact-range overwrite in
        // recordSplice), and a repeat with a DIFFERENT value overwrites the
        // prior create's value substring in place rather than falling
        // through to `insertSegments`, which would append a second line. A
        // path created earlier this session as the OTHER kind (a list, via
        // `setValueSegments`) is checked too: rather than appending a second,
        // duplicate backing for the same path, the prior list create's lines
        // are collapsed into this one scalar line in place.
        const created_key = try self.joinSectionFolded(segments);
        if (self.created.get(created_key)) |entry| {
            if (std.mem.eql(u8, entry.raw, raw)) return;
            return self.overwriteCreatedValue(created_key, entry, raw);
        }
        if (self.created_lists.get(created_key)) |entry| {
            return self.overwriteCreatedListAsScalar(created_key, entry, raw);
        }
        // Prepare every fallible step before the mutating insert, so a
        // failure here can never leave a splice recorded with no matching
        // `created` entry (which would break the atomicity `recordSplice`
        // otherwise guarantees).
        const owned_raw = try self.arena.dupe(u8, raw);
        try self.created.ensureUnusedCapacity(self.arena, 1);
        const seq_before = self.seq;
        const res = try self.insertSegments(segments, raw);
        self.created.putAssumeCapacity(created_key, .{
            .seq = seq_before,
            .leading = res.leading,
            .indent = res.indent,
            .key = res.key,
            .value = res.offsets[0],
            .raw = owned_raw,
        });
    }

    /// Overwrite the value substring of a path created earlier this session
    /// (found by the `Splice.seq` `created` recorded for it) with `raw`,
    /// instead of appending a whole new line the way `insertSegments` would.
    /// The zero-width create-splice's `text` is edited directly (bypassing
    /// `recordSplice`'s own dedup, which only recognizes an exact-range or a
    /// byte-identical repeat, neither of which this is) with the same
    /// rollback-on-reparse-failure discipline `recordSplice` uses elsewhere.
    fn overwriteCreatedValue(
        self: *Document,
        created_key: []const u8,
        entry: CreatedEntry,
        raw: []const u8,
    ) DocumentError!void {
        const owned_raw = try self.arena.dupe(u8, raw);
        var idx: usize = 0;
        while (self.splices.items[idx].seq != entry.seq) idx += 1;
        const old_text = self.splices.items[idx].text;
        const new_text = try std.fmt.allocPrint(self.arena, "{s}{s}{s}", .{
            old_text[0..entry.value.start], raw, old_text[entry.value.end..],
        });
        self.splices.items[idx].text = new_text;
        self.refreshView() catch |e| {
            self.splices.items[idx].text = old_text;
            return e;
        };
        self.created.putAssumeCapacity(created_key, .{
            .seq = entry.seq,
            .leading = entry.leading,
            .indent = entry.indent,
            .key = entry.key,
            .value = .{ .start = entry.value.start, .end = entry.value.start + raw.len },
            .raw = owned_raw,
        });
    }

    /// Cross-kind counterpart of `overwriteCreatedValue`: `path` was created
    /// earlier this session as a LIST (`created_lists`) and is now being
    /// re-set as a scalar. Rebuilds the same splice (found by `entry.seq`,
    /// reusing its `leading`/`indent`/`key`) as a single `key = raw` line via
    /// `buildEntryBlock`, rather than leaving the old N list lines in place
    /// and appending a new scalar line alongside them. Bookkeeping moves from
    /// `created_lists` to `created` so a further re-set (of either kind)
    /// still finds this path.
    fn overwriteCreatedListAsScalar(
        self: *Document,
        created_key: []const u8,
        entry: CreatedListEntry,
        raw: []const u8,
    ) DocumentError!void {
        const owned_raw = try self.arena.dupe(u8, raw);
        try self.created.ensureUnusedCapacity(self.arena, 1);
        var idx: usize = 0;
        while (self.splices.items[idx].seq != entry.seq) idx += 1;
        const old_text = self.splices.items[idx].text;
        const block = try self.buildEntryBlock(entry.leading, entry.indent, entry.key, &.{raw});
        self.splices.items[idx].text = block.text;
        self.refreshView() catch |e| {
            self.splices.items[idx].text = old_text;
            return e;
        };
        _ = self.created_lists.remove(created_key);
        self.created.putAssumeCapacity(created_key, .{
            .seq = entry.seq,
            .leading = entry.leading,
            .indent = entry.indent,
            .key = entry.key,
            .value = block.offsets[0],
            .raw = owned_raw,
        });
    }

    /// `setValueSegments`'s `.list` branch: render every item (dialect-aware,
    /// same as a scalar `set`) up front -- so a rejected item leaves the
    /// document untouched, before any splice is recorded -- then either
    /// remove, replace, or create the key's lines to match.
    fn setListSegments(self: *Document, segments: []const []const u8, items: []const []const u8) DocumentError!void {
        const values = try self.arena.alloc([]const u8, items.len);
        for (items, 0..) |it, i| values[i] = try self.renderTyped([]const u8, it);

        const occurrences = try self.locateAllOccurrences(segments);
        const created_key = try self.joinSectionFolded(segments);

        if (values.len == 0) {
            if (occurrences.len == 0) {
                // A path created earlier THIS session (either kind) is
                // invisible to `locateAllOccurrences` (it only scans the
                // frozen `self.source`), so an empty-list re-set on it must
                // be resolved here instead of falling through to the no-op
                // below -- otherwise the earlier create's line(s) would be
                // silently left behind instead of removed.
                if (self.created.get(created_key)) |entry| {
                    return self.clearCreatedScalar(created_key, entry);
                }
                if (self.created_lists.get(created_key)) |entry| {
                    return self.clearCreatedList(created_key, entry);
                }
                // A no-op ONLY when the path genuinely names nothing yet; a
                // path already shadowed by an existing section fails the
                // exact same way a non-empty list's create would (see
                // `validateCreatablePath`), rather than silently leaving
                // that section untouched and unmentioned.
                try self.validateCreatablePath(segments);
                return;
            }
            const ops = try self.arena.alloc(SpliceOp, occurrences.len);
            for (occurrences, 0..) |a, i| ops[i] = .{ .start = a.line_start, .end = a.line_end, .text = "" };
            try self.recordSpliceGroup(ops);
            _ = self.created.remove(created_key);
            _ = self.created_lists.remove(created_key);
            return;
        }

        if (occurrences.len == 0) {
            return self.createListSegments(segments, created_key, values);
        }

        // Reuse the first occurrence's line for values[0] (splice its value,
        // or graft one onto a bare key); delete every OTHER existing line
        // outright; append values[1..] as fresh lines mirroring the first
        // occurrence's indentation and key spelling, right after it.
        const first = occurrences[0];
        var ops: std.ArrayList(SpliceOp) = .empty;
        if (first.bare) {
            const graft = try std.fmt.allocPrint(self.arena, " {c} {s}", .{ self.assignChar(), values[0] });
            try ops.append(self.arena, .{ .start = first.key_end, .end = first.key_end, .text = graft });
        } else {
            try ops.append(self.arena, .{ .start = first.value_start, .end = first.value_end, .text = values[0] });
        }
        for (occurrences[1..]) |a| try ops.append(self.arena, .{ .start = a.line_start, .end = a.line_end, .text = "" });
        if (values.len > 1) {
            const key_text = self.keyTextFromLine(first.line_start);
            const leading = leadingNewlineIfNeeded(self.source, first.line_end);
            const block = try self.buildEntryBlock(leading, first.indent, key_text, values[1..]);
            try ops.append(self.arena, .{ .start = first.line_end, .end = first.line_end, .text = block.text });
        }
        try self.recordSpliceGroup(ops.items);
    }

    /// `setListSegments`'s create-missing-key path: parallels
    /// `setLiteralSegments`'s own create-then-cache handling, but against
    /// `created_lists` instead of `created` since a list create's splice
    /// text may need a different number of lines on a later re-set (see
    /// `CreatedListEntry`). A path created earlier this session as a SCALAR
    /// (`created`) is checked first: rather than appending a second,
    /// duplicate backing for the same path, the prior scalar create's line
    /// is expanded into this one list's lines in place.
    fn createListSegments(
        self: *Document,
        segments: []const []const u8,
        created_key: []const u8,
        values: []const []const u8,
    ) DocumentError!void {
        if (self.created.get(created_key)) |entry| {
            return self.overwriteCreatedScalarAsList(created_key, entry, values);
        }
        if (self.created_lists.get(created_key)) |entry| {
            if (itemsEqual(entry.raw, values)) return;
            return self.overwriteCreatedListValue(created_key, entry, values);
        }
        try self.created_lists.ensureUnusedCapacity(self.arena, 1);
        const seq_before = self.seq;
        const res = try self.insertListSegments(segments, values);
        self.created_lists.putAssumeCapacity(created_key, .{
            .seq = seq_before,
            .leading = res.leading,
            .indent = res.indent,
            .key = res.key,
            .items = res.offsets,
            .raw = values,
        });
    }

    /// Rebuild a whole create-list splice's `text` from scratch (reusing the
    /// ORIGINAL create's `leading`/`indent`/`key`) rather than editing a
    /// value substring in place: unlike a scalar overwrite, the number of
    /// lines itself may change between `values` and `entry`'s prior items.
    fn overwriteCreatedListValue(
        self: *Document,
        created_key: []const u8,
        entry: CreatedListEntry,
        values: []const []const u8,
    ) DocumentError!void {
        var idx: usize = 0;
        while (self.splices.items[idx].seq != entry.seq) idx += 1;
        const old_text = self.splices.items[idx].text;
        const block = try self.buildEntryBlock(entry.leading, entry.indent, entry.key, values);
        self.splices.items[idx].text = block.text;
        self.refreshView() catch |e| {
            self.splices.items[idx].text = old_text;
            return e;
        };
        self.created_lists.putAssumeCapacity(created_key, .{
            .seq = entry.seq,
            .leading = entry.leading,
            .indent = entry.indent,
            .key = entry.key,
            .items = block.offsets,
            .raw = values,
        });
    }

    /// Cross-kind counterpart of `overwriteCreatedListValue`: `path` was
    /// created earlier this session as a SCALAR (`created`) and is now being
    /// re-set as a list. Rebuilds the same splice (found by `entry.seq`,
    /// reusing its `leading`/`indent`/`key`) as `values.len` lines via
    /// `buildEntryBlock`, rather than leaving the old scalar line in place
    /// and appending a new list block alongside it. Bookkeeping moves from
    /// `created` to `created_lists` so a further re-set (of either kind)
    /// still finds this path. `values` is never empty here -- an empty list
    /// on a source-miss is handled by `setListSegments` itself, via
    /// `clearCreatedScalar`, before this is ever reached.
    fn overwriteCreatedScalarAsList(
        self: *Document,
        created_key: []const u8,
        entry: CreatedEntry,
        values: []const []const u8,
    ) DocumentError!void {
        try self.created_lists.ensureUnusedCapacity(self.arena, 1);
        var idx: usize = 0;
        while (self.splices.items[idx].seq != entry.seq) idx += 1;
        const old_text = self.splices.items[idx].text;
        const block = try self.buildEntryBlock(entry.leading, entry.indent, entry.key, values);
        self.splices.items[idx].text = block.text;
        self.refreshView() catch |e| {
            self.splices.items[idx].text = old_text;
            return e;
        };
        _ = self.created.remove(created_key);
        self.created_lists.putAssumeCapacity(created_key, .{
            .seq = entry.seq,
            .leading = entry.leading,
            .indent = entry.indent,
            .key = entry.key,
            .items = block.offsets,
            .raw = values,
        });
    }

    /// Clear a path created earlier this session as a SCALAR (`created`),
    /// entirely, for an empty-list re-set on a source-miss (see
    /// `setListSegments`): the created line's splice `text` is blanked out
    /// (rather than rebuilt) so the line disappears from `emit` output, and
    /// the path's bookkeeping is dropped so a further `set`/`setValueSegments`
    /// on it takes the genuinely-fresh create path again.
    fn clearCreatedScalar(self: *Document, created_key: []const u8, entry: CreatedEntry) DocumentError!void {
        var idx: usize = 0;
        while (self.splices.items[idx].seq != entry.seq) idx += 1;
        const old_text = self.splices.items[idx].text;
        self.splices.items[idx].text = "";
        self.refreshView() catch |e| {
            self.splices.items[idx].text = old_text;
            return e;
        };
        _ = self.created.remove(created_key);
    }

    /// `clearCreatedScalar`'s counterpart for a path created earlier this
    /// session as a LIST (`created_lists`).
    fn clearCreatedList(self: *Document, created_key: []const u8, entry: CreatedListEntry) DocumentError!void {
        var idx: usize = 0;
        while (self.splices.items[idx].seq != entry.seq) idx += 1;
        const old_text = self.splices.items[idx].text;
        self.splices.items[idx].text = "";
        self.refreshView() catch |e| {
            self.splices.items[idx].text = old_text;
            return e;
        };
        _ = self.created_lists.remove(created_key);
    }

    /// Delete the whole line containing `path`. Never creates.
    pub fn remove(self: *Document, path: []const u8) DocumentError!void {
        return self.removeSegments(try self.segmentsFromPath(path));
    }

    /// Segment-path counterpart of `remove`. Deletes EVERY physical line
    /// backing `segments`, not just one: under a dialect whose
    /// `duplicate_keys` policy is `.accumulate`, a multi-value key may be
    /// backed by several lines, and the span map (which only ever holds the
    /// LAST occurrence -- see `locateAllOccurrences`) is not enough on its
    /// own to find them all. Never creates.
    pub fn removeSegments(self: *Document, segments: []const []const u8) DocumentError!void {
        const occurrences = try self.locateAllOccurrences(segments);
        if (occurrences.len == 0) return error.PathNotFound;
        const ops = try self.arena.alloc(SpliceOp, occurrences.len);
        for (occurrences, 0..) |a, i| ops[i] = .{ .start = a.line_start, .end = a.line_end, .text = "" };
        try self.recordSpliceGroup(ops);
        const created_key = try self.joinSectionFolded(segments);
        _ = self.created.remove(created_key);
        _ = self.created_lists.remove(created_key);
    }

    /// Insert a comment line immediately before the line containing `path`.
    /// The leading whitespace of the target line is mirrored; the comment
    /// character and a trailing newline are added automatically. Never creates.
    pub fn addCommentBefore(self: *Document, path: []const u8, text: []const u8) DocumentError!void {
        if (hasNewline(text)) return error.InvalidComment;
        const a = try self.locate(path) orelse return error.PathNotFound;
        const line = try std.fmt.allocPrint(self.arena, "{s}{c} {s}\n", .{ a.indent, self.commentChar(), text });
        try self.recordSplice(a.line_start, a.line_start, line);
    }

    /// Set or replace the trailing comment on the line containing `path`. For a
    /// continuation value the comment lands after the last physical line, so the
    /// join stays intact. A trailing comment only round-trips under a dialect
    /// that strips inline comments; otherwise the appended bytes would re-parse
    /// as value text, so the call is refused. A no-value key is first grafted
    /// with an empty value (`<assign>`) so the comment attaches without
    /// clobbering the key. Never creates.
    pub fn setTrailingComment(self: *Document, path: []const u8, text: []const u8) DocumentError!void {
        if (!self.options.dialect.inline_comments) return error.CommentsNotSupported;
        if (hasNewline(text)) return error.InvalidComment;
        const a = try self.locate(path) orelse return error.PathNotFound;
        if (a.bare) {
            const graft = try std.fmt.allocPrint(self.arena, " {c}  {c} {s}", .{ self.assignChar(), self.commentChar(), text });
            return self.recordSplice(a.key_end, a.key_end, graft);
        }
        const repl = try std.fmt.allocPrint(self.arena, "  {c} {s}", .{ self.commentChar(), text });
        try self.recordSplice(a.value_end, a.content_end, repl);
    }

    /// Write the document, applying any recorded splices to the original
    /// buffer in order. With no splices the buffer is written verbatim.
    /// A leading BOM present in the original input is re-emitted first.
    pub fn emit(self: *const Document, w: *Io.Writer) Io.Writer.Error!void {
        if (self.bom) try w.writeAll("\xEF\xBB\xBF");
        var pos: usize = 0;
        for (self.splices.items) |s| {
            if (s.start < pos) continue;
            try w.writeAll(self.source[pos..s.start]);
            try w.writeAll(s.text);
            pos = s.end;
        }
        try w.writeAll(self.source[pos..]);
    }

    /// Resolve `path` to its `Anchors`, splitting it into segments the same
    /// way `PathIterator` always has. `null` when the path does not resolve;
    /// allocation failure propagates (building the segment list allocates).
    fn locate(self: *const Document, path: []const u8) DocumentError!?Anchors {
        return self.locateSegments(try self.segmentsFromPath(path));
    }

    /// Segment-path counterpart of `locate`: resolve explicit segments (no
    /// splitting) to their `Anchors` by looking up the same dot-joined key
    /// `recordSpan` stores (so a name containing `.` is addressable, matching
    /// `Section.locateSegments`).
    fn locateSegments(self: *const Document, segments: []const []const u8) DocumentError!?Anchors {
        if (segments.len == 0) return null;
        const joined = try self.joinSectionFolded(segments);
        const span = self.spans.get(joined) orelse return null;
        return self.anchorsForSpan(span);
    }

    /// `Anchors` for EVERY physical line backing `segments`, in source order.
    /// `locateSegments` resolves through the span map, which `recordSpan`
    /// overwrites on each repeat, so for a multi-value key (`duplicate_keys
    /// = .accumulate`) it only ever holds the LAST occurrence's span; this
    /// walks the whole source directly instead, so `removeSegments` and
    /// `setListSegments` can find and touch every one.
    ///
    /// Gated on `duplicate_keys == .accumulate`: under any other policy a
    /// same-named duplicate line in the source is a shadowed/superseded
    /// occurrence, not a genuine multi-value entry (the parser itself never
    /// treats it as one), so this delegates to plain `locateSegments` and
    /// returns at most the one occurrence it already resolves -- preserving
    /// `removeSegments`'s existing single-line behavior there exactly.
    ///
    /// Also gated on `segments` being no deeper than `maxDepth` (section,
    /// optional subsection, key): a dotted-STRING path addressing a
    /// subsection whose own name contains a `.` (e.g. `branch.feature.x.merge`
    /// for gitconfig's `[branch "feature.x"]`) over-segments into MORE parts
    /// than the dialect's header shape has, so `container = segments[0..len-1]`
    /// no longer names a reconstructable section(+subsection) -- `locateSegments`
    /// resolves such a path only via its raw dot-joined span-map key (the
    /// same anchor the parser itself stored it under), and there is no way to
    /// walk the source scanning for "every occurrence in that container"
    /// because the container itself cannot be rebuilt from the segments. This
    /// falls back to that single dot-joined anchor instead of scanning a
    /// truncated (and therefore wrong) container. The segments-ARRAY API
    /// (e.g. `&.{"branch", "feature.x", "merge"}`) is unaffected: there the
    /// subsection is already its own segment, so `segments.len` stays within
    /// `maxDepth` and multi-occurrence scanning below still applies.
    fn locateAllOccurrences(self: *const Document, segments: []const []const u8) DocumentError![]Anchors {
        if (segments.len == 0) return &.{};
        if (self.options.dialect.duplicate_keys != .accumulate or segments.len > self.maxDepth()) {
            const a = try self.locateSegments(segments) orelse return &.{};
            const out = try self.arena.alloc(Anchors, 1);
            out[0] = a;
            return out;
        }

        const d = self.options.dialect;
        const container = segments[0 .. segments.len - 1];
        const key = segments[segments.len - 1];
        const target_path = try self.joinContainerPath(container);
        const target_key = try self.foldedKey(key);

        var out: std.ArrayList(Anchors) = .empty;
        var current_path: []const u8 = "";
        var tz = tok.Tokenizer.init(self.source, d);
        while (tz.next()) |t| {
            switch (t.kind) {
                .section_header => {
                    const raw = self.source[@intCast(t.span.start)..@intCast(t.span.end)];
                    const parts = parser_mod.splitHeader(raw, d) catch continue;
                    const sec = if (d.case_insensitive_sections) try parser_mod.toLowerAlloc(self.arena, parts.name) else parts.name;
                    if (parts.subsection) |raw_sub| {
                        const sub = try escape.unescapeSubsection(self.arena, raw_sub);
                        current_path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ sec, sub });
                    } else {
                        current_path = sec;
                    }
                },
                .key_value => {
                    if (!std.mem.eql(u8, current_path, target_path)) continue;
                    const line_start: usize = @intCast(t.span.start);
                    const line_key = self.keyTextFromLine(line_start);
                    const folded = try self.foldedKey(line_key);
                    if (!std.mem.eql(u8, folded, target_key)) continue;
                    const first_end = firstLineEnd(self.source, line_start);
                    const content = self.source[line_start..first_end];
                    const assign = tok.findAssign(content, d.assign_chars);
                    if (assign) |a_idx| {
                        var vs = line_start + a_idx + 1;
                        while (vs < self.source.len and (self.source[vs] == ' ' or self.source[vs] == '\t')) vs += 1;
                        try out.append(self.arena, self.anchorsForSpan(.{ .start = vs, .end = t.span.end }));
                    } else {
                        try out.append(self.arena, self.anchorsForSpan(.{ .start = line_start, .end = line_start }));
                    }
                },
                else => {},
            }
        }
        return out.items;
    }

    /// The exact source spelling of the key on the line starting at
    /// `line_start`, trimmed of surrounding whitespace -- used to mirror an
    /// existing key's own spelling (rather than the caller's path segment,
    /// which may differ only in case under a folding dialect) when appending
    /// more lines for the same multi-value key.
    fn keyTextFromLine(self: *const Document, line_start: usize) []const u8 {
        const d = self.options.dialect;
        const first_end = firstLineEnd(self.source, line_start);
        const content = self.source[line_start..first_end];
        const assign = tok.findAssign(content, d.assign_chars);
        const raw = if (assign) |a| content[0..a] else content;
        return std.mem.trim(u8, raw, " \t");
    }

    /// Join a CONTAINER-only path (section, or section+subsection) the same
    /// way the parser's own `current_path` is built while scanning
    /// (`openHeader` in parser.zig): the section segment folds under
    /// `case_insensitive_sections`; a subsection is never folded. Distinct
    /// from `joinSectionFolded`, which joins a FULL path (container plus a
    /// trailing leaf key) and folds its last segment as a key instead.
    fn joinContainerPath(self: *const Document, container: []const []const u8) Allocator.Error![]const u8 {
        if (container.len == 0) return "";
        const sec = try self.foldedSection(container[0]);
        if (container.len == 2) return try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ sec, container[1] });
        return sec;
    }

    /// Join `segments` into the dot-joined key `recordSpan` stores: the
    /// section-name segment (index 0, only when there is a section --
    /// `segments.len >= 2`) folds under `case_insensitive_sections` (see
    /// `foldedSection`), and the leaf-key segment (the last one, at any
    /// depth including a 1-segment root-level global key) folds under
    /// `case_insensitive_keys` (see `foldedKey`) -- both match how the
    /// parser stores them (`openHeader` / `storeKey` in parser.zig). A
    /// subsection segment (index 1 of a 3-segment path) is never folded --
    /// it is always stored case-sensitively.
    fn joinSectionFolded(self: *const Document, segments: []const []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (segments, 0..) |seg, i| {
            if (i > 0) try out.append(self.arena, '.');
            const folded = if (i == 0 and segments.len >= 2)
                try self.foldedSection(seg)
            else if (i == segments.len - 1)
                try self.foldedKey(seg)
            else
                seg;
            try out.appendSlice(self.arena, folded);
        }
        return out.items;
    }

    /// Split a dotted string path into arena-owned segments, exactly as
    /// `Section.get` splits one for navigation.
    fn segmentsFromPath(self: *const Document, path: []const u8) Allocator.Error![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var it = value_mod.PathIterator{ .rest = path };
        while (it.next()) |seg| try list.append(self.arena, seg);
        return list.items;
    }

    /// Compute the full set of byte anchors for a value at `span`. Shared by
    /// `locateSegments` (an existing path) and the create-missing-key paths,
    /// which anchor off a sibling entry's span the same way.
    fn anchorsForSpan(self: *const Document, span: Span) Anchors {
        const src = self.source;
        const dialect = self.options.dialect;
        // u64 span offsets index an in-memory buffer, so they fit usize.
        const value_start: usize = @intCast(span.start);
        const value_span_end: usize = @intCast(span.end);
        const line_start = lineStartOf(src, value_start);

        // Walk physical lines from the entry's first line so edits cover the
        // whole logical line: a continuation value's span records only its first
        // physical line, but remove/set must reach the last continuation line.
        const ext = logicalExtent(src, dialect, line_start);
        const value_end: usize = if (ext.multi)
            ext.last_start + valueTokenLen(src[ext.last_start..ext.content_end], dialect)
        else
            value_start + valueTokenLen(src[value_start..value_span_end], dialect);

        // A no-value key carries the synthetic empty string, so its span falls
        // back to the whole first line (covering the key, not a value). Detect it
        // by the absence of an assign char so set/setTrailingComment graft onto
        // the key instead of overwriting it.
        const first_end = firstLineEnd(src, line_start);
        const bare = tok.findAssign(src[line_start..first_end], dialect.assign_chars) == null;
        const key_end: usize = if (bare) keyTokenEnd(src, line_start, first_end) else value_end;

        return .{
            .line_start = line_start,
            .value_start = value_start,
            .value_end = value_end,
            .content_end = ext.content_end,
            .line_end = ext.line_end,
            .indent = indentOf(src, line_start),
            .bare = bare,
            .key_end = key_end,
        };
    }

    /// Deepest segment count this dialect's header shape can express: section
    /// + quoted subsection + key when subsections are quoted, else section +
    /// key. A single-segment path (a root-level key) is representable only
    /// when the dialect allows `global_keys`, checked separately.
    fn maxDepth(self: *const Document) usize {
        return if (self.options.dialect.subsections == .quoted) 3 else 2;
    }

    /// Resolve every segment but the last (the section, or section and
    /// subsection) against the ORIGINAL parse. `null` when that container is
    /// entirely or partially missing (create it); `error.InvalidValue` when a
    /// segment along the way already names a string/list value instead of a
    /// section (can neither be descended into nor created under).
    ///
    /// Segment 0 (the top-level section name) is folded the same way the
    /// parser folds it under `case_insensitive_sections` before comparing,
    /// so `set("X.k", v)` resolves INTO an existing `[x]` instead of
    /// mismatching and creating a case-variant `[X]` header that would merge
    /// with `[x]` on re-parse. A subsection segment (index 1) is never
    /// folded -- it is always stored case-sensitively (see `openHeader` in
    /// parser.zig).
    fn resolveContainer(self: *const Document, container: []const []const u8) (error{InvalidValue} || Allocator.Error)!?*Section {
        var cur: *Section = self.parsed.section;
        for (container, 0..) |seg, i| {
            const lookup = if (i == 0) try self.foldedSection(seg) else seg;
            const val = cur.findValue(lookup) orelse return null;
            if (val != .section) return error.InvalidValue;
            cur = val.section;
        }
        return cur;
    }

    /// Fold `key` the same way the parser will store it once it is written
    /// as a key: lower-cased under `case_insensitive_keys`, unchanged
    /// otherwise. Used both before a `Section.findValue` shadowing check (so
    /// the comparison matches what a re-parse will actually collide on,
    /// instead of the byte-exact match `findValue` performs on its own) and
    /// by `joinSectionFolded` to fold the leaf segment of a span-map lookup
    /// key the same way `recordSpan` folded it when storing.
    fn foldedKey(self: *const Document, key: []const u8) Allocator.Error![]const u8 {
        return if (self.options.dialect.case_insensitive_keys)
            try parser_mod.toLowerAlloc(self.arena, key)
        else
            key;
    }

    /// Fold a top-level section-name segment the same way the parser folds
    /// it when storing (`openHeader` in parser.zig): lower-cased under
    /// `case_insensitive_sections`, unchanged otherwise. A quoted subsection
    /// is always stored case-sensitively and must never be passed here.
    fn foldedSection(self: *const Document, name: []const u8) Allocator.Error![]const u8 {
        return if (self.options.dialect.case_insensitive_sections)
            try parser_mod.toLowerAlloc(self.arena, name)
        else
            name;
    }

    /// Create and append the key (and its section/subsection, if missing)
    /// named by `segments`. Called only after `locateSegments` has already
    /// missed, so `segments` is known not to resolve today. A thin
    /// single-value wrapper over `insertListSegments` (`&.{raw}`), sharing
    /// its validation and placement logic entirely: a created scalar's
    /// `leading`/`indent`/`key` therefore come from the exact same place a
    /// created list's do, letting `created`'s `CreatedEntry` carry them too
    /// (see its doc comment), for a same-session cross-kind re-set.
    fn insertSegments(self: *Document, segments: []const []const u8, raw: []const u8) DocumentError!ListInsertResult {
        return self.insertListSegments(segments, &.{raw});
    }

    /// Key of the last entry in `section` that is a scalar (string/list), not
    /// a nested subsection, or null if it has none. Scans backward since a
    /// mixed section (rare, but valid: a bare `[branch]` block followed later
    /// by `[branch "main"]`) always has its subsection entries trailing its
    /// own direct keys in file order.
    fn lastScalarKey(section: *const Section) ?[]const u8 {
        var i = section.entries.len;
        while (i > 0) {
            i -= 1;
            if (section.entries[i].value != .section) return section.entries[i].key;
        }
        return null;
    }

    /// Return shape shared by `insertGlobalKeyList`/`insertKeyIntoSectionList`/
    /// `appendNewSectionList` once they build a multi-line block (or, via
    /// `insertSegments`'s single-value wrapper, a one-line block): the
    /// strings needed to rebuild an equivalent block later (see
    /// `overwriteCreatedListValue`/`overwriteCreatedScalarAsList`), plus each
    /// item's `ValueOffset`.
    const ListInsertResult = struct {
        leading: []const u8,
        indent: []const u8,
        key: []const u8,
        offsets: []ValueOffset,
    };

    /// Build a multi-line `key = value` block, one line per item, all
    /// sharing `key` and `indent`, prefixed by `leading` -- shared by
    /// `insertGlobalKeyList`/`insertKeyIntoSectionList`/`appendNewSectionList`
    /// (and, via `insertSegments`'s single-value wrapper, its own one-line
    /// case). Returns the block text plus each item's `ValueOffset` within
    /// it, in order.
    fn buildEntryBlock(
        self: *Document,
        leading: []const u8,
        indent: []const u8,
        key: []const u8,
        values: []const []const u8,
    ) Allocator.Error!struct { text: []const u8, offsets: []ValueOffset } {
        const eol = dominantEol(self.source);
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.arena, leading);
        const offsets = try self.arena.alloc(ValueOffset, values.len);
        for (values, 0..) |v, i| {
            try buf.appendSlice(self.arena, indent);
            try buf.appendSlice(self.arena, key);
            try buf.append(self.arena, ' ');
            try buf.append(self.arena, self.assignChar());
            try buf.append(self.arena, ' ');
            const start = buf.items.len;
            try buf.appendSlice(self.arena, v);
            offsets[i] = .{ .start = start, .end = buf.items.len };
            try buf.appendSlice(self.arena, eol);
        }
        return .{ .text = buf.items, .offsets = offsets };
    }

    /// Create and append `key` (and its section/subsection, if missing) as a
    /// block of `values.len` lines. `insertSegments` is a thin single-value
    /// wrapper around this (`&.{raw}`, see its doc comment): every scalar
    /// create shares this same validation and placement logic with a list
    /// create, rather than duplicating it.
    fn insertListSegments(self: *Document, segments: []const []const u8, values: []const []const u8) DocumentError!ListInsertResult {
        try self.validateCreatablePath(segments);
        const key = segments[segments.len - 1];

        if (segments.len == 1) return self.insertGlobalKeyList(key, values);

        const container = segments[0 .. segments.len - 1];
        if (try self.resolveContainer(container)) |section| {
            return self.insertKeyIntoSectionList(container, section, key, values);
        }
        return self.appendNewSectionList(container, key, values);
    }

    /// Every check `insertSegments`/`insertListSegments` perform before
    /// actually writing anything: right segment count, valid key/section
    /// text, and no shadowing collision with an existing section. Shared
    /// with `setListSegments`'s empty-list-on-an-absent-path case, which
    /// must fail the exact same way a non-empty list's create WOULD --
    /// rather than silently succeeding as a no-op while the path still
    /// shadows a section it never touched.
    fn validateCreatablePath(self: *const Document, segments: []const []const u8) DocumentError!void {
        const max_depth = self.maxDepth();
        if (segments.len == 0 or segments.len > max_depth) return error.PathNotFound;
        const key = segments[segments.len - 1];
        try self.validateKeyText(key);

        if (segments.len == 1) {
            if (!self.options.dialect.global_keys) return error.PathNotFound;
            if (self.parsed.section.findValue(try self.foldedKey(key))) |existing| {
                if (existing == .section) return error.InvalidValue;
            }
            return;
        }

        const container = segments[0 .. segments.len - 1];
        try self.validateSectionName(container[0], container.len == 2);
        if (container.len == 2) try validateSubsectionName(container[1]);

        if (try self.resolveContainer(container)) |section| {
            if (section.findValue(try self.foldedKey(key))) |existing| {
                if (existing == .section) return error.InvalidValue;
            }
        }
    }

    /// Append a root-level (global) key as a block of `values.len` lines:
    /// after the last existing global key, or at the very start of the
    /// document if there are none (global keys must precede every section
    /// header). Unindented. Shared by `insertSegments` (a single-value
    /// wrapper) and `insertListSegments`.
    fn insertGlobalKeyList(self: *Document, key: []const u8, values: []const []const u8) DocumentError!ListInsertResult {
        var last_key: ?[]const u8 = null;
        for (self.parsed.section.entries) |e| {
            if (e.value == .section) break;
            last_key = e.key;
        }
        var at: usize = 0;
        if (last_key) |lk| {
            const a = self.anchorsForSpan(self.spans.get(lk).?);
            at = a.line_end;
        }
        const leading = leadingNewlineIfNeeded(self.source, at);
        const block = try self.buildEntryBlock(leading, "", key, values);
        try self.recordSplice(at, at, block.text);
        return .{ .leading = leading, .indent = "", .key = key, .offsets = block.offsets };
    }

    /// Append `key` into an already-resolved, existing `section`, as a block
    /// of `values.len` lines: after its last SCALAR entry (mirroring that
    /// entry's indentation) -- a top-level section's entries may mix scalars
    /// with subsections (e.g. a bare `[branch]` block followed by
    /// `[branch "main"]`), and only a scalar entry has a span to anchor on.
    /// With no scalar entry, falls back to right after the section's own
    /// bare header line (mirroring the first indented key found anywhere
    /// else in the document, if any); with no bare header line either (a
    /// top-level section that exists only as `[section "sub"]` blocks),
    /// falls back to appending a whole new bare section, same as a
    /// genuinely missing one. Shared by `insertSegments` (a single-value
    /// wrapper) and `insertListSegments`.
    fn insertKeyIntoSectionList(
        self: *Document,
        container: []const []const u8,
        section: *Section,
        key: []const u8,
        values: []const []const u8,
    ) DocumentError!ListInsertResult {
        var at: usize = undefined;
        var indent: []const u8 = undefined;
        if (lastScalarKey(section)) |last_key| {
            var full_segments: [3][]const u8 = undefined;
            for (container, 0..) |seg, i| full_segments[i] = seg;
            full_segments[container.len] = last_key;
            const full = try self.joinSectionFolded(full_segments[0 .. container.len + 1]);
            const a = self.anchorsForSpan(self.spans.get(full).?);
            at = a.line_end;
            indent = a.indent;
        } else if (self.headerLineEnd(container)) |end| {
            at = end;
            indent = self.prevailingIndent();
        } else {
            return self.appendNewSectionList(container, key, values);
        }
        const leading = leadingNewlineIfNeeded(self.source, at);
        const block = try self.buildEntryBlock(leading, indent, key, values);
        try self.recordSplice(at, at, block.text);
        return .{ .leading = leading, .indent = indent, .key = key, .offsets = block.offsets };
    }

    /// Append a whole new section (or `[section "subsection"]`) plus a block
    /// of `values.len` lines at the end of the document, separated from
    /// prior content by exactly one blank line (none if the document is
    /// empty). This is the only place a header line is created, so a
    /// subsection is always a full new header -- gitconfig has no syntax for
    /// adding a subsection to an existing `[section]` block. Shared by
    /// `insertSegments` (a single-value wrapper) and `insertListSegments`.
    fn appendNewSectionList(self: *Document, container: []const []const u8, key: []const u8, values: []const []const u8) DocumentError!ListInsertResult {
        const nl = dominantEol(self.source);
        const header = if (container.len == 2) blk: {
            const sub = try escapeSubsectionName(self.arena, container[1]);
            break :blk try std.fmt.allocPrint(self.arena, "[{s} \"{s}\"]{s}", .{ container[0], sub, nl });
        } else try std.fmt.allocPrint(self.arena, "[{s}]{s}", .{ container[0], nl });
        const sep = newSectionSeparator(self.source);
        const indent = self.prevailingIndent();
        const leading = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ sep, header });
        const block = try self.buildEntryBlock(leading, indent, key, values);
        try self.recordSpliceKind(self.source.len, self.source.len, block.text, true);
        return .{ .leading = leading, .indent = indent, .key = key, .offsets = block.offsets };
    }

    /// Byte offset just past the source line of the first header matching
    /// `container` (1 name, or 2 for a quoted subsection), or null if none is
    /// found. Used only to anchor a key appended into a section/subsection
    /// that exists but has zero entries, where no entry span is available.
    /// Reuses the real tokenizer and header splitter so this always agrees
    /// with how `self.parsed` itself read the file.
    fn headerLineEnd(self: *const Document, container: []const []const u8) ?usize {
        const d = self.options.dialect;
        var tz = tok.Tokenizer.init(self.source, d);
        while (tz.next()) |t| {
            if (t.kind != .section_header) continue;
            const raw = self.source[@intCast(t.span.start)..@intCast(t.span.end)];
            const parts = parser_mod.splitHeader(raw, d) catch continue;
            const name_matches = if (d.case_insensitive_sections)
                std.ascii.eqlIgnoreCase(parts.name, container[0])
            else
                std.mem.eql(u8, parts.name, container[0]);
            if (!name_matches) continue;
            if (container.len == 2) {
                const raw_sub = parts.subsection orelse continue;
                const sub = escape.unescapeSubsection(self.arena, raw_sub) catch continue;
                if (!std.mem.eql(u8, sub, container[1])) continue;
            } else if (parts.subsection != null) {
                continue;
            }
            return tz.pos;
        }
        return null;
    }

    /// Indentation of the first key/value line anywhere in the document, or
    /// "" if there are none. Used to pick an indent for a freshly created key
    /// with no local sibling to mirror.
    fn prevailingIndent(self: *const Document) []const u8 {
        var tz = tok.Tokenizer.init(self.source, self.options.dialect);
        while (tz.next()) |t| {
            if (t.kind != .key_value) continue;
            return indentOf(self.source, @intCast(t.span.start));
        }
        return "";
    }

    /// Reject a key that would not survive a re-parse as the SAME key: empty,
    /// a line break, containing an assign char (would truncate it early),
    /// edge whitespace under a trimming dialect, or a leading byte that would
    /// misclassify the line as a comment or section header.
    fn validateKeyText(self: *const Document, key: []const u8) DocumentError!void {
        if (key.len == 0) return error.EmptyKey;
        if (hasNewline(key)) return error.UnrepresentableValue;
        const d = self.options.dialect;
        if (std.mem.indexOfAny(u8, key, d.assign_chars) != null) return error.UnrepresentableValue;
        if (d.trim_whitespace and edgeWhitespace(key)) return error.UnrepresentableValue;
        if (std.mem.indexOfScalar(u8, d.comment_chars, key[0]) != null) return error.UnrepresentableValue;
        if (key[0] == '[') return error.UnrepresentableValue;
        if (d.quoting == .git and !parser_mod.validGitKey(key)) return error.InvalidKey;
    }

    /// Reject a section (or plain, non-subsection header) name that would not
    /// survive a re-parse as the SAME name: empty, a line break, an embedded
    /// `"` under a subsection-quoting dialect (would be misread as opening a
    /// subsection), an invalid git section-name charset, or edge whitespace
    /// that would actually be trimmed away on re-parse. A quoted-subsection
    /// header (`has_subsection`) always trims its outer name, regardless of
    /// `trim_section_names`; a plain header only trims when the dialect does
    /// (`generic`'s `trim_section_names = false` makes `[ s ]` a legitimately
    /// distinct, round-tripping section there).
    fn validateSectionName(self: *const Document, name: []const u8, has_subsection: bool) DocumentError!void {
        if (name.len == 0) return error.MalformedSectionHeader;
        if (hasNewline(name)) return error.UnrepresentableValue;
        const d = self.options.dialect;
        if ((has_subsection or d.trim_section_names) and edgeWhitespace(name)) return error.UnrepresentableValue;
        if (d.subsections == .quoted and std.mem.indexOfScalar(u8, name, '"') != null) return error.UnrepresentableValue;
        if (d.quoting == .git and !parser_mod.validGitSectionName(name)) return error.MalformedSectionHeader;
    }

    /// Reject a subsection name that would not survive a re-parse: empty or a
    /// line break. Otherwise unrestricted -- `escapeSubsectionName` encodes
    /// any backslash or double quote so the header stays well-formed.
    fn validateSubsectionName(name: []const u8) DocumentError!void {
        if (name.len == 0) return error.MalformedSectionHeader;
        if (hasNewline(name)) return error.UnrepresentableValue;
    }

    /// Record a splice. A pure insertion (`start == end`) always composes,
    /// stacking with other edits at the same point; an exact-range repeat of a
    /// prior range edit overwrites it (last-wins); a partial range overlap is
    /// rejected as a conflict. Splices stay ordered by (start, insertions before
    /// range edits, call order) so `emit` applies them without a sort.
    ///
    /// The refresh is atomic: an edit whose emitted bytes fail to re-parse is
    /// rolled back (its splice removed / its overwritten text restored) so a
    /// failed edit leaves the document EXACTLY as before and get()==emit()==pre-edit.
    fn recordSplice(self: *Document, start: usize, end: usize, text: []const u8) DocumentError!void {
        return self.recordSpliceKind(start, end, text, false);
    }

    /// `recordSplice` with an explicit `tail` (see `Splice.tail`): a brand-new
    /// end-of-file section block passes `true` so it sorts after any same-offset
    /// insertion into existing content.
    fn recordSpliceKind(self: *Document, start: usize, end: usize, text: []const u8, tail: bool) DocumentError!void {
        const new_range = end > start;
        for (self.splices.items, 0..) |s, i| {
            const ex_range = s.end > s.start;
            if (new_range and ex_range) {
                if (s.start == start and s.end == end) {
                    const prev = self.splices.items[i].text;
                    self.splices.items[i].text = try self.arena.dupe(u8, text);
                    self.refreshView() catch |e| {
                        self.splices.items[i].text = prev;
                        return e;
                    };
                    return;
                }
                if (start < s.end and s.start < end) return error.ConflictingEdit;
            } else if (new_range and !ex_range) {
                // An existing insertion strictly inside the new range would be
                // emitted mid-replacement.
                if (start < s.start and s.start < end) return error.ConflictingEdit;
            } else if (!new_range and ex_range) {
                if (s.start < start and start < s.end) return error.ConflictingEdit;
            } else if (s.start == start and std.mem.eql(u8, s.text, text)) {
                // Both are zero-width insertions at the same point with
                // byte-identical text: an exact repeat of a prior insertion
                // (e.g. splicing the same value onto a key whose value was
                // already empty, so both start and end sit at that same
                // point). Two DIFFERENT insertions at the same point still
                // legitimately compose (handled below); only a byte-for-byte
                // repeat is a no-op, matching the idempotence every other
                // edit already has via the exact-range overwrite above.
                return;
            }
        }
        const owned = try self.arena.dupe(u8, text);
        const sp = Splice{ .start = start, .end = end, .text = owned, .seq = self.seq, .tail = tail };
        var idx: usize = 0;
        while (idx < self.splices.items.len and spliceLess(self.splices.items[idx], sp)) idx += 1;
        try self.splices.insert(self.arena, idx, sp);
        self.seq += 1;
        self.refreshView() catch |e| {
            _ = self.splices.orderedRemove(idx);
            self.seq -= 1;
            return e;
        };
    }

    /// Record several splices as one atomic group: `recordSplice` already
    /// rolls back its OWN attempt on a reparse failure, but that alone would
    /// leave any EARLIER call in the same group still applied. This restores
    /// the splice list (and re-derives `view` from it) to exactly how it was
    /// before the group started, so a multi-line edit (removing every
    /// occurrence of a multi-value key, or replacing one with a different
    /// number of lines) is genuinely all-or-nothing.
    fn recordSpliceGroup(self: *Document, ops: []const SpliceOp) DocumentError!void {
        const saved_len = self.splices.items.len;
        const saved_seq = self.seq;
        for (ops) |op| {
            self.recordSplice(op.start, op.end, op.text) catch |e| {
                self.splices.shrinkRetainingCapacity(saved_len);
                self.seq = saved_seq;
                self.refreshView() catch |e2| return e2;
                return e;
            };
        }
    }

    /// Reparse the current emitted bytes into `view` so reads reflect pending
    /// edits. `parsed`/`spans`/`source`/`splices` stay pinned to the original,
    /// keeping edit resolution and conflict detection byte-exact; only the read
    /// view moves. `emit` re-prepends any BOM and the parser re-strips it. On a
    /// re-parse failure `view` is left untouched (the assignment never runs), so
    /// the caller can roll the triggering splice back to restore consistency.
    fn refreshView(self: *Document) DocumentError!void {
        var aw: Io.Writer.Allocating = .init(self.arena);
        self.emit(&aw.writer) catch return error.OutOfMemory;
        var opts = self.options;
        opts.spans = null;
        self.view = try parser_mod.parse(self.arena, aw.written(), opts);
    }

    fn renderTyped(self: *const Document, comptime T: type, value: T) DocumentError![]const u8 {
        const plain = try plainRepr(self.arena, T, value);
        if (escape.unrepresentableSpliced(self.options.dialect, plain)) return error.UnrepresentableValue;
        if (self.options.dialect.quoting != .git) return plain;
        var aw: Io.Writer.Allocating = .init(self.arena);
        escapeGit(&aw.writer, plain) catch return error.OutOfMemory;
        return aw.written();
    }

    fn commentChar(self: *const Document) u8 {
        const cc = self.options.dialect.comment_chars;
        if (std.mem.indexOfScalar(u8, cc, '#') != null) return '#';
        if (cc.len > 0) return cc[0];
        return '#';
    }

    fn assignChar(self: *const Document) u8 {
        const ac = self.options.dialect.assign_chars;
        if (std.mem.indexOfScalar(u8, ac, '=') != null) return '=';
        if (ac.len > 0) return ac[0];
        return '=';
    }
};

fn plainRepr(arena: Allocator, comptime T: type, value: T) DocumentError![]const u8 {
    return switch (@typeInfo(T)) {
        .bool => if (value) "true" else "false",
        .int, .comptime_int => try std.fmt.allocPrint(arena, "{d}", .{value}),
        .float, .comptime_float => try std.fmt.allocPrint(arena, "{}", .{value}),
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) break :blk value;
            if (p.size == .one) {
                const ci = @typeInfo(p.child);
                if (ci == .array and ci.array.child == u8) break :blk @as([]const u8, value);
            }
            @compileError("Document.set: unsupported value type " ++ @typeName(T));
        },
        else => @compileError("Document.set: unsupported value type " ++ @typeName(T)),
    };
}

/// Length of the value token within `raw`, excluding a trailing comment and
/// the whitespace before it. A comment character terminates the value only
/// when the dialect strips inline comments (otherwise the comment char is value
/// text), preceded by whitespace, and outside a quoted span.
fn valueTokenLen(raw: []const u8, dialect: Dialect) usize {
    var i: usize = 0;
    var last: usize = 0;
    var in_quotes = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (dialect.quoting == .git and c == '\\' and i + 1 < raw.len) {
            i += 1;
            last = i + 1;
            continue;
        }
        if (c == '"') {
            in_quotes = !in_quotes;
            last = i + 1;
            continue;
        }
        if (!in_quotes and (c == ' ' or c == '\t')) continue;
        if (!in_quotes and dialect.inline_comments and i > 0 and
            (raw[i - 1] == ' ' or raw[i - 1] == '\t') and
            std.mem.indexOfScalar(u8, dialect.comment_chars, c) != null)
        {
            break;
        }
        last = i + 1;
    }
    return last;
}

fn lineStartOf(src: []const u8, pos: usize) usize {
    var i: usize = pos;
    while (i > 0 and src[i - 1] != '\n') i -= 1;
    return i;
}

/// Offset of the first physical line's content end (before its terminator).
fn firstLineEnd(src: []const u8, line_start: usize) usize {
    var i: usize = line_start;
    while (i < src.len and src[i] != '\n' and src[i] != '\r') i += 1;
    return i;
}

/// Offset just past the bare key's last non-whitespace byte on its line.
fn keyTokenEnd(src: []const u8, line_start: usize, first_end: usize) usize {
    var e: usize = first_end;
    while (e > line_start and (src[e - 1] == ' ' or src[e - 1] == '\t')) e -= 1;
    return e;
}

fn indentOf(src: []const u8, line_start: usize) []const u8 {
    var i: usize = line_start;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    return src[line_start..i];
}

fn hasNewline(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\n\r") != null;
}

/// Element-wise byte equality of two rendered-item slices, for
/// `createListSegments`' repeat-set-is-a-no-op check.
fn itemsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// True when `s` has a leading or trailing space/tab, which a trimming
/// dialect would strip on re-parse.
fn edgeWhitespace(s: []const u8) bool {
    if (s.len == 0) return false;
    return s[0] == ' ' or s[0] == '\t' or s[s.len - 1] == ' ' or s[s.len - 1] == '\t';
}

/// Escape `\` and `"` for a quoted subsection header (`[section "name"]`),
/// the git-recognized pair `unescapeSubsection` decodes back. Any other byte
/// (already screened for a line break by the caller) passes through verbatim.
fn escapeSubsectionName(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, name, "\\\"") == null) return name;
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| {
        if (c == '\\' or c == '"') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    return out.items;
}

/// The line terminator `source` uses, so freshly appended lines mirror it
/// instead of always emitting a bare `\n` (which would mix line endings into
/// a CRLF source). Detected from the LAST newline in the source: `"\r\n"`
/// when it is preceded by a carriage return, `"\n"` otherwise -- also the
/// default for a source with no newline at all.
fn dominantEol(source: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, source, '\n')) |i| {
        if (i > 0 and source[i - 1] == '\r') return "\r\n";
    }
    return "\n";
}

/// Leading bytes to prepend before a brand-new section header so it starts
/// its own paragraph: no separator for an empty document (nothing precedes
/// it), one blank line when the document already ends in one, two newlines
/// (terminate the dangling last line, then a blank line) otherwise. Mirrors
/// `source`'s line terminator; a blank-line check that only looked for
/// `"\n\n"` would miss a CRLF source's `"\r\n\r\n"` (whose last two bytes are
/// `"\r\n"`, not `"\n\n"`) and double up the blank line.
fn newSectionSeparator(source: []const u8) []const u8 {
    if (source.len == 0) return "";
    if (std.mem.endsWith(u8, source, "\n\n") or std.mem.endsWith(u8, source, "\r\n\r\n")) return "";
    const crlf = std.mem.eql(u8, dominantEol(source), "\r\n");
    if (std.mem.endsWith(u8, source, "\n")) return if (crlf) "\r\n" else "\n";
    return if (crlf) "\r\n\r\n" else "\n\n";
}

/// A single line terminator (mirroring `source`'s) to prepend when `at` does
/// not already sit right after a newline (or at the very start of the
/// source), so text inserted there starts its own line instead of running
/// onto a dangling, unterminated prior line.
fn leadingNewlineIfNeeded(source: []const u8, at: usize) []const u8 {
    if (at == 0 or source[at - 1] == '\n') return "";
    return dominantEol(source);
}

/// Ordering for the splice list: by start, then insertions (zero-width) before
/// range edits at the same start, then by call order.
fn spliceLess(a: Splice, b: Splice) bool {
    if (a.start != b.start) return a.start < b.start;
    const a_ins = a.start == a.end;
    const b_ins = b.start == b.end;
    if (a_ins != b_ins) return a_ins;
    // Among zero-width insertions at the same offset, an end-of-file new
    // section block always emits after an insertion into existing content, so
    // a key appended into a section that ends the file is not displaced into
    // a later-appended section (see `Splice.tail`).
    if (a_ins and a.tail != b.tail) return b.tail;
    return a.seq < b.seq;
}

/// Byte extent of an entry's last physical line. `multi` is set when the value
/// spans continuation lines; `last_start` is that final line's content start,
/// `content_end` its content end (before the terminator), `line_end` the offset
/// just past its terminator.
const LogicalExtent = struct {
    multi: bool,
    last_start: usize,
    content_end: usize,
    line_end: usize,
};

/// Find where an entry's logical line ends by re-classifying physical lines
/// from `line_start` with the same framing the tokenizer uses, so the document
/// and parser agree on continuation boundaries. Trailing blank lines (which the
/// parser drops from the value) are not folded into the extent.
fn logicalExtent(src: []const u8, dialect: Dialect, line_start: usize) LogicalExtent {
    var tz = tok.Tokenizer.init(src[line_start..], dialect);
    const first = tz.next() orelse return .{
        .multi = false,
        .last_start = line_start,
        .content_end = line_start,
        .line_end = line_start,
    };
    var ext = LogicalExtent{
        .multi = false,
        .last_start = line_start,
        .content_end = line_start + @as(usize, @intCast(first.span.end)),
        .line_end = line_start + tz.pos,
    };
    while (tz.next()) |t| {
        switch (t.kind) {
            .continuation => {
                ext.multi = true;
                ext.last_start = line_start + @as(usize, @intCast(t.span.start));
                ext.content_end = line_start + @as(usize, @intCast(t.span.end));
                ext.line_end = line_start + tz.pos;
            },
            // A blank inside an indent value block is only part of the value if a
            // later continuation follows; keep scanning without committing it.
            .blank => {},
            else => break,
        }
    }
    return ext;
}

const testing = std.testing;

test "unmodified document emits byte-identical" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "# header\n[remote \"o\"]\n\turl = u  # trailing\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings(src, aw.written());
}

test "set produces a minimal diff and preserves comments" {
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[user]\n\tname = Ada  # who\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    try doc.set("user.name", "Grace");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings("[user]\n\tname = Grace  # who\n", aw.written());
}

test "a failed edit leaves the document unchanged (atomic)" {
    // A missing section/key no longer errors (it is created -- see the
    // CREATE tests below); an over-deep path still does, since gitconfig's
    // header shape has no fourth level to create.
    const G = @import("dialect.zig").Dialect.gitconfig;
    const src = "[user]\n\tname = Ada\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    try std.testing.expectError(error.PathNotFound, doc.set("missing.section.sub.key", "x"));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try std.testing.expectEqualStrings(src, aw.written());
}

test "an edit whose emitted bytes fail to re-parse rolls back fully (atomic)" {
    // setLiteral only screens structure-breaking literals, not every literal
    // that is invalid on re-parse: `a\zb` carries an invalid git escape, caught
    // only when refreshView re-parses the emitted bytes. A failed refresh must
    // leave the document EXACTLY as before - no recorded splice, view intact -
    // so get() and emit() stay consistent (both pre-edit).
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = orig\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });

    try testing.expectError(error.InvalidEscape, doc.setLiteral("s.k", "a\\zb"));
    // Fully rolled back: the read is the pre-edit value, and emit is byte-exact.
    try testing.expectEqualStrings("orig", doc.get("s.k").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());

    // A subsequent valid edit still lands in both get() and emit().
    try doc.setLiteral("s.k", "new");
    try testing.expectEqualStrings("new", doc.get("s.k").?.string);
    var aw2: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw2.writer);
    try testing.expectEqualStrings("[s]\n\tk = new\n", aw2.written());
}

test "a rolled-back overwrite edit leaves a prior successful edit intact" {
    // The exact-range last-wins overwrite path must also roll back: a valid edit,
    // then a same-range edit whose bytes fail to re-parse, must leave the first
    // edit's value visible in both get() and emit().
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = orig\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });

    try doc.setLiteral("s.k", "good");
    try testing.expectError(error.InvalidEscape, doc.setLiteral("s.k", "a\\zb"));
    try testing.expectEqualStrings("good", doc.get("s.k").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\n\tk = good\n", aw.written());
}

test "get and getT read the parsed tree" {
    const src = "[server]\nport = 8080\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("8080", doc.get("server.port").?.string);
    try testing.expectEqual(@as(u16, 8080), (try doc.getT(u16, "server.port")).?);
}

test "C3: get/getT reflect a pending set (read-after-write matches emit)" {
    const src = "[server]\nport = 8080\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.set("server.port", @as(u16, 9999));
    // The read now agrees with what emit will write.
    try testing.expectEqualStrings("9999", doc.get("server.port").?.string);
    try testing.expectEqual(@as(u16, 9999), (try doc.getT(u16, "server.port")).?);
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("[server]\nport = 9999\n", out);
}

test "C3: get reflects setLiteral, and set-then-set returns the latest value" {
    const src = "[s]\nk = a\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.setLiteral("s.k", "b");
    try testing.expectEqualStrings("b", doc.get("s.k").?.string);
    // Repeated edit to the same path (exact-range last-wins) is visible.
    try doc.setLiteral("s.k", "c");
    try testing.expectEqualStrings("c", doc.get("s.k").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\nk = c\n", aw.written());
}

test "C3: get reflects a pending remove (read-after-write matches emit)" {
    const src = "[s]\na = 1\nb = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.remove("s.a");
    try testing.expect(doc.get("s.a") == null);
    try testing.expect(try doc.getT(u32, "s.a") == null);
    // The surviving key still reads.
    try testing.expectEqualStrings("2", doc.get("s.b").?.string);
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\nb = 2\n", aw.written());
}

test "C3: set-then-remove leaves get null, matching emit" {
    const src = "[s]\nk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.set("s.k", @as([]const u8, "new"));
    try testing.expectEqualStrings("new", doc.get("s.k").?.string);
    // remove spans the value edit's line -> conflict is rejected atomically, so
    // the read still reflects the set. (Documents the interaction, not a bug.)
    try testing.expectError(error.ConflictingEdit, doc.remove("s.k"));
    try testing.expectEqualStrings("new", doc.get("s.k").?.string);
}

test "C3: a grafted value on a bare gitconfig key is visible via get" {
    const G = Dialect.gitconfig;
    const src = "[core]\n\tbare\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    // Before the edit the bare key reads as the empty string.
    try testing.expectEqualStrings("", doc.get("core.bare").?.string);
    try doc.set("core.bare", @as([]const u8, "yes"));
    try testing.expectEqualStrings("yes", doc.get("core.bare").?.string);
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[core]\n\tbare = yes\n", out);
}

test "C3: getSegments on a document reflects edits to a dotted subsection" {
    const G = Dialect.gitconfig;
    const src = "[branch \"feature.x\"]\n\tmerge = refs/heads/main\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    // Reachable only by segments (the '.' in the subsection name).
    try testing.expectEqualStrings(
        "refs/heads/main",
        doc.getSegments(&.{ "branch", "feature.x", "merge" }).?.string,
    );
    // Edit that same value through the dotted path git-config would use, and see
    // the segment read reflect it.
    try doc.set("branch.feature.x.merge", @as([]const u8, "refs/heads/dev"));
    try testing.expectEqualStrings(
        "refs/heads/dev",
        doc.getSegments(&.{ "branch", "feature.x", "merge" }).?.string,
    );
    try testing.expectEqualStrings(
        "refs/heads/dev",
        (try doc.getTSegments([]const u8, &.{ "branch", "feature.x", "merge" })).?,
    );
}

test "setLiteral splices raw text verbatim" {
    const src = "[server]\nport = 8080\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try doc.setLiteral("server.port", "9999");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[server]\nport = 9999\n", aw.written());
}

test "set typed values render and escape per dialect" {
    const G = Dialect.gitconfig;
    const src = "[core]\n\tbare = old\n\tn = 0\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    try doc.set("core.bare", true);
    try doc.set("core.n", @as(i64, 42));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[core]\n\tbare = true\n\tn = 42\n", aw.written());
}

test "remove deletes the whole line" {
    const src = "[s]\na = 1\nb = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try doc.remove("s.a");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\nb = 2\n", aw.written());
}

test "remove on a missing path is atomic" {
    const src = "[s]\na = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try testing.expectError(error.PathNotFound, doc.remove("s.missing"));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "addCommentBefore mirrors indentation" {
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try doc.addCommentBefore("s.k", "note");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\n\t# note\n\tk = v\n", aw.written());
}

test "setTrailingComment replaces an existing trailing comment (reparses to same value)" {
    const G = Dialect.gitconfig;
    const src = "[user]\n\tname = Ada  # who\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setTrailingComment("user.name", "person");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[user]\n\tname = Ada  # person\n", out);
    // The comment is stripped on re-parse; the value is untouched.
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("Ada", v2.get("user.name").?.string);
}

test "setTrailingComment adds a comment when none exists (reparses to same value)" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setTrailingComment("s.k", "added");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = v  # added\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("v", v2.get("s.k").?.string);
}

test "R5: setTrailingComment refuses a non-inline dialect (atomic)" {
    // Under a dialect that does NOT strip inline comments the appended `# text`
    // would re-parse as value bytes, so the call is refused before any splice.
    inline for (.{ Dialect.strict, Dialect.generic, Dialect.systemd, Dialect.windows }) |D| {
        const src = "[s]\nk = v\n";
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), src, .{ .dialect = D });
        try testing.expectError(error.CommentsNotSupported, doc.setTrailingComment("s.k", "added"));
        var aw: std.Io.Writer.Allocating = .init(arena.allocator());
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings(src, aw.written());
    }
}

test "DOC6: BOM is stripped for parsing and re-emitted verbatim by emit" {
    const src = "\xEF\xBB\xBF[s]\nk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{});
    try testing.expectEqualStrings("v", doc.get("s.k").?.string);
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "DOC3: set rejects values that would not survive a re-parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // strict: leading whitespace would be trimmed away.
    {
        var doc = try Document.parse(a, "[s]\nk = orig\n", .{ .dialect = Dialect.strict });
        try testing.expectError(error.UnrepresentableValue, doc.set("s.k", @as([]const u8, " lead")));
    }
    // strict: an embedded newline would shatter the document structure.
    {
        var doc = try Document.parse(a, "[s]\nk = orig\n", .{ .dialect = Dialect.strict });
        try testing.expectError(error.UnrepresentableValue, doc.set("s.k", @as([]const u8, "a\nb")));
    }
    // generic: a carriage return is rejected even though git is not involved.
    {
        var doc = try Document.parse(a, "[s]\nk = orig\n", .{ .dialect = Dialect.generic });
        try testing.expectError(error.UnrepresentableValue, doc.set("s.k", @as([]const u8, "a\rb")));
    }
}

test "DOC3: a rejected set leaves the document unchanged (atomic)" {
    const src = "[s]\nk = orig\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try testing.expectError(error.UnrepresentableValue, doc.set("s.k", @as([]const u8, "a\nb")));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "DOC3: a representable value still round-trips through set" {
    // A '#' is not stripped by any non-git dialect, so it must NOT be rejected.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, "[s]\nk = orig\n", .{ .dialect = Dialect.generic });
    try doc.set("s.k", @as([]const u8, "a # b"));
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    const v2 = try parser_mod.parse(a, aw.written(), .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("a # b", v2.get("s.k").?.string);
}

test "DOC3: setLiteral rejects a structure-breaking newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), "[s]\nk = orig\n", .{ .dialect = Dialect.strict });
    try testing.expectError(error.UnrepresentableValue, doc.setLiteral("s.k", "a\nb"));
    try testing.expectError(error.UnrepresentableValue, doc.setLiteral("s.k", "a\rb"));
    // A plain raw splice is still allowed (the documented footgun stays usable).
    try doc.setLiteral("s.k", "raw value");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\nk = raw value\n", aw.written());
}

test "DOC6: set on a BOM document round-trips BOM in output" {
    const src = "\xEF\xBB\xBF[s]\nk = old\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{});
    try doc.set("s.k", "new");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("\xEF\xBB\xBF[s]\nk = new\n", aw.written());
}

/// Emit `doc` and re-parse the result, asserting the round-trip is well-formed.
fn emitAndReparse(arena: Allocator, doc: *const Document, opts: parser_mod.ParseOptions) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try doc.emit(&aw.writer);
    _ = try parser_mod.parse(arena, aw.written(), opts);
    return aw.written();
}

test "DOC1: remove deletes the whole continuation line (gitconfig backslash)" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"]\n\turl = first \\\n\tsecond\n[other]\n\tx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.remove("remote.o.url");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    // No orphaned `\tsecond` line, and the unrelated key survives.
    try testing.expectEqualStrings("[remote \"o\"]\n[other]\n\tx = 1\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expect(v2.get("remote.o.url") == null);
    try testing.expectEqualStrings("1", v2.get("other.x").?.string);
}

test "DOC1: remove deletes the whole continuation line (generic indent)" {
    const src = "[s]\nkey = first\n    second\n[other]\nx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
    try doc.remove("s.key");
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("[s]\n[other]\nx = 1\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.generic });
    try testing.expect(v2.get("s.key") == null);
    try testing.expectEqualStrings("1", v2.get("other.x").?.string);
}

test "DOC1: set replaces the whole continuation value (gitconfig)" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"]\n\turl = first \\\n\tsecond\n[other]\n\tx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("remote.o.url", "new");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[remote \"o\"]\n\turl = new\n[other]\n\tx = 1\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("new", v2.get("remote.o.url").?.string);
    try testing.expectEqualStrings("1", v2.get("other.x").?.string);
}

test "DOC1: set replaces the whole continuation value (generic indent)" {
    const src = "[s]\nkey = first\n    second\nother = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
    try doc.set("s.key", "new");
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("[s]\nkey = new\nother = 1\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("new", v2.get("s.key").?.string);
    try testing.expectEqualStrings("1", v2.get("s.other").?.string);
}

test "DOC1: setLiteral replaces the whole continuation value (generic indent)" {
    const src = "[s]\nkey = first\n    second\nother = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
    try doc.setLiteral("s.key", "raw");
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("[s]\nkey = raw\nother = 1\n", out);
}

test "DOC2: setTrailingComment lands after the last continuation line" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"]\n\turl = first \\\n\tsecond\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    const before = doc.get("remote.o.url").?.string;
    try doc.setTrailingComment("remote.o.url", "note");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    // The `\` continuation stays intact; the comment sits on the last line.
    try testing.expectEqualStrings("[remote \"o\"]\n\turl = first \\\n\tsecond  # note\n", out);
    // The joined value is unchanged (the comment is stripped on re-parse).
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings(before, v2.get("remote.o.url").?.string);
}

test "DOC4: addCommentBefore and remove compose (both orders)" {
    const src = "[s]\na = 1\nb = 2\n";
    inline for (.{ true, false }) |comment_first| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
        if (comment_first) {
            try doc.addCommentBefore("s.a", "note");
            try doc.remove("s.a");
        } else {
            try doc.remove("s.a");
            try doc.addCommentBefore("s.a", "note");
        }
        var aw: std.Io.Writer.Allocating = .init(arena.allocator());
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings("[s]\n# note\nb = 2\n", aw.written());
    }
}

test "DOC4: two addCommentBefore on one key stack both comments" {
    const src = "[s]\na = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try doc.addCommentBefore("s.a", "one");
    try doc.addCommentBefore("s.a", "two");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\n# one\n# two\na = 1\n", aw.written());
}

test "DOC4: set and setTrailingComment on one key compose" {
    const G = Dialect.gitconfig;
    const src = "[user]\n\tname = Ada\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    try doc.set("user.name", "Grace");
    try doc.setTrailingComment("user.name", "who");
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[user]\n\tname = Grace  # who\n", aw.written());
}

test "DOC4: genuinely overlapping range edits are rejected, atomically" {
    const src = "[s]\na = 1\nb = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = Dialect.strict });
    try doc.set("s.a", "9");
    // remove spans the line set already edited -> conflict, records nothing.
    try testing.expectError(error.ConflictingEdit, doc.remove("s.a"));
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[s]\na = 9\nb = 2\n", aw.written());
}

test "DOC5: a comment with a newline is rejected (no structure injection)" {
    // gitconfig strips inline comments, so setTrailingComment is supported here;
    // the rejection under test is the comment TEXT carrying a newline.
    const G = Dialect.gitconfig;
    const src = "[s]\nk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try Document.parse(arena.allocator(), src, .{ .dialect = G });
    try testing.expectError(error.InvalidComment, doc.addCommentBefore("s.k", "a\n[evil]\nx = 1"));
    try testing.expectError(error.InvalidComment, doc.setTrailingComment("s.k", "a\r b"));
    // Rejected edits are atomic: the document is untouched.
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "DOC7: set on an empty value re-parses correctly (post-= space left as-is)" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk =\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("s.k", "v");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk =v\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("v", v2.get("s.k").?.string);
}

test "R4: set on a non-inline dialect overwrites the whole value past a false '#'" {
    // generic does not strip inline comments, so `hello # world` is one value;
    // set must overwrite all of it, not truncate at the ` #` boundary.
    const src = "[s]\nk = hello # world\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("hello # world", doc.get("s.k").?.string);
    try doc.set("s.k", @as([]const u8, "NEW"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("[s]\nk = NEW\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("NEW", v2.get("s.k").?.string);
}

test "R4: gitconfig set still stops at a real inline comment" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = a ; c\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("s.k", @as([]const u8, "NEW"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = NEW ; c\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("NEW", v2.get("s.k").?.string);
}

test "R6: set on a bare gitconfig key grafts a value without clobbering the key" {
    const G = Dialect.gitconfig;
    const src = "[core]\n\tbare\n\tx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("core.bare", @as([]const u8, "yes"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[core]\n\tbare = yes\n\tx = 1\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("yes", v2.get("core.bare").?.string);
    try testing.expectEqualStrings("1", v2.get("core.x").?.string);
}

test "R6: setLiteral on a bare gitconfig key grafts the raw literal" {
    const G = Dialect.gitconfig;
    const src = "[core]\n\tbare\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setLiteral("core.bare", "raw");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[core]\n\tbare = raw\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("raw", v2.get("core.bare").?.string);
}

test "R6: setTrailingComment on a bare gitconfig key attaches without clobbering" {
    const G = Dialect.gitconfig;
    const src = "[core]\n\tbare\n\tx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setTrailingComment("core.bare", "tc");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[core]\n\tbare =  # tc\n\tx = 1\n", out);
    // The key survives; its value stays the bare empty string.
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("", v2.get("core.bare").?.string);
    try testing.expectEqualStrings("1", v2.get("core.x").?.string);
}

test "R2: setLiteral rejects an odd trailing backslash under backslash continuation (atomic)" {
    // systemd has no quoting; an odd trailing '\' would swallow the next line.
    const src = "[s]\nk = v\nnext = w\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.systemd });
    try testing.expectError(error.UnrepresentableValue, doc.setLiteral("s.k", "a\\"));
    try testing.expectError(error.UnrepresentableValue, doc.setLiteral("s.k", "a\\\\\\"));
    // An even run is an escaped pair, not a continuation: still allowed.
    try doc.setLiteral("s.k", "a\\\\");
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.systemd });
    try testing.expectEqualStrings("[s]\nk = a\\\\\nnext = w\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.systemd });
    try testing.expectEqualStrings("w", v2.get("s.next").?.string);
}

test "R2: setLiteral rejects an unbalanced git quote (atomic)" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n\tnext = w\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try testing.expectError(error.UnrepresentableValue, doc.setLiteral("s.k", "a\"b"));
    // An escaped quote does not open a span: still allowed.
    try doc.setLiteral("s.k", "a\\\"b");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = a\\\"b\n\tnext = w\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("a\"b", v2.get("s.k").?.string);
    try testing.expectEqualStrings("w", v2.get("s.next").?.string);
}

// CREATE: missing section, empty-document bootstrap, and segment paths.

test "CREATE: set creates a missing section, byte-preserving existing comments and entries" {
    const G = Dialect.gitconfig;
    const src = "# top-level comment\n[user]\n\tname = Ada\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("server.port", @as(u16, 8080));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    // One blank line separates the new section; its key mirrors the "\t"
    // indentation already used by the existing section's entry.
    try testing.expectEqualStrings(
        "# top-level comment\n[user]\n\tname = Ada\n\n[server]\n\tport = 8080\n",
        out,
    );
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    // The comment, the existing section, and its entry all survive untouched.
    try testing.expectEqualStrings("Ada", v2.get("user.name").?.string);
    try testing.expectEqualStrings("8080", v2.get("server.port").?.string);
}

test "CREATE: set into an empty document bootstraps the whole section and key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.empty(a, .{ .dialect = Dialect.strict });
    // An untouched empty() document emits exactly the empty string.
    var aw0: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw0.writer);
    try testing.expectEqualStrings("", aw0.written());

    try doc.set("server.port", @as(u16, 8080));
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("[server]\nport = 8080\n", out);
    try testing.expectEqualStrings("8080", doc.get("server.port").?.string);
}

test "CREATE: setSegments creates a section literally named with a dot, not a nested path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.empty(a, .{ .dialect = Dialect.strict });
    try doc.setSegments(&.{ "weird.name", "key" }, @as([]const u8, "v"));
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[weird.name]\nkey = v\n", aw.written());

    // Re-parse independently and walk the tree: exactly one section named
    // "weird.name" verbatim (Dialect.strict has no subsection syntax to fold
    // it into), not a nested "weird" -> "name".
    const v2 = try parser_mod.parse(a, aw.written(), .{ .dialect = Dialect.strict });
    try testing.expectEqual(@as(usize, 1), v2.section.entries.len);
    try testing.expectEqualStrings("weird.name", v2.section.entries[0].key);
    try testing.expectEqualStrings("v", v2.section.entries[0].value.section.entries[0].value.string);
    // The dotted string API cannot address this (a 3-deep path is over the
    // 2-deep strict-dialect cap), confirming segments were required.
    try testing.expect(doc.get("weird.name.key") == null);
}

test "CREATE: removeSegments removes an entry addressed by explicit segments" {
    const G = Dialect.gitconfig;
    const src = "[branch \"feature.x\"]\n\tmerge = refs/heads/main\n\tremote = origin\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.removeSegments(&.{ "branch", "feature.x", "merge" });
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[branch \"feature.x\"]\n\tremote = origin\n", out);
}

test "CREATE: an existing section+key set via segments is byte-identical to the string-path route" {
    const src = "[s]\nk = old\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc1 = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc1.setLiteral("s.k", "new");
    var aw1: std.Io.Writer.Allocating = .init(a);
    try doc1.emit(&aw1.writer);

    var doc2 = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc2.setLiteralSegments(&.{ "s", "k" }, "new");
    var aw2: std.Io.Writer.Allocating = .init(a);
    try doc2.emit(&aw2.writer);

    try testing.expectEqualStrings(aw1.written(), aw2.written());
    try testing.expectEqualStrings("[s]\nk = new\n", aw1.written());
}

test "CREATE: an over-deep segment path errors without creating anything" {
    const G = Dialect.gitconfig;
    const src = "[a]\n\tx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    // gitconfig's deepest shape is section + subsection + key (3 segments).
    try testing.expectError(error.PathNotFound, doc.setSegments(&.{ "a", "b", "c", "d" }, @as([]const u8, "v")));
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "CREATE: a single-segment path is a root key only when the dialect allows global_keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // strict: no global_keys -> a bare 1-segment path can never be created.
    {
        var doc = try Document.parse(a, "[s]\nk = v\n", .{ .dialect = Dialect.strict });
        try testing.expectError(error.PathNotFound, doc.set("y", @as([]const u8, "2")));
    }
    // generic: global_keys -> appended after the last existing global key.
    {
        var doc = try Document.parse(a, "x = 1\n[s]\nk = v\n", .{ .dialect = Dialect.generic });
        try doc.set("y", @as([]const u8, "2"));
        const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
        try testing.expectEqualStrings("x = 1\ny = 2\n[s]\nk = v\n", out);
    }
    // generic, no existing global key: created at the very start of the file.
    {
        var doc = try Document.parse(a, "[s]\nk = v\n", .{ .dialect = Dialect.generic });
        try doc.set("y", @as([]const u8, "2"));
        const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
        try testing.expectEqualStrings("y = 2\n[s]\nk = v\n", out);
    }
}

test "CREATE: create a missing gitconfig subsection appends a whole new header block" {
    const G = Dialect.gitconfig;
    const src = "[branch \"main\"]\n\tmerge = refs/heads/main\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("branch.feature.merge", @as([]const u8, "refs/heads/feature"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings(
        "[branch \"main\"]\n\tmerge = refs/heads/main\n\n[branch \"feature\"]\n\tmerge = refs/heads/feature\n",
        out,
    );
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("refs/heads/main", v2.get("branch.main.merge").?.string);
    try testing.expectEqualStrings("refs/heads/feature", v2.get("branch.feature.merge").?.string);
}

test "CREATE: set appends a key into an existing but entirely empty section" {
    const src = "[cache]\n[other]\nx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.set("cache.ttl", @as(u32, 300));
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("[cache]\nttl = 300\n[other]\nx = 1\n", out);
}

test "CREATE: a container segment that already names a scalar is InvalidValue, not created" {
    const src = "server = direct\n[other]\nx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
    try testing.expectError(error.InvalidValue, doc.set("server.port", @as([]const u8, "9000")));
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "CREATE: two sequential creates into the same still-missing section both survive" {
    // Each create resolves against the ORIGINAL parse (matching every other
    // edit in this Document), so a section created by one call is not yet
    // visible to a second create in the same session; both append a full new
    // header block at the end of the document. Under the default (and every
    // built-in preset's) `duplicate_sections = .merge` policy the two blocks
    // simply merge on read, so both keys are set correctly -- just not as
    // tidily as a single merged block.
    const G = Dialect.gitconfig;
    const src = "[a]\n\tx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("b.y", @as([]const u8, "1"));
    try doc.set("b.z", @as([]const u8, "2"));
    try testing.expectEqualStrings("1", doc.get("b.y").?.string);
    try testing.expectEqualStrings("2", doc.get("b.z").?.string);
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "[b]"));
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("1", v2.get("b.y").?.string);
    try testing.expectEqualStrings("2", v2.get("b.z").?.string);
}

test "CREATE: a key appended into the file's last section stays there when a new section was created first" {
    // Both edits anchor at the same zero-width offset: the source's last
    // section ends exactly at EOF, so appending a key into it lands at
    // `source.len` -- the very offset a brand-new section block is appended
    // at. Ordered by recording sequence alone, the key issued AFTER the
    // new-section create would emit after that new block, silently slipping
    // into the wrong section. The new-section block must always emit last.
    const G = Dialect.generic;
    const src = "[s1]\nk1 = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setSegments(&.{ "s2", "k2" }, @as([]const u8, "x")); // create a new section
    try doc.setSegments(&.{ "s1", "new" }, @as([]const u8, "N")); // append into the last existing one
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    const v = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("N", v.getSegments(&.{ "s1", "new" }).?.string);
    try testing.expectEqualStrings("v", v.getSegments(&.{ "s1", "k1" }).?.string);
    try testing.expectEqualStrings("x", v.getSegments(&.{ "s2", "k2" }).?.string);
    // `new` sits inside [s1], before the appended [s2] header.
    const new_at = std.mem.indexOf(u8, out, "new = N").?;
    const s2_at = std.mem.indexOf(u8, out, "[s2]").?;
    try testing.expect(new_at < s2_at);
}

test "CREATE: a list key appended into the file's last section stays there after a new section create" {
    // The multi-value (`setValueSegments` .list) counterpart of the scalar
    // last-section-at-EOF displacement: the same EOF-offset collision applies
    // to a whole appended `key = item` block.
    const G = Dialect.gitconfig;
    const src = "[s1]\nk1 = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setValueSegments(&.{ "s2", "k2" }, .{ .list = &.{ "a", "b" } }); // new section
    try doc.setValueSegments(&.{ "s1", "new" }, .{ .list = &.{ "p", "q" } }); // into last existing
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    const v = try parser_mod.parse(a, out, .{ .dialect = G });
    const got = v.getSegments(&.{ "s1", "new" }).?;
    try testing.expectEqual(@as(usize, 2), got.list.len);
    try testing.expectEqualStrings("p", got.list[0]);
    try testing.expectEqualStrings("q", got.list[1]);
    const new_at = std.mem.indexOf(u8, out, "new = p").?;
    const s2_at = std.mem.indexOf(u8, out, "[s2]").?;
    try testing.expect(new_at < s2_at);
}

test "CREATE: repeating an identical create-set on a freshly created path is a byte-identical no-op" {
    // A path a prior edit created is invisible to locateSegments forever
    // after (its span map stays pinned to the ORIGINAL parse -- see the
    // `created` field), so without the `created` cache below, repeating the
    // exact same set would not recognize its own prior create and would
    // append a second, duplicate entry instead of the no-op every other
    // repeated set already is.
    const G = Dialect.gitconfig;
    const src = "[s]\nk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("s.newkey", @as([]const u8, "x"));
    var aw1: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw1.writer);
    const out1 = try a.dupe(u8, aw1.written());

    try doc.set("s.newkey", @as([]const u8, "x"));
    var aw2: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw2.writer);
    try testing.expectEqualStrings(out1, aw2.written());

    // gitconfig accumulates duplicate keys, so a real (non-idempotent) repeat
    // would have silently turned "x" from a scalar into a 2-element list.
    const v2 = try parser_mod.parse(a, aw2.written(), .{ .dialect = G });
    try testing.expectEqualStrings("x", v2.get("s.newkey").?.string);

    // A DIFFERENT value on the same freshly created path is still a genuine
    // second edit, not swallowed by the cache -- and it overwrites the prior
    // create in place (one line) rather than appending a second line, which
    // would silently turn "s.newkey" from a scalar into a 2-element list
    // under gitconfig's accumulate duplicate-key policy.
    try doc.set("s.newkey", @as([]const u8, "y"));
    var aw3: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw3.writer);
    try testing.expect(!std.mem.eql(u8, out1, aw3.written()));
    try testing.expectEqualStrings("y", doc.get("s.newkey").?.string);
    const v3 = try parser_mod.parse(a, aw3.written(), .{ .dialect = G });
    try testing.expectEqualStrings("y", v3.get("s.newkey").?.string);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, aw3.written(), "newkey"));
}

test "CREATE: a case-variant KEY under a case-folding dialect resolves into the existing key (BUG2)" {
    // gitconfig folds keys (and sections) but not subsections. A case-variant
    // KEY must resolve INTO the already-parsed entry instead of falling
    // through to the create path and appending a duplicate line, which would
    // silently turn a scalar into a 2-element list under gitconfig's
    // accumulate duplicate-key policy.
    const G = Dialect.gitconfig;
    const src = "[core]\n\tautocrlf = input\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setSegments(&.{ "core", "AUTOCRLF" }, @as([]const u8, "false"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[core]\n\tautocrlf = false\n", out);
    try testing.expectEqualStrings("false", doc.get("core.autocrlf").?.string);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
    try testing.expectEqualStrings("false", v2.get("core.autocrlf").?.string);
}

test "CREATE: a case-variant KEY under a case-sensitive dialect stays distinct" {
    // strict never folds key names, so "AUTOCRLF" and the existing
    // "autocrlf" are genuinely distinct keys, matching set()'s ordinary
    // create-missing behavior.
    const src = "[core]\nautocrlf = input\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.setSegments(&.{ "core", "AUTOCRLF" }, @as([]const u8, "false"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("[core]\nautocrlf = input\nAUTOCRLF = false\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("input", v2.get("core.autocrlf").?.string);
    try testing.expectEqualStrings("false", v2.get("core.AUTOCRLF").?.string);
}

test "DOC1: repeating an identical set on an empty existing value is a byte-identical no-op" {
    // "k = " has an empty value at a zero-width span (value_start ==
    // value_end): recordSplice's insertion-vs-insertion dedup must still
    // fire for two zero-width splices at the same point with identical
    // text, not just for a non-empty (non-zero-width) range.
    const src = "[s]\nk = \n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.setLiteral("s.k", "v");
    var aw1: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw1.writer);
    const out1 = try a.dupe(u8, aw1.written());
    try testing.expectEqualStrings("[s]\nk = v\n", out1);

    try doc.setLiteral("s.k", "v");
    var aw2: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw2.writer);
    try testing.expectEqualStrings(out1, aw2.written());
    try testing.expectEqualStrings("v", doc.get("s.k").?.string);
}

test "CREATE: a brand-new section with no trailing newline in the source gets terminated first" {
    const src = "[a]\n\tx = 1";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.gitconfig });
    try doc.set("b.y", @as([]const u8, "2"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.gitconfig });
    try testing.expectEqualStrings("[a]\n\tx = 1\n\n[b]\n\ty = 2\n", out);
}

test "CREATE: a brand-new section after an existing blank line gets no extra blank line" {
    const src = "[a]\n\tx = 1\n\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.gitconfig });
    try doc.set("b.y", @as([]const u8, "2"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.gitconfig });
    try testing.expectEqualStrings("[a]\n\tx = 1\n\n[b]\n\ty = 2\n", out);
}

test "CREATE: a key or section name that would not round-trip is rejected before any splice" {
    // A key containing the assign char would truncate itself on re-parse.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), "[x]\ny = 1\n", .{ .dialect = Dialect.gitconfig });
        try testing.expectError(error.UnrepresentableValue, doc.setSegments(&.{ "newsec", "a=b" }, @as([]const u8, "v")));
    }
    // A key starting with a comment char would misclassify the whole line.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), "[x]\ny = 1\n", .{ .dialect = Dialect.gitconfig });
        try testing.expectError(error.UnrepresentableValue, doc.setSegments(&.{ "newsec", "#bad" }, @as([]const u8, "v")));
    }
    // A key starting with '[' would misclassify as a section header.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), "[x]\ny = 1\n", .{ .dialect = Dialect.gitconfig });
        try testing.expectError(error.UnrepresentableValue, doc.setSegments(&.{ "newsec", "[bad" }, @as([]const u8, "v")));
    }
    // A section name with edge whitespace would be trimmed differently on re-parse.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), "[x]\ny = 1\n", .{ .dialect = Dialect.gitconfig });
        try testing.expectError(error.UnrepresentableValue, doc.setSegments(&.{ " newsec", "k" }, @as([]const u8, "v")));
    }
    // A plain section name containing '"' under a subsection-quoting dialect
    // would be misread as opening a quoted subsection.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), "[x]\ny = 1\n", .{ .dialect = Dialect.gitconfig });
        try testing.expectError(error.UnrepresentableValue, doc.setSegments(&.{ "weird\"name", "k" }, @as([]const u8, "v")));
    }
    // A subsection name with an embedded newline would break the header line.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), "[x]\ny = 1\n", .{ .dialect = Dialect.gitconfig });
        try testing.expectError(error.UnrepresentableValue, doc.setSegments(&.{ "branch", "bad\nsub", "k" }, @as([]const u8, "v")));
    }
    // An empty section name or key.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), "[x]\ny = 1\n", .{ .dialect = Dialect.strict });
        try testing.expectError(error.MalformedSectionHeader, doc.setSegments(&.{ "", "k" }, @as([]const u8, "v")));
        try testing.expectError(error.EmptyKey, doc.setSegments(&.{ "sec", "" }, @as([]const u8, "v")));
    }
    // git charset: a key must start with a letter; a section name may not
    // contain a space.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var doc = try Document.parse(arena.allocator(), "[x]\ny = 1\n", .{ .dialect = Dialect.gitconfig });
        try testing.expectError(error.InvalidKey, doc.setSegments(&.{ "sec", "1bad" }, @as([]const u8, "v")));
        try testing.expectError(error.MalformedSectionHeader, doc.setSegments(&.{ "bad name", "k" }, @as([]const u8, "v")));
    }
}

test "CREATE: appending into a top-level section that mixes scalars and subsections anchors on the last scalar" {
    // "branch" has a direct scalar entry ("x") AND a subsection entry
    // ("main"), in that order -- the subsection entry has no span, so the
    // append must skip past it rather than trying to anchor on it.
    const G = Dialect.gitconfig;
    const src = "[branch]\n\tx = 1\n[branch \"main\"]\n\tmerge = refs/heads/main\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("branch.y", @as([]const u8, "2"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    // Appended right after the bare block's own last entry, not after the
    // (later, unrelated) subsection block.
    try testing.expectEqualStrings(
        "[branch]\n\tx = 1\n\ty = 2\n[branch \"main\"]\n\tmerge = refs/heads/main\n",
        out,
    );
}

test "CREATE: a top-level section that exists only as subsection blocks gets a fresh bare header" {
    // No bare [branch] header exists anywhere -- only [branch "main"], so
    // there is neither a scalar entry nor a bare header line to anchor a
    // direct branch.* key on.
    const G = Dialect.gitconfig;
    const src = "[branch \"main\"]\n\tmerge = refs/heads/main\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("branch.y", @as([]const u8, "2"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings(
        "[branch \"main\"]\n\tmerge = refs/heads/main\n\n[branch]\n\ty = 2\n",
        out,
    );
}

test "CREATE: a new key colliding with an existing section/subsection name is InvalidValue, not a silent shadow" {
    // Root level: "s" already names a whole [s] section.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var doc = try Document.parse(a, "[s]\nk = v\n", .{ .dialect = Dialect.generic });
        try testing.expectError(error.InvalidValue, doc.set("s", @as([]const u8, "direct")));
        var aw: std.Io.Writer.Allocating = .init(a);
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings("[s]\nk = v\n", aw.written());
    }
    // Nested level: "main" already names a subsection of "branch".
    {
        const G = Dialect.gitconfig;
        const src = "[branch \"main\"]\n\tmerge = refs/heads/main\n";
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var doc = try Document.parse(a, src, .{ .dialect = G });
        try testing.expectError(error.InvalidValue, doc.set("branch.main", @as([]const u8, "direct")));
        var aw: std.Io.Writer.Allocating = .init(a);
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings(src, aw.written());
    }
}

test "CREATE: a case-folded collision with an existing section is caught, not just an exact-case one (root level)" {
    // generic folds both section and key names, so "X" and the existing "[x]"
    // section collide once stored, even though they differ in source case.
    const src = "[x]\nk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Exact case still rejected (pre-existing guard).
    {
        var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
        try testing.expectError(error.InvalidValue, doc.set("x", @as([]const u8, "direct")));
        var aw: std.Io.Writer.Allocating = .init(a);
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings(src, aw.written());
    }
    // Case-mismatched collision: "X" folds to "x" the same way the parser
    // would store it, so it must be rejected too instead of silently
    // shadowing "[x]" on re-parse.
    {
        var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
        try testing.expectError(error.InvalidValue, doc.set("X", @as([]const u8, "2")));
        var aw: std.Io.Writer.Allocating = .init(a);
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings(src, aw.written());
    }
    // A genuinely distinct root key still succeeds. Global keys must precede
    // every section header (see insertGlobalKeyList), so it lands at the start.
    {
        var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
        try doc.set("y", @as([]const u8, "2"));
        const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
        try testing.expectEqualStrings("y = 2\n[x]\nk = v\n", out);
    }
}

test "CREATE: a case-folded collision with an existing subsection is caught (nested level, gitconfig)" {
    // gitconfig folds keys but stores subsection names case-sensitively (see
    // openHeader in parser.zig), so "MAIN" must still be folded to "main"
    // before comparing against the subsection, catching the collision the
    // parser's own case-folding would create on re-parse.
    const G = Dialect.gitconfig;
    const src = "[branch \"main\"]\n\tmerge = refs/heads/main\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Exact case still rejected (pre-existing guard, also covered above).
    {
        var doc = try Document.parse(a, src, .{ .dialect = G });
        try testing.expectError(error.InvalidValue, doc.set("branch.main", @as([]const u8, "direct")));
    }
    // Case-mismatched collision.
    {
        var doc = try Document.parse(a, src, .{ .dialect = G });
        try testing.expectError(error.InvalidValue, doc.set("branch.MAIN", @as([]const u8, "direct2")));
        var aw: std.Io.Writer.Allocating = .init(a);
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings(src, aw.written());
    }
    // A genuinely distinct key under the same top-level section still succeeds.
    {
        var doc = try Document.parse(a, src, .{ .dialect = G });
        try doc.set("branch.other", @as([]const u8, "x"));
        const out = try emitAndReparse(a, &doc, .{ .dialect = G });
        const v2 = try parser_mod.parse(a, out, .{ .dialect = G });
        try testing.expectEqualStrings("x", v2.getSegments(&.{ "branch", "other" }).?.string);
        try testing.expectEqualStrings("refs/heads/main", v2.get("branch.main.merge").?.string);
    }
}

test "CREATE: setSegments on a differently-cased section resolves into the existing one under a folding dialect" {
    // generic folds section names, so "X" must resolve into the already-
    // parsed "[x]" instead of the container going unresolved and a
    // case-variant "[X]" header being appended (which would merge with
    // "[x]" on re-parse, but only after fragmenting the source first).
    const src = "[x]\na = 1\nb = 2\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Value-replace on an existing key: caught by locateSegments's own
    // folded lookup, so this never even reaches the create path.
    {
        var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
        try doc.setSegments(&.{ "X", "a" }, @as([]const u8, "9"));
        const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
        try testing.expectEqualStrings("[x]\na = 9\nb = 2\n", out);
        const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.generic });
        try testing.expectEqual(@as(usize, 1), v2.section.entries.len);
    }
    // A new key under the differently-cased section: caught by
    // resolveContainer's folded lookup, appending into the existing section
    // instead of creating a second header.
    {
        var doc = try Document.parse(a, src, .{ .dialect = Dialect.generic });
        try doc.setSegments(&.{ "X", "c" }, @as([]const u8, "3"));
        const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.generic });
        try testing.expectEqualStrings("[x]\na = 1\nb = 2\nc = 3\n", out);
        const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.generic });
        try testing.expectEqual(@as(usize, 1), v2.section.entries.len);
        try testing.expectEqualStrings("3", v2.get("x.c").?.string);
    }
}

test "CREATE: setSegments on a differently-cased section creates a distinct one under a case-sensitive dialect" {
    // strict never folds section names, so "X" and the existing "x" are
    // genuinely distinct sections, matching set()'s ordinary create-missing
    // behavior.
    const src = "[x]\nk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.setSegments(&.{ "X", "k" }, @as([]const u8, "v2"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = Dialect.strict });
    try testing.expectEqualStrings("[x]\nk = v\n\n[X]\nk = v2\n", out);
    const v2 = try parser_mod.parse(a, out, .{ .dialect = Dialect.strict });
    try testing.expectEqual(@as(usize, 2), v2.section.entries.len);
    try testing.expectEqualStrings("v", v2.get("x.k").?.string);
    try testing.expectEqualStrings("v2", v2.get("X.k").?.string);
}

test "CREATE: a brand-new section on a CRLF source uses CRLF throughout, with no doubled blank line" {
    // A dangling (non-blank-terminated) CRLF source: the separator must
    // become a CRLF blank line, not a bare "\n\n".
    {
        const src = "[a]\r\nx = 1\r\n";
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
        try doc.set("b.y", @as([]const u8, "2"));
        var aw: std.Io.Writer.Allocating = .init(a);
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings("[a]\r\nx = 1\r\n\r\n[b]\r\ny = 2\r\n", aw.written());
        const v2 = try parser_mod.parse(a, aw.written(), .{ .dialect = Dialect.strict });
        try testing.expectEqualStrings("2", v2.get("b.y").?.string);
    }
    // A CRLF source already ending in a blank line ("\r\n\r\n"): the old
    // endsWith(source, "\n\n") check missed this (last two bytes are "\r\n",
    // not "\n\n") and inserted a second blank line. Must stay single.
    {
        const src = "[a]\r\nx = 1\r\n\r\n";
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
        try doc.set("b.y", @as([]const u8, "2"));
        var aw: std.Io.Writer.Allocating = .init(a);
        try doc.emit(&aw.writer);
        try testing.expectEqualStrings("[a]\r\nx = 1\r\n\r\n[b]\r\ny = 2\r\n", aw.written());
        const v2 = try parser_mod.parse(a, aw.written(), .{ .dialect = Dialect.strict });
        try testing.expectEqualStrings("2", v2.get("b.y").?.string);
    }
}

test "CREATE: a brand-new section on an LF source still uses bare LF" {
    const src = "[a]\nx = 1\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = Dialect.strict });
    try doc.set("b.y", @as([]const u8, "2"));
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[a]\nx = 1\n\n[b]\ny = 2\n", aw.written());
    try testing.expect(std.mem.indexOfScalar(u8, aw.written(), '\r') == null);
}

test "CREATE: a section name with edge whitespace round-trips under a non-trimming dialect (generic)" {
    // generic sets trim_section_names = false, so "[ s ]" and "[s]" are
    // legitimately distinct, representable sections there; the create path
    // must not over-reject the edge whitespace the way a trimming dialect
    // (which would actually strip it, changing the name) rightly does.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.empty(a, .{ .dialect = Dialect.generic });
    try doc.setSegments(&.{ " s ", "key" }, @as([]const u8, "v"));
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings("[ s ]\nkey = v\n", aw.written());
    const v2 = try parser_mod.parse(a, aw.written(), .{ .dialect = Dialect.generic });
    try testing.expectEqualStrings("v", v2.getSegments(&.{ " s ", "key" }).?.string);
}

test "MULTIVAL: setValueSegments creates a missing key as N lines from a list" {
    const G = Dialect.gitconfig;
    const src = "[remote \"origin\"]\n\turl = git@example.com\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setValueSegments(&.{ "remote", "origin", "fetch" }, .{ .list = &.{
        "+refs/heads/a:refs/remotes/origin/a",
        "+refs/heads/b:refs/remotes/origin/b",
        "+refs/heads/c:refs/remotes/origin/c",
    } });
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings(
        "[remote \"origin\"]\n\turl = git@example.com\n" ++
            "\tfetch = +refs/heads/a:refs/remotes/origin/a\n" ++
            "\tfetch = +refs/heads/b:refs/remotes/origin/b\n" ++
            "\tfetch = +refs/heads/c:refs/remotes/origin/c\n",
        out,
    );
    const list = doc.getSegments(&.{ "remote", "origin", "fetch" }).?.list;
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqualStrings("+refs/heads/b:refs/remotes/origin/b", list[1]);

    // A byte-identical repeat is a no-op (matches the scalar create path).
    try doc.setValueSegments(&.{ "remote", "origin", "fetch" }, .{ .list = &.{
        "+refs/heads/a:refs/remotes/origin/a",
        "+refs/heads/b:refs/remotes/origin/b",
        "+refs/heads/c:refs/remotes/origin/c",
    } });
    const out2 = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings(out, out2);
}

test "MULTIVAL: setValueSegments replaces a single-value key with a list" {
    const G = Dialect.gitconfig;
    const src = "[remote \"origin\"]\n\tfetch = old\n\turl = git@example.com\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setValueSegments(&.{ "remote", "origin", "fetch" }, .{ .list = &.{ "a", "b" } });
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings(
        "[remote \"origin\"]\n\tfetch = a\n\tfetch = b\n\turl = git@example.com\n",
        out,
    );
    const list = doc.getSegments(&.{ "remote", "origin", "fetch" }).?.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("a", list[0]);
    try testing.expectEqualStrings("b", list[1]);

    // Idempotent: setting the exact same list again changes nothing.
    try doc.setValueSegments(&.{ "remote", "origin", "fetch" }, .{ .list = &.{ "a", "b" } });
    const out2 = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings(out, out2);
}

test "MULTIVAL: setValueSegments replaces a multi-value key with a shorter list (net one line)" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"]\n\tpush = a\n\tpush = b\n\tpush = c\n\turl = u\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setValueSegments(&.{ "remote", "o", "push" }, .{ .list = &.{"only"} });
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[remote \"o\"]\n\tpush = only\n\turl = u\n", out);
    const got = doc.getSegments(&.{ "remote", "o", "push" }).?;
    try testing.expect(got == .string);
    try testing.expectEqualStrings("only", got.string);
}

test "MULTIVAL: an empty list on an absent key is a no-op" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setValueSegments(&.{ "remote", "origin", "fetch" }, .{ .list = &.{} });
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "MULTIVAL: an empty list removes an existing key's lines entirely" {
    const G = Dialect.gitconfig;
    {
        // Multi-value key: every line goes.
        const src = "[remote \"o\"]\n\tpush = a\n\tpush = b\n\turl = u\n";
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var doc = try Document.parse(a, src, .{ .dialect = G });
        try doc.setValueSegments(&.{ "remote", "o", "push" }, .{ .list = &.{} });
        const out = try emitAndReparse(a, &doc, .{ .dialect = G });
        try testing.expectEqualStrings("[remote \"o\"]\n\turl = u\n", out);
        try testing.expect(doc.getSegments(&.{ "remote", "o", "push" }) == null);
    }
    {
        // Single-value key: same "absence, not a valueless key" semantics.
        const src = "[s]\n\tk = v\n\tj = w\n";
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var doc = try Document.parse(a, src, .{ .dialect = G });
        try doc.setValueSegments(&.{ "s", "k" }, .{ .list = &.{} });
        const out = try emitAndReparse(a, &doc, .{ .dialect = G });
        try testing.expectEqualStrings("[s]\n\tj = w\n", out);
        try testing.expect(doc.getSegments(&.{ "s", "k" }) == null);
    }
}

test "MULTIVAL: setValueSegments .string is byte-identical to setSegments" {
    const G = Dialect.gitconfig;
    const src = "[user]\n\tname = Ada\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc_a = try Document.parse(a, src, .{ .dialect = G });
    try doc_a.setValueSegments(&.{ "user", "name" }, .{ .string = "Grace" });
    var aw_a: std.Io.Writer.Allocating = .init(a);
    try doc_a.emit(&aw_a.writer);

    var doc_b = try Document.parse(a, src, .{ .dialect = G });
    try doc_b.setSegments(&.{ "user", "name" }, @as([]const u8, "Grace"));
    var aw_b: std.Io.Writer.Allocating = .init(a);
    try doc_b.emit(&aw_b.writer);

    try testing.expectEqualStrings(aw_b.written(), aw_a.written());
}

test "MULTIVAL: setValueSegments rejects a section value" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    var sub_entries: [0]value_mod.Entry = .{};
    var sub = Section{ .entries = &sub_entries };
    try testing.expectError(error.InvalidValue, doc.setValueSegments(&.{ "s", "k" }, .{ .section = &sub }));
    var aw: std.Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    try testing.expectEqualStrings(src, aw.written());
}

test "MULTIVAL: removeSegments on a multi-value key removes every line" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"]\n\tpush = a\n\tpush = b\n\tpush = c\n\turl = u\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.removeSegments(&.{ "remote", "o", "push" });
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[remote \"o\"]\n\turl = u\n", out);
    try testing.expect(doc.getSegments(&.{ "remote", "o", "push" }) == null);
    try testing.expectEqualStrings("u", doc.getSegments(&.{ "remote", "o", "url" }).?.string);
}

test "MULTIVAL: a CRLF source stays CRLF through a list replace" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"]\r\n\tpush = a\r\n\tpush = b\r\n\turl = u\r\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setValueSegments(&.{ "remote", "o", "push" }, .{ .list = &.{ "x", "y", "z" } });
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings(
        "[remote \"o\"]\r\n\tpush = x\r\n\tpush = y\r\n\tpush = z\r\n\turl = u\r\n",
        out,
    );
}

test "MULTIVAL: setValueSegments on a freshly created list path can be re-set to a different, differently-sized list" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setValueSegments(&.{ "s", "fresh" }, .{ .list = &.{ "a", "b", "c" } });
    const out1 = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = v\n\tfresh = a\n\tfresh = b\n\tfresh = c\n", out1);

    try doc.setValueSegments(&.{ "s", "fresh" }, .{ .list = &.{ "x", "y" } });
    const out2 = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = v\n\tfresh = x\n\tfresh = y\n", out2);
    const list = doc.getSegments(&.{ "s", "fresh" }).?.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("x", list[0]);
    try testing.expectEqualStrings("y", list[1]);
}

test "MULTIVAL: a list-create re-set as a scalar collapses in place instead of duplicating (A1 repro 1)" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setValueSegments(&.{ "s", "fresh" }, .{ .list = &.{ "a", "b", "c" } });
    try doc.setSegments(&.{ "s", "fresh" }, @as([]const u8, "solo"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = v\n\tfresh = solo\n", out);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\n"));
    const got = doc.getSegments(&.{ "s", "fresh" }).?;
    try testing.expect(got == .string);
    try testing.expectEqualStrings("solo", got.string);
}

test "MULTIVAL: a scalar-create re-set as a list collapses in place instead of duplicating (A1 repro 2)" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setSegments(&.{ "s", "fresh" }, @as([]const u8, "solo"));
    try doc.setValueSegments(&.{ "s", "fresh" }, .{ .list = &.{ "a", "b" } });
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = v\n\tfresh = a\n\tfresh = b\n", out);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "\n"));
    const list = doc.getSegments(&.{ "s", "fresh" }).?.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("a", list[0]);
    try testing.expectEqualStrings("b", list[1]);
}

test "MULTIVAL: a scalar-create re-set to an empty list removes the created line (A1 repro 3)" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setSegments(&.{ "s", "fresh" }, @as([]const u8, "solo"));
    try doc.setValueSegments(&.{ "s", "fresh" }, .{ .list = &.{} });
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings(src, out);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
    try testing.expect(doc.getSegments(&.{ "s", "fresh" }) == null);
}

test "MULTIVAL: a list-create re-set to an empty list removes the created lines" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setValueSegments(&.{ "s", "fresh" }, .{ .list = &.{ "a", "b" } });
    try doc.setValueSegments(&.{ "s", "fresh" }, .{ .list = &.{} });
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings(src, out);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
    try testing.expect(doc.getSegments(&.{ "s", "fresh" }) == null);
}

test "MULTIVAL: create then cross-kind then cross-kind-again collapses to the final kind, single-kind bookkeeping" {
    const G = Dialect.gitconfig;
    const src = "[s]\n\tk = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setSegments(&.{ "s", "fresh" }, @as([]const u8, "solo")); // scalar create
    try doc.setValueSegments(&.{ "s", "fresh" }, .{ .list = &.{ "a", "b", "c" } }); // -> list
    try doc.setSegments(&.{ "s", "fresh" }, @as([]const u8, "final")); // -> scalar again
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = v\n\tfresh = final\n", out);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\n"));
    const got = doc.getSegments(&.{ "s", "fresh" }).?;
    try testing.expect(got == .string);
    try testing.expectEqualStrings("final", got.string);

    // A further re-set (either kind) still finds the path tracked under
    // exactly one kind: no stale entry left in the other map to also match.
    try doc.setValueSegments(&.{ "s", "fresh" }, .{ .list = &.{ "x", "y" } }); // -> list again
    const out2 = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[s]\n\tk = v\n\tfresh = x\n\tfresh = y\n", out2);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out2, "\n"));
    const list = doc.getSegments(&.{ "s", "fresh" }).?.list;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("x", list[0]);
    try testing.expectEqualStrings("y", list[1]);
}

test "MULTIVAL: a scalar set on an in-source multi-value key collapses it to one line, via all three scalar entry points" {
    const G = Dialect.gitconfig;
    const src = "[remote \"origin\"]\n\tfetch = a\n\tfetch = b\n";

    const Entry = enum { value_segments, set_segments, literal_segments };
    const entries = [_]Entry{ .value_segments, .set_segments, .literal_segments };
    for (entries) |entry| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var doc = try Document.parse(a, src, .{ .dialect = G });
        switch (entry) {
            .value_segments => try doc.setValueSegments(&.{ "remote", "origin", "fetch" }, .{ .string = "a" }),
            .set_segments => try doc.setSegments(&.{ "remote", "origin", "fetch" }, @as([]const u8, "a")),
            .literal_segments => try doc.setLiteralSegments(&.{ "remote", "origin", "fetch" }, "a"),
        }
        const out = try emitAndReparse(a, &doc, .{ .dialect = G });
        try testing.expectEqualStrings("[remote \"origin\"]\n\tfetch = a\n", out);
        const got = doc.getSegments(&.{ "remote", "origin", "fetch" }).?;
        try testing.expect(got == .string);
        try testing.expectEqualStrings("a", got.string);
    }
}

test "MULTIVAL: a scalar set on a 3-occurrence key collapses to one line" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"]\n\tpush = a\n\tpush = b\n\tpush = c\n\turl = u\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setSegments(&.{ "remote", "o", "push" }, @as([]const u8, "only"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[remote \"o\"]\n\tpush = only\n\turl = u\n", out);
    const got = doc.getSegments(&.{ "remote", "o", "push" }).?;
    try testing.expect(got == .string);
    try testing.expectEqualStrings("only", got.string);
}

test "MULTIVAL: a scalar set on a single-occurrence key stays byte-identical to the plain splice" {
    const G = Dialect.gitconfig;
    const src = "[remote \"o\"]\n\tpush = a\n\turl = u\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setSegments(&.{ "remote", "o", "push" }, @as([]const u8, "z"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[remote \"o\"]\n\tpush = z\n\turl = u\n", out);
}

test "MULTIVAL: a source multi-value key set to a scalar can be set back to a list, round-tripping" {
    const G = Dialect.gitconfig;
    const src = "[remote \"origin\"]\n\tfetch = a\n\tfetch = b\n\turl = u\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setValueSegments(&.{ "remote", "origin", "fetch" }, .{ .string = "solo" });
    const collapsed = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[remote \"origin\"]\n\tfetch = solo\n\turl = u\n", collapsed);

    try doc.setValueSegments(&.{ "remote", "origin", "fetch" }, .{ .list = &.{ "x", "y" } });
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[remote \"origin\"]\n\tfetch = x\n\tfetch = y\n\turl = u\n", out);
    const list2 = doc.getSegments(&.{ "remote", "origin", "fetch" }).?.list;
    try testing.expectEqual(@as(usize, 2), list2.len);
    try testing.expectEqualStrings("x", list2[0]);
    try testing.expectEqualStrings("y", list2[1]);
}

test "MULTIVAL: a scalar set on a multi-value key preserves a trailing comment and sibling keys byte-for-byte" {
    const G = Dialect.gitconfig;
    // The trailing comment sits on the FIRST occurrence -- the one that
    // survives the collapse; the second occurrence (no comment) is removed
    // outright, and both sibling keys must stay byte-for-byte untouched.
    const src = "[remote \"o\"]\n\turl = u\n\tpush = a  ; keep\n\tpush = b\n\tother = v\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.setSegments(&.{ "remote", "o", "push" }, @as([]const u8, "solo"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings(
        "[remote \"o\"]\n\turl = u\n\tpush = solo  ; keep\n\tother = v\n",
        out,
    );
    try testing.expectEqualStrings("u", doc.getSegments(&.{ "remote", "o", "url" }).?.string);
    try testing.expectEqualStrings("v", doc.getSegments(&.{ "remote", "o", "other" }).?.string);
}

test "MULTIVAL: removeSegments on an over-segmented dotted-subsection path removes the subsection line" {
    const G = Dialect.gitconfig;
    const src = "[branch \"feature.x\"]\n\tmerge = refs/heads/main\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.remove("branch.feature.x.merge");
    try testing.expect(doc.get("branch.feature.x.merge") == null);
    try testing.expect(doc.getSegments(&.{ "branch", "feature.x", "merge" }) == null);
}

test "MULTIVAL: removeSegments on an over-segmented dotted-subsection path leaves an unrelated same-key section untouched" {
    const G = Dialect.gitconfig;
    const src = "[branch]\n\tmerge = a\n\tmerge = b\n[branch \"feature.x\"]\n\tmerge = target\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.remove("branch.feature.x.merge");
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings("[branch]\n\tmerge = a\n\tmerge = b\n[branch \"feature.x\"]\n", out);
}

test "MULTIVAL: setLiteral on an over-segmented dotted-subsection path sets only the subsection line" {
    const G = Dialect.gitconfig;
    const src = "[branch]\n\tmerge = a\n\tmerge = b\n[branch \"feature.x\"]\n\tmerge = target\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try Document.parse(a, src, .{ .dialect = G });
    try doc.set("branch.feature.x.merge", @as([]const u8, "NEW"));
    const out = try emitAndReparse(a, &doc, .{ .dialect = G });
    try testing.expectEqualStrings(
        "[branch]\n\tmerge = a\n\tmerge = b\n[branch \"feature.x\"]\n\tmerge = NEW\n",
        out,
    );
}

test "MULTIVAL: a genuinely multi-value dotted-subsection key still collapses/removes via segments" {
    const G = Dialect.gitconfig;
    const src = "[branch]\n\tmerge = a\n\tmerge = b\n[branch \"feature.x\"]\n\tmerge = one\n\tmerge = two\n\tmerge = three\n";
    // The segments-array API addresses the subsection container directly
    // ({branch,"feature.x"}, depth 2) rather than over-segmenting it via a
    // raw dotted string, so multi-occurrence scanning applies normally.
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var doc = try Document.parse(a, src, .{ .dialect = G });
        try doc.setSegments(&.{ "branch", "feature.x", "merge" }, @as([]const u8, "solo"));
        const out = try emitAndReparse(a, &doc, .{ .dialect = G });
        try testing.expectEqualStrings(
            "[branch]\n\tmerge = a\n\tmerge = b\n[branch \"feature.x\"]\n\tmerge = solo\n",
            out,
        );
    }
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var doc = try Document.parse(a, src, .{ .dialect = G });
        try doc.removeSegments(&.{ "branch", "feature.x", "merge" });
        const out = try emitAndReparse(a, &doc, .{ .dialect = G });
        try testing.expectEqualStrings("[branch]\n\tmerge = a\n\tmerge = b\n[branch \"feature.x\"]\n", out);
        try testing.expectEqualStrings("a", doc.getSegments(&.{ "branch", "merge" }).?.list[0]);
        try testing.expectEqualStrings("b", doc.getSegments(&.{ "branch", "merge" }).?.list[1]);
    }
}

test "MULTIVAL: normal 2-segment and 3-segment multi-value collapse/remove are unchanged by the over-segmentation guard" {
    const G = Dialect.gitconfig;
    // 3-segment (section+subsection+key), already covered above by the
    // "remote.o.push" tests; this covers the 2-segment (bare section+key,
    // no subsection) shape explicitly.
    const src = "[s]\n\tfetch = a\n\tfetch = b\n\tfetch = c\n\turl = u\n";
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var doc = try Document.parse(a, src, .{ .dialect = G });
        try doc.set("s.fetch", @as([]const u8, "solo"));
        const out = try emitAndReparse(a, &doc, .{ .dialect = G });
        try testing.expectEqualStrings("[s]\n\tfetch = solo\n\turl = u\n", out);
    }
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var doc = try Document.parse(a, src, .{ .dialect = G });
        try doc.remove("s.fetch");
        const out = try emitAndReparse(a, &doc, .{ .dialect = G });
        try testing.expectEqualStrings("[s]\n\turl = u\n", out);
    }
}
