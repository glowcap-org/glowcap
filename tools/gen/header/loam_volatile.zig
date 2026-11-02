//! Reflected optional Loam ABI header for the in-memory engine companion. The crossing
//! contracts every companion shares are written once in `loam_engine.zig`.
const loam_engine = @import("loam_engine.zig");
const Output = @import("output").Output;

const H = loam_engine.Header(.{
    .module_name = "c_abi_loam_volatile",
    .symbol = "volatile",
    .macro = "VOLATILE",
    .typedef = "GlowcapLoamVolatile",
    .owner = "in-memory owner",
    .open_params = &.{ "store_id", "create", "capacity_bytes", "schemas", "schema_count", "limits", "out_storage", "out_store" },
    .open_doc = "Create a new in-memory store and reserve a fresh incarnation. The open takes no path, and each open makes its own store that lives until release, so two opens with one identity coexist. create=0 returns NOT_FOUND because no store exists before it is created, and create=1 and create=2 both create. capacity_bytes bounds the stored keys and values together, independent of the resident and staged bytes in limits. The storage owner owns the returned borrowed Store; limits and schemas are copied.",
    .release_doc = "Release a quiescent storage owner and its Store, then free the store, which ends it. Busy leaves both alive. Attachments and storage workers must finish first.",
    .work_run_note = " Calls into the one engine are serialized by a lock.",
}, @import("c_abi_loam_volatile"));
pub const step_name = H.step_name;
pub const outputs = [_]Output{.{ .path = H.header_path, .generate = H.generate }};
