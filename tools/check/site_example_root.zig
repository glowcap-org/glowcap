//! Roots one site Zig snippet so compiling it reads the whole file.
//!
//! Zig analyzes a declaration only when something references it. A snippet is
//! a `pub fn example` nothing calls, so compiling the file on its own accepts
//! a body that names an API glowcap no longer has. This root takes the address status-allow: lifecycle transition
//! of every public declaration in the snippet, which pulls each body through
//! semantic analysis. It compiles as an object rather than a test binary
//! because the iroh and relay snippets reach externs only a sidecar link
//! resolves, and the compile claim needs no link.

const snippet = @import("snippet");

comptime {
    for (@typeInfo(snippet).@"struct".decl_names) |name| _ = &@field(snippet, name);
}
