//! Reflected optional Loam ABI header for the SQLite engine companion. The crossing
//! contracts every companion shares are written once in `loam_engine.zig`.
const loam_engine = @import("loam_engine.zig");
const Output = @import("output").Output;

const H = loam_engine.Header(.{
    .module_name = "c_abi_loam_sqlite",
    .symbol = "sqlite",
    .macro = "SQLITE",
    .typedef = "GlowcapLoamSqlite",
    .owner = "SQLite owner",
    .open_params = &.{ "path", "path_len", "store_id", "create", "capacity_bytes", "schemas", "schema_count", "limits", "out_storage", "out_store" },
    .open_doc = "Open exclusive SQLite custody of a store directory and reserve a fresh incarnation. create=0 requires an existing Store and refuses a missing one as NOT_FOUND, create=1 requires absence, and create=2 atomically initializes absence or opens the exact persisted identity. capacity_bytes is the most the database file may grow to, at least 1 MiB. A file that is not a Loam store, a mismatched identity, and corrupt metadata always refuse, and an open whose durable outcome is unknown returns IO. The storage owner owns the returned borrowed Store; limits and schemas are copied.",
    .release_doc = "Release a quiescent storage owner and its Store, then close the database. Busy leaves both alive. Attachments and storage workers must finish first.",
}, @import("c_abi_loam_sqlite"));
pub const step_name = H.step_name;
pub const outputs = [_]Output{.{ .path = H.header_path, .generate = H.generate }};
