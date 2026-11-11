//! Where each binding's FFI omission policy lives. The binding FFI generator
//! steps (`tools/build/gen.zig`) and the source-check runtime proofs read the
//! policies from these paths.

/// The omission policy file of `binding` (`python`, `racket`, `rust`, `ts`).
pub fn path(comptime binding: []const u8) []const u8 {
    return "bindings/ffi_omissions/" ++ binding ++ ".zig";
}
