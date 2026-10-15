//! The in-memory engine behind one lock. The engine is sync and
//! single-threaded, as a core layer must be, and the storage executor's
//! threads and the Host thread both call an archive's engine, so the archive
//! owns the serialization. Each call is a walk over memory with no I/O, the
//! condition a spin lock needs.
const std = @import("std");
const loam = @import("loam_core");
const Volatile = @import("loam_volatile").Volatile;
const SpinLock = @import("net").sync.SpinLock;

pub const Serialized = struct {
    engine: Volatile,
    metadata: loam.Metadata,
    lock: SpinLock = .{},

    /// A new store holding only its claimed metadata.
    pub fn open(allocator: std.mem.Allocator, identity: loam.StoreId, capacity_bytes: usize) !Serialized {
        var engine = try Volatile.init(allocator, identity, capacity_bytes);
        errdefer engine.deinit();
        const metadata = try engine.open();
        return .{ .engine = engine, .metadata = metadata };
    }

    /// Close and free every row, so the store ends here. Every caller has
    /// joined its workers, which leaves no transaction to refuse the close.
    pub fn close(self: *Serialized) !void {
        try self.engine.close();
        self.engine.deinit();
    }

    /// The lock admits one call at a time, and each read ends inside its
    /// call, so any number of reads may be submitted at once.
    pub fn readerCapacity(self: *const Serialized) usize {
        return self.engine.readerCapacity();
    }

    pub fn read(self: *Serialized, request: loam.Read) loam.ReadResult {
        self.lock.lock();
        defer self.lock.unlock();
        return self.engine.read(request);
    }

    pub fn commit(self: *Serialized, batch: loam.Batch) loam.Outcome {
        self.lock.lock();
        defer self.lock.unlock();
        return self.engine.commit(batch);
    }

    pub fn lookup(self: *Serialized, request: loam.NameLookup) loam.NameResult {
        self.lock.lock();
        defer self.lock.unlock();
        return self.engine.lookup(request);
    }

    pub fn recover(self: *Serialized, batch: loam.Batch) !loam.Resolution {
        self.lock.lock();
        defer self.lock.unlock();
        return self.engine.recover(batch);
    }
};
