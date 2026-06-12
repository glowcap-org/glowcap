//! Idiomatic Rust API for `libpancake` — an OCapN/CapTP peer you drive.
//!
//! The raw C ABI lives in the private [`sys`] module; nothing in it escapes.
//! What you use is a [`Peer`] that releases itself on drop, real Rust enums for
//! [`Reference`]/[`Argument`]/[`Event`], `Result` for fallible calls, and owned
//! values out of `poll` (no manual `free`). This is the dogfood consumer
//! `zig build rust-dogfood` runs, so the ergonomic surface stays honest.

#![allow(clippy::missing_safety_doc)]

mod abi_constants;

#[cfg(feature = "async")]
mod async_io;
#[cfg(feature = "async")]
pub use async_io::AsyncConnection;

#[cfg(feature = "async")]
mod connection;
#[cfg(feature = "async")]
pub use connection::{connect, listen, Connection, Ref, Server};

#[cfg(feature = "iroh")]
pub use connection::{connect_iroh, connect_iroh_uri, listen_iroh, IrohServer};

// The mandatory iroh reachability posture (no default): the caller always names
// one when dialing or binding over iroh.
#[cfg(feature = "iroh")]
pub use iroh::Reachability;

// The transport-dispatching dialer over an `ocapn://` URI (TCP today, iroh when
// the feature is built). Available on the async surface, like `connect`.
#[cfg(feature = "async")]
pub use connection::connect_uri;

// Socket driving the two async surfaces share: the outbound pump and the keyed
// handshake live once, here, so the copies cannot drift.
#[cfg(feature = "async")]
mod wire;

// The iroh transport (its own optional superset library, ADR-0055): the
// encrypted-QUIC byte-stream bridge the `Connection` driver carries a peer over.
#[cfg(feature = "iroh")]
mod iroh;

// OCapN locator URIs — core libpancake vocabulary, so a TCP-only consumer reaches
// the grammar without the iroh superset. One grammar, no hand-rolled percent codec.
mod uri;
pub use uri::{format_peer_uri, parse_locator, parse_sturdyref, Locator};

pub mod actors;

use core::marker::PhantomData;

mod sys {
    // The raw FFI mirror of the C ABI. It declares the full surface — every
    // error code, reference kind, and argument tag `pancake.h` defines — so the
    // safe wrapper above can reach for any of them. Not every constant is used
    // yet (e.g. `ERR_CLOSED`, `REF_BROKEN` round out their enums), and that is
    // expected of a `sys` layer, so dead code is allowed here and only here.
    #![allow(dead_code)]

    use core::ffi::{c_int, c_uchar, c_uint, c_void};
    pub use super::abi_constants::*;

    #[repr(C)]
    pub struct PancakePeer {
        _private: [u8; 0],
    }

    #[repr(C)]
    pub struct PancakeTcpNetlayer {
        _private: [u8; 0],
    }
    #[repr(C)]
    pub struct PancakeTcpConn {
        _private: [u8; 0],
    }
    #[repr(C)]
    pub struct PancakeTcpListener {
        _private: [u8; 0],
    }

    #[repr(C)]
    pub struct PancakeContext {
        _private: [u8; 0],
    }

    /// A parsed OCapN locator — one opaque handle carrying a peer or a sturdyref,
    /// minted by `pancake_uri_parse_*` and read by the `pancake_locator_*`
    /// accessors.
    #[repr(C)]
    pub struct PancakeLocator {
        _private: [u8; 0],
    }

    pub type PancakeAllocFn =
        unsafe extern "C" fn(user_data: *mut c_void, size: usize, alignment: usize) -> *mut c_void;
    pub type PancakeFreeFn =
        unsafe extern "C" fn(user_data: *mut c_void, ptr: *mut c_void, size: usize, alignment: usize);

    #[repr(C)]
    pub struct PancakeAllocator {
        pub alloc: PancakeAllocFn,
        pub free: PancakeFreeFn,
        pub user_data: *mut c_void,
    }

    #[repr(C)]
    pub struct PancakeFrame {
        pub bytes: *const c_uchar,
        pub len: usize,
        pub shape: c_uint,
    }

    #[repr(C)]
    pub struct PancakeManagedFrame {
        pub bytes: *mut c_uchar,
        pub len: usize,
        pub shape: c_uint,
        pub release: Option<unsafe extern "C" fn(*mut PancakeManagedFrame)>,
        pub private_data: *mut c_void,
    }

