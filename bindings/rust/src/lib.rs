//! Idiomatic Rust API for `libpancake` — an OCapN/CapTP peer you drive.
//!
//! The raw C ABI lives in the private [`sys`] module; nothing in it escapes.
//! What you use is a [`Peer`] that releases itself on drop, real Rust enums for
//! [`Reference`]/[`Argument`]/[`Event`], `Result` for fallible calls, and owned
//! values out of `poll` (no manual `free`). This is the dogfood consumer
//! `zig build rust-dogfood` runs, so the ergonomic surface stays honest.

#![allow(clippy::missing_safety_doc)]

#[cfg(feature = "async")]
mod async_io;
#[cfg(feature = "async")]
pub use async_io::AsyncConnection;

#[cfg(feature = "async")]
mod connection;
#[cfg(feature = "async")]
pub use connection::{connect, Connection, Ref};

pub mod actors;

mod sys {
    // The raw FFI mirror of the C ABI. It declares the full surface — every
    // error code, reference kind, and argument tag `pancake.h` defines — so the
    // safe wrapper above can reach for any of them. Not every constant is used
    // yet (e.g. `ERR_CLOSED`, `REF_BROKEN` round out their enums), and that is
    // expected of a `sys` layer, so dead code is allowed here and only here.
    #![allow(dead_code)]

    use core::ffi::{c_int, c_uchar, c_uint, c_void};

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

    extern "C" {
        pub fn pancake_abi_version(major: *mut c_uint, minor: *mut c_uint, patch: *mut c_uint);
        pub fn pancake_last_error(out_buf: *mut c_uchar, cap: usize) -> usize;
        pub fn pancake_clear_last_error();

        pub fn pancake_context_new_default(out: *mut *mut PancakeContext) -> c_int;
        pub fn pancake_context_new_with_allocator(
            allocator: *const PancakeAllocator,
            out: *mut *mut PancakeContext,
        ) -> c_int;
        pub fn pancake_context_release(context: *mut PancakeContext);

        pub fn pancake_peer_new(peer: *mut *mut PancakePeer) -> c_int;
        pub fn pancake_peer_new_in(context: *mut PancakeContext, peer: *mut *mut PancakePeer) -> c_int;
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
        pub fn pancake_peer_register_export(peer: *mut PancakePeer, export_id: u64) -> c_int;
        pub fn pancake_peer_register_import(peer: *mut PancakePeer, import_id: u64) -> c_int;
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
        pub fn pancake_deliver_free(deliver: *mut PancakeDeliver);
        pub fn pancake_resolve_free(resolve: *mut PancakeResolve);
        pub fn pancake_peer_register_bootstrap_cap(
            peer: *mut PancakePeer,
            swissnum: *const c_uchar,
            swissnum_len: usize,
            out_export_id: *mut u64,
        ) -> c_int;
        pub fn pancake_peer_new_negotiating(peer: *mut *mut PancakePeer) -> c_int;
        pub fn pancake_peer_start_session_keyed(
            peer: *mut PancakePeer,
            captp_version: c_uint,
            transport: *const c_uchar,
            transport_len: usize,
            designator: *const c_uchar,
            designator_len: usize,
            hints_empty_false: c_uint,
            seed: *const c_uchar,
        ) -> c_int;
        pub fn pancake_peer_session_is_open(peer: *mut PancakePeer) -> c_int;

        pub fn pancake_tcp_netlayer_new(out: *mut *mut PancakeTcpNetlayer) -> c_int;
        pub fn pancake_tcp_netlayer_new_in(
            context: *mut PancakeContext,
            out: *mut *mut PancakeTcpNetlayer,
        ) -> c_int;
        pub fn pancake_tcp_netlayer_release(netlayer: *mut PancakeTcpNetlayer);
        pub fn pancake_endpoint_tcp_testing_connect(
            netlayer: *mut PancakeTcpNetlayer,
            host: *const c_uchar,
            host_len: usize,
            port: u16,
            codec: c_uint,
            max_frame_bytes: usize,
            out: *mut *mut PancakeTcpConn,
        ) -> c_int;
        pub fn pancake_endpoint_tcp_testing_listen(
            netlayer: *mut PancakeTcpNetlayer,
            host: *const c_uchar,
            host_len: usize,
            port: u16,
            out: *mut *mut PancakeTcpListener,
        ) -> c_int;
        pub fn pancake_endpoint_tcp_listener_port(listener: *mut PancakeTcpListener, out_port: *mut u16) -> c_int;
        pub fn pancake_endpoint_tcp_testing_accept(
            listener: *mut PancakeTcpListener,
            codec: c_uint,
            max_frame_bytes: usize,
            out: *mut *mut PancakeTcpConn,
        ) -> c_int;
        pub fn pancake_endpoint_tcp_read_frame(conn: *mut PancakeTcpConn, out: *mut PancakeManagedFrame) -> c_int;
        pub fn pancake_endpoint_tcp_write_frame(conn: *mut PancakeTcpConn, frame: *const PancakeFrame) -> c_int;
        pub fn pancake_endpoint_tcp_conn_close(conn: *mut PancakeTcpConn);
        pub fn pancake_endpoint_tcp_listener_close(listener: *mut PancakeTcpListener);
    }

