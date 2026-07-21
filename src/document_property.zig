//! Deterministic property/round-trip battery over the lossless `Document`
//! editor: generates random valid INI documents and edits against them,
//! asserting the invariants a human reviewer checks by hand -- a set is
//! total-or-clean, a successful edit re-parses and reads back exactly,
//! siblings/comments survive, a repeat edit is a byte-identical no-op, and
//! removing an existing path leaves everything else intact.
//!
//! Construction goes through the public `Document`/`encode` surface only (no
//! internal access), so a bug in the editor itself cannot silently launder
//! the fixtures it is then tested against. Each case is seeded from a fixed
//! base seed for full reproducibility; a failing case prints its index,
//! seed, source, path, value, and output before returning an error so it can
//! be replayed by re-running with that seed.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const ini = @import("ini.zig");

const Dialect = ini.Dialect;
const Value = ini.Value;

const max_segments = 3;

const ModelEntry = struct {
    segs: [max_segments][]const u8,
    len: usize,
    value: []const u8,
};

/// `ModelEntry`'s multi-value counterpart, kept in its OWN list (`GenResult.
/// list_model`) rather than folded into `model`: every existing scalar-only
/// check (`genPath`, `runCase`, `checkCaseVariant`) reads `model` and assumes
/// every entry is a `.string`, so keeping list entries out of it entirely
/// means those checks need no list-awareness of their own -- only
/// `checkListValue` ever reads `list_model`.
const ListModelEntry = struct {
    segs: [max_segments][]const u8,
    len: usize,
    items: []const []const u8,
};

const GenResult = struct {
    source: []const u8,
    model: []ModelEntry,
    /// Multi-value keys genuinely present in `source` -- see `ListModelEntry`.
    /// Only ever non-empty under a `duplicate_keys = .accumulate` dialect.
    list_model: []ListModelEntry,
    comments: [][]const u8,
    /// Whether `source` uses `\r\n` line endings throughout (see `toCrlf`).
    crlf: bool,
};

const safe_pool = [_][]const u8{ "abc", "k1", "foo", "alpha", "beta", "sec", "item" };

/// Names chosen to be adversarial for the editor: a literal dot, embedded
/// quote/backslash/space, a leading char that would misclassify the line
/// (comment/section/assign starters), values that look like other types, and
/// an empty name. Each is tried where the dialect might represent it; a
/// rejection is a legitimate `error.*` outcome, not a generator bug.
const adversarial_pool = [_][]const u8{
    "a.b",   "a\"b",  "a\\b",       "a b",  "-lead", "?lead",
    "#lead", ";lead", "[lead",      "true", "false", "null",
    "123",   "3.14",  "2024-01-01", "",
};

const safe_values = [_][]const u8{ "v", "42", "hello_world", "true", "false", "3.14", "" };

const target_values = [_][]const u8{
    "v2",          "99",        "world", "false",  "true",     "2.71",
    "",            "- x",       "a\"b",  "a\\b",   "a # b",    "a ; b",
    "line\nbreak", "cr\rvalue", " lead", "trail ", "  both  ", "123",
    "null",
};

fn segsEqual(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |a, b| if (!std.mem.eql(u8, a, b)) return false;
    return true;
}

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn containsDot(segs: []const []const u8) bool {
    for (segs) |s| if (std.mem.indexOfScalar(u8, s, '.') != null) return true;
    return false;
}

/// True when `s` is pure lowercase-ascii-or-digit: fold-invariant under
/// `case_insensitive_sections`/`case_insensitive_keys` (folding is a no-op)
/// and dot-free, so the dotted join used for the exact-byte-diff check
/// (invariant 5b) is guaranteed to match the parser's own stored span key.
fn isSafeName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'))) return false;
    }
    return true;
}

fn allSafeNames(path: []const []const u8) bool {
    for (path) |s| if (!isSafeName(s)) return false;
    return true;
}

fn candidateName(a: std.mem.Allocator, rng: std.Random, ctr: *usize) ![]const u8 {
    if (rng.uintLessThan(u8, 100) < 35) {
        return adversarial_pool[rng.uintLessThan(usize, adversarial_pool.len)];
    }
    ctr.* += 1;
    return std.fmt.allocPrint(a, "{s}{d}", .{ safe_pool[rng.uintLessThan(usize, safe_pool.len)], ctr.* });
}

/// A candidate name guaranteed not to collide with `used` (retried a few
/// times, then a guaranteed-fresh counter name as a last resort), so a
/// section's keys (or a section's subsections) stay pairwise distinct: a
/// literal same-path repeat within one `Document.empty` construction session
/// does not splice-replace (its span map never updates -- see the comment on
/// `buildOneSection`), so a repeat would silently become a second
/// accumulated/duplicated entry instead of the intended fresh one.
fn uniqueName(a: std.mem.Allocator, rng: std.Random, ctr: *usize, used: []const []const u8) ![]const u8 {
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        const cand = try candidateName(a, rng, ctr);
        if (!containsName(used, cand)) return cand;
    }
    ctr.* += 1;
    return std.fmt.allocPrint(a, "u{d}", .{ctr.*});
}

fn safeValue(rng: std.Random) []const u8 {
    return safe_values[rng.uintLessThan(usize, safe_values.len)];
}

fn genTargetValue(rng: std.Random) []const u8 {
    return target_values[rng.uintLessThan(usize, target_values.len)];
}

/// A random list of 0-3 target values, for `checkListValue`: 0 exercises the
/// empty-list (remove-or-no-op) path, 1 collapses back to a `.string` on
/// read-back, 2-3 exercise a genuine multi-value `.list`.
fn genValueList(a: std.mem.Allocator, rng: std.Random) ![]const []const u8 {
    const n = rng.uintLessThan(usize, 4);
    const out = try a.alloc([]const u8, n);
    for (out) |*v| v.* = genTargetValue(rng);
    return out;
}

