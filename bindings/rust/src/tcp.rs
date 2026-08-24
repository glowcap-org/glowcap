//! The blocking TCP transport (the `tcp` feature).
//!
//! This module wraps `libpancake_net_transport_tcp` — the `pancake_tcp_*`
//! archive that the `tcp` Cargo feature links (ADR-0059). It is the
//! frame-shuttle layer one step below the async [`Session`](crate::Session):
//! a [`Netlayer`] owns the blocking-TCP I/O backend, [`Netlayer::listen`] /
//! [`Netlayer::connect`] bind and dial, and a [`Connection`] reads and writes one
//! whole CapTP frame at a time. The frame methods block.
//!
//! Errors from a `pancake_tcp_*` call route through the transport archive's own
//! thread-local last-error (`pancake_tcp_last_error`),
//! never the ocapn family's [`last_error`](crate::last_error).

use core::marker::PhantomData;

use crate::error_slot::error_slot;
use crate::sys::tcp as ffi;
use crate::{Codec, Context, HintValue, HintWireForm, Locator, Result};

/// TCP keepalive window. Every field is required when enabled.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Keepalive {
	pub idle_seconds: u32,
	pub interval_seconds: u32,
	pub count: u32,
}

/// Policy for one TCP stream. `None` at an operation inherits the provider's
/// value; `Some(StreamOptions::default())` explicitly disables keepalive.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct StreamOptions {
	pub keepalive: Option<Keepalive>,
}

/// Defaults inherited by every stream in the TCP provider package.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Config {
	pub stream: StreamOptions,
}

impl StreamOptions {
	fn to_c(self) -> ffi::PancakeTcpStreamOptions {
		match self.keepalive {
			Some(value) => ffi::PancakeTcpStreamOptions {
				keepalive_idle_sec: value.idle_seconds,
				keepalive_interval_sec: value.interval_seconds,
				keepalive_count: value.count,
			},
			None => ffi::PancakeTcpStreamOptions::default(),
		}
	}
}

impl Config {
	fn to_c(self) -> ffi::PancakeTcpConfig {
		ffi::PancakeTcpConfig {
			stream: self.stream.to_c(),
		}
	}
}

/// Typed per-operation TCP policy for [`crate::Runtime::connect`].
///
/// `None` in [`crate::ConnectOptions`] inherits the provider's configured
/// [`Config::stream`] value. Supplying `OperationOptions::default()` is an
/// explicit all-zero override that disables keepalive for this operation.
#[cfg(feature = "async")]
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct OperationOptions {
	stream: ffi::PancakeTcpStreamOptions,
}

#[cfg(feature = "async")]
const _: () = {
	use core::mem::{offset_of, size_of};
	assert!(size_of::<OperationOptions>() == ffi::PANCAKE_TCP_OPERATION_OPTIONS_SIZE);
	assert!(offset_of!(OperationOptions, stream) == ffi::PANCAKE_TCP_OPERATION_OPTIONS_STREAM_OFF);
};

#[cfg(feature = "async")]
impl OperationOptions {
	/// Override the provider with an explicit keepalive policy.
	pub fn with_keepalive(keepalive: Keepalive) -> Self {
		Self {
			stream: StreamOptions {
				keepalive: Some(keepalive),
			}
			.to_c(),
		}
	}

	fn bytes(&self) -> &[u8] {
		unsafe { core::slice::from_raw_parts(self as *const Self as *const u8, core::mem::size_of::<Self>()) }
	}
}

#[cfg(feature = "async")]
impl crate::TransportOperationOptions for OperationOptions {
	fn transports(&self) -> &'static [&'static str] {
		&[
			crate::TRANSPORT_TCP,
			crate::TRANSPORT_KEYED_TCP,
			crate::TRANSPORT_NOISE_TCP,
		]
	}

	fn as_bytes(&self) -> &[u8] {
		self.bytes()
	}
}

#[cfg(all(test, feature = "async"))]
mod operation_options_tests {
	use super::*;

	#[test]
	fn options_are_typed_and_borrowed_for_the_dial() {
		let tcp_options = OperationOptions::with_keepalive(Keepalive {
			idle_seconds: 30,
			interval_seconds: 10,
			count: 3,
		});
		let options = crate::ConnectOptions::default().with_transport(&tcp_options);
		let bytes = options
			.transport_options(&locator("127.0.0.1", 9))
			.unwrap()
			.expect("TCP options should produce one opaque operation payload");
		assert_eq!(bytes.len(), ffi::PANCAKE_TCP_OPERATION_OPTIONS_SIZE);
	}

