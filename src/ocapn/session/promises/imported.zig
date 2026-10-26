//! Session metadata for imported promises: the next profile's shortening
//! edges and settling subscriptions.
//!
//! A promise a partner relays from a third party is no import row here. The
//! Node projects it as a local promise (`local_promise.zig`) and settles it
//! through the answer path, so an `op:listen` on that export reaches the same
//! answer listeners as every other local promise.
//! The row type (`ImportedPromise`) and its storage (`imported_promises`) live
//! on `Session`. These helpers are aliased back into that namespace.

const std = @import("std");
const model = @import("model");
const session = @import("../mod.zig");
const settling = @import("imported/settling.zig");

const Session = session.Session;
const ImportedPromise = session.ImportedPromise;

pub fn findImportedPromise(self: *Session, import_position: model.ImportPosition) ?*ImportedPromise {
    return self.imported_promises.getPtr(import_position);
}

pub fn shortenedTarget(self: *Session, source: model.ImportPosition) model.ImportPosition {
    var current = source;
    // `shortening.validateCompletion` admits no chain longer than this.
    var remaining = self.limits.max_resolution_chain;
    while (remaining != 0) : (remaining -= 1) {
        const entry = findImportedPromise(self, current) orelse return current;
        if (entry.shortening_target == current) return current;
        current = entry.shortening_target;
    }
    return current;
}

pub const SettlingMovePlan = settling.SettlingMovePlan;
pub const claimSettlingListener = settling.claimSettlingListener;
pub const abandonSettlingListener = settling.abandonSettlingListener;
pub const settlingAnswer = settling.settlingAnswer;
pub const settlingListenerExport = settling.settlingListenerExport;
pub const settlingNodeClaimed = settling.settlingNodeClaimed;
pub const settlingConsumerClaimed = settling.settlingConsumerClaimed;
pub const discardUnconsumedSettlingListener = settling.discardUnconsumedSettlingListener;
pub const detachSettlingNodeConsumer = settling.detachSettlingNodeConsumer;
pub const settlingFollowersForAnswer = settling.settlingFollowersForAnswer;
pub const validateSettlingFollowers = settling.validateSettlingFollowers;
pub const applySettlingFollowers = settling.applySettlingFollowers;
pub const takeSettlingFollowers = settling.takeSettlingFollowers;
pub const unlinkSettlingAnswer = settling.unlinkSettlingAnswer;
pub const settlingListenerClaimed = settling.settlingListenerClaimed;
pub const prepareSettlingMove = settling.prepareSettlingMove;
pub const commitSettlingMove = settling.commitSettlingMove;

pub fn deinitImportedPromise(allocator: std.mem.Allocator, entry: *ImportedPromise) void {
    entry.settling_followers.deinit(allocator);
}