fn recordModel(a: std.mem.Allocator, model: *std.ArrayList(ModelEntry), segs: []const []const u8, value: []const u8) !void {
    for (model.items) |*e| {
        if (e.len == segs.len and segsEqual(e.segs[0..e.len], segs)) {
            e.value = value;
            return;
        }
    }
    var entry: ModelEntry = .{ .segs = undefined, .len = segs.len, .value = value };
    for (segs, 0..) |s, i| entry.segs[i] = s;
    try model.append(a, entry);
}

fn emitToOwned(a: std.mem.Allocator, doc: *const ini.Document) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(a);
    try doc.emit(&aw.writer);
    return aw.written();
}

/// Set `segs` = `value` on `builder`, recording whatever path actually
/// landed. On a representability error (an adversarial name this dialect
/// cannot carry) falls back to a guaranteed-fresh, guaranteed-safe path of
/// the same length so construction never aborts; the actual path used is
/// returned so the caller's bookkeeping (e.g. the section name for
/// subsequent keys) stays in sync with what was really written.
fn setAndRecord(
    builder: *ini.Document,
    a: std.mem.Allocator,
    model: *std.ArrayList(ModelEntry),
    segs: []const []const u8,
    value: []const u8,
    ctr: *usize,
) ![]const []const u8 {
    if (builder.setSegments(segs, value)) |_| {
        try recordModel(a, model, segs, value);
        return segs;
    } else |_| {}
    const fallback = try a.alloc([]const u8, segs.len);
    for (fallback) |*s| {
        ctr.* += 1;
        s.* = try std.fmt.allocPrint(a, "f{d}", .{ctr.*});
    }
    try builder.setSegments(fallback, value);
    try recordModel(a, model, fallback, value);
    return fallback;
}

fn recordListModel(a: std.mem.Allocator, list_model: *std.ArrayList(ListModelEntry), segs: []const []const u8, items: []const []const u8) !void {
    var entry: ListModelEntry = .{ .segs = undefined, .len = segs.len, .items = items };
    for (segs, 0..) |s, i| entry.segs[i] = s;
    try list_model.append(a, entry);
}

/// `setAndRecord`'s multi-value counterpart: sets `segs` to a `.list` via
/// `setValueSegments` instead of a scalar via `setSegments`, recording it
/// into `list_model` -- see that type's doc comment for why it is kept
/// separate from `model`. Same representability-error fallback discipline.
fn setAndRecordList(
    builder: *ini.Document,
    a: std.mem.Allocator,
    list_model: *std.ArrayList(ListModelEntry),
    segs: []const []const u8,
    items: []const []const u8,
    ctr: *usize,
) ![]const []const u8 {
    if (builder.setValueSegments(segs, .{ .list = items })) |_| {
        try recordListModel(a, list_model, segs, items);
        return segs;
    } else |_| {}
    const fallback = try a.alloc([]const u8, segs.len);
    for (fallback) |*s| {
        ctr.* += 1;
        s.* = try std.fmt.allocPrint(a, "f{d}", .{ctr.*});
    }
    try builder.setValueSegments(fallback, .{ .list = items });
    try recordListModel(a, list_model, fallback, items);
    return fallback;
}

/// Build one top-level section (1-3 direct keys, and under a
/// subsection-quoting dialect 0-2 subsections of 1-2 keys each) into
/// `builder`/`model`.
///
/// `builder` is `Document.empty`-backed (or was promoted from a prior
/// section's snapshot -- see `genDoc`): its `parsed`/`spans` snapshot is
/// pinned to whatever `builder` looked like when it was created, so every
/// `setSegments` call in this function resolves containers against that same
/// still-empty-for-this-section snapshot and always takes the create path,
/// same as two sequential creates into a still-missing section in the hand
/// -written suite (see "CREATE: two sequential creates..." in document.zig).
/// That is harmless: the blocks merge under every built-in dialect's
/// `duplicate_sections = .merge`, and `setAndRecord` only ever targets a
/// pairwise-distinct name within this section (via `uniqueName`), so no
/// entry is silently dropped or overwritten.
fn buildOneSection(
    builder: *ini.Document,
    a: std.mem.Allocator,
    dialect: Dialect,
    rng: std.Random,
    ctr: *usize,
    model: *std.ArrayList(ModelEntry),
    list_model: *std.ArrayList(ListModelEntry),
) !void {
    const sec_candidate = try candidateName(a, rng, ctr);
    var sec_name: []const u8 = sec_candidate;

    // Shared across direct keys AND subsections: both live in the same
    // section's entry namespace (`Section.entries`), so a key and a
    // subsection with the same name would collide there exactly like two
    // same-named keys would -- the real (non-frozen-parsed) create path
    // guards against this via its shadow-guard, but this generator's
    // sequential-create construction (see `buildOneSection`'s doc comment)
    // never resolves an existing container, so that guard never engages
    // here; the generator must not manufacture the collision itself.
    var used_names: std.ArrayList([]const u8) = .empty;
    const num_keys = rng.intRangeAtMost(usize, 1, 3);
    var ki: usize = 0;
    var first = true;
    while (ki < num_keys) : (ki += 1) {
        const key_name = try uniqueName(a, rng, ctr, used_names.items);
        try used_names.append(a, key_name);
        const segs = try a.dupe([]const u8, &.{ sec_name, key_name });
        // Under a dialect that accumulates duplicate keys (gitconfig here),
        // a direct key is sometimes made a genuine multi-value key instead
        // of a scalar, so the battery also exercises reading/replacing a
        // multi-value key that was already IN THE SOURCE, not just one
        // created by the edit under test -- see `checkListValue`.
        const actual = if (dialect.duplicate_keys == .accumulate and rng.uintLessThan(u8, 100) < 30) blk: {
            const items = try a.alloc([]const u8, rng.intRangeAtMost(usize, 2, 3));
            for (items) |*v| v.* = safeValue(rng);
            break :blk try setAndRecordList(builder, a, list_model, segs, items, ctr);
        } else blk: {
            const value = safeValue(rng);
            break :blk try setAndRecord(builder, a, model, segs, value, ctr);
        };
        if (first) {
            sec_name = actual[0];
            first = false;
        }
    }

    if (dialect.subsections != .quoted) return;

    const num_subs = rng.uintLessThan(usize, 3);
    var ssi: usize = 0;
    while (ssi < num_subs) : (ssi += 1) {
        const sub_name = try uniqueName(a, rng, ctr, used_names.items);
        try used_names.append(a, sub_name);
        var used_sub_keys: std.ArrayList([]const u8) = .empty;
        const num_sub_keys = rng.intRangeAtMost(usize, 1, 2);
        var ki2: usize = 0;
        while (ki2 < num_sub_keys) : (ki2 += 1) {
            const key_name2 = try uniqueName(a, rng, ctr, used_sub_keys.items);
            try used_sub_keys.append(a, key_name2);
            const value2 = safeValue(rng);
            const segs2 = try a.dupe([]const u8, &.{ sec_name, sub_name, key_name2 });
            _ = try setAndRecord(builder, a, model, segs2, value2, ctr);
        }
    }
}