    #[repr(C)]
    pub struct PancakeEvent {
        pub kind: c_uint,
        pub frame: PancakeManagedFrame,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct PancakeReference {
        pub kind: c_uint,
        pub sub_kind: c_uint,
        pub id: u64,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct PancakeArgument {
        pub kind: c_uint,
        pub boolean: c_uint,
        pub integer: i64,
        pub float64: f64,
        pub bytes: *const c_uchar,
        pub bytes_len: usize,
        pub reference: PancakeReference,
        pub items: *const PancakeArgument,
        pub items_len: usize,
    }

    #[repr(C)]
    pub struct PancakeDeliver {
        pub target: PancakeReference,
        pub args: *const PancakeArgument,
        pub args_len: usize,
        pub has_answer: c_uint,
        pub answer: u64,
        pub owner: *mut c_void,
    }

    #[repr(C)]
    pub struct PancakeResolve {
        pub answer: u64,
        pub resolution_kind: c_uint,
        pub fulfill: PancakeArgument,
        pub break_message: *const c_uchar,
        pub break_message_len: usize,
        pub owner: *mut c_void,
    }

    #[repr(C)]
    pub struct PancakeLastAbort {
        /// 0 codec, 1 session, 2 foreign.
        pub domain: c_uint,
        /// Nonzero when an `op:abort` kind was projected.
        pub has_kind: c_uint,
        /// Wire name of the abort kind (process-static).
        pub kind_name: *const c_uchar,
        pub kind_name_len: usize,
        /// Static diagnostic.
        pub message: *const c_uchar,
        pub message_len: usize,
        /// Originating error name (process-static).
        pub error_name: *const c_uchar,
        pub error_name_len: usize,
    }

    extern "C" {
        pub fn pancake_abi_version(major: *mut c_uint, minor: *mut c_uint, patch: *mut c_uint);
        pub fn pancake_last_error(out_buf: *mut c_uchar, cap: usize) -> usize;
        pub fn pancake_clear_last_error();

        pub fn pancake_context_new(out: *mut *mut PancakeContext) -> c_int;
        pub fn pancake_context_new_with_allocator(
            allocator: *const PancakeAllocator,
            out: *mut *mut PancakeContext,
        ) -> c_int;
        pub fn pancake_context_release(context: *mut PancakeContext);

        pub fn pancake_peer_new(peer: *mut *mut PancakePeer) -> c_int;
        pub fn pancake_peer_new_in(context: *mut PancakeContext, peer: *mut *mut PancakePeer) -> c_int;
        pub fn pancake_peer_new_negotiated(captp_version: c_uint, codec: c_uint, peer: *mut *mut PancakePeer) -> c_int;
        pub fn pancake_peer_new_negotiated_in(
            context: *mut PancakeContext,
            captp_version: c_uint,
            codec: c_uint,
            peer: *mut *mut PancakePeer,
        ) -> c_int;
        pub fn pancake_peer_new_raw_open(peer: *mut *mut PancakePeer) -> c_int;
        pub fn pancake_peer_new_raw_open_in(context: *mut PancakeContext, peer: *mut *mut PancakePeer) -> c_int;
        pub fn pancake_peer_release(peer: *mut PancakePeer);
        pub fn pancake_peer_feed_borrowed(peer: *mut PancakePeer, frame: *const PancakeFrame) -> c_int;
        pub fn pancake_peer_feed_owned(peer: *mut PancakePeer, frame: *mut PancakeManagedFrame) -> c_int;
        pub fn pancake_peer_recv_stream(
            peer: *mut PancakePeer,
            bytes: *const c_uchar,
            len: usize,
            out_consumed: *mut usize,
        ) -> c_int;
        pub fn pancake_peer_step(peer: *mut PancakePeer) -> c_int;
        pub fn pancake_peer_take_outbound(peer: *mut PancakePeer, frame: *mut PancakeManagedFrame) -> c_int;
        pub fn pancake_peer_poll_event(peer: *mut PancakePeer, event: *mut PancakeEvent) -> c_int;
        pub fn pancake_event_release(event: *mut PancakeEvent);
        pub fn pancake_managed_frame_release(frame: *mut PancakeManagedFrame);
        pub fn pancake_peer_register_export(peer: *mut PancakePeer, export_position: u64) -> c_int;
        pub fn pancake_peer_next_export(peer: *mut PancakePeer, out_export_position: *mut u64) -> c_int;
        pub fn pancake_peer_next_answer(peer: *mut PancakePeer, out_answer: *mut u64) -> c_int;
        pub fn pancake_peer_register_import(peer: *mut PancakePeer, import_position: u64) -> c_int;
        pub fn pancake_peer_peek_event(peer: *mut PancakePeer) -> c_int;
        pub fn pancake_peer_send_deliver(
            peer: *mut PancakePeer,
            target: *const PancakeReference,
            args: *const PancakeArgument,
            args_len: usize,
            has_answer: c_uint,
            answer: u64,
        ) -> c_int;
        pub fn pancake_peer_send_resolve(
            peer: *mut PancakePeer,
            answer: u64,
            resolution_kind: c_uint,
            fulfill: *const PancakeArgument,
            break_message: *const c_uchar,
            break_message_len: usize,
        ) -> c_int;
        pub fn pancake_peer_poll_event_deliver(peer: *mut PancakePeer, out: *mut PancakeDeliver) -> c_int;
        pub fn pancake_peer_poll_event_resolve(peer: *mut PancakePeer, out: *mut PancakeResolve) -> c_int;
        pub fn pancake_deliver_release(deliver: *mut PancakeDeliver);
        pub fn pancake_resolve_release(resolve: *mut PancakeResolve);
        pub fn pancake_peer_register_bootstrap_cap(
            peer: *mut PancakePeer,
            swissnum: *const c_uchar,
            swissnum_len: usize,
            out_export_position: *mut u64,
        ) -> c_int;
        pub fn pancake_peer_last_abort(peer: *mut PancakePeer, out: *mut PancakeLastAbort) -> c_int;
        pub fn pancake_peer_start_session(
            peer: *mut PancakePeer,
            transport: *const c_uchar,
            transport_len: usize,
            designator: *const c_uchar,
            designator_len: usize,
            hints: c_uint,
            seed: *const c_uchar,
            seed_len: usize,
        ) -> c_int;
        pub fn pancake_peer_session_is_open(peer: *mut PancakePeer) -> c_int;
        pub fn pancake_peer_codec(peer: *const PancakePeer, out_codec: *mut c_uint) -> c_int;
        pub fn pancake_peer_send_bootstrap_fetch(
            peer: *mut PancakePeer,
            name: *const c_uchar,
            name_len: usize,
            out_answer: *mut u64,
        ) -> c_int;
        pub fn pancake_peer_send_gc_export(
            peer: *mut PancakePeer,
            positions: *const u64,
            deltas: *const u64,
            len: usize,
        ) -> c_int;
        pub fn pancake_peer_send_gc_answer(peer: *mut PancakePeer, answer: u64) -> c_int;

        pub fn pancake_tcp_netlayer_new(out: *mut *mut PancakeTcpNetlayer) -> c_int;
        pub fn pancake_tcp_netlayer_new_in(
            context: *mut PancakeContext,
            out: *mut *mut PancakeTcpNetlayer,
        ) -> c_int;
        pub fn pancake_tcp_netlayer_release(netlayer: *mut PancakeTcpNetlayer);
        pub fn pancake_tcp_connect(
            netlayer: *mut PancakeTcpNetlayer,
            host: *const c_uchar,
            host_len: usize,
            port: u16,
            codec: c_uint,
            max_frame_bytes: usize,
            out: *mut *mut PancakeTcpConn,
        ) -> c_int;
        pub fn pancake_tcp_listen(
            netlayer: *mut PancakeTcpNetlayer,
            host: *const c_uchar,
            host_len: usize,
            port: u16,
            out: *mut *mut PancakeTcpListener,
        ) -> c_int;
        pub fn pancake_tcp_listener_port(listener: *mut PancakeTcpListener, out_port: *mut u16) -> c_int;
        pub fn pancake_tcp_accept(
            listener: *mut PancakeTcpListener,
            codec: c_uint,
            max_frame_bytes: usize,
            out: *mut *mut PancakeTcpConn,
        ) -> c_int;
        pub fn pancake_tcp_conn_read_frame(conn: *mut PancakeTcpConn, out: *mut PancakeManagedFrame) -> c_int;
        pub fn pancake_tcp_conn_write_frame(conn: *mut PancakeTcpConn, frame: *const PancakeFrame) -> c_int;
        pub fn pancake_tcp_conn_release(conn: *mut PancakeTcpConn);
        pub fn pancake_tcp_listener_release(listener: *mut PancakeTcpListener);

        // OCapN locator URIs — core libpancake vocabulary, so a TCP-only consumer
        // reaches them without the iroh superset. One grammar, no hand-rolled
        // percent codec.
        pub fn pancake_uri_parse_peer(
            uri: *const c_uchar,
            uri_len: usize,
            out_locator: *mut *mut PancakeLocator,
        ) -> c_int;
        pub fn pancake_uri_parse_sturdyref(
            uri: *const c_uchar,
            uri_len: usize,
            out_locator: *mut *mut PancakeLocator,
        ) -> c_int;
        pub fn pancake_uri_format_peer(
            transport: *const c_uchar,
            transport_len: usize,
            designator: *const c_uchar,
            designator_len: usize,
            hint_keys: *const *const c_uchar,
            hint_key_lens: *const usize,
            hint_vals: *const *const c_uchar,
            hint_val_lens: *const usize,
            hint_count: usize,
            out: *mut c_uchar,
            cap: usize,
            out_len: *mut usize,
        ) -> c_int;
        pub fn pancake_uri_format_sturdyref(
            transport: *const c_uchar,
            transport_len: usize,
            designator: *const c_uchar,
            designator_len: usize,
            swissnum: *const c_uchar,
            swissnum_len: usize,
            hint_keys: *const *const c_uchar,
            hint_key_lens: *const usize,
            hint_vals: *const *const c_uchar,
            hint_val_lens: *const usize,
            hint_count: usize,
            out: *mut c_uchar,
            cap: usize,
            out_len: *mut usize,
        ) -> c_int;
        pub fn pancake_locator_transport(
            loc: *mut PancakeLocator,
            out_ptr: *mut *const c_uchar,
            out_len: *mut usize,
        ) -> c_int;
        pub fn pancake_locator_designator(
            loc: *mut PancakeLocator,
            out_ptr: *mut *const c_uchar,
            out_len: *mut usize,
        ) -> c_int;
        pub fn pancake_locator_swissnum(
            loc: *mut PancakeLocator,
            out_ptr: *mut *const c_uchar,
            out_len: *mut usize,
        ) -> c_int;
        pub fn pancake_locator_hint(
            loc: *mut PancakeLocator,
            key: *const c_uchar,
            key_len: usize,
            out_ptr: *mut *const c_uchar,
            out_len: *mut usize,
        ) -> c_int;
        pub fn pancake_locator_hint_count(loc: *mut PancakeLocator, out_count: *mut usize) -> c_int;
        pub fn pancake_locator_hint_at(
            loc: *mut PancakeLocator,
            idx: usize,
            out_key: *mut *const c_uchar,
            out_key_len: *mut usize,
            out_val: *mut *const c_uchar,
            out_val_len: *mut usize,
        ) -> c_int;
        pub fn pancake_locator_release(loc: *mut PancakeLocator);
    }

}

/// Which layer of the peer refused a frame: the codec (parsing), the session
/// (authority and table validity), or a foreign failure surfaced through
/// dispatch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AbortDomain {
    Codec,
    Session,
    Foreign,
}

/// The typed cause of a peer's most recent local dispatch failure — the safe
/// projection of `pancake_peer_last_abort`. The flat `PANCAKE_ERR_*` code names
/// the failure family; this names the member: which layer refused, the
/// projected `op:abort` kind when one applies, and the diagnostic strings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AbortInfo {
    /// Which layer refused the frame.
    pub domain: AbortDomain,
    /// The wire name of the projected `op:abort` kind, when one was projected.
    pub kind: Option<String>,
    /// The static diagnostic message.
    pub message: String,
    /// The originating error name.
    pub error_name: String,
}

/// A failed pancake call. It always carries the negative `PANCAKE_ERR_*` code;
/// when a `send` was broken by the partner it also carries the break reason, so
/// the reason a partner gave for refusing a call is not lost behind a code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    code: i32,
    detail: Option<String>,
    abort: Option<AbortInfo>,
}

impl Error {
    /// The negative `PANCAKE_ERR_*` code for this failure.
    pub fn code(&self) -> i32 {
        self.code
    }

    /// The diagnostic message for this failure. For a broken `send` it is the
    /// partner's break reason; otherwise it is the calling thread's C ABI message
    /// captured at the moment the failure was raised, so a later fallible call on
    /// the same thread cannot overwrite it. `None` when neither was set.
    pub fn message(&self) -> Option<String> {
        self.detail.clone()
    }

    /// The typed abort cause the peer recorded when this failure refused an
    /// inbound frame ([`Peer::feed`], [`Peer::feed_owned`],
    /// [`Peer::recv_stream`]); `None` for other failures. The flat
    /// [`code`](Error::code) names the failure family; this names the member.
    pub fn abort(&self) -> Option<&AbortInfo> {
        self.abort.as_ref()
    }

    fn from_code(code: i32) -> Error {
        // Snapshot the thread-local message now, while it still belongs to the
        // call that just failed — matching the Python/Deno/Racket bindings.
        Error { code, detail: last_error(), abort: None }
    }

    /// A binding-side failure with an explicit message — for a refusal the C ABI
    /// never saw (e.g. an `ocapn://` URI naming a transport this build cannot dial).
    #[cfg(feature = "async")]
    fn with_detail(code: i32, detail: String) -> Error {
        Error { code, detail: Some(detail), abort: None }
    }