	#[test]
	fn options_reject_a_non_tcp_locator() {
		let tcp_options = OperationOptions::default();
		let options = crate::ConnectOptions::default().with_transport(&tcp_options);
		let locator = Locator {
			transport: crate::TRANSPORT_IROH.to_string(),
			designator: "node".to_string(),
			hints: Default::default(),
			hint_wire_form: HintWireForm::BooleanFalse,
		};
		assert!(options.transport_options(&locator).is_err());
	}
}

#[cfg(feature = "async")]
pub use crate::tcp_listen::{KeyedListenOptions, ListenOptions, Server};
#[cfg(feature = "async")]
pub use crate::ListenerIdentity;

/// Bind the plain TCP profile through this package's native provider.
#[cfg(feature = "async")]
pub async fn listen(bind_host: &str, port: u16, options: ListenOptions) -> Result<Server> {
	crate::tcp_listen::listen(bind_host, port, options).await
}

/// Spell a TCP `host:port` designator, including IPv6 brackets.
pub fn address_designator(host: &str, port: u16) -> String {
	if host.contains(':') && !(host.starts_with('[') && host.ends_with(']')) {
		format!("[{host}]:{port}")
	} else {
		format!("{host}:{port}")
	}
}

/// Build the plain TCP profile's typed OCapN locator.
pub fn locator(host: &str, port: u16) -> Locator {
	Locator {
		transport: crate::TRANSPORT_TCP.to_string(),
		designator: address_designator(host, port),
		hints: std::collections::BTreeMap::new(),
		hint_wire_form: HintWireForm::BooleanFalse,
	}
}

fn key_addressed_locator(transport: &str, designator: &str, host: &str, port: u16) -> Locator {
	let mut hints = std::collections::BTreeMap::new();
	hints.insert(
		crate::HINT_DIRECT_ADDRESSES.to_string(),
		HintValue::String(address_designator(host, port)),
	);
	Locator {
		transport: transport.to_string(),
		designator: designator.to_string(),
		hints,
		hint_wire_form: HintWireForm::Map,
	}
}

/// Identity-addressed cleartext over this TCP package.
pub mod keyed {
	#[cfg(feature = "async")]
	use super::{KeyedListenOptions, Server};
	use crate::Locator;
	#[cfg(feature = "async")]
	use crate::Result;

	pub fn locator(designator: &str, host: &str, port: u16) -> Locator {
		super::key_addressed_locator(crate::TRANSPORT_KEYED_TCP, designator, host, port)
	}

	/// Bind identity-addressed cleartext through this package's native provider.
	#[cfg(feature = "async")]
	pub async fn listen(bind_host: &str, port: u16, options: KeyedListenOptions) -> Result<Server> {
		crate::tcp_listen::listen_keyed(bind_host, port, crate::TRANSPORT_KEYED_TCP, options).await
	}
}

/// Noise_XK-sealed streams over this TCP package.
pub mod noise {
	#[cfg(feature = "async")]
	use super::{KeyedListenOptions, Server};
	use crate::Locator;
	#[cfg(feature = "async")]
	use crate::Result;

	pub fn locator(designator: &str, host: &str, port: u16) -> Locator {
		super::key_addressed_locator(crate::TRANSPORT_NOISE_TCP, designator, host, port)
	}

	/// Bind Noise_XK-sealed streams through this package's native provider.
	#[cfg(feature = "async")]
	pub async fn listen(bind_host: &str, port: u16, options: KeyedListenOptions) -> Result<Server> {
		crate::tcp_listen::listen_keyed(bind_host, port, crate::TRANSPORT_NOISE_TCP, options).await
	}
}

/// Install the complete TCP provider package through the native driver.
#[cfg(feature = "async")]
pub(crate) fn ensure_loop_provider(lp: &crate::driver_loop::LoopShared, config: Config) -> Result<()> {
	let netlayer = Netlayer::new(config)?;
	lp.add_provider(netlayer.transport_provider()?)
}

/// Configure this archive's complete tcp/keyed-tcp/noise-tcp package for a
/// generic [`crate::Runtime::connect`] operation.
#[cfg(feature = "async")]
pub fn provider(config: Config) -> crate::driver_loop::Provider {
	crate::driver_loop::Provider::new(move |lp| async move { ensure_loop_provider(&lp, config) })
}