/// Every comment-line's trimmed text in `source`, for invariant 5's
/// "every comment survives" check. Scanned back out of the constructed
/// source (rather than bookkept at insertion time) so the check is exact
/// regardless of how a comment landed.
fn extractComments(a: std.mem.Allocator, source: []const u8, dialect: Dialect) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, dialect.comment_chars, trimmed[0]) != null) {
            try out.append(a, trimmed);
        }
    }
    return out.toOwnedSlice(a);
}

/// Rewrite `source` (built with bare `\n` line endings, the only kind
/// `Document.empty`-backed construction ever produces) to `\r\n` throughout,
/// so the generator can also exercise a CRLF source -- the current battery
/// only ever built from `Document.empty`, so it never caught a mutation that
/// forced every appended line to bare `\n` regardless of the source's own
/// line ending.
fn toCrlf(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (source) |c| {
        if (c == '\n') try out.append(a, '\r');
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

/// True when `s` contains a `\n` not immediately preceded by `\r`: a source
/// that started fully CRLF (see `toCrlf`) must never gain one of these, since
/// every append path mirrors `dominantEol`/`leadingNewlineIfNeeded` off the
/// source's own line ending.
fn hasBareLf(s: []const u8) bool {
    for (s, 0..) |c, i| {
        if (c == '\n' and (i == 0 or s[i - 1] != '\r')) return true;
    }
    return false;
}

/// Generate a random valid document for `dialect`: 1-3 top-level sections,
/// each promoted (re-parsed) before the next is built so a later section's
/// creation sees genuine prior content (a real blank-line separator,
/// exercising layout preservation), then 0-3 comments inserted against
/// existing dot-free paths, then (with even odds) rewritten to CRLF.
fn genDoc(a: std.mem.Allocator, dialect: Dialect, rng: std.Random, ctr: *usize) !GenResult {
    var builder = try ini.Document.empty(a, .{ .dialect = dialect });
    var model: std.ArrayList(ModelEntry) = .empty;
    var list_model: std.ArrayList(ListModelEntry) = .empty;

    const num_sections = rng.intRangeAtMost(usize, 1, 3);
    var si: usize = 0;
    while (si < num_sections) : (si += 1) {
        try buildOneSection(&builder, a, dialect, rng, ctr, &model, &list_model);
        const snapshot = try emitToOwned(a, &builder);
        builder = try ini.Document.parse(a, snapshot, .{ .dialect = dialect });
    }

    const num_comments = rng.uintLessThan(usize, 4);
    var ci: usize = 0;
    while (ci < num_comments and model.items.len > 0) : (ci += 1) {
        const e = &model.items[rng.uintLessThan(usize, model.items.len)];
        if (containsDot(e.segs[0..e.len])) continue;
        const dotted = try std.mem.join(a, ".", e.segs[0..e.len]);
        ctr.* += 1;
        const text = try std.fmt.allocPrint(a, "note {d}", .{ctr.*});
        builder.addCommentBefore(dotted, text) catch continue;
    }

    const lf_source = try emitToOwned(a, &builder);
    // Sanity check on the generator itself: a constructed document must
    // always be valid INI for its dialect.
    _ = try ini.parse(a, lf_source, .{ .dialect = dialect });
    const crlf = rng.boolean();
    const source = if (crlf) try toCrlf(a, lf_source) else lf_source;
    if (crlf) _ = try ini.parse(a, source, .{ .dialect = dialect });
    const comments = try extractComments(a, source, dialect);
    return .{
        .source = source,
        .model = try model.toOwnedSlice(a),
        .list_model = try list_model.toOwnedSlice(a),
        .comments = comments,
        .crlf = crlf,
    };
}

fn modelFind(model: []const ModelEntry, path: []const []const u8) ?[]const u8 {
    for (model) |e| {
        if (segsEqual(e.segs[0..e.len], path)) return e.value;
    }
    return null;
}

fn containerExists(model: []const ModelEntry, path: []const []const u8) bool {
    if (path.len < 2) return false;
    const container = path[0 .. path.len - 1];
    for (model) |e| {
        if (e.len < 2) continue;
        if (segsEqual(e.segs[0 .. e.len - 1], container)) return true;
    }
    return false;
}

/// Depths this dialect's header shape can express: section+key (2), or under
/// a subsection-quoting dialect also section+subsection+key (3); a dialect
/// with `global_keys` additionally allows a bare root-level key (1). Mirrors
/// `Document.maxDepth`'s shape from the outside, over the public `Dialect`.
fn validDepths(dialect: Dialect) []const usize {
    if (dialect.global_keys) return &.{ 1, 2 };
    return &.{ 2, 3 };
}

fn genFreshPath(a: std.mem.Allocator, dialect: Dialect, rng: std.Random, ctr: *usize) ![]const []const u8 {
    const depths = validDepths(dialect);
    const depth = depths[rng.uintLessThan(usize, depths.len)];
    const segs = try a.alloc([]const u8, depth);
    for (segs) |*s| s.* = try candidateName(a, rng, ctr);
    return segs;
}

/// A mix of: an existing leaf (value-replace), a new leaf under an existing
/// container (append), and a fresh path with missing intermediates (create
/// chain) -- each segment possibly adversarial via `candidateName`.
fn genPath(a: std.mem.Allocator, rng: std.Random, model: []const ModelEntry, dialect: Dialect, ctr: *usize) ![]const []const u8 {
    const roll = rng.uintLessThan(u8, 100);
    if (model.len > 0 and roll < 30) {
        const e = &model[rng.uintLessThan(usize, model.len)];
        return e.segs[0..e.len];
    }
    if (roll < 65) {
        var containers: std.ArrayList([]const []const u8) = .empty;
        for (model) |e| if (e.len >= 2) try containers.append(a, e.segs[0 .. e.len - 1]);
        if (containers.items.len > 0) {
            const c = containers.items[rng.uintLessThan(usize, containers.items.len)];
            const segs = try a.alloc([]const u8, c.len + 1);
            @memcpy(segs[0..c.len], c);
            segs[c.len] = try candidateName(a, rng, ctr);
            return segs;
        }
    }
    return genFreshPath(a, dialect, rng, ctr);
}

fn collidesWithListModel(list_model: []const ListModelEntry, p: []const []const u8) bool {
    for (list_model) |e| {
        if (segsEqual(e.segs[0..e.len], p)) return true;
    }
    return false;
}

/// A guaranteed-fresh, guaranteed-safe 2-segment path (valid depth for every
/// accumulate dialect in this battery) that cannot collide with anything --
/// `genPathAvoidingLists`/`genFreshPathAvoidingLists`'s last resort after
/// exhausting their retries.
fn guaranteedFreshPath(a: std.mem.Allocator, ctr: *usize) ![]const []const u8 {
    ctr.* += 1;
    const fresh_sec = try std.fmt.allocPrint(a, "gp{d}", .{ctr.*});
    ctr.* += 1;
    const fresh_key = try std.fmt.allocPrint(a, "gp{d}", .{ctr.*});
    return a.dupe([]const u8, &.{ fresh_sec, fresh_key });
}

/// `genPath`, retried (bounded) to avoid exactly landing on a path
/// `list_model` already occupies. `genPath`'s "fresh key" branches pick a
/// key name (via `candidateName`, including the small fixed adversarial
/// pool) with no knowledge of `list_model` -- which only `checkListValue`
/// consults -- so an unguarded call could coincidentally collide with a
/// genuine multi-value key already planted in the source. That matters here
/// specifically because `runCase`'s SCALAR flow (`setSegments`) is not
/// equipped to fully collapse an existing multi-value key to one line (only
/// `setValueSegments` is); it would just splice the LAST occurrence in
/// place, leaving the key a shorter list instead of the scalar `runCase`
/// expects.
fn genPathAvoidingLists(
    a: std.mem.Allocator,
    rng: std.Random,
    model: []const ModelEntry,
    list_model: []const ListModelEntry,
    dialect: Dialect,
    ctr: *usize,
) ![]const []const u8 {
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        const p = try genPath(a, rng, model, dialect, ctr);
        if (!collidesWithListModel(list_model, p)) return p;
    }
    return guaranteedFreshPath(a, ctr);
}

/// `genFreshPath`'s counterpart of `genPathAvoidingLists`, for a caller
/// (`checkResetToDistinctValue`) that specifically needs a path guaranteed
/// not to already exist -- an unguarded `genFreshPath` has the same
/// `list_model`-collision risk `genPathAvoidingLists` documents, but the
/// consequence there is worse: a "fresh create" test whose path secretly
/// already names an existing multi-value key is not creating anything at
/// all, invalidating the whole check.
fn genFreshPathAvoidingLists(
    a: std.mem.Allocator,
    rng: std.Random,
    list_model: []const ListModelEntry,
    dialect: Dialect,
    ctr: *usize,
) ![]const []const u8 {
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        const p = try genFreshPath(a, dialect, rng, ctr);
        if (!collidesWithListModel(list_model, p)) return p;
    }
    return guaranteedFreshPath(a, ctr);
}

