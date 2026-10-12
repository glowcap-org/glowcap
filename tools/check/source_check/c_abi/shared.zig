//! The names the resolve family shares (ADR-0077): the canonical contract,
//! the operator fetch script, and the binding loaders that implement the
//! download cascade. One authority, because three sibling checks each walk
//! the same set and a drifted copy would let a port fall out of one of them.

pub const contract_path = "bindings/c-abi-resolve.json";
pub const tarball_template = "glowcap-c-v{version}-{target}.tar.gz";
pub const operator_script = "tools/c-abi/fetch-c-abi.sh";

/// The C-ABI find/download cascade is one contract (`bindings/c-abi-resolve.json`)
/// shipped inside every binding package (ADR-0077). Bindings download with
/// language-native code, `tools/c-abi/fetch-c-abi.sh` is an operator CLI only.
pub const c_abi_binding_loaders = [_][]const u8{
    "bindings/rust/build.rs",
    "bindings/python/glowcap/_lib_resolve.py",
    "bindings/ts/runtime/internal/ffi/load.ts",
    "bindings/racket/private/lib-resolve.rkt",
};

/// Whether `byte` continues a C identifier, shared by every check that scans
/// header text for symbol boundaries.
pub fn isIdentChar(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or byte == '_';
}
