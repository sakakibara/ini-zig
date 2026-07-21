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

const GenResult = struct {
    source: []const u8,
    model: []ModelEntry,
    comments: [][]const u8,
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
        const value = safeValue(rng);
        const segs = try a.dupe([]const u8, &.{ sec_name, key_name });
        const actual = try setAndRecord(builder, a, model, segs, value, ctr);
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

/// Generate a random valid document for `dialect`: 1-3 top-level sections,
/// each promoted (re-parsed) before the next is built so a later section's
/// creation sees genuine prior content (a real blank-line separator,
/// exercising layout preservation), then 0-3 comments inserted against
/// existing dot-free paths.
fn genDoc(a: std.mem.Allocator, dialect: Dialect, rng: std.Random, ctr: *usize) !GenResult {
    var builder = try ini.Document.empty(a, .{ .dialect = dialect });
    var model: std.ArrayList(ModelEntry) = .empty;

    const num_sections = rng.intRangeAtMost(usize, 1, 3);
    var si: usize = 0;
    while (si < num_sections) : (si += 1) {
        try buildOneSection(&builder, a, dialect, rng, ctr, &model);
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

    const source = try emitToOwned(a, &builder);
    // Sanity check on the generator itself: a constructed document must
    // always be valid INI for its dialect.
    _ = try ini.parse(a, source, .{ .dialect = dialect });
    const comments = try extractComments(a, source, dialect);
    return .{ .source = source, .model = try model.toOwnedSlice(a), .comments = comments };
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
    const path = try genPath(a, rng, gen.model, dialect, &ctr);
    const existed_before = modelFind(gen.model, path) != null;
    const is_leaf_case = existed_before or containerExists(gen.model, path);
    const value = genTargetValue(rng);

    var docA = ini.Document.parse(a, gen.source, .{ .dialect = dialect }) catch |e| {
        report(dialect_name, idx, seed, gen.source, path, value, null, "constructed source failed to parse");
        return e;
    };

    if (docA.setSegments(path, value)) |_| {
        const out1 = try emitToOwned(a, &docA);

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

        // Invariant 5: every comment survives.
        for (gen.comments) |c| {
            if (std.mem.indexOf(u8, out1, c) == null) {
                report(dialect_name, idx, seed, gen.source, path, value, out1, "comment dropped");
                return error.CommentDropped;
            }
        }
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
            for (gen.comments) |c| {
                if (std.mem.indexOf(u8, outc, c) == null) {
                    report(dialect_name, idx, seed, gen.source, path, value, outc, "remove: comment dropped");
                    return error.RemoveCommentDropped;
                }
            }
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