/// Every line of `s`, trimmed the same way `extractComments` trims a
/// comment line, so a whole-line comparison against `extractComments`'
/// output is exact.
fn lineMultiset(a: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| try out.append(a, std.mem.trim(u8, line, " \t\r"));
    return out.toOwnedSlice(a);
}

fn countOccurrences(lines: []const []const u8, target: []const u8) usize {
    var n: usize = 0;
    for (lines) |l| {
        if (std.mem.eql(u8, l, target)) n += 1;
    }
    return n;
}

/// Every comment in `comments` survives in `out` as a WHOLE LINE, checked by
/// multiset count rather than `std.mem.indexOf` substring search -- a
/// substring check would let `# note 1` be satisfied by the mere presence of
/// `# note 10`, or by a coincidentally colliding key/value line.
fn assertCommentsSurvive(
    a: std.mem.Allocator,
    dialect_name: []const u8,
    idx: usize,
    seed: u64,
    gen: GenResult,
    path: []const []const u8,
    value: []const u8,
    out: []const u8,
    what: []const u8,
) !void {
    const out_lines = try lineMultiset(a, out);
    for (gen.comments) |c| {
        const want = countOccurrences(gen.comments, c);
        const have = countOccurrences(out_lines, c);
        if (have < want) {
            report(dialect_name, idx, seed, gen.source, path, value, out, what);
            return error.CommentDropped;
        }
    }
}

/// A CRLF source (see `GenResult.crlf`) must stay fully CRLF: no edit path
/// may introduce a bare `\n`.
fn assertCrlfPreserved(
    dialect_name: []const u8,
    idx: usize,
    seed: u64,
    gen: GenResult,
    path: []const []const u8,
    value: []const u8,
    out: []const u8,
    what: []const u8,
) !void {
    if (!gen.crlf) return;
    if (hasBareLf(out)) {
        report(dialect_name, idx, seed, gen.source, path, value, out, what);
        return error.CrlfNotPreserved;
    }
}

