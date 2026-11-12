//! Reflected optional Loam ABI header for the LMDB engine companion. The crossing
//! contracts every companion shares are written once in `loam_engine.zig`.
const loam_engine = @import("loam_engine.zig");
const Output = @import("output").Output;

const H = loam_engine.Header(.{
    .module_name = "c_abi_loam_lmdb",
    .symbol = "lmdb",
    .macro = "LMDB",
    .typedef = "GlowcapLoamLmdb",
    .owner = "LMDB owner",
    .open_params = &.{ "path", "path_len", "store_id", "create", "map_bytes", "schemas", "schema_count", "limits", "out_storage", "out_store" },
    .open_doc = "Open exclusive LMDB custody in an existing directory and reserve a fresh incarnation. create=0 requires an existing Store, create=1 requires absence, and create=2 atomically initializes absence or opens the exact persisted identity. Corrupt or mismatched metadata always refuses. The storage owner owns the returned borrowed Store; limits and schemas are copied.",
    .release_doc = "Release a quiescent storage owner and its Store, then close LMDB. A busy Store refuses before teardown and leaves both alive. Attachments and storage workers must finish first.",
}, @import("c_abi_loam_lmdb"));
pub const step_name = H.step_name;
pub const outputs = [_]Output{.{ .path = H.header_path, .generate = H.generate }};