    /// A broken promise carrying the partner's reason: a `send`/`fetch` the
    /// remote side refused, distinct from a fault in this peer or the transport.
    /// Carries `PANCAKE_ERR_BROKEN` so a caller can tell a refusal apart from a
    /// real failure by `code()`, with the reason on `detail`.
    fn broken(message: String) -> Error {
        Error { code: sys::ERR_BROKEN, detail: Some(message), abort: None }
    }

    fn with_abort(mut self, abort: Option<AbortInfo>) -> Error {
        self.abort = abort;
        self
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.message() {
            Some(msg) => write!(f, "pancake error {}: {msg}", self.code),
            None => write!(f, "pancake error {}", self.code),
        }
    }
}
impl std::error::Error for Error {}

type Result<T> = core::result::Result<T, Error>;

fn check(code: i32) -> Result<()> {
    if code == sys::OK {
        Ok(())
    } else {
        Err(Error::from_code(code))
    }
}

/// The linked `libpancake`'s ABI version as `(major, minor, patch)`. Compare it
/// against the header constants the binding was built against to detect skew.
pub fn abi_version() -> (u32, u32, u32) {
    let (mut major, mut minor, mut patch) = (0u32, 0u32, 0u32);
    unsafe { sys::pancake_abi_version(&mut major, &mut minor, &mut patch) };
    (major, minor, patch)
}

/// The calling thread's last recorded error message, or `None` if none is set.
pub fn last_error() -> Option<String> {
    let len = unsafe { sys::pancake_last_error(core::ptr::null_mut(), 0) };
    if len == 0 {
        return None;
    }
    // The C side reserves one byte for a NUL terminator and copies at most
    // `cap - 1` message bytes, so pass `len + 1` to receive all `len` of them.
    let mut buf = vec![0u8; len + 1];
    let written = unsafe { sys::pancake_last_error(buf.as_mut_ptr(), buf.len()) };
    buf.truncate(written.min(buf.len()));
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// Clear the calling thread's last error message.
pub fn clear_last_error() {
    unsafe { sys::pancake_clear_last_error() };
}

/// A host-supplied allocation backend for a [`Context`]. Every method must be
/// thread-safe; the library may call them from any thread that touches a handle
/// created in the context.
pub trait HostAllocator: Send + Sync {
    /// Return a block of at least `size` bytes aligned to `alignment`, or null on
    /// failure.
    fn alloc(&self, size: usize, alignment: usize) -> *mut u8;
    /// Release a block previously returned by [`alloc`](HostAllocator::alloc).
    ///
    /// # Safety
    /// `ptr` must have come from this allocator with the same `size`/`alignment`.
    unsafe fn free(&self, ptr: *mut u8, size: usize, alignment: usize);
}

unsafe extern "C" fn alloc_trampoline(
    user_data: *mut core::ffi::c_void,
    size: usize,
    alignment: usize,
) -> *mut core::ffi::c_void {
    let allocator = &*(user_data as *const Box<dyn HostAllocator>);
    allocator.alloc(size, alignment) as *mut core::ffi::c_void
}

unsafe extern "C" fn free_trampoline(
    user_data: *mut core::ffi::c_void,
    ptr: *mut core::ffi::c_void,
    size: usize,
    alignment: usize,
) {
    let allocator = &*(user_data as *const Box<dyn HostAllocator>);
    allocator.free(ptr as *mut u8, size, alignment);
}

/// An allocation scope. Peers and netlayers created [in](Peer::new_in) a context
/// route every allocation through it. Release order matters: drop the context
/// only after every handle created in it. Released on drop.
pub struct Context {
    raw: *mut sys::PancakeContext,
    // Kept alive (and freed after `pancake_context_release`) for the custom
    // allocator path; null for the default-allocator context.
    allocator: *mut Box<dyn HostAllocator>,
}

impl Context {
    /// A context backed by the library-owned allocator.
    pub fn new() -> Result<Context> {
        let mut raw: *mut sys::PancakeContext = core::ptr::null_mut();
        check(unsafe { sys::pancake_context_new(&mut raw) })?;
        Ok(Context { raw, allocator: core::ptr::null_mut() })
    }

    /// A context that routes every allocation through `allocator`.
    pub fn with_allocator(allocator: Box<dyn HostAllocator>) -> Result<Context> {
        let user_data = Box::into_raw(Box::new(allocator));
        let c_allocator = sys::PancakeAllocator {
            alloc: alloc_trampoline,
            free: free_trampoline,
            user_data: user_data as *mut core::ffi::c_void,
        };
        let mut raw: *mut sys::PancakeContext = core::ptr::null_mut();
        let rc = unsafe { sys::pancake_context_new_with_allocator(&c_allocator, &mut raw) };
        if rc != sys::OK {
            unsafe { drop(Box::from_raw(user_data)) };
            return Err(Error::from_code(rc));
        }
        Ok(Context { raw, allocator: user_data })
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        // Release the context first — it frees its tables through the allocator —
        // then drop the host allocator the trampolines borrowed.
        unsafe { sys::pancake_context_release(self.raw) };
        if !self.allocator.is_null() {
            unsafe { drop(Box::from_raw(self.allocator)) };
        }
    }
}

/// A capability reference.
#[derive(Debug, Clone, PartialEq)]
pub enum Reference {
    /// A local export this peer hosts.
    Near { id: u64, promise: bool },
    /// A partner-hosted import this peer holds.
    Far { id: u64, promise: bool },
    /// A pipeline promise on an answer.
    Promise { answer: u64 },
    Sturdy,
    Broken,
}

impl Reference {
    /// The common case: call a partner object you hold as import `id`.
    pub fn far(id: u64) -> Reference {
        Reference::Far { id, promise: false }
    }

    fn to_sys(&self) -> Result<sys::PancakeReference> {
        let (kind, sub, id) = match *self {
            Reference::Near { id, promise } => (sys::REF_NEAR, sub(promise), id),
            Reference::Far { id, promise } => (sys::REF_FAR, sub(promise), id),
            Reference::Promise { answer } => (sys::REF_PROMISE, 0, answer),
            Reference::Sturdy | Reference::Broken => {
                return Err(Error::from_code(sys::ERR_UNSUPPORTED_VALUE))
            }
        };
        Ok(sys::PancakeReference { kind, sub_kind: sub, id })
    }

    fn from_sys(r: &sys::PancakeReference) -> Reference {
        let promise = r.sub_kind == sys::REF_SUB_PROMISE;
        match r.kind {
            sys::REF_NEAR => Reference::Near { id: r.id, promise },
            sys::REF_FAR => Reference::Far { id: r.id, promise },
            sys::REF_PROMISE => Reference::Promise { answer: r.id },
            sys::REF_STURDY => Reference::Sturdy,
            _ => Reference::Broken,
        }
    }
}

fn sub(promise: bool) -> u32 {
    if promise {
        sys::REF_SUB_PROMISE
    } else {
        sys::REF_SUB_OBJECT
    }
}

/// A passable argument value.
#[derive(Debug, Clone, PartialEq)]
pub enum Argument {
    Integer(i64),
    Float(f64),
    Boolean(bool),
    Bytes(Vec<u8>),
    String(String),
    Symbol(String),
    Void,
    Reference(Reference),
    List(Vec<Argument>),
    Set(Vec<Argument>),
    Tagged { tag: String, value: Vec<Argument> },
    Keyword(String),
    /// An arbitrary-precision OCapN Integer outside `i64` (ADR-0049): the sign
    /// plus the canonical decimal magnitude (ASCII digits, no leading zero).
    /// Parse `digits` into your own bignum type; pancake transports and
    /// compares the value, it does not compute with it.
    BigInteger { negative: bool, digits: String },
}

/// How a promise settled.
#[derive(Debug, Clone, PartialEq)]
pub enum Resolution {
    Fulfill(Argument),
    Break(String),
}

/// An application event surfaced by [`Peer::poll`].
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Deliver {
        target: Reference,
        args: Vec<Argument>,
        answer: Option<u64>,
    },
    Resolve {
        answer: u64,
        resolution: Resolution,
    },
    /// Any other surfaced event (abort, gc, handoff, …), with its raw frame.
    Other {
        kind: u32,
        frame: Vec<u8>,
    },
}

/// Owns nested C argument arrays for the duration of one send call.
#[derive(Default)]
struct SendArena {
    boxes: Vec<Box<[sys::PancakeArgument]>>,
}

impl SendArena {
    fn build(&mut self, args: &[Argument]) -> Result<(*const sys::PancakeArgument, usize)> {
        let mut out = Vec::with_capacity(args.len());
        for a in args {
            out.push(self.one(a)?);
        }
        let boxed = out.into_boxed_slice();
        let ptr = boxed.as_ptr();
        let len = boxed.len();
        self.boxes.push(boxed);
        Ok((ptr, len))
    }

