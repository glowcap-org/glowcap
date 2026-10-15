//! The storage-engine contract and the backend derived from it. An engine is
//! transactions: `beginRead` yields a read transaction (`get`, `next`, `end`)
//! and `beginWrite` a write transaction (`get`, `next`, `put`, `remove`, then
//! `commit` or `abort`). `readerCapacity` reports how many read
//! transactions can be open at once, so a worker never runs more reads than
//! the engine admits. A backend is what the worker drives: `read`,
//! `commit`, `lookup`, and `recover`. This module derives all four from any
//! engine once, so an engine implements no record logic of its own. Opening
//! an engine takes arguments the engine owns and is outside the contract.
//! Returned rows borrow the transaction until its next operation or end. The
//! next operation may consume those slices as inputs before retiring them.
const transaction = @import("transaction.zig");
const residency = @import("residency.zig");
const names = @import("names.zig");

/// The result of a write transaction's commit. A refused commit is an error
/// instead, and the transaction then changed nothing. Every result finishes
/// the transaction. A repeated commit after a committed result answers it
/// again, and every operation after a refusal or an abort is `error.Closed`.
/// A refused put or remove applied nothing and ends the transaction the
/// same way, so a later commit can never apply part of a batch.
pub const Commit = enum { committed, unknown };

const read_operations = [_][]const u8{ "get", "next", "end" };
const write_operations = [_][]const u8{ "get", "next", "put", "remove", "commit", "abort" };
const backend_operations = [_][]const u8{ "read", "commit", "lookup", "recover" };

/// The first operation `Engine` lacks, phrased for a compile error, or null.
pub fn missingOperation(comptime Engine: type) ?[]const u8 {
    if (!@hasDecl(Engine, "beginRead")) return "engine lacks beginRead";
    if (!@hasDecl(Engine, "beginWrite")) return "engine lacks beginWrite";
    if (!@hasDecl(Engine, "readerCapacity")) return "engine lacks readerCapacity";
    if (!@hasDecl(Engine, "ReadTransaction")) return "engine lacks ReadTransaction";
    if (!@hasDecl(Engine, "WriteTransaction")) return "engine lacks WriteTransaction";
    inline for (read_operations) |name| {
        if (!@hasDecl(Engine.ReadTransaction, name)) return "read transaction lacks " ++ name;
    }
    inline for (write_operations) |name| {
        if (!@hasDecl(Engine.WriteTransaction, name)) return "write transaction lacks " ++ name;
    }
    return null;
}

/// Refuse at compile time an engine that does not implement the contract.
pub fn checkEngine(comptime Engine: type) void {
    if (comptime missingOperation(Engine)) |missing| {
        @compileError("loam engine " ++ @typeName(Engine) ++ ": " ++ missing);
    }
}

/// The first of `read`, `commit`, `lookup`, and `recover` that `Backend` lacks.
pub fn missingBackendOperation(comptime Backend: type) ?[]const u8 {
    inline for (backend_operations) |name| {
        if (!@hasDecl(Backend, name)) return "backend lacks " ++ name;
    }
    return null;
}

/// Refuse at compile time a backend the worker cannot drive. A pointer type
/// stands for the type it points to.
pub fn checkBackend(comptime Backend: type) void {
    const Type = switch (@typeInfo(Backend)) {
        .pointer => |pointer| pointer.child,
        else => Backend,
    };
    if (comptime missingBackendOperation(Type)) |missing| {
        @compileError("loam backend " ++ @typeName(Type) ++ ": " ++ missing);
    }
}

/// The metadata row of an open transaction, or `error.Corrupt` when absent.
pub fn metadata(txn: anytype) !transaction.Metadata {
    return transaction.Metadata.decode((try txn.get(transaction.metadata_key)) orelse return error.Corrupt);
}

/// Answer a read inside an open transaction: check the ticket against the
/// metadata row, then copy the record into the request's buffer.
pub fn readRecord(txn: anytype, request: residency.Read) !residency.ReadResult {
    const meta = try metadata(txn);
    if (meta.store != request.ticket.store or meta.incarnation != request.ticket.incarnation or meta.revision != request.ticket.revision) return error.StaleCompletion;
    const bytes = (try txn.get(&request.id.key())) orelse return .missing;
    if (bytes.len > request.buffer.len) return error.RecordTooLarge;
    @memcpy(request.buffer[0..bytes.len], bytes);
    return .{ .found = .{ .length = bytes.len, .metadata = meta } };
}

/// `engine` is a pointer to any type that passes `checkEngine`.
pub fn read(engine: anytype, request: residency.Read) residency.ReadResult {
    var txn = engine.beginRead() catch |err| return .{ .failed = err };
    defer txn.end();
    return readRecord(&txn, request) catch |err| .{ .failed = err };
}

/// Apply the batch in one write transaction. A failed apply aborts, and a
/// refused commit changed nothing. Only an uncertain commit is `.unknown`.
pub fn commit(engine: anytype, batch: transaction.Batch) transaction.Outcome {
    var txn = engine.beginWrite() catch |err| return .{ .unchanged = err };
    const next = batch.apply(&txn) catch |err| {
        txn.abort();
        return .{ .unchanged = err };
    };
    const state = txn.commit() catch |err| return .{ .unchanged = err };
    return switch (state) {
        .committed => .{ .committed = next },
        .unknown => .unknown,
    };
}

pub fn lookup(engine: anytype, request: names.Lookup) names.Result {
    var txn = engine.beginRead() catch |err| return .{ .failed = err };
    defer txn.end();
    return request.read(&txn) catch |err| .{ .failed = err };
}

/// The original commit worker must be joined before resolving absence.
pub fn recover(engine: anytype, batch: transaction.Batch) !transaction.Resolution {
    var txn = try engine.beginRead();
    defer txn.end();
    return batch.resolve(try metadata(&txn));
}
