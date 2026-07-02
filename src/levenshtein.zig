//! Edit distance and closest-match lookup for "did you mean" suggestions.

const std = @import("std");
const testing = std.testing;

/// Bounded Levenshtein edit distance between a and b. When the true distance
/// exceeds cap, the result is cap + 1 -- except when either input is empty:
/// the early return then yields the other input's length uncapped. Callers
/// compare against a threshold <= cap, so an over-cap result is filtered
/// either way. O(a.len * b.len), no allocation (stack rows up to 256 chars).
fn levenshtein(a: []const u8, b: []const u8, cap: usize) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > 256 or b.len > 256) {
        const diff = if (a.len > b.len) a.len - b.len else b.len - a.len;
        return if (diff > cap) cap + 1 else diff;
    }

    var prev: [257]usize = undefined;
    var curr: [257]usize = undefined;
    var i: usize = 0;
    while (i <= b.len) : (i += 1) prev[i] = i;

    i = 0;
    while (i < a.len) : (i += 1) {
        curr[0] = i + 1;
        var min_in_row: usize = curr[0];
        var j: usize = 0;
        while (j < b.len) : (j += 1) {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            const del = prev[j + 1] + 1;
            const ins = curr[j] + 1;
            const sub = prev[j] + cost;
            curr[j + 1] = @min(@min(del, ins), sub);
            if (curr[j + 1] < min_in_row) min_in_row = curr[j + 1];
        }
        if (min_in_row > cap) return cap + 1;
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return if (prev[b.len] > cap) cap + 1 else prev[b.len];
}

/// Return the candidate closest to word by edit distance, or null when no
/// candidate falls within max(2, word.len/4) edits. Ties go to the earlier
/// candidate in the slice.
pub fn closest(candidates: []const []const u8, word: []const u8) ?[]const u8 {
    const threshold = @max(2, word.len / 4);
    var best: ?[]const u8 = null;
    var best_dist: usize = threshold + 1;
    for (candidates) |cand| {
        const d = levenshtein(word, cand, threshold);
        if (d <= threshold and d < best_dist) {
            best = cand;
            best_dist = d;
        }
    }
    return best;
}

test "levenshtein: identical and empty strings" {
    try testing.expectEqual(@as(usize, 0), levenshtein("", "", 10));
    try testing.expectEqual(@as(usize, 0), levenshtein("hello", "hello", 10));
    try testing.expectEqual(@as(usize, 5), levenshtein("", "hello", 10));
    try testing.expectEqual(@as(usize, 5), levenshtein("hello", "", 10));
}

test "levenshtein: substitutions" {
    try testing.expectEqual(@as(usize, 1), levenshtein("hello", "hallo", 10));
    try testing.expectEqual(@as(usize, 2), levenshtein("hello", "hxllx", 10));
    try testing.expectEqual(@as(usize, 3), levenshtein("kitten", "sitting", 10));
}

test "levenshtein: cap limits return value" {
    try testing.expectEqual(@as(usize, 3), levenshtein("kitten", "kittenmore", 2));
}

test "closest: naem matches name" {
    try testing.expectEqualStrings("name", closest(&.{ "name", "email" }, "naem").?);
}

test "closest: unrelated word returns null" {
    try testing.expect(closest(&.{ "name", "email" }, "xyz") == null);
}

test "closest: ties broken by earlier candidate" {
    try testing.expectEqualStrings("apple", closest(&.{ "apple", "april" }, "appl").?);
}

test "closest: empty candidates returns null" {
    try testing.expect(closest(&.{}, "name") == null);
}