error_slot!(
	// Like the core `check`, but for `pancake_tcp_*` calls: snapshot the TCP
	// transport's own thread-local last-error rather than the unrelated
	// ocapn-family one.
	fn check_tcp;
	fn tcp_last_error;
	ffi::pancake_tcp_last_error
);

fn require_archive() -> Result<()> {
	crate::require_archive_fingerprint(
		"tcp",
		unsafe { ffi::pancake_tcp_archive_fingerprint() },
		crate::abi_constants::TCP_ARCHIVE_FINGERPRINT,
	)
}

/// Owns the blocking-TCP I/O backend. Connections and listeners borrow it (via
/// `&self`), so the borrow checker rejects a [`Connection`] or [`Listener`] that
/// outlives the netlayer that produced it. The `'ctx` lifetime additionally ties
/// a context-backed netlayer to its [`Context`]; a netlayer on the library-owned
/// allocator is `Netlayer<'static>`.
///
/// A connection cannot outlive the netlayer that produced it:
///
/// ```compile_fail
/// use pancake_rust_dogfood::{Codec, tcp::Netlayer};
/// let _conn = {
///     let netlayer = Netlayer::new(Default::default()).unwrap();
///     netlayer.connect("127.0.0.1", 1, None, Codec::Syrup, 4096).unwrap()
/// }; // netlayer is dropped here, so the borrow checker rejects keeping the conn.
/// ```
pub struct Netlayer<'ctx> {
	raw: *mut ffi::PancakeTcpNetlayer,
	_ctx: PhantomData<&'ctx Context>,
}

impl<'ctx> Netlayer<'ctx> {
	pub fn new(config: Config) -> Result<Netlayer<'ctx>> {
		require_archive()?;
		let mut raw: *mut ffi::PancakeTcpNetlayer = core::ptr::null_mut();
		let config = config.to_c();
		check_tcp(unsafe { ffi::pancake_tcp_netlayer_new(&config, &mut raw) })?;
		Ok(Netlayer { raw, _ctx: PhantomData })
	}

	/// Create a netlayer whose backend and per-connection buffers allocate through
	/// `context`. The context must outlive the netlayer, which `'ctx` enforces.
	pub fn new_in(context: &'ctx Context, config: Config) -> Result<Netlayer<'ctx>> {
		require_archive()?;
		let mut raw: *mut ffi::PancakeTcpNetlayer = core::ptr::null_mut();
		let config = config.to_c();
		check_tcp(unsafe { ffi::pancake_tcp_netlayer_new_in(context.raw(), &config, &mut raw) })?;
		Ok(Netlayer { raw, _ctx: PhantomData })
	}

	/// Borrow this runtime's complete tcp/keyed-tcp/noise-tcp package. The
	/// driver acquires its own lease during registration.
	#[cfg(feature = "async")]
	pub(crate) fn transport_provider(&self) -> Result<crate::driver_loop::ProviderPackage<'_>> {
		let mut package: crate::sys::PancakeTransportProvider = unsafe { core::mem::zeroed() };
		check_tcp(unsafe { ffi::pancake_tcp_transport_provider(self.raw, &mut package) })?;
		Ok(crate::driver_loop::ProviderPackage {
			package,
			_owner: PhantomData,
		})
	}

	/// Bind and listen on `bind_host:port` (port 0 = OS-chosen). The returned listener
	/// borrows this netlayer and cannot outlive it.
	pub fn listen(&self, bind_host: &str, port: u16) -> Result<Listener<'_>> {
		let mut raw: *mut ffi::PancakeTcpListener = core::ptr::null_mut();
		check_tcp(unsafe { ffi::pancake_tcp_listen(self.raw, bind_host.as_ptr(), bind_host.len(), port, &mut raw) })?;
		Ok(Listener { raw, _nl: PhantomData })
	}

	/// Connect to `host:port`, framing on `codec` with an inbound cap of
	/// `max_frame_bytes`. The returned connection borrows this netlayer and
	/// cannot outlive it.
	pub fn connect(
		&self,
		host: &str,
		port: u16,
		options: Option<StreamOptions>,
		codec: Codec,
		max_frame_bytes: usize,
	) -> Result<Connection<'_>> {
		let mut raw: *mut ffi::PancakeTcpConn = core::ptr::null_mut();
		let options = options.map(StreamOptions::to_c);
		check_tcp(unsafe {
			ffi::pancake_tcp_connect(
				self.raw,
				host.as_ptr(),
				host.len(),
				port,
				options.as_ref().map_or(core::ptr::null(), |value| value),
				codec.to_c(),
				max_frame_bytes,
				&mut raw,
				core::ptr::null_mut(),
				0,
				core::ptr::null_mut(),
			)
		})?;
		Ok(Connection { raw, _nl: PhantomData })
	}
}