fn report(
    dialect_name: []const u8,
    idx: usize,
    seed: u64,
    source: []const u8,
    path: []const []const u8,
    value: []const u8,
    out: ?[]const u8,
    what: []const u8,
) void {
    std.debug.print("\nBATTERY FAIL: {s}\n  dialect={s} idx={d} seed=0x{x}\n  path:", .{ what, dialect_name, idx, seed });
    for (path) |s| std.debug.print(" [{s}]", .{s});
    std.debug.print("\n  value: {s}\n  source:\n{s}\n  ---\n", .{ value, source });
    if (out) |o| std.debug.print("  output:\n{s}\n  ---\n", .{o});
}

fn runCase(a: std.mem.Allocator, dialect: Dialect, dialect_name: []const u8, rng: std.Random, seed: u64, idx: usize) !void {
    var ctr: usize = 0;
    const gen = try genDoc(a, dialect, rng, &ctr);
    const path = try genPathAvoidingLists(a, rng, gen.model, gen.list_model, dialect, &ctr);
    const existed_before = modelFind(gen.model, path) != null;
    const is_leaf_case = existed_before or containerExists(gen.model, path);
    const value = genTargetValue(rng);

    var docA = ini.Document.parse(a, gen.source, .{ .dialect = dialect }) catch |e| {
        report(dialect_name, idx, seed, gen.source, path, value, null, "constructed source failed to parse");
        return e;
    };

    if (docA.setSegments(path, value)) |_| {
        const out1 = try emitToOwned(a, &docA);
        try assertCrlfPreserved(dialect_name, idx, seed, gen, path, value, out1, "CRLF source gained a bare LF (set)");

        // Invariant 2: reparse-clean.
        const reparsed = ini.parse(a, out1, .{ .dialect = dialect }) catch |e| {
            report(dialect_name, idx, seed, gen.source, path, value, out1, "output failed to reparse");
            return e;
        };

        // Invariant 3: read-back exact.
        const got = reparsed.getSegments(path) orelse {
            report(dialect_name, idx, seed, gen.source, path, value, out1, "read-back missing");
            return error.ReadBackMissing;
        };
        if (got != .string or !std.mem.eql(u8, got.string, value)) {
            report(dialect_name, idx, seed, gen.source, path, value, out1, "read-back mismatch");
            return error.ReadBackMismatch;
        }

        // Invariant 4: sibling preservation.
        for (gen.model) |e| {
            if (segsEqual(e.segs[0..e.len], path)) continue;
            const gv = reparsed.getSegments(e.segs[0..e.len]) orelse {
                report(dialect_name, idx, seed, gen.source, path, value, out1, "sibling dropped");
                return error.SiblingDropped;
            };
            if (gv != .string or !std.mem.eql(u8, gv.string, e.value)) {
                report(dialect_name, idx, seed, gen.source, path, value, out1, "sibling corrupted");
                return error.SiblingCorrupted;
            }
        }

        // Invariant 5: every comment survives, as a whole line.
        try assertCommentsSurvive(a, dialect_name, idx, seed, gen, path, value, out1, "comment dropped");
        // Invariant 5b: a pure value-replace on a fold-invariant path is a
        // byte-exact diff over just the old value's span.
        if (existed_before and allSafeNames(path)) {
            var spans: ini.Spans = .empty;
            _ = try ini.parse(a, gen.source, .{ .dialect = dialect, .spans = &spans });
            const joined = try std.mem.join(a, ".", path);
            if (spans.get(joined)) |old_span| {
                const rendered = if (dialect.quoting == .git) blk: {
                    var aw: Io.Writer.Allocating = .init(a);
                    try ini.escape.escapeGit(&aw.writer, value);
                    break :blk aw.written();
                } else value;
                const start: usize = @intCast(old_span.start);
                const end: usize = @intCast(old_span.end);
                const expected = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ gen.source[0..start], rendered, gen.source[end..] });
                if (!std.mem.eql(u8, expected, out1)) {
                    report(dialect_name, idx, seed, gen.source, path, value, out1, "not a minimal (byte-exact-except-value) diff");
                    return error.NotMinimalDiff;
                }
            }
        }

        // Invariant 6: idempotence.
        docA.setSegments(path, value) catch |e| {
            report(dialect_name, idx, seed, gen.source, path, value, out1, "idempotent re-apply errored");
            return e;
        };
        const out2 = try emitToOwned(a, &docA);
        if (!std.mem.eql(u8, out1, out2)) {
            report(dialect_name, idx, seed, gen.source, path, value, out1, "not idempotent");
            return error.NotIdempotent;
        }

        // Invariant 7: remove round-trip, for a path that existed (as a
        // leaf, or newly appended into an existing container) after the set.
        if (is_leaf_case) {
            var docC = ini.Document.parse(a, out1, .{ .dialect = dialect }) catch |e| {
                report(dialect_name, idx, seed, gen.source, path, value, out1, "edited output failed to reparse for remove");
                return e;
            };
            docC.removeSegments(path) catch |e| {
                report(dialect_name, idx, seed, gen.source, path, value, out1, "remove errored on an existing path");
                return e;
            };
            const outc = try emitToOwned(a, &docC);
            try assertCrlfPreserved(dialect_name, idx, seed, gen, path, value, outc, "CRLF source gained a bare LF (remove)");
            const reparsedC = ini.parse(a, outc, .{ .dialect = dialect }) catch |e| {
                report(dialect_name, idx, seed, gen.source, path, value, outc, "post-remove output failed to reparse");
                return e;
            };
            if (reparsedC.getSegments(path) != null) {
                report(dialect_name, idx, seed, gen.source, path, value, outc, "path still present after remove");
                return error.RemoveIneffective;
            }
            for (gen.model) |e| {
                if (segsEqual(e.segs[0..e.len], path)) continue;
                const gv = reparsedC.getSegments(e.segs[0..e.len]) orelse {
                    report(dialect_name, idx, seed, gen.source, path, value, outc, "remove: sibling dropped");
                    return error.RemoveSiblingDropped;
                };
                if (gv != .string or !std.mem.eql(u8, gv.string, e.value)) {
                    report(dialect_name, idx, seed, gen.source, path, value, outc, "remove: sibling corrupted");
                    return error.RemoveSiblingCorrupted;
                }
            }
            try assertCommentsSurvive(a, dialect_name, idx, seed, gen, path, value, outc, "remove: comment dropped");
        }
    } else |_| {
        // Invariant 1: set is total-or-clean -- an error must leave the
        // document byte-unchanged.
        const out_after = try emitToOwned(a, &docA);
        if (!std.mem.eql(u8, out_after, gen.source)) {
            report(dialect_name, idx, seed, gen.source, path, value, out_after, "failed edit did not roll back");
            return error.NotRolledBack;
        }
    }

    try checkCaseVariant(a, dialect, dialect_name, gen, rng, idx, seed);
    try checkResetToDistinctValue(a, dialect, dialect_name, gen, rng, &ctr, idx, seed);
    try checkListValue(a, dialect, dialect_name, gen, path, rng, idx, seed);
}