    fn one(&mut self, a: &Argument) -> Result<sys::PancakeArgument> {
        let mut c: sys::PancakeArgument = unsafe { core::mem::zeroed() };
        match a {
            Argument::Integer(v) => {
                c.kind = sys::ARG_INTEGER;
                c.integer = *v;
            }
            Argument::Float(v) => {
                c.kind = sys::ARG_FLOAT64;
                c.float64 = *v;
            }
            Argument::Boolean(v) => {
                c.kind = sys::ARG_BOOLEAN;
                c.boolean = u32::from(*v);
            }
            Argument::Bytes(b) => set_bytes(&mut c, sys::ARG_BYTES, b),
            Argument::String(s) => set_bytes(&mut c, sys::ARG_STRING, s.as_bytes()),
            Argument::Symbol(s) => set_bytes(&mut c, sys::ARG_SYMBOL, s.as_bytes()),
            Argument::Void => c.kind = sys::ARG_VOID,
            Argument::Reference(r) => {
                c.kind = sys::ARG_REFERENCE;
                c.reference = r.to_sys()?;
            }
            Argument::List(items) => {
                c.kind = sys::ARG_LIST;
                let (ptr, len) = self.build(items)?;
                c.items = ptr;
                c.items_len = len;
            }
            Argument::Set(items) => {
                c.kind = sys::ARG_SET;
                let (ptr, len) = self.build(items)?;
                c.items = ptr;
                c.items_len = len;
            }
            Argument::Tagged { tag, value } => {
                c.kind = sys::ARG_TAGGED;
                c.bytes = tag.as_ptr();
                c.bytes_len = tag.len();
                let (ptr, len) = self.build(value)?;
                c.items = ptr;
                c.items_len = len;
            }
            Argument::Keyword(s) => set_bytes(&mut c, sys::ARG_KEYWORD, s.as_bytes()),
            Argument::BigInteger { negative, digits } => {
                set_bytes(&mut c, sys::ARG_BIG_INTEGER, digits.as_bytes());
                c.boolean = u32::from(*negative);
            }
        }
        Ok(c)
    }
}

fn set_bytes(c: &mut sys::PancakeArgument, kind: u32, b: &[u8]) {
    c.kind = kind;
    c.bytes = b.as_ptr();
    c.bytes_len = b.len();
}

/// Project a received C argument tree into owned Rust values.
unsafe fn arg_from_sys(c: &sys::PancakeArgument) -> Argument {
    match c.kind {
        sys::ARG_INTEGER => Argument::Integer(c.integer),
        sys::ARG_FLOAT64 => Argument::Float(c.float64),
        sys::ARG_BOOLEAN => Argument::Boolean(c.boolean != 0),
        sys::ARG_BYTES => Argument::Bytes(bytes_from_sys(c)),
        sys::ARG_STRING => Argument::String(String::from_utf8_lossy(&bytes_from_sys(c)).into_owned()),
        sys::ARG_SYMBOL => Argument::Symbol(String::from_utf8_lossy(&bytes_from_sys(c)).into_owned()),
        sys::ARG_REFERENCE => Argument::Reference(Reference::from_sys(&c.reference)),
        sys::ARG_LIST => Argument::List(args_from_sys(c.items, c.items_len)),
        sys::ARG_SET => Argument::Set(args_from_sys(c.items, c.items_len)),
        sys::ARG_TAGGED => Argument::Tagged {
            tag: String::from_utf8_lossy(&bytes_from_sys(c)).into_owned(),
            value: args_from_sys(c.items, c.items_len),
        },
        sys::ARG_KEYWORD => Argument::Keyword(String::from_utf8_lossy(&bytes_from_sys(c)).into_owned()),
        sys::ARG_VOID => Argument::Void,
        sys::ARG_BIG_INTEGER => Argument::BigInteger {
            negative: c.boolean != 0,
            digits: String::from_utf8_lossy(&bytes_from_sys(c)).into_owned(),
        },
        // The C ABI kind set is closed (0..=12); any other value is the C ABI and
        // this binding drifting out of sync. Fail loud where a test would catch
        // it rather than silently decoding a future kind as Void.
        other => {
            debug_assert!(false, "unknown PancakeArgument kind {other} from the C ABI");
            Argument::Void
        }
    }
}

unsafe fn bytes_from_sys(c: &sys::PancakeArgument) -> Vec<u8> {
    if c.bytes.is_null() || c.bytes_len == 0 {
        Vec::new()
    } else {
        core::slice::from_raw_parts(c.bytes, c.bytes_len).to_vec()
    }
}

unsafe fn args_from_sys(ptr: *const sys::PancakeArgument, len: usize) -> Vec<Argument> {
    if ptr.is_null() {
        return Vec::new();
    }
    (0..len).map(|i| arg_from_sys(&*ptr.add(i))).collect()
}

/// Reclaim the `Vec<u8>` backing an owned frame once the library is done with
/// it (or when a failed `feed_owned` hands ownership back). Idempotent: a null
/// `bytes` means the descriptor was already reclaimed.
unsafe extern "C" fn release_owned_vec(frame: *mut sys::PancakeManagedFrame) {
    let frame = &mut *frame;
    if frame.bytes.is_null() {
        return;
    }
    let capacity = frame.private_data as usize;
    drop(Vec::from_raw_parts(frame.bytes, frame.len, capacity));
    frame.bytes = core::ptr::null_mut();
}

/// An OCapN/CapTP peer. Released on drop.
///
/// The `'ctx` lifetime ties a context-backed peer to the [`Context`] it was
/// created in, so the borrow checker rejects dropping the context while the peer
/// is still live. A peer on the library-owned allocator is `Peer<'static>`.
///
/// A context-backed peer cannot outlive its context:
///
/// ```compile_fail
/// use pancake_rust_dogfood::{Context, Peer};
/// let _peer = {
///     let ctx = Context::new().unwrap();
///     Peer::new_in(&ctx).unwrap()
/// }; // ctx is dropped here, so the borrow checker rejects keeping the peer.
/// ```
pub struct Peer<'ctx> {
    raw: *mut sys::PancakePeer,
    _ctx: PhantomData<&'ctx Context>,
}

/// Authenticated OCapN profile to negotiate for a peer.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Profile {
    V1_0,
    PreSpec,
}

impl Profile {
    fn id(self) -> u32 {
        match self {
            Profile::V1_0 => sys::CAPTP_VERSION_V1_0,
            Profile::PreSpec => sys::CAPTP_VERSION_PRE_SPEC,
        }
    }
}

/// The wire codec a peer's session speaks and a TCP endpoint frames with. A
/// session and the endpoint that carries it must use the same value.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Codec {
    Syrup,
    Capnp,
}

impl Codec {
    fn to_c(self) -> u32 {
        match self {
            Codec::Syrup => sys::CODEC_SYRUP,
            Codec::Capnp => sys::CODEC_CAPNP,
        }
    }
}

