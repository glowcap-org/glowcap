//! The CapTP version words the trace-vocabulary checks hold producers and the
//! viewer to.

const std = @import("std");
const model = @import("model");

/// A CapTP version's Zig enum tag and the word it puts on the wire.
pub const CaptpWireWord = struct { tag: []const u8, wire: []const u8 };

/// Every `model.CaptpVersion` with its `wireString`. Two checks hold their
/// files to these words: `c_abi.checkTraceVocabulary` the four producers, and
/// `binding_spine/viewer.zig` the viewer that reads them.
pub const captp_wire_words = blk: {
    const versions = std.enums.values(model.CaptpVersion);
    var words: [versions.len]CaptpWireWord = undefined;
    for (versions, &words) |version, *word| word.* = .{ .tag = @tagName(version), .wire = version.wireString() };
    break :blk words;
};