    pub const CODEC_SYRUP: c_uint = 0;
    pub const ERR_CLOSED: c_int = -8;
    pub const ERR_BROKEN: c_int = -14;

    pub const OK: c_int = 0;
    pub const WOULD_BLOCK: c_int = -7;
    pub const FRAME_SHAPE_BYTE: c_uint = 0;

    pub const EVENT_DELIVER: c_int = 1;
    pub const EVENT_RESOLVE: c_int = 2;

    pub const REF_NEAR: c_uint = 0;
    pub const REF_FAR: c_uint = 1;
    pub const REF_PROMISE: c_uint = 2;
    pub const REF_STURDY: c_uint = 3;
    pub const REF_BROKEN: c_uint = 4;
    pub const REF_OBJECT: c_uint = 0;
    pub const REF_PROMISE_KIND: c_uint = 1;

    pub const ARG_INTEGER: c_uint = 0;
    pub const ARG_FLOAT64: c_uint = 1;
    pub const ARG_BOOLEAN: c_uint = 2;
    pub const ARG_BYTES: c_uint = 3;
    pub const ARG_STRING: c_uint = 4;
    pub const ARG_SYMBOL: c_uint = 5;
    pub const ARG_VOID: c_uint = 6;
    pub const ARG_REFERENCE: c_uint = 7;
    pub const ARG_LIST: c_uint = 8;
    pub const ARG_SET: c_uint = 9;
    pub const ARG_TAGGED: c_uint = 10;
    pub const ARG_KEYWORD: c_uint = 11;

    pub const RESOLUTION_FULFILL: c_uint = 0;
    pub const RESOLUTION_BREAK: c_uint = 1;
}

/// A failed pancake call. It always carries the negative `PANCAKE_ERR_*` code;
/// when a `send` was broken by the partner it also carries the break reason, so
/// the reason a partner gave for refusing a call is not lost behind a code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    code: i32,
    detail: Option<String>,
}

impl Error {
    /// The negative `PANCAKE_ERR_*` code for this failure.
    pub fn code(&self) -> i32 {
        self.code
    }

    /// The diagnostic message for this failure. For a broken `send` it is the
    /// partner's break reason, carried on the error itself. Otherwise it is the
    /// calling thread's last recorded C ABI message, if the library set one —
    /// read that right after the failing call, since it is thread-local and the
    /// next fallible call may overwrite it. `None` when neither is set.
    pub fn message(&self) -> Option<String> {
        self.detail.clone().or_else(last_error)
    }

    fn from_code(code: i32) -> Error {
        Error { code, detail: None }
    }

