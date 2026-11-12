//! The annotated-symbol vocabulary the per-archive inventories share.
//!
//! Each archive keeps one `symbols.zig` listing its exports' crossing
//! semantics, the facts a language FFI table cannot reflect from the C
//! signature alone. The structs live here, in the shared vocabulary leaf, so
//! every archive's inventory and every generator speak the same rows without
//! inheriting another archive's exports.

/// One export's crossing semantics. Parameter indexes are zero-based.
pub const Symbol = struct {
    name: []const u8,
    /// Buffer parameters the callee writes into. A generator emits an
    /// out-annotation only for symbols that have buffer-crossing parameters
    /// at all. An empty list on such a symbol means every buffer is
    /// input-only.
    out_params: []const u8 = &.{},
    /// Parameters that cross as opaque pointers although their type would
    /// classify as a writable slot: a raw-pointer release must free the
    /// address it was handed, and a turn's out-reply is the trampoline's own
    /// pointer, so neither may cross as a copied JS buffer.
    pointer_params: []const u8 = &.{},
    /// Whether the symbol blocks the calling thread long enough that a JS
    /// runtime must dispatch it off the event loop (`nonblocking` in Deno's
    /// FFI). The onion family sets it on every call that reaches Tor. Iroh's
    /// readiness and try-I/O surface returns at once. Endpoint bind and graceful
    /// teardown are lifecycle calls and are classified separately.
    ///
    /// TCP, inproc, and onion mark every call that can park, including a parent
    /// release that joins Zig operation ownership. Their TypeScript surfaces
    /// refuse runtimes whose FFI cannot honor that dispatch. High-level JS hosts
    /// otherwise use the JS runtime's own async sockets where available.
    nonblocking: bool = false,
    /// Whether the symbol may park the calling OS thread (a socket or pipe
    /// wait, a dial). Every Racket row for such a symbol carries
    /// `#:blocking?`, which deactivates the calling thread during the callout
    /// so the collector never stops the world waiting on a parked call. The
    /// mark alone does not free the place's green threads, so a blocking call
    /// that must overlap them additionally rides a plain OS thread. The lazy
    /// iroh table emits its dial unwrapped for that choreography.
    /// `nonblocking` above is the narrower JS dispatch policy. This is the
    /// thread-level fact.
    blocking: bool = false,
    /// A comment emitted before this row in generated tables, naming the
    /// group that starts here.
    section: ?[]const u8 = null,
};