impl Drop for Netlayer<'_> {
	fn drop(&mut self) {
		unsafe { ffi::pancake_tcp_netlayer_release(self.raw) };
	}
}

/// A bound listener. Released on drop. Borrows the [`Netlayer`] it came from, so
/// the netlayer outlives every accepted connection.
pub struct Listener<'a> {
	raw: *mut ffi::PancakeTcpListener,
	_nl: PhantomData<&'a ()>,
}

impl Listener<'_> {
	/// The OS-resolved local port (useful after binding to port 0).
	pub fn port(&self) -> Result<u16> {
		let mut port: u16 = 0;
		check_tcp(unsafe { ffi::pancake_tcp_listener_port(self.raw, &mut port) })?;
		Ok(port)
	}

	/// Return the borrowed listening descriptor for reactor integration.
	/// The listener owns it; callers must not close it or retain it after drop.
	pub fn readiness_fd(&self) -> Result<i32> {
		let mut fd: i32 = -1;
		check_tcp(unsafe { ffi::pancake_tcp_listener_readiness_fd(self.raw, &mut fd) })?;
		Ok(fd)
	}

	/// Block for a client connection. The returned connection borrows this
	/// listener (and thus the netlayer) and cannot outlive it.
	pub fn accept(
		&self,
		options: Option<StreamOptions>,
		codec: Codec,
		max_frame_bytes: usize,
	) -> Result<Connection<'_>> {
		let mut raw: *mut ffi::PancakeTcpConn = core::ptr::null_mut();
		let options = options.map(StreamOptions::to_c);
		check_tcp(unsafe {
			ffi::pancake_tcp_accept(
				self.raw,
				options.as_ref().map_or(core::ptr::null(), |value| value),
				codec.to_c(),
				max_frame_bytes,
				&mut raw,
				core::ptr::null_mut(),
				0,
				core::ptr::null_mut(),
			)
		})?;
		Ok(Connection { raw, _nl: PhantomData })
	}
}

// SAFETY: a `Listener` owns a self-contained payload — its own listening socket
// plus a copy of the netlayer's allocator — and shares no per-handle mutable
// state with the netlayer or sibling handles, so moving it to the accepting
// thread and calling `accept` there touches only its own state. The two pieces
// it does share with the netlayer are both thread-safe: the allocator
// (`std.heap.smp_allocator` for `Netlayer::new`, or a bounded `Send + Sync`
// `ContextAllocator` for `new_in`) and the netlayer's `std.Io.Threaded` backend,
// which tolerates the concurrent blocking calls a borrowed handle on one thread
// makes while the netlayer is used on the origin. Borrowing the netlayer keeps
// it non-`'static`, so callers move it into a scoped thread.
unsafe impl Send for Listener<'_> {}

impl Drop for Listener<'_> {
	fn drop(&mut self) {
		unsafe { ffi::pancake_tcp_listener_release(self.raw) };
	}
}

/// A blocking TCP connection, the `pancake_tcp_*` frame shuttle, one
/// layer below [`Session`](crate::Session). Closed on drop. The frame
/// methods block. Borrows the [`Netlayer`] (or [`Listener`]) it came from, so
/// that backend outlives it.
pub struct Connection<'a> {
	raw: *mut ffi::PancakeTcpConn,
	_nl: PhantomData<&'a ()>,
}