/// Case-flip the section (index 0) and leaf key (the last index) of `path`,
/// leaving a subsection (index 1 of a 3-segment path) untouched -- mirrors
/// exactly which segments `Document`'s case-folding covers (`foldedSection`
/// only ever folds index 0, `foldedKey` only ever folds the leaf).
fn caseFlip(a: std.mem.Allocator, path: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, path.len);
    for (path, 0..) |seg, i| {
        if (i == 0 or i == path.len - 1) {
            const up = try a.alloc(u8, seg.len);
            for (seg, 0..) |c, j| up[j] = std.ascii.toUpper(c);
            out[i] = up;
        } else {
            out[i] = seg;
        }
    }
    return out;
}

/// Pick an existing model entry built from pure lowercase-safe names (so its
/// uppercase variant is unambiguous -- see `isSafeName`), set its case-flipped
/// path to a fresh value, and check the two BUG2 directions: under a dialect
/// that folds both sections and keys, the set must resolve INTO the existing
/// entry (no new line, scalar read-back at the canonical path); under a
/// dialect that folds neither, it must create a genuinely distinct entry
/// (the original entry untouched, the variant path reads back its own value).
fn checkCaseVariant(
    a: std.mem.Allocator,
    dialect: Dialect,
    dialect_name: []const u8,
    gen: GenResult,
    rng: std.Random,
    idx: usize,
    seed: u64,
) !void {
    var candidates: std.ArrayList(usize) = .empty;
    for (gen.model, 0..) |e, i| {
        if (e.len < 2 or e.len > max_segments) continue;
        if (allSafeNames(e.segs[0..e.len])) try candidates.append(a, i);
    }
    if (candidates.items.len == 0) return;
    const e = gen.model[candidates.items[rng.uintLessThan(usize, candidates.items.len)]];
    const canonical = e.segs[0..e.len];
    const variant = try caseFlip(a, canonical);
    const new_value: []const u8 = "CASEVARIANT";

    var doc = ini.Document.parse(a, gen.source, .{ .dialect = dialect }) catch |err| {
        report(dialect_name, idx, seed, gen.source, variant, new_value, null, "case-variant: source failed to parse");
        return err;
    };
    const before_lines = std.mem.count(u8, gen.source, "\n");
    doc.setSegments(variant, new_value) catch |err| {
        report(dialect_name, idx, seed, gen.source, variant, new_value, null, "case-variant: set errored");
        return err;
    };
    const out = try emitToOwned(a, &doc);
    try assertCrlfPreserved(dialect_name, idx, seed, gen, variant, new_value, out, "CRLF source gained a bare LF (case-variant)");
    const after_lines = std.mem.count(u8, out, "\n");
    const reparsed = ini.parse(a, out, .{ .dialect = dialect }) catch |err| {
        report(dialect_name, idx, seed, gen.source, variant, new_value, out, "case-variant: output failed to reparse");
        return err;
    };

    const folds = dialect.case_insensitive_sections and dialect.case_insensitive_keys;
    if (folds) {
        if (after_lines != before_lines) {
            report(dialect_name, idx, seed, gen.source, variant, new_value, out, "case-variant: resolving into an existing key added a line");
            return error.CaseVariantDuplicated;
        }
        const got = reparsed.getSegments(canonical) orelse {
            report(dialect_name, idx, seed, gen.source, variant, new_value, out, "case-variant: canonical path missing after fold-in");
            return error.CaseVariantMissing;
        };
        if (got != .string or !std.mem.eql(u8, got.string, new_value)) {
            report(dialect_name, idx, seed, gen.source, variant, new_value, out, "case-variant: did not resolve into the existing key as a scalar");
            return error.CaseVariantNotScalar;
        }
    } else {
        // No line-count assertion here: a distinct new entry may cost one
        // line (append into an existing section) or several (a whole new
        // section, plus its blank-line separator) depending on where the
        // canonical path's section happens to sit. The two read-back checks
        // below already pin down "genuinely distinct, not folded in": if a
        // case-sensitive dialect ever wrongly folded, the ORIGINAL entry
        // would read back as `new_value` instead of `e.value`, tripping the
        // very next check.
        const orig = reparsed.getSegments(canonical) orelse {
            report(dialect_name, idx, seed, gen.source, variant, new_value, out, "case-variant: original entry lost under case-sensitive dialect");
            return error.CaseVariantOriginalLost;
        };
        if (orig != .string or !std.mem.eql(u8, orig.string, e.value)) {
            report(dialect_name, idx, seed, gen.source, variant, new_value, out, "case-variant: original entry mutated under case-sensitive dialect");
            return error.CaseVariantOriginalMutated;
        }
        const got = reparsed.getSegments(variant) orelse {
            report(dialect_name, idx, seed, gen.source, variant, new_value, out, "case-variant: new distinct entry missing under case-sensitive dialect");
            return error.CaseVariantMissing;
        };
        if (got != .string or !std.mem.eql(u8, got.string, new_value)) {
            report(dialect_name, idx, seed, gen.source, variant, new_value, out, "case-variant: new distinct entry has wrong value");
            return error.CaseVariantWrongValue;
        }
    }
}