impl<'ctx> Peer<'ctx> {
    /// Create an authenticated v1.0 peer in the negotiating state using the
    /// library-owned allocator.
    pub fn new() -> Result<Peer<'ctx>> {
        let mut raw: *mut sys::PancakePeer = core::ptr::null_mut();
        check(unsafe { sys::pancake_peer_new(&mut raw) })?;
        Ok(Peer { raw, _ctx: PhantomData })
    }

    /// Create a negotiating peer whose allocations route through `context`. The
    /// context must outlive the peer.
    pub fn new_in(context: &'ctx Context) -> Result<Peer<'ctx>> {
        let mut raw: *mut sys::PancakePeer = core::ptr::null_mut();
        check(unsafe { sys::pancake_peer_new_in(context.raw, &mut raw) })?;
        Ok(Peer { raw, _ctx: PhantomData })
    }

    /// Create a negotiating peer carrying an out-of-band negotiated profile
    /// and codec. Both ends of a connection must construct with the same
    /// pair, and the codec must match the one the connection's endpoint
    /// frames with.
    pub fn negotiated(profile: Profile, codec: Codec) -> Result<Peer<'ctx>> {
        let mut raw: *mut sys::PancakePeer = core::ptr::null_mut();
        check(unsafe { sys::pancake_peer_new_negotiated(profile.id(), codec.to_c(), &mut raw) })?;
        Ok(Peer { raw, _ctx: PhantomData })
    }

    /// Context-backed counterpart of [`Peer::negotiated`].
    pub fn negotiated_in(context: &'ctx Context, profile: Profile, codec: Codec) -> Result<Peer<'ctx>> {
        let mut raw: *mut sys::PancakePeer = core::ptr::null_mut();
        check(unsafe { sys::pancake_peer_new_negotiated_in(context.raw, profile.id(), codec.to_c(), &mut raw) })?;
        Ok(Peer { raw, _ctx: PhantomData })
    }

    /// Create an already-open peer for tests and low-level direct-frame fixtures.
    pub fn new_raw_open() -> Result<Peer<'ctx>> {
        let mut raw: *mut sys::PancakePeer = core::ptr::null_mut();
        check(unsafe { sys::pancake_peer_new_raw_open(&mut raw) })?;
        Ok(Peer { raw, _ctx: PhantomData })
    }

    /// Context-backed counterpart of [`Peer::new_raw_open`].
    pub fn new_raw_open_in(context: &'ctx Context) -> Result<Peer<'ctx>> {
        let mut raw: *mut sys::PancakePeer = core::ptr::null_mut();
        check(unsafe { sys::pancake_peer_new_raw_open_in(context.raw, &mut raw) })?;
        Ok(Peer { raw, _ctx: PhantomData })
    }

    /// Sign and queue `op:start-session` from this negotiating peer. The
    /// handshake speaks the profile the peer was constructed with
    /// ([`Peer::new`] is v1.0, [`Peer::negotiated`] chooses). The 32-byte
    /// `seed` is the session key; `transport`/`designator` form the locator
    /// the partner verifies, so they must be what it expects — for a Goblins
    /// partner, `"tcp"` with `hints_empty_false` true (Goblins emits the empty
    /// hints as the boolean `#f`). Flush it, then pump until
    /// [`session_is_open`](Peer::session_is_open).
    pub fn start_session(
        &mut self,
        seed: &[u8; 32],
        transport: &str,
        designator: &str,
        hints_empty_false: bool,
    ) -> Result<()> {
        check(unsafe {
            sys::pancake_peer_start_session(
                self.raw,
                transport.as_ptr(),
                transport.len(),
                designator.as_ptr(),
                designator.len(),
                if hints_empty_false { sys::HINTS_EMPTY_FALSE } else { sys::HINTS_EMPTY_MAP },
                seed.as_ptr(),
                seed.len(),
            )
        })
    }

    /// Whether the authenticated handshake has completed and the session is open for
    /// traffic. Pump the connection and poll this before sending application
    /// messages.
    pub fn session_is_open(&self) -> bool {
        unsafe { sys::pancake_peer_session_is_open(self.raw) == 1 }
    }

    /// Publish a local export so inbound deliveries to it surface as events.
    pub fn register_export(&mut self, id: u64) -> Result<()> {
        check(unsafe { sys::pancake_peer_register_export(self.raw, id) })
    }

    /// Allocate and register the next free export position from the session's
    /// one export allocator — the counter that also mints bootstrap and
    /// resolver exports, so a spawned position can never alias one.
    pub fn next_export(&mut self) -> Result<u64> {
        let mut id: u64 = 0;
        check(unsafe { sys::pancake_peer_next_export(self.raw, &mut id) })?;
        Ok(id)
    }

    /// Track a partner-hosted import this peer holds, so a deliver to it is admitted.
    pub fn register_import(&mut self, id: u64) -> Result<()> {
        check(unsafe { sys::pancake_peer_register_import(self.raw, id) })
    }

    /// Allocate the next outbound answer position from the session's one answer
    /// allocator — the counter that backs every outbound question, so a
    /// privately-counted answer can never alias a live one.
    pub fn next_answer(&mut self) -> Result<u64> {
        let mut answer: u64 = 0;
        check(unsafe { sys::pancake_peer_next_answer(self.raw, &mut answer) })?;
        Ok(answer)
    }

    /// The codec the peer's session speaks (a `PANCAKE_CODEC_*` value), so an
    /// opaque [`Event::Other`] frame drained after a typed-poll refusal can be
    /// interpreted.
    pub fn codec(&self) -> Result<u32> {
        let mut codec: u32 = 0;
        check(unsafe { sys::pancake_peer_codec(self.raw, &mut codec) })?;
        Ok(codec)
    }

    /// Queue the canonical bootstrap `fetch` for the capability published
    /// behind `name`, returning the answer position the partner's resolution
    /// arrives on (as an [`Event::Resolve`]). Registers the bootstrap import
    /// and allocates the answer from the session's own counters.
    pub fn send_bootstrap_fetch(&mut self, name: &[u8]) -> Result<u64> {
        let mut answer: u64 = 0;
        check(unsafe {
            sys::pancake_peer_send_bootstrap_fetch(self.raw, name.as_ptr(), name.len(), &mut answer)
        })?;
        Ok(answer)
    }

    /// Queue an `op:gc-export` releasing wire-delta counts on imports this peer
    /// holds: `positions[i]` is released by `deltas[i]`. The slices are
    /// parallel and must be non-empty and the same length.
    pub fn send_gc_export(&mut self, positions: &[u64], deltas: &[u64]) -> Result<()> {
        if positions.len() != deltas.len() {
            return Err(Error::from_code(sys::ERR_INVALID_ARGUMENT));
        }
        check(unsafe {
            sys::pancake_peer_send_gc_export(self.raw, positions.as_ptr(), deltas.as_ptr(), positions.len())
        })
    }

    /// Queue an `op:gc-answer` releasing an answer this peer no longer needs.
    pub fn send_gc_answer(&mut self, answer: u64) -> Result<()> {
        check(unsafe { sys::pancake_peer_send_gc_answer(self.raw, answer) })
    }

    /// Dispatch one inbound frame, borrowed for the call. A refusal carries the
    /// typed abort cause on [`Error::abort`].
    pub fn feed(&mut self, frame: &[u8]) -> Result<()> {
        let f = sys::PancakeFrame {
            bytes: frame.as_ptr(),
            len: frame.len(),
            shape: sys::FRAME_SHAPE_BYTE,
        };
        let rc = unsafe { sys::pancake_peer_feed_borrowed(self.raw, &f) };
        if rc == sys::OK {
            Ok(())
        } else {
            Err(Error::from_code(rc).with_abort(self.last_abort()))
        }
    }

    /// Frame and dispatch one inbound frame from a byte-stream buffer. `bytes` is
    /// whatever has accumulated from the wire so far; returns `Some(n)` when a
    /// whole frame was consumed and dispatched (drop the first `n` bytes, then
    /// call again to drain more), or `None` when `bytes` holds only part of a
    /// frame (read more and retry). This is the sans-io stream-input primitive —
    /// the caller owns the socket; the peer never blocks. A reply or abort lands
    /// on the outbound queue; drain it with [`take_outbound`](Peer::take_outbound),
    /// and read events with [`poll`](Peer::poll). A refused frame carries the
    /// typed abort cause on [`Error::abort`].
    pub fn recv_stream(&mut self, bytes: &[u8]) -> Result<Option<usize>> {
        let mut consumed: usize = 0;
        let rc = unsafe { sys::pancake_peer_recv_stream(self.raw, bytes.as_ptr(), bytes.len(), &mut consumed) };
        match rc {
            sys::OK => Ok(Some(consumed)),
            sys::WOULD_BLOCK => Ok(None),
            _ => Err(Error::from_code(rc).with_abort(self.last_abort())),
        }
    }

    /// Transfer owned `frame` bytes into the inbound queue for the next
    /// [`step`](Peer::step) — no borrow to keep alive, no copy by the library.
    pub fn feed_owned(&mut self, frame: Vec<u8>) -> Result<()> {
        let mut frame = frame;
        let mut managed = sys::PancakeManagedFrame {
            bytes: frame.as_mut_ptr(),
            len: frame.len(),
            shape: sys::FRAME_SHAPE_BYTE,
            release: Some(release_owned_vec),
            // Carry the capacity so the release callback can rebuild the Vec.
            private_data: frame.capacity() as *mut core::ffi::c_void,
        };
        core::mem::forget(frame); // ownership now lives in `managed`
        let rc = unsafe { sys::pancake_peer_feed_owned(self.raw, &mut managed) };
        if rc != sys::OK {
            // The descriptor was not adopted; reclaim the bytes ourselves.
            unsafe { release_owned_vec(&mut managed) };
            return Err(Error::from_code(rc).with_abort(self.last_abort()));
        }
        Ok(())
    }

    /// Advance the peer (apply queued inbound, encode pending outbound).
    pub fn step(&mut self) -> Result<()> {
        check(unsafe { sys::pancake_peer_step(self.raw) })
    }

    /// Construct and queue a call to `target`. `answer` requests a reply.
    pub fn send_deliver(&mut self, target: &Reference, args: &[Argument], answer: Option<u64>) -> Result<()> {
        let t = target.to_sys()?;
        let mut arena = SendArena::default();
        let (args_ptr, args_len) = arena.build(args)?;
        check(unsafe {
            sys::pancake_peer_send_deliver(
                self.raw,
                &t,
                args_ptr,
                args_len,
                u32::from(answer.is_some()),
                answer.unwrap_or(0),
            )
        })
    }

    /// Construct and queue a reply settling `answer`.
    pub fn send_resolve(&mut self, answer: u64, resolution: &Resolution) -> Result<()> {
        match resolution {
            Resolution::Fulfill(value) => {
                let mut arena = SendArena::default();
                let v = arena.one(value)?;
                check(unsafe {
                    sys::pancake_peer_send_resolve(self.raw, answer, sys::RESOLUTION_FULFILL, &v, core::ptr::null(), 0)
                })
            }
            Resolution::Break(msg) => check(unsafe {
                sys::pancake_peer_send_resolve(
                    self.raw,
                    answer,
                    sys::RESOLUTION_BREAK,
                    core::ptr::null(),
                    msg.as_ptr(),
                    msg.len(),
                )
            }),
        }
    }

    /// Take the next outbound frame as owned bytes, or `Ok(None)` when the queue
    /// is empty. Any other failure (e.g. an OOM after the frame was already
    /// dequeued and freed) surfaces as `Err` — swallowing it would silently drop
    /// an outbound frame and end the drain as if the queue were empty.
    pub fn take_outbound(&mut self) -> Result<Option<Vec<u8>>> {
        let mut frame: sys::PancakeManagedFrame = unsafe { core::mem::zeroed() };
        let rc = unsafe { sys::pancake_peer_take_outbound(self.raw, &mut frame) };
        if rc == sys::WOULD_BLOCK {
            return Ok(None);
        }
        check(rc)?;
        let out = unsafe { core::slice::from_raw_parts(frame.bytes, frame.len) }.to_vec();
        unsafe { sys::pancake_managed_frame_release(&mut frame) };
        Ok(Some(out))
    }

    /// Take the next application event as a typed [`Event`], or `Ok(None)` when
    /// idle. A typed-poll failure (re-decode or allocation failure between the
    /// peek and the poll) surfaces as `Err`, never as a fabricated event.
    pub fn poll(&mut self) -> Result<Option<Event>> {
        match unsafe { sys::pancake_peer_peek_event(self.raw) } {
            sys::EVENT_DELIVER => Ok(Some(self.poll_deliver()?)),
            sys::EVENT_RESOLVE => Ok(Some(self.poll_resolve()?)),
            sys::WOULD_BLOCK => Ok(None),
            kind if kind < 0 => Err(Error::from_code(kind)),
            _ => Ok(Some(self.poll_other()?)),
        }
    }

    fn poll_deliver(&mut self) -> Result<Event> {
        let mut d: sys::PancakeDeliver = unsafe { core::mem::zeroed() };
        let rc = unsafe { sys::pancake_peer_poll_event_deliver(self.raw, &mut d) };
        if rc == sys::ERR_UNSUPPORTED_VALUE {
            // The typed projection cannot carry this deliver (e.g. a handoff
            // argument). The event stays queued, so drain it as an opaque
            // `Event::Other` — failing here would peek the same event forever.
            return self.poll_other();
        }
        check(rc)?;
        let event = Event::Deliver {
            target: Reference::from_sys(&d.target),
            args: unsafe { args_from_sys(d.args, d.args_len) },
            answer: if d.has_answer != 0 { Some(d.answer) } else { None },
        };
        unsafe { sys::pancake_deliver_release(&mut d) };
        Ok(event)
    }

    fn poll_resolve(&mut self) -> Result<Event> {
        let mut r: sys::PancakeResolve = unsafe { core::mem::zeroed() };
        let rc = unsafe { sys::pancake_peer_poll_event_resolve(self.raw, &mut r) };
        if rc == sys::ERR_UNSUPPORTED_VALUE {
            // Same leave-queued contract as poll_deliver: drain the refused
            // resolve as an opaque event so the loop survives.
            return self.poll_other();
        }
        check(rc)?;
        let resolution = if r.resolution_kind == sys::RESOLUTION_FULFILL {
            Resolution::Fulfill(unsafe { arg_from_sys(&r.fulfill) })
        } else {
            let msg = if r.break_message.is_null() {
                String::new()
            } else {
                String::from_utf8_lossy(unsafe { core::slice::from_raw_parts(r.break_message, r.break_message_len) })
                    .into_owned()
            };
            Resolution::Break(msg)
        };
        let event = Event::Resolve { answer: r.answer, resolution };
        unsafe { sys::pancake_resolve_release(&mut r) };
        Ok(event)
    }

    fn poll_other(&mut self) -> Result<Event> {
        let mut e: sys::PancakeEvent = unsafe { core::mem::zeroed() };
        check(unsafe { sys::pancake_peer_poll_event(self.raw, &mut e) })?;
        let frame = if e.frame.bytes.is_null() {
            Vec::new()
        } else {
            unsafe { core::slice::from_raw_parts(e.frame.bytes, e.frame.len) }.to_vec()
        };
        let kind = e.kind;
        unsafe { sys::pancake_event_release(&mut e) };
        Ok(Event::Other { kind, frame })
    }

    /// The typed cause of this peer's most recent local dispatch failure, or
    /// `None` when none has been recorded. The frame-feeding calls
    /// ([`feed`](Peer::feed), [`feed_owned`](Peer::feed_owned),
    /// [`recv_stream`](Peer::recv_stream)) already attach this to the `Err`
    /// they return; read it there via [`Error::abort`].
    pub fn last_abort(&self) -> Option<AbortInfo> {
        let mut raw: sys::PancakeLastAbort = unsafe { core::mem::zeroed() };
        if unsafe { sys::pancake_peer_last_abort(self.raw, &mut raw) } != sys::OK {
            return None;
        }
        // The C views are process-static; copy them into owned strings so the
        // info outlives any later peer call.
        let text = |ptr: *const u8, len: usize| -> String {
            if ptr.is_null() || len == 0 {
                String::new()
            } else {
                String::from_utf8_lossy(unsafe { core::slice::from_raw_parts(ptr, len) }).into_owned()
            }
        };
        Some(AbortInfo {
            domain: match raw.domain {
                sys::ABORT_DOMAIN_CODEC => AbortDomain::Codec,
                sys::ABORT_DOMAIN_SESSION => AbortDomain::Session,
                _ => AbortDomain::Foreign,
            },
            kind: (raw.has_kind != 0).then(|| text(raw.kind_name, raw.kind_name_len)),
            message: text(raw.message, raw.message_len),
            error_name: text(raw.error_name, raw.error_name_len),
        })
    }

    /// Publish a local capability behind `swissnum` for inbound bootstrap-fetch;
    /// returns the allocated export id.
    pub fn register_bootstrap_cap(&mut self, swissnum: &[u8]) -> Result<u64> {
        let mut id: u64 = 0;
        check(unsafe {
            sys::pancake_peer_register_bootstrap_cap(self.raw, swissnum.as_ptr(), swissnum.len(), &mut id)
        })?;
        Ok(id)
    }
}

