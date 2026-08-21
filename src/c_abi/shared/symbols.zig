//! The annotated-symbol vocabulary the per-archive inventories share.
//!
//! Each archive keeps one `symbols.zig` listing its exports' crossing
//! semantics — the facts a language FFI table cannot reflect from the C
//! signature alone. The structs live here, in the shared vocabulary leaf, so
//! every archive's inventory and every generator speak the same rows without
//! inheriting another archive's exports.

/// One export's crossing semantics. Parameter indexes are zero-based.
pub const Symbol = struct {
    name: []const u8,
    /// Buffer parameters the callee writes into. A generator emits an
    /// out-annotation only for symbols that have buffer-crossing parameters
    /// at all; an empty list on such a symbol means every buffer is
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
    /// readiness and try-I/O surface returns at once; endpoint bind and graceful
    /// teardown are lifecycle calls and are classified separately.
    ///
    /// TCP, inproc, and onion mark every call that can park, including a parent
    /// release that joins native operation ownership. Their TypeScript surfaces
    /// refuse runtimes whose FFI cannot honor that dispatch; high-level JS hosts
    /// otherwise use runtime-native async sockets where available.
    nonblocking: bool = false,
    /// Whether the symbol may park the calling OS thread (a socket or pipe
    /// wait, a dial). Every Racket row for such a symbol carries
    /// `#:blocking?`, which deactivates the calling thread during the callout
    /// so the collector never stops the world waiting on a parked call. The
    /// mark alone does not free the place's green threads, so a blocking call
    /// that must overlap them additionally rides a plain OS thread — the lazy
    /// iroh table emits its dial unwrapped for exactly that choreography.
    /// `nonblocking` above is the narrower JS dispatch policy; this is the
    /// thread-level fact.
    blocking: bool = false,
    /// Why the TypeScript dlopen table omits this symbol, or null when it
    /// declares it.
    ts_omit: ?[]const u8 = null,
    /// Why the Rust extern block omits this symbol, or null when it declares
    /// it.
    rust_omit: ?[]const u8 = null,
    /// Why the Python ctypes table omits this symbol, or null when it
    /// declares it.
    python_omit: ?[]const u8 = null,
    /// Why the Racket FFI table omits this symbol, or null when it declares
    /// it.
    racket_omit: ?[]const u8 = null,
    /// A comment emitted before this row in generated tables, naming the
    /// group that starts here.
    section: ?[]const u8 = null,
};

/// A whole export family a binding's table omits for one reason. The inventory
/// walk accepts an export that
/// matches a family prefix instead of demanding a row per symbol.
pub const OmittedFamily = struct {
    prefix: []const u8,
    reason: []const u8,
};

/// Recurring omission reasons shared by archive inventories. A row still owns
/// whether a binding omits that symbol; these constants keep repeated boundary
/// facts in one wording.
pub const omit_reason = struct {
    pub const rust_last_error = "unused: the Rust binding reads the slot after a failing call and never resets it";
    pub const ts_last_error = "unused: the TS binding reads the slot after a failing call and never resets it";
    pub const python_last_error = "unused: the Python binding reads the slot after a failing call and never resets it";
    pub const racket_last_error = "unused: the Racket binding reads the slot after a failing call and never resets it";

    pub const rust_transport_allocator = "unused: the Rust binding keeps its transports on the library allocator";
    pub const ts_transport_allocator = "unused: the TS binding keeps its transports on the library allocator";
    pub const python_transport_allocator = "unused: the Python binding keeps its transports on the library allocator";
    pub const racket_transport_allocator = "unused: the Racket binding keeps its transports on the library allocator";

    pub const ts_transport_runtime_allocator = "unused: the TypeScript binding keeps transport runtimes on the library allocator";
    pub const python_transport_runtime_allocator = "unused: the Python binding keeps transport runtimes on the library allocator";
    pub const racket_transport_runtime_allocator = "unused: the Racket binding keeps transport runtimes on the library allocator";
};