/// Set a fresh path to one value, then re-set the SAME path to a DIFFERENT
/// value: the second set must overwrite in place (exactly one line added
/// total, scalar read-back of the second value), not append a second line
/// for the same path (BUG1).
fn checkResetToDistinctValue(
    a: std.mem.Allocator,
    dialect: Dialect,
    dialect_name: []const u8,
    gen: GenResult,
    rng: std.Random,
    ctr: *usize,
    idx: usize,
    seed: u64,
) !void {
    const path = try genFreshPathAvoidingLists(a, rng, gen.list_model, dialect, ctr);
    var doc = ini.Document.parse(a, gen.source, .{ .dialect = dialect }) catch |err| {
        report(dialect_name, idx, seed, gen.source, path, "", null, "reset-distinct: source failed to parse");
        return err;
    };
    doc.setSegments(path, @as([]const u8, "first")) catch return;
    const out1 = try emitToOwned(a, &doc);
    // Whatever the first create cost (one line for a key append, several for
    // a whole new section plus its blank-line separator) is the baseline; the
    // SECOND set, to a different value, must not add anything more.
    const lines_after_first = std.mem.count(u8, out1, "\n");

    doc.setSegments(path, @as([]const u8, "second")) catch |err| {
        report(dialect_name, idx, seed, gen.source, path, "second", null, "reset-distinct: second set on a freshly created path errored");
        return err;
    };
    const out = try emitToOwned(a, &doc);
    try assertCrlfPreserved(dialect_name, idx, seed, gen, path, "second", out, "CRLF source gained a bare LF (reset-distinct)");
    const after_lines = std.mem.count(u8, out, "\n");
    if (after_lines != lines_after_first) {
        report(dialect_name, idx, seed, gen.source, path, "second", out, "reset-distinct: a different value on a freshly created path added a second line");
        return error.ResetToDistinctValueDuplicated;
    }
    const reparsed = ini.parse(a, out, .{ .dialect = dialect }) catch |err| {
        report(dialect_name, idx, seed, gen.source, path, "second", out, "reset-distinct: output failed to reparse");
        return err;
    };
    const got = reparsed.getSegments(path) orelse {
        report(dialect_name, idx, seed, gen.source, path, "second", out, "reset-distinct: path missing after re-set");
        return error.ResetToDistinctValueMissing;
    };
    if (got != .string or !std.mem.eql(u8, got.string, "second")) {
        report(dialect_name, idx, seed, gen.source, path, "second", out, "reset-distinct: read-back is not the second value");
        return error.ResetToDistinctValueMismatch;
    }
}

/// Every non-`path` entry in `gen.model`/`gen.list_model` must still read
/// back unchanged in `reparsed` -- `checkListValue`'s invariant 4 (and its
/// invariant-7 remove-round-trip counterpart), covering both a scalar
/// sibling and a genuinely pre-existing multi-value (`list_model`) sibling.
fn checkListSiblings(
    dialect_name: []const u8,
    idx: usize,
    seed: u64,
    gen: GenResult,
    path: []const []const u8,
    items_desc: []const u8,
    reparsed: Value,
    out: []const u8,
    what: []const u8,
) !void {
    for (gen.model) |e| {
        if (segsEqual(e.segs[0..e.len], path)) continue;
        const gv = reparsed.getSegments(e.segs[0..e.len]) orelse {
            report(dialect_name, idx, seed, gen.source, path, items_desc, out, what);
            return error.ListSiblingDropped;
        };
        if (gv != .string or !std.mem.eql(u8, gv.string, e.value)) {
            report(dialect_name, idx, seed, gen.source, path, items_desc, out, what);
            return error.ListSiblingCorrupted;
        }
    }
    for (gen.list_model) |e| {
        if (segsEqual(e.segs[0..e.len], path)) continue;
        const gv = reparsed.getSegments(e.segs[0..e.len]) orelse {
            report(dialect_name, idx, seed, gen.source, path, items_desc, out, what);
            return error.ListSiblingDropped;
        };
        if (gv != .list or gv.list.len != e.items.len) {
            report(dialect_name, idx, seed, gen.source, path, items_desc, out, what);
            return error.ListSiblingCorrupted;
        }
        for (gv.list, e.items) |g, w| {
            if (!std.mem.eql(u8, g, w)) {
                report(dialect_name, idx, seed, gen.source, path, items_desc, out, what);
                return error.ListSiblingCorrupted;
            }
        }
    }
}