impl Drop for Peer<'_> {
    fn drop(&mut self) {
        unsafe { sys::pancake_peer_release(self.raw) };
    }
}

/// Owns the blocking-TCP I/O backend. Connections and listeners borrow it (via
/// `&self`), so the borrow checker rejects a [`Endpoint`] or [`Listener`] that
/// outlives the netlayer that produced it. The `'ctx` lifetime additionally ties
/// a context-backed netlayer to its [`Context`]; a netlayer on the library-owned
/// allocator is `Netlayer<'static>`.
///
/// A connection cannot outlive the netlayer that produced it:
///
/// ```compile_fail
/// use pancake_rust_dogfood::{Codec, Netlayer};
/// let _conn = {
///     let netlayer = Netlayer::new().unwrap();
///     netlayer.connect("127.0.0.1", 1, Codec::Syrup, 4096).unwrap()
/// }; // netlayer is dropped here, so the borrow checker rejects keeping the conn.
/// ```
pub struct Netlayer<'ctx> {
    raw: *mut sys::PancakeTcpNetlayer,
    _ctx: PhantomData<&'ctx Context>,
}

impl<'ctx> Netlayer<'ctx> {
    pub fn new() -> Result<Netlayer<'ctx>> {
        let mut raw: *mut sys::PancakeTcpNetlayer = core::ptr::null_mut();
        check(unsafe { sys::pancake_tcp_netlayer_new(&mut raw) })?;
        Ok(Netlayer { raw, _ctx: PhantomData })
    }

    /// Create a netlayer whose backend and per-connection buffers allocate through
    /// `context`. The context must outlive the netlayer, which `'ctx` enforces.
    pub fn new_in(context: &'ctx Context) -> Result<Netlayer<'ctx>> {
        let mut raw: *mut sys::PancakeTcpNetlayer = core::ptr::null_mut();
        check(unsafe { sys::pancake_tcp_netlayer_new_in(context.raw, &mut raw) })?;
        Ok(Netlayer { raw, _ctx: PhantomData })
    }

    /// Bind and listen on `host:port` (port 0 = OS-chosen). The returned listener
    /// borrows this netlayer and cannot outlive it.
    pub fn listen(&self, host: &str, port: u16) -> Result<Listener<'_>> {
        let mut raw: *mut sys::PancakeTcpListener = core::ptr::null_mut();
        check(unsafe {
            sys::pancake_tcp_listen(self.raw, host.as_ptr(), host.len(), port, &mut raw)
        })?;
        Ok(Listener { raw, _nl: PhantomData })
    }

    /// Connect to `host:port`, framing on `codec` with an inbound cap of
    /// `max_frame_bytes`. The returned connection borrows this netlayer and
    /// cannot outlive it.
    pub fn connect(&self, host: &str, port: u16, codec: Codec, max_frame_bytes: usize) -> Result<Endpoint<'_>> {
        let mut raw: *mut sys::PancakeTcpConn = core::ptr::null_mut();
        check(unsafe {
            sys::pancake_tcp_connect(
                self.raw,
                host.as_ptr(),
                host.len(),
                port,
                codec.to_c(),
                max_frame_bytes,
                &mut raw,
            )
        })?;
        Ok(Endpoint { raw, _nl: PhantomData })
    }
}

impl Drop for Netlayer<'_> {
    fn drop(&mut self) {
        unsafe { sys::pancake_tcp_netlayer_release(self.raw) };
    }
}

