//! The engine the shared durable suite under `test/loam/engines/` runs over.
//! Each engine's test root supplies a module named `engine_fixture` with
//! these declarations, so a shared test never names an engine.
const core = @import("loam_core");

pub const Engine = @import("loam_lmdb").Lmdb;
pub const name = "lmdb";
/// The file inside a store directory that holds its records.
pub const data_file = @import("loam_lmdb").file_name;
/// What the engine suite's `Options.capacity_bytes` takes. LMDB's capacity is
/// a map, not a byte count.
pub const capacity_bytes: ?usize = null;

/// Opens the store at `path` in `mode` with the default options.
pub fn open(path: [:0]const u8, mode: core.OpenMode, id: core.StoreId) !Engine {
    return Engine.open(path, .{ .opening = .{ .id = id, .mode = mode } });
}

pub const Temp = @import("loam_engine_temp").Temp;