impl Connection<'_> {
	/// Seal this connection and interrupt blocking frame operations. Drop then
	/// releases its storage after callers have joined their operation threads.
	pub fn shutdown(&self) -> Result<()> {
		check_tcp(unsafe { ffi::pancake_tcp_conn_shutdown(self.raw) })
	}

	/// Close explicitly, reporting a shutdown failure to the caller. Native
	/// storage is released as this value is consumed; a release-only refusal is
	/// retained by the process diagnostic fallback because `Drop` has no caller.
	pub fn close(self) -> Result<()> {
		self.shutdown()
	}

	/// Block for one whole frame. [`ErrorKind::Closed`](crate::ErrorKind::Closed)
	/// reports a clean EOF.
	pub fn read_frame(&mut self) -> Result<Vec<u8>> {
		let mut frame: crate::sys::PancakeManagedFrame = unsafe { core::mem::zeroed() };
		check_tcp(unsafe {
			ffi::pancake_tcp_conn_read_frame(self.raw, &mut frame, core::ptr::null_mut(), 0, core::ptr::null_mut())
		})?;
		let out = unsafe { crate::owned_from_view(frame.bytes, frame.len) };
		unsafe { crate::sys::pancake_managed_frame_release(&mut frame) };
		Ok(out)
	}

	/// Write one frame's bytes and flush.
	pub fn write_frame(&mut self, bytes: &[u8]) -> Result<()> {
		let f = crate::sys::PancakeFrame {
			bytes: bytes.as_ptr(),
			len: bytes.len(),
			shape: crate::sys::FRAME_SHAPE_BYTE,
		};
		check_tcp(unsafe {
			ffi::pancake_tcp_conn_write_frame(self.raw, &f, core::ptr::null_mut(), 0, core::ptr::null_mut())
		})
	}
}

// SAFETY: a `Connection` owns a self-contained payload — its own TCP stream plus
// a copy of the netlayer's allocator — and shares no per-handle mutable state
// with the netlayer or sibling handles, so moving it to another thread and doing
// frame I/O on it touches only its own state. The allocator and the netlayer's
// `std.Io.Threaded` backend it shares are thread-safe under the concurrent
// blocking calls a borrowed handle makes off-thread (see `Listener` above).
unsafe impl Send for Connection<'_> {}

impl Drop for Connection<'_> {
	fn drop(&mut self) {
		if let Err(error) = check_tcp(unsafe {
			ffi::pancake_tcp_conn_release(self.raw, core::ptr::null_mut(), 0, core::ptr::null_mut())
		}) {
			crate::record_runtime_failure(crate::FailureLayer::Transport, "tcp-connection-drop-release", error);
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::Codec;

	#[test]
	fn shuttles_a_frame_over_a_real_tcp_socket() {
		// The netlayer owns the I/O backend; the listener and connections borrow
		// it, so a scoped thread keeps those borrows honest (the borrowed
		// `Listener` is not `'static` and cannot enter `thread::spawn`).
		let netlayer = Netlayer::new(Config::default()).unwrap();
		let listener = netlayer.listen("127.0.0.1", 0).unwrap();
		let port = listener.port().unwrap();

		let received = std::thread::scope(|scope| {
			let server = scope.spawn(move || {
				let mut conn = listener.accept(None, Codec::Syrup, 4096).unwrap();
				conn.read_frame().unwrap()
			});

			let mut client = netlayer.connect("127.0.0.1", port, None, Codec::Syrup, 4096).unwrap();
			client.write_frame(b"<8'op:abort3\"bye>").unwrap();

			server.join().unwrap()
		});
		assert_eq!(received, b"<8'op:abort3\"bye>");
	}

	// A whole-frame round-trip over the blocking TCP transport: the server
	// reads the client's frame, answers with its own, and the client reads it
	// back, proving the `tcp` archive delimits and shuttles whole frames in
	// both directions. The frames are canned protocol bytes; the transport
	// archive owns framing, never dispatch.
	#[test]
	fn shuttles_whole_frames_in_both_directions_over_tcp() {
		const QUESTION: &[u8] = b"<10'op:deliver<11'desc:export7+>[5:hello]11+<19'desc:import-promise99+>>";
		const ANSWER: &[u8] = b"<8'op:abort7\"replied>";

		let netlayer = Netlayer::new(Config::default()).unwrap();
		let listener = netlayer.listen("127.0.0.1", 0).unwrap();
		let port = listener.port().unwrap();

		let reply = std::thread::scope(|scope| {
			let server = scope.spawn(move || {
				let mut conn = listener.accept(None, Codec::Syrup, 4096).unwrap();
				let frame = conn.read_frame().unwrap();
				assert_eq!(frame, QUESTION);
				conn.write_frame(ANSWER).unwrap();
			});

			let mut client = netlayer.connect("127.0.0.1", port, None, Codec::Syrup, 4096).unwrap();
			client.write_frame(QUESTION).unwrap();
			let frame = client.read_frame().unwrap();
			server.join().unwrap();
			frame
		});
		assert_eq!(reply, ANSWER);
	}
}