/// A bound listener. Released on drop. Borrows the [`Netlayer`] it came from, so
/// the netlayer outlives every accepted connection.
pub struct Listener<'a> {
    raw: *mut sys::PancakeTcpListener,
    _nl: PhantomData<&'a ()>,
}

impl Listener<'_> {
    /// The OS-resolved local port (useful after binding to port 0).
    pub fn port(&self) -> Result<u16> {
        let mut port: u16 = 0;
        check(unsafe { sys::pancake_tcp_listener_port(self.raw, &mut port) })?;
        Ok(port)
    }

    /// Block for a client connection. The returned connection borrows this
    /// listener (and thus the netlayer) and cannot outlive it.
    pub fn accept(&self, codec: Codec, max_frame_bytes: usize) -> Result<Endpoint<'_>> {
        let mut raw: *mut sys::PancakeTcpConn = core::ptr::null_mut();
        check(unsafe { sys::pancake_tcp_accept(self.raw, codec.to_c(), max_frame_bytes, &mut raw) })?;
        Ok(Endpoint { raw, _nl: PhantomData })
    }
}

// A listener handle is safe to move to the accepting thread (use a scoped
// thread, since it borrows the netlayer and so is not `'static`).
unsafe impl Send for Listener<'_> {}

impl Drop for Listener<'_> {
    fn drop(&mut self) {
        unsafe { sys::pancake_tcp_listener_release(self.raw) };
    }
}

/// A blocking TCP endpoint — the `pancake_tcp_*` frame shuttle, one
/// layer below [`Connection`](crate::Connection). Closed on drop. The frame
/// methods block. Borrows the [`Netlayer`] (or [`Listener`]) it came from, so
/// that backend outlives it.
pub struct Endpoint<'a> {
    raw: *mut sys::PancakeTcpConn,
    _nl: PhantomData<&'a ()>,
}

impl Endpoint<'_> {
    /// Block for one whole frame. An error with `code() == -8` is a clean EOF.
    pub fn read_frame(&mut self) -> Result<Vec<u8>> {
        let mut frame: sys::PancakeManagedFrame = unsafe { core::mem::zeroed() };
        check(unsafe { sys::pancake_tcp_conn_read_frame(self.raw, &mut frame) })?;
        let out = unsafe { core::slice::from_raw_parts(frame.bytes, frame.len) }.to_vec();
        unsafe { sys::pancake_managed_frame_release(&mut frame) };
        Ok(out)
    }

    /// Write one frame's bytes and flush.
    pub fn write_frame(&mut self, bytes: &[u8]) -> Result<()> {
        let f = sys::PancakeFrame {
            bytes: bytes.as_ptr(),
            len: bytes.len(),
            shape: sys::FRAME_SHAPE_BYTE,
        };
        check(unsafe { sys::pancake_tcp_conn_write_frame(self.raw, &f) })
    }
}

unsafe impl Send for Endpoint<'_> {}

