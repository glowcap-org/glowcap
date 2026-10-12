//! An allocator that runs out of memory at a point the fuzzer picks.
//!
//! Running out of memory partway through building something is the case this
//! codebase documents most and tests least. `.agents/rules/memory.md` names
//! roughly twenty-five allocations as bounded, owned, or freed on every path,
//! and each of those claims has an unwind behind it that only runs when an
//! allocation fails. A parse can only fail where the bytes are wrong. An
//! allocation can fail anywhere, including halfway down a tree with a boxed arm
//! already built and nothing left to build the next one with.
//!
//! Nothing here asserts. The leak check underneath is what decides: if the
//! unwind forgets something, the allocator reports it and the test fails. All
//! this has to do is make the failure happen somewhere interesting, and let the
//! fuzzer choose where.
//!
//! Roughly half the draws leave it switched off, so the ordinary success paths
//! keep their share of the budget.

const std = @import("std");

pub const Budget = struct {
    failing: std.testing.FailingAllocator,

    /// Draw a failure point. `span` is how far into a run the failure may land:
    /// a decoder does tens of allocations, an open session does hundreds, and a
    /// point past the end of a run is the same as no failure at all.
    pub fn draw(smith: *std.testing.Smith, span: u16) Budget {
        return drawWith(smith, span, std.testing.allocator);
    }

    /// `draw` with an explicit backing allocator. Lifecycle-heavy targets use
    /// this to put a fresh lightweight leak-checking allocator around each
    /// mutation instead of retaining the test runner's allocator state across
    /// hundreds of thousands of complete host lifecycles.
    pub fn drawWith(smith: *std.testing.Smith, span: u16, backing: std.mem.Allocator) Budget {
        // Inducing a failure is the *top* of the range. When a draw runs past
        // the input the generator falls back to the bottom, so putting it at
        // the bottom meant every seed replay failed its very first allocation
        // and the program under it never ran at all.
        const pick = smith.valueRangeAtMost(u16, 0, span *| 2);
        return .{ .failing = std.testing.FailingAllocator.init(backing, .{
            .fail_index = if (pick > span) pick - span - 1 else std.math.maxInt(usize),
        }) };
    }

    pub fn allocator(self: *Budget) std.mem.Allocator {
        return self.failing.allocator();
    }

    /// Whether the failure this run asked for actually happened. A run that
    /// never reached its failure point took the ordinary path.
    pub fn failed(self: *const Budget) bool {
        return self.failing.has_induced_failure;
    }

    /// For a step whose refusal is a legitimate answer: parsing bytes nobody
    /// promised were well formed, or encoding a message the codec declines to
    /// put on the wire. The property ends for this input.
    ///
    /// Running out of memory is not one of those. It ends the property when the
    /// failure was induced here, and is a real error when it was not.
    pub fn refusalEndsIt(self: *const Budget, err: anyerror) anyerror!void {
        if (err == error.OutOfMemory and !self.failed()) return error.OutOfMemory;
        return;
    }

    /// For a step that is checking a property: the only outcome to let past is
    /// the failure this run asked for. Anything else means the property did not
    /// hold, and saying otherwise would make the check a computation whose
    /// answer is thrown away.
    pub fn onlyInducedFailure(self: *const Budget, err: anyerror) anyerror!void {
        if (err == error.OutOfMemory and self.failed()) return;
        return err;
    }
};