/// `setValueSegments`' `.list` branch, against its own fresh `Document`, with
/// a random 0-3 item list. Only meaningful under a `duplicate_keys =
/// .accumulate` dialect (gitconfig here); every other dialect's parser
/// collapses repeated lines back to one value regardless of how they were
/// written, so the read-back-as-`.list` invariant would not hold there and
/// this is skipped.
///
/// The target path is a mix, matching `genPath`'s own "existing leaf / fresh
/// create" spirit: when `buildOneSection` planted a genuine multi-value key
/// in the source (`gen.list_model`), often replace ONE OF THOSE (exercising
/// reading and replacing a key that already had several physical lines);
/// otherwise fall back to `fallback_path` (the same path `runCase`'s scalar
/// flow already exercised), covering create and scalar-to-list replace.
///
/// Checks the same invariants as the scalar path -- set is total-or-clean,
/// reparse-clean, read-back exact (a 0-item list reads back absent, a
/// 1-item list collapses to `.string`, 2+ items round-trip as an
/// ORDER-preserving `.list`), siblings (scalar AND multi-value) and comments
/// survive, a repeat set is idempotent, and removing an existing list path
/// removes every line -- but not invariant 5b (byte-exact-except-value
/// minimal diff): a list replace may change the line COUNT itself, so "diff
/// over one value's span" does not apply the way it does to a single scalar
/// token.
fn checkListValue(
    a: std.mem.Allocator,
    dialect: Dialect,
    dialect_name: []const u8,
    gen: GenResult,
    fallback_path: []const []const u8,
    rng: std.Random,
    idx: usize,
    seed: u64,
) !void {
    if (dialect.duplicate_keys != .accumulate) return;
    const path = if (gen.list_model.len > 0 and rng.uintLessThan(u8, 100) < 40) blk: {
        const e = gen.list_model[rng.uintLessThan(usize, gen.list_model.len)];
        break :blk e.segs[0..e.len];
    } else fallback_path;
    const items = try genValueList(a, rng);
    const items_desc = try std.mem.join(a, ",", items);

    var doc = ini.Document.parse(a, gen.source, .{ .dialect = dialect }) catch |err| {
        report(dialect_name, idx, seed, gen.source, path, items_desc, null, "list: source failed to parse");
        return err;
    };

    if (doc.setValueSegments(path, .{ .list = items })) |_| {
        const out1 = try emitToOwned(a, &doc);
        try assertCrlfPreserved(dialect_name, idx, seed, gen, path, items_desc, out1, "CRLF source gained a bare LF (list set)");

        const reparsed = ini.parse(a, out1, .{ .dialect = dialect }) catch |e| {
            report(dialect_name, idx, seed, gen.source, path, items_desc, out1, "list: output failed to reparse");
            return e;
        };

        // Invariant 3: read-back exact.
        if (items.len == 0) {
            if (reparsed.getSegments(path) != null) {
                report(dialect_name, idx, seed, gen.source, path, items_desc, out1, "list: empty-list path still present");
                return error.ListEmptyStillPresent;
            }
        } else {
            const got = reparsed.getSegments(path) orelse {
                report(dialect_name, idx, seed, gen.source, path, items_desc, out1, "list: read-back missing");
                return error.ListReadBackMissing;
            };
            if (items.len == 1) {
                if (got != .string or !std.mem.eql(u8, got.string, items[0])) {
                    report(dialect_name, idx, seed, gen.source, path, items_desc, out1, "list: single-item read-back mismatch");
                    return error.ListReadBackMismatch;
                }
            } else {
                if (got != .list or got.list.len != items.len) {
                    report(dialect_name, idx, seed, gen.source, path, items_desc, out1, "list: read-back not a matching list");
                    return error.ListReadBackMismatch;
                }
                for (got.list, items) |g, w| {
                    if (!std.mem.eql(u8, g, w)) {
                        report(dialect_name, idx, seed, gen.source, path, items_desc, out1, "list: item mismatch or reordered");
                        return error.ListReadBackMismatch;
                    }
                }
            }
        }

        // Invariant 4: sibling preservation (scalar and multi-value).
        try checkListSiblings(dialect_name, idx, seed, gen, path, items_desc, reparsed, out1, "list: sibling dropped or corrupted");

        // Invariant 5: every comment survives, as a whole line.
        try assertCommentsSurvive(a, dialect_name, idx, seed, gen, path, items_desc, out1, "list: comment dropped");

        // Invariant 6: idempotence.
        doc.setValueSegments(path, .{ .list = items }) catch |e| {
            report(dialect_name, idx, seed, gen.source, path, items_desc, out1, "list: idempotent re-apply errored");
            return e;
        };
        const out2 = try emitToOwned(a, &doc);
        if (!std.mem.eql(u8, out1, out2)) {
            report(dialect_name, idx, seed, gen.source, path, items_desc, out1, "list: not idempotent");
            return error.ListNotIdempotent;
        }

        // Invariant 7: remove round-trip, for a path that now resolves.
        if (items.len > 0) {
            var doc_c = ini.Document.parse(a, out1, .{ .dialect = dialect }) catch |e| {
                report(dialect_name, idx, seed, gen.source, path, items_desc, out1, "list: edited output failed to reparse for remove");
                return e;
            };
            doc_c.removeSegments(path) catch |e| {
                report(dialect_name, idx, seed, gen.source, path, items_desc, out1, "list: remove errored on an existing list path");
                return e;
            };
            const outc = try emitToOwned(a, &doc_c);
            try assertCrlfPreserved(dialect_name, idx, seed, gen, path, items_desc, outc, "CRLF source gained a bare LF (list remove)");
            const reparsed_c = ini.parse(a, outc, .{ .dialect = dialect }) catch |e| {
                report(dialect_name, idx, seed, gen.source, path, items_desc, outc, "list: post-remove output failed to reparse");
                return e;
            };
            if (reparsed_c.getSegments(path) != null) {
                report(dialect_name, idx, seed, gen.source, path, items_desc, outc, "list: path still present after remove");
                return error.ListRemoveIneffective;
            }
            try checkListSiblings(dialect_name, idx, seed, gen, path, items_desc, reparsed_c, outc, "list: remove sibling dropped or corrupted");
            try assertCommentsSurvive(a, dialect_name, idx, seed, gen, path, items_desc, outc, "list: remove comment dropped");
        }
    } else |_| {
        // Invariant 1: set is total-or-clean.
        const out_after = try emitToOwned(a, &doc);
        if (!std.mem.eql(u8, out_after, gen.source)) {
            report(dialect_name, idx, seed, gen.source, path, items_desc, out_after, "list: failed edit did not roll back");
            return error.ListNotRolledBack;
        }
    }
}

fn runBattery(dialect: Dialect, dialect_name: []const u8, base_seed: u64, k: usize) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var i: usize = 0;
    while (i < k) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const seed = base_seed +% i;
        var prng: std.Random.DefaultPrng = .init(seed);
        try runCase(a, dialect, dialect_name, prng.random(), seed, i);
    }
}

// Fixed seed, bounded case count (1500 per dialect, 3000 total): deterministic
// and fast, but wide enough to hit the adversarial-name and create-path
// corners a handwritten suite would only sample by hand.
test "document property battery: generic" {
    try runBattery(Dialect.generic, "generic", 0x1101_2222_baba_dada, 1500);
}

test "document property battery: gitconfig" {
    try runBattery(Dialect.gitconfig, "gitconfig", 0x2202_3333_cbcb_ebeb, 1500);
}

// generic and gitconfig both fold sections AND keys, so neither ever
// exercises the case-SENSITIVE direction of `checkCaseVariant` (a
// case-variant path must stay distinct, not resolve in). strict folds
// neither, covering that direction.
test "document property battery: strict" {
    try runBattery(Dialect.strict, "strict", 0x3303_4444_dcdc_fcfc, 1500);
}