impl Drop for Endpoint<'_> {
    fn drop(&mut self) {
        unsafe { sys::pancake_tcp_conn_release(self.raw) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Bounded inbox: a frame declaring more than max_frame_bytes is a typed
    // refusal, never "read more". A connection's inbox keeps growing only
    // while recv_stream returns Ok(None), so this is the contract that stops
    // a hostile partner from growing it without bound.
    #[test]
    fn recv_stream_refuses_an_over_cap_frame_typed() {
        let mut peer = Peer::new_raw_open().unwrap();
        peer.register_export(7).unwrap();
        let err = peer
            .recv_stream(b"<10'op:deliver<11'desc:export7+>[2000000:")
            .unwrap_err();
        assert_eq!(err.code(), sys::ERR_FRAME_TOO_LARGE);
    }

    // A refused frame is diagnosable beyond the flat family code: the typed
    // abort cause (domain, kind, message, error name) rides the error from
    // `feed`, mirrored from `pancake_peer_last_abort` — the same member the
    // Zig `Peer.lastAbort` names.
    #[test]
    fn a_refused_frame_carries_the_typed_abort_cause() {
        let mut peer = Peer::new_raw_open().unwrap();
        let err = peer.feed(b"this is not a syrup frame").unwrap_err();
        let abort = err.abort().expect("the typed abort cause");
        assert_eq!(abort.domain, AbortDomain::Codec);
        assert!(!abort.message.is_empty());
        assert!(!abort.error_name.is_empty());
        // The same cause is readable straight off the peer.
        assert_eq!(peer.last_abort().as_ref(), Some(abort));
    }

    #[test]
    fn drives_ocapn_with_the_idiomatic_api() {
        // Construct a call with typed args — no raw FFI in sight.
        let mut caller = Peer::new_raw_open().unwrap();
        caller.register_import(5).unwrap();
        caller
            .send_deliver(
                &Reference::far(5),
                &[Argument::Integer(42), Argument::Bytes(b"hi".to_vec())],
                Some(9),
            )
            .unwrap();
        caller.step().unwrap();
        let wire = caller.take_outbound().unwrap().expect("an outbound frame");
        assert!(wire.starts_with(b"<10'op:deliver"));

        // Inspect an inbound delivery as a typed Event.
        let mut callee = Peer::new_raw_open().unwrap();
        callee.register_export(7).unwrap();
        callee.feed(b"<10'op:deliver<11'desc:export7+>[5:hello]11+f>").unwrap();
        match callee.poll().unwrap().expect("a deliver event") {
            Event::Deliver { target, args, answer } => {
                assert_eq!(target, Reference::Near { id: 7, promise: false });
                assert_eq!(answer, Some(11));
                assert_eq!(args, vec![Argument::Bytes(b"hello".to_vec())]);
            }
            other => panic!("expected a deliver, got {other:?}"),
        }
    }

    #[test]
    fn carries_set_tagged_and_keyword_arguments() {
        let mut peer = Peer::new_raw_open().unwrap();
        peer.register_export(7).unwrap();
        peer.feed(b"<10'op:deliver<11'desc:export7+>[#1+2+$<11'user-record5'Point[3+4+]><2'kw5'color>]11+f>")
            .unwrap();
        match peer.poll().unwrap().expect("a deliver") {
            Event::Deliver { args, .. } => {
                assert_eq!(args.len(), 3);
                assert_eq!(args[0], Argument::Set(vec![Argument::Integer(1), Argument::Integer(2)]));
                assert_eq!(
                    args[1],
                    Argument::Tagged {
                        tag: "Point".into(),
                        value: vec![Argument::Integer(3), Argument::Integer(4)],
                    }
                );
                assert_eq!(args[2], Argument::Keyword("color".into()));
            }
            other => panic!("expected a deliver, got {other:?}"),
        }
    }

    #[test]
    fn surfaces_an_abort_as_a_typed_event() {
        let mut peer = Peer::new_raw_open().unwrap();
        peer.feed(b"<8'op:abort3\"bye>").unwrap();
        match peer.poll().unwrap().expect("an abort event") {
            Event::Other { kind, frame } => {
                assert_eq!(kind, 7); // PANCAKE_EVENT_ABORT
                assert_eq!(frame, b"<8'op:abort3\"bye>");
            }
            other => panic!("expected abort, got {other:?}"),
        }
        assert!(peer.poll().unwrap().is_none());
    }

    #[test]
    fn runs_a_peer_over_a_real_tcp_socket() {
        // The netlayer owns the I/O backend; the listener and connections borrow
        // it, so a scoped thread keeps those borrows honest (the borrowed
        // `Listener` is not `'static` and cannot enter `thread::spawn`).
        let netlayer = Netlayer::new().unwrap();
        let listener = netlayer.listen("127.0.0.1", 0).unwrap();
        let port = listener.port().unwrap();

        let received = std::thread::scope(|scope| {
            let server = scope.spawn(move || {
                let mut conn = listener.accept(Codec::Syrup, 4096).unwrap();
                conn.read_frame().unwrap()
            });

            let mut client = netlayer.connect("127.0.0.1", port, Codec::Syrup, 4096).unwrap();
            client.write_frame(b"<8'op:abort3\"bye>").unwrap();

            server.join().unwrap()
        });
        assert_eq!(received, b"<8'op:abort3\"bye>");
    }

    #[test]
    fn server_replies_to_a_received_call() {
        let mut peer = Peer::new_raw_open().unwrap();
        peer.register_export(7).unwrap();
        peer.feed(b"<10'op:deliver<11'desc:export7+>[5:hello]11+<19'desc:import-promise99+>>").unwrap();
        let answer = match peer.poll().unwrap().unwrap() {
            Event::Deliver { answer, .. } => answer.unwrap(),
            other => panic!("expected deliver, got {other:?}"),
        };
        peer.send_resolve(answer, &Resolution::Fulfill(Argument::Integer(7))).unwrap();
        peer.step().unwrap();
        let wire = peer.take_outbound().unwrap().expect("a resolver-callback frame");
        let text = core::str::from_utf8(&wire).unwrap();
        assert!(text.contains("op:deliver"));
        assert!(text.contains("fulfill"));
    }

    #[test]
    fn reports_a_nonzero_abi_version() {
        let (major, minor, patch) = abi_version();
        assert!(major + minor + patch > 0);
    }

    #[test]
    fn prespec_peer_queues_matching_start_session() {
        let mut peer = Peer::negotiated(Profile::PreSpec, Codec::Syrup).unwrap();
        let seed = [0x77; 32];
        // The peer signs with the profile it was constructed with.
        peer.start_session(&seed, "tcp", "127.0.0.1:77", true).unwrap();
        peer.step().unwrap();
        let wire = peer.take_outbound().unwrap().expect("a PreSpec start-session frame");
        assert!(wire.windows(b"op:start-session".len()).any(|window| window == b"op:start-session"));
    }

    #[test]
    fn hosts_an_actor_that_serves_a_delivered_call() {
        use crate::actors::Vat;

        let mut peer = Peer::new_raw_open().unwrap();
        let mut vat = Vat::over(&mut peer);

        // Publish a counter at export 7 — a Rust closure, not a foreign callback.
        let mut n: i64 = 10;
        vat.publish(7, move |verb, args| match verb {
            "add" => match args[0] {
                Argument::Integer(x) => {
                    n += x;
                    Ok(Argument::Integer(n))
                }
                _ => Err("add expects an integer".into()),
            },
            other => Err(format!("no such method: {other}")),
        })
        .unwrap();

        // A partner delivers counter.add(5) with answer 11 and a V1.0 resolver callback.
        vat.peer()
            .unwrap()
            .feed(b"<10'op:deliver<11'desc:export7+>[3'add5+]11+<19'desc:import-promise99+>>")
            .unwrap();
        let event = vat.peer().unwrap().poll().unwrap().expect("a deliver event");
        assert!(vat.serve(&event).unwrap());

        vat.peer().unwrap().step().unwrap();
        let wire = vat.peer().unwrap().take_outbound().unwrap().expect("a resolver-callback frame");
        let text = core::str::from_utf8(&wire).unwrap();
        assert!(text.contains("op:deliver"));
        assert!(text.contains("fulfill"));
        // The reply carries the new count, 15.
        assert!(text.contains("15+"));
    }

    #[test]
    fn near_call_local_send_and_drive() {
        use crate::actors::{Promise, Ref, Vat};
        use std::cell::Cell;
        use std::rc::Rc;

        let mut vat = Vat::new();
        let mut n: i64 = 0;
        let counter = vat.spawn(move |verb, args| match verb {
            "add" => match args[0] {
                Argument::Integer(x) => {
                    n += x;
                    Ok(Argument::Integer(n))
                }
                _ => Err("add expects an integer".into()),
            },
            other => Err(format!("no such method: {other}")),
        });

        // Near-call is synchronous and local-only.
        assert_eq!(vat.call(&counter, "add", &[Argument::Integer(3)]).unwrap(), Argument::Integer(3));

        // Near-calling a far ref is illegal.
        assert!(vat.call(&Ref::Far(Reference::far(5)), "add", &[]).is_err());

        // An eventual send queues a turn; drive settles its promise.
        let captured = Rc::new(Cell::new(0i64));
        let sink = captured.clone();
        let promise = vat.send(&counter, "add", &[Argument::Integer(4)]).unwrap();
        assert!(matches!(promise, Promise::Local(_)));
        vat.on(promise, move |resolution| {
            if let Resolution::Fulfill(Argument::Integer(v)) = resolution {
                sink.set(v);
            }
        });
        vat.drive();
        assert_eq!(captured.get(), 7); // 3 + 4
    }

    #[test]
    fn far_send_routes_over_the_wire_and_settles_the_promise() {
        use crate::actors::{Promise, Ref, Vat};
        use std::cell::Cell;
        use std::rc::Rc;

        // PeerB publishes a counter at export 7.
        let mut peer_b = Peer::new_raw_open().unwrap();
        let mut vat_b = Vat::over(&mut peer_b);
        let mut n: i64 = 10;
        vat_b
            .publish(7, move |verb, args| match verb {
                "add" => match args[0] {
                    Argument::Integer(x) => {
                        n += x;
                        Ok(Argument::Integer(n))
                    }
                    _ => Err("add expects an integer".into()),
                },
                other => Err(format!("no such method: {other}")),
            })
            .unwrap();

        // PeerA far-sends counter.add(5) and listens on the returned promise.
        let mut peer_a = Peer::new_raw_open().unwrap();
        peer_a.register_import(7).unwrap();
        let mut vat_a = Vat::over(&mut peer_a);
        let captured = Rc::new(Cell::new(0i64));
        let sink = captured.clone();
        let promise = vat_a
            .send(&Ref::Far(Reference::far(7)), "add", &[Argument::Integer(5)])
            .unwrap();
        assert!(matches!(promise, Promise::Far(_)));
        vat_a.on(promise, move |resolution| {
            if let Resolution::Fulfill(Argument::Integer(v)) = resolution {
                sink.set(v);
            }
        });

        // Shuttle A's outbound deliver to B.
        vat_a.peer().unwrap().step().unwrap();
        let to_b = vat_a.peer().unwrap().take_outbound().unwrap().expect("A's deliver frame");
        vat_b.peer().unwrap().feed(&to_b).unwrap();

        // B serves the deliver: runs the counter (10 + 5 = 15) and resolves.
        let deliver = vat_b.peer().unwrap().poll().unwrap().expect("a deliver event");
        assert!(vat_b.serve(&deliver).unwrap());

        // Shuttle B's outbound resolve back to A.
        vat_b.peer().unwrap().step().unwrap();
        let to_a = vat_b.peer().unwrap().take_outbound().unwrap().expect("B's resolve frame");
        vat_a.peer().unwrap().feed(&to_a).unwrap();

        // A serves the resolve: fires the far promise's listener.
        let resolve = vat_a.peer().unwrap().poll().unwrap().expect("a resolve event");
        assert!(vat_a.serve(&resolve).unwrap());

        assert_eq!(captured.get(), 15);
    }

    #[cfg(feature = "async")]
    #[tokio::test]
    async fn async_loopback_deliver_and_resolve() {
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        // Server: accept, drive a peer over the socket, reply to the first call.
        let server = async {
            let (stream, _) = listener.accept().await.unwrap();
            let mut peer = Peer::new_raw_open().unwrap();
            peer.register_export(7).unwrap();
            let mut conn = AsyncConnection::from_stream(peer, stream);
            match conn.next_event().await.unwrap().expect("a deliver") {
                Event::Deliver { target, answer, .. } => {
                    assert_eq!(target, Reference::Near { id: 7, promise: false });
                    conn.send_resolve(answer.unwrap(), &Resolution::Fulfill(Argument::Integer(7)))
                        .await
                        .unwrap();
                }
                other => panic!("server expected a deliver, got {other:?}"),
            }
        };

        // Client: connect, call far(7), await the resolution — all async.
        let client = async {
            let stream = tokio::net::TcpStream::connect(addr).await.unwrap();
            let mut conn = AsyncConnection::from_stream(Peer::new_raw_open().unwrap(), stream);
            conn.peer().register_import(7).unwrap();
            conn.send_deliver(&Reference::far(7), &[Argument::Integer(42)], Some(9)).await.unwrap();
            match conn.next_event().await.unwrap().expect("a resolve") {
                Event::Resolve { answer, resolution } => {
                    assert_eq!(answer, 9);
                    assert_eq!(resolution, Resolution::Fulfill(Argument::Integer(7)));
                }
                other => panic!("client expected a resolve, got {other:?}"),
            }
        };

        tokio::join!(server, client);
    }

    #[test]
    fn drives_a_peer_in_a_context_with_a_custom_allocator() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;

        struct Counting {
            allocs: Arc<AtomicUsize>,
        }
        impl HostAllocator for Counting {
            fn alloc(&self, size: usize, alignment: usize) -> *mut u8 {
                self.allocs.fetch_add(1, Ordering::Relaxed);
                let layout = std::alloc::Layout::from_size_align(size, alignment).unwrap();
                unsafe { std::alloc::alloc(layout) }
            }
            unsafe fn free(&self, ptr: *mut u8, size: usize, alignment: usize) {
                let layout = std::alloc::Layout::from_size_align(size, alignment).unwrap();
                std::alloc::dealloc(ptr, layout);
            }
        }

        let allocs = Arc::new(AtomicUsize::new(0));
        let ctx = Context::with_allocator(Box::new(Counting { allocs: allocs.clone() })).unwrap();
        let mut peer = Peer::new_raw_open_in(&ctx).unwrap();
        peer.register_export(7).unwrap();

        // feed_owned transfers the bytes into the inbound queue; step applies them.
        peer.feed_owned(b"<10'op:deliver<11'desc:export7+>[5:hello]11+f>".to_vec()).unwrap();
        peer.step().unwrap();
        match peer.poll().unwrap().expect("a deliver event") {
            Event::Deliver { target, .. } => assert_eq!(target, Reference::Near { id: 7, promise: false }),
            other => panic!("expected a deliver, got {other:?}"),
        }
        // The host allocator actually serviced the context-backed peer.
        assert!(allocs.load(Ordering::Relaxed) > 0);

        // Release the peer before the context it was created in.
        drop(peer);
        drop(ctx);
    }
}
