//! The engine the shared durable suite under `test/loam/engines/` runs over.
//! Each engine's test root supplies a module named `engine_fixture` with
//! these declarations, so a shared test never names an engine.
const core = @import("loam_core");

pub const Engine = @import("loam_sqlite").Sqlite;
pub const name = "sqlite";
/// The file inside a store directory that holds its records.
pub const data_file = @import("loam_sqlite").file_name;
/// What every store the suite opens may grow to, and what the engine suite's
/// `Options.capacity_bytes` takes.
pub const capacity_bytes: ?usize = 16 * 1024 * 1024;
pub const Temp = @import("loam_engine_temp").Temp;

/// Opens the store at `path` in `mode` with the suite's capacity.
pub fn open(path: [:0]const u8, mode: core.OpenMode, id: core.StoreId) !Engine {
    return Engine.open(path, .{ .capacity_bytes = capacity_bytes.?, .mode = switch (mode) {
        .create => .{ .create = id },
        .open => .{ .open = id },
        .bootstrap => .{ .bootstrap = id },
    } });
}