    /// A broken promise carrying the partner's reason: a `send`/`fetch` the
    /// remote side refused, distinct from a fault in this peer or the transport.
    /// Carries `PANCAKE_ERR_BROKEN` so a caller can tell a refusal apart from a
    /// real failure by `code()`, with the reason on `detail`.
    fn broken(message: String) -> Error {
        Error { code: sys::ERR_BROKEN, detail: Some(message) }
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
    let mut buf = vec![0u8; len];
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
        check(unsafe { sys::pancake_context_new_default(&mut raw) })?;
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
            Reference::Sturdy | Reference::Broken => return Err(Error::from_code(-13)),
        };
        Ok(sys::PancakeReference { kind, sub_kind: sub, id })
    }

    fn from_sys(r: &sys::PancakeReference) -> Reference {
        let promise = r.sub_kind == sys::REF_PROMISE_KIND;
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
        sys::REF_PROMISE_KIND
    } else {
        sys::REF_OBJECT
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
        _ => Argument::Void,
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
pub struct Peer {
    raw: *mut sys::PancakePeer,
}

impl Peer {
    /// Create a peer using the library-owned allocator.
    pub fn new() -> Result<Peer> {
        let mut raw: *mut sys::PancakePeer = core::ptr::null_mut();
        check(unsafe { sys::pancake_peer_new(&mut raw) })?;
        Ok(Peer { raw })
    }

    /// Create a peer whose allocations route through `context`. The context must
    /// outlive the peer.
    pub fn new_in(context: &Context) -> Result<Peer> {
        let mut raw: *mut sys::PancakePeer = core::ptr::null_mut();
        check(unsafe { sys::pancake_peer_new_in(context.raw, &mut raw) })?;
        Ok(Peer { raw })
    }

    /// A negotiating peer, awaiting the keyed `op:start-session` handshake — the
    /// peer to drive when the partner requires it (a real Goblins vat). Pair it
    /// with [`start_session_keyed`](Peer::start_session_keyed), then pump until
    /// [`session_is_open`](Peer::session_is_open).
    pub fn new_negotiating() -> Result<Peer> {
        let mut raw: *mut sys::PancakePeer = core::ptr::null_mut();
        check(unsafe { sys::pancake_peer_new_negotiating(&mut raw) })?;
        Ok(Peer { raw })
    }

    /// Sign and queue a keyed `op:start-session` from this negotiating peer over
    /// the canonical v1.0 wire. The 32-byte `seed` is the session key;
    /// `transport`/`designator` form the locator the partner verifies, so they
    /// must be what it expects — for a Goblins partner, `"tcp"` with
    /// `hints_empty_false` true (an empty hints map encoded as `#f`). Flush it,
    /// then pump until [`session_is_open`](Peer::session_is_open).
    pub fn start_session_keyed(
        &mut self,
        seed: &[u8; 32],
        transport: &str,
        designator: &str,
        hints_empty_false: bool,
    ) -> Result<()> {
        check(unsafe {
            sys::pancake_peer_start_session_keyed(
                self.raw,
                0, // v1.0
                transport.as_ptr(),
                transport.len(),
                designator.as_ptr(),
                designator.len(),
                u32::from(hints_empty_false),
                seed.as_ptr(),
            )
        })
    }

    /// Whether the keyed handshake has completed and the session is open for
    /// traffic. Pump the connection and poll this before sending application
    /// messages.
    pub fn session_is_open(&self) -> bool {
        unsafe { sys::pancake_peer_session_is_open(self.raw) == 1 }
    }

    /// Publish a local export so inbound deliveries to it surface as events.
    pub fn register_export(&mut self, id: u64) -> Result<()> {
        check(unsafe { sys::pancake_peer_register_export(self.raw, id) })
    }

    /// Track a partner-hosted import this peer holds, so a deliver to it is admitted.
    pub fn register_import(&mut self, id: u64) -> Result<()> {
        check(unsafe { sys::pancake_peer_register_import(self.raw, id) })
    }

    /// Dispatch one inbound frame, borrowed for the call.
    pub fn feed(&mut self, frame: &[u8]) -> Result<()> {
        let f = sys::PancakeFrame {
            bytes: frame.as_ptr(),
            len: frame.len(),
            shape: sys::FRAME_SHAPE_BYTE,
        };
        check(unsafe { sys::pancake_peer_feed_borrowed(self.raw, &f) })
    }

    /// Frame and dispatch one inbound frame from a byte-stream buffer. `bytes` is
    /// whatever has accumulated from the wire so far; returns `Some(n)` when a
    /// whole frame was consumed and dispatched (drop the first `n` bytes, then
    /// call again to drain more), or `None` when `bytes` holds only part of a
    /// frame (read more and retry). This is the sans-io stream-input primitive —
    /// the caller owns the socket; the peer never blocks. A reply or abort lands
    /// on the outbound queue; drain it with [`take_outbound`](Peer::take_outbound),
    /// and read events with [`poll`](Peer::poll).
    pub fn recv_stream(&mut self, bytes: &[u8]) -> Result<Option<usize>> {
        let mut consumed: usize = 0;
        let rc = unsafe { sys::pancake_peer_recv_stream(self.raw, bytes.as_ptr(), bytes.len(), &mut consumed) };
        match rc {
            sys::OK => Ok(Some(consumed)),
            sys::WOULD_BLOCK => Ok(None),
            _ => Err(Error::from_code(rc)),
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
            return Err(Error::from_code(rc));
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

    /// Take the next outbound frame as owned bytes, or `None` when the queue is empty.
    pub fn take_outbound(&mut self) -> Option<Vec<u8>> {
        let mut frame: sys::PancakeManagedFrame = unsafe { core::mem::zeroed() };
        let rc = unsafe { sys::pancake_peer_take_outbound(self.raw, &mut frame) };
        if rc != sys::OK {
            return None;
        }
        let out = unsafe { core::slice::from_raw_parts(frame.bytes, frame.len) }.to_vec();
        unsafe { sys::pancake_managed_frame_release(&mut frame) };
        Some(out)
    }

    /// Take the next application event as a typed [`Event`], or `Ok(None)` when
    /// idle. A typed-poll failure (re-decode or allocation failure between the
    /// peek and the poll) surfaces as `Err`, never as a fabricated event.
    pub fn poll(&mut self) -> Result<Option<Event>> {
        match unsafe { sys::pancake_peer_peek_event(self.raw) } {
            sys::EVENT_DELIVER => Ok(Some(self.poll_deliver()?)),
            sys::EVENT_RESOLVE => Ok(Some(self.poll_resolve()?)),
            sys::WOULD_BLOCK => Ok(None),
            _ => Ok(Some(self.poll_other())),
        }
    }

    fn poll_deliver(&mut self) -> Result<Event> {
        let mut d: sys::PancakeDeliver = unsafe { core::mem::zeroed() };
        check(unsafe { sys::pancake_peer_poll_event_deliver(self.raw, &mut d) })?;
        let event = Event::Deliver {
            target: Reference::from_sys(&d.target),
            args: unsafe { args_from_sys(d.args, d.args_len) },
            answer: if d.has_answer != 0 { Some(d.answer) } else { None },
        };
        unsafe { sys::pancake_deliver_free(&mut d) };
        Ok(event)
    }

    fn poll_resolve(&mut self) -> Result<Event> {
        let mut r: sys::PancakeResolve = unsafe { core::mem::zeroed() };
        check(unsafe { sys::pancake_peer_poll_event_resolve(self.raw, &mut r) })?;
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
        unsafe { sys::pancake_resolve_free(&mut r) };
        Ok(event)
    }

    fn poll_other(&mut self) -> Event {
        let mut e: sys::PancakeEvent = unsafe { core::mem::zeroed() };
        unsafe { sys::pancake_peer_poll_event(self.raw, &mut e) };
        let frame = if e.frame.bytes.is_null() {
            Vec::new()
        } else {
            unsafe { core::slice::from_raw_parts(e.frame.bytes, e.frame.len) }.to_vec()
        };
        let kind = e.kind;
        unsafe { sys::pancake_event_release(&mut e) };
        Event::Other { kind, frame }
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

impl Drop for Peer {
    fn drop(&mut self) {
        unsafe { sys::pancake_peer_release(self.raw) };
    }
}

/// The framing codec a TCP endpoint uses.
#[derive(Debug, Clone, Copy)]
pub enum Codec {
    Syrup,
}

impl Codec {
    fn to_c(self) -> u32 {
        match self {
            Codec::Syrup => sys::CODEC_SYRUP,
        }
    }
}

/// Owns the blocking-TCP I/O backend. Connections and listeners borrow it, so it
/// must outlive them (enforced by Rust's borrow checker via `&self`).
pub struct Netlayer {
    raw: *mut sys::PancakeTcpNetlayer,
}

impl Netlayer {
    pub fn new() -> Result<Netlayer> {
        let mut raw: *mut sys::PancakeTcpNetlayer = core::ptr::null_mut();
        check(unsafe { sys::pancake_tcp_netlayer_new(&mut raw) })?;
        Ok(Netlayer { raw })
    }

    /// Create a netlayer whose backend and per-connection buffers allocate through
    /// `context`. The context must outlive the netlayer.
    pub fn new_in(context: &Context) -> Result<Netlayer> {
        let mut raw: *mut sys::PancakeTcpNetlayer = core::ptr::null_mut();
        check(unsafe { sys::pancake_tcp_netlayer_new_in(context.raw, &mut raw) })?;
        Ok(Netlayer { raw })
    }

    /// Bind and listen on `host:port` (port 0 = OS-chosen).
    pub fn listen(&self, host: &str, port: u16) -> Result<Listener> {
        let mut raw: *mut sys::PancakeTcpListener = core::ptr::null_mut();
        check(unsafe {
            sys::pancake_endpoint_tcp_testing_listen(self.raw, host.as_ptr(), host.len(), port, &mut raw)
        })?;
        Ok(Listener { raw })
    }

    /// Connect to `host:port`, framing on `codec` with an inbound cap of `max_frame_bytes`.
    pub fn connect(&self, host: &str, port: u16, codec: Codec, max_frame_bytes: usize) -> Result<Conn> {
        let mut raw: *mut sys::PancakeTcpConn = core::ptr::null_mut();
        check(unsafe {
            sys::pancake_endpoint_tcp_testing_connect(
                self.raw,
                host.as_ptr(),
                host.len(),
                port,
                codec.to_c(),
                max_frame_bytes,
                &mut raw,
            )
        })?;
        Ok(Conn { raw })
    }
}

impl Drop for Netlayer {
    fn drop(&mut self) {
        unsafe { sys::pancake_tcp_netlayer_release(self.raw) };
    }
}

/// A bound listener. Released on drop.
pub struct Listener {
    raw: *mut sys::PancakeTcpListener,
}

impl Listener {
    /// The OS-resolved local port (useful after binding to port 0).
    pub fn port(&self) -> Result<u16> {
        let mut port: u16 = 0;
        check(unsafe { sys::pancake_endpoint_tcp_listener_port(self.raw, &mut port) })?;
        Ok(port)
    }

    /// Block for a client connection.
    pub fn accept(&self, codec: Codec, max_frame_bytes: usize) -> Result<Conn> {
        let mut raw: *mut sys::PancakeTcpConn = core::ptr::null_mut();
        check(unsafe { sys::pancake_endpoint_tcp_testing_accept(self.raw, codec.to_c(), max_frame_bytes, &mut raw) })?;
        Ok(Conn { raw })
    }
}

// A listener handle is safe to move to the accepting thread.
unsafe impl Send for Listener {}

impl Drop for Listener {
    fn drop(&mut self) {
        unsafe { sys::pancake_endpoint_tcp_listener_close(self.raw) };
    }
}

/// A connection. Closed on drop. The frame methods block.
pub struct Conn {
    raw: *mut sys::PancakeTcpConn,
}

impl Conn {
    /// Block for one whole frame. An error with `code() == -8` is a clean EOF.
    pub fn read_frame(&mut self) -> Result<Vec<u8>> {
        let mut frame: sys::PancakeManagedFrame = unsafe { core::mem::zeroed() };
        check(unsafe { sys::pancake_endpoint_tcp_read_frame(self.raw, &mut frame) })?;
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
        check(unsafe { sys::pancake_endpoint_tcp_write_frame(self.raw, &f) })
    }
}

unsafe impl Send for Conn {}

impl Drop for Conn {
    fn drop(&mut self) {
        unsafe { sys::pancake_endpoint_tcp_conn_close(self.raw) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drives_ocapn_with_the_idiomatic_api() {
        // Construct a call with typed args — no raw FFI in sight.
        let mut caller = Peer::new().unwrap();
        caller.register_import(5).unwrap();
        caller
            .send_deliver(
                &Reference::far(5),
                &[Argument::Integer(42), Argument::Bytes(b"hi".to_vec())],
                Some(9),
            )
            .unwrap();
        caller.step().unwrap();
        let wire = caller.take_outbound().expect("an outbound frame");
        assert!(wire.starts_with(b"<10'op:deliver"));

        // Inspect an inbound delivery as a typed Event.
        let mut callee = Peer::new().unwrap();
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
        let mut peer = Peer::new().unwrap();
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
        let mut peer = Peer::new().unwrap();
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
        use std::thread;
        // The netlayer owns the I/O backend; it outlives the endpoints made from
        // it (it is dropped last, after the join).
        let netlayer = Netlayer::new().unwrap();
        let listener = netlayer.listen("127.0.0.1", 0).unwrap();
        let port = listener.port().unwrap();

        let server = thread::spawn(move || {
            let mut conn = listener.accept(Codec::Syrup, 4096).unwrap();
            conn.read_frame().unwrap()
        });

        let mut client = netlayer.connect("127.0.0.1", port, Codec::Syrup, 4096).unwrap();
        client.write_frame(b"<8'op:abort3\"bye>").unwrap();

        let received = server.join().unwrap();
        assert_eq!(received, b"<8'op:abort3\"bye>");
    }

    #[test]
    fn server_replies_to_a_received_call() {
        let mut peer = Peer::new().unwrap();
        peer.register_export(7).unwrap();
        peer.feed(b"<10'op:deliver<11'desc:export7+>[5:hello]11+f>").unwrap();
        let answer = match peer.poll().unwrap().unwrap() {
            Event::Deliver { answer, .. } => answer.unwrap(),
            other => panic!("expected deliver, got {other:?}"),
        };
        peer.send_resolve(answer, &Resolution::Fulfill(Argument::Integer(7))).unwrap();
        peer.step().unwrap();
        let wire = peer.take_outbound().expect("a resolve frame");
        assert!(core::str::from_utf8(&wire).unwrap().contains("op:resolve"));
    }

    #[test]
    fn reports_a_nonzero_abi_version() {
        let (major, minor, patch) = abi_version();
        assert!(major + minor + patch > 0);
    }

    #[test]
    fn hosts_an_actor_that_serves_a_delivered_call() {
        use crate::actors::Vat;

        let mut peer = Peer::new().unwrap();
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

        // A partner delivers counter.add(5) with answer 11.
        vat.peer()
            .unwrap()
            .feed(b"<10'op:deliver<11'desc:export7+>[3'add5+]11+f>")
            .unwrap();
        let event = vat.peer().unwrap().poll().unwrap().expect("a deliver event");
        assert!(vat.serve(&event).unwrap());

        vat.peer().unwrap().step().unwrap();
        let wire = vat.peer().unwrap().take_outbound().expect("a resolve frame");
        let text = core::str::from_utf8(&wire).unwrap();
        assert!(text.contains("op:resolve"));
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
        let mut peer_b = Peer::new().unwrap();
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
        let mut peer_a = Peer::new().unwrap();
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
        let to_b = vat_a.peer().unwrap().take_outbound().expect("A's deliver frame");
        vat_b.peer().unwrap().feed(&to_b).unwrap();

        // B serves the deliver: runs the counter (10 + 5 = 15) and resolves.
        let deliver = vat_b.peer().unwrap().poll().unwrap().expect("a deliver event");
        assert!(vat_b.serve(&deliver).unwrap());

        // Shuttle B's outbound resolve back to A.
        vat_b.peer().unwrap().step().unwrap();
        let to_a = vat_b.peer().unwrap().take_outbound().expect("B's resolve frame");
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
            let mut peer = Peer::new().unwrap();
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
            let mut conn = AsyncConnection::connect(addr).await.unwrap();
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
        let mut peer = Peer::new_in(&ctx).unwrap();
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
