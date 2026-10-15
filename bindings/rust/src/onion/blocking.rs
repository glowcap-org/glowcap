use super::*;
use core::marker::PhantomData;
use std::sync::{Arc, Mutex};

fn lock_failure(slot: &Mutex<Option<Error>>) -> std::sync::MutexGuard<'_, Option<Error>> {
	slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Netlayer {
	/// Build a netlayer from `config`, on the library-owned allocator.
	///
	/// The configuration text is copied in, so `config`'s borrows need not
	/// outlive this call.
	pub fn new(config: &Config<'_>) -> Result<Netlayer> {
		require_archive()?;
		let c = config.to_c();
		let mut raw: *mut ffi::GlowcapOnionNetlayer = core::ptr::null_mut();
		// SAFETY: `c` is a local `GlowcapOnionConfig` borrowed for the call, and the callee copies its text; `raw` is
		// an out-parameter the callee fills with the new netlayer handle.
		check_onion(unsafe { ffi::glowcap_onion_netlayer_new(&c, &mut raw) })?;
		Ok(Netlayer {
			raw,
			listener_close_failure: Arc::new(Mutex::new(None)),
		})
	}

	#[cfg(feature = "async")]
	pub(super) fn transport_provider(&self) -> Result<crate::driver_loop::ProviderPackage<'_>> {
		// SAFETY: `GlowcapTransportProvider` is a plain C struct of integers, null pointers, and `Option` function
		// pointers; all-zero is a valid value, and the callee fills it before it is read.
		let mut package: crate::sys::GlowcapTransportProvider = unsafe { core::mem::zeroed() };
		// SAFETY: `self.raw` is this `Netlayer`'s handle from `glowcap_onion_netlayer_new`, released only by `close` or
		// its `Drop`; `package` is an out-parameter the callee fills, and the returned `ProviderPackage<'_>` borrows
		// this netlayer.
		check_onion(unsafe { ffi::glowcap_onion_transport_provider(self.raw, &mut package) })?;
		Ok(crate::driver_loop::ProviderPackage {
			package,
			_owner: PhantomData,
		})
	}

	/// Ask Tor for an onion service and bind its local end.
	///
	/// Requires a control endpoint in the [`Config`]. Without one this fails
	/// rather than reporting a service nothing could reach. Blocking: the control
	/// conversation is several round trips to the daemon.
	pub fn listen(&self) -> Result<Listener<'_>> {
		let mut id = [0u8; ffi::ONION_SERVICE_ID_LEN];
		let mut id_len: usize = 0;
		let mut key = [0u8; ffi::ONION_SERVICE_KEY_CAP];
		let mut key_len: usize = 0;
		let mut raw: *mut ffi::GlowcapOnionListener = core::ptr::null_mut();
		// SAFETY: `self.raw` is this `Netlayer`'s handle from `glowcap_onion_netlayer_new`, released only by `close` or
		// its `Drop`; `id` and `key` are local arrays whose pointers and lengths stay live for the call and which the
		// callee fills, reporting the bytes written through `id_len` and `key_len`; `raw` is an out-parameter the
		// callee fills; the null error buffer with length zero asks for no error text.
		check_onion(unsafe {
			ffi::glowcap_onion_listen(
				self.raw,
				id.as_mut_ptr(),
				id.len(),
				&mut id_len,
				key.as_mut_ptr(),
				key.len(),
				&mut key_len,
				&mut raw,
				core::ptr::null_mut(),
				0,
				core::ptr::null_mut(),
			)
		})?;
		Ok(Listener {
			raw,
			id,
			id_len,
			key,
			key_len,
			close_failure: Arc::clone(&self.listener_close_failure),
			_nl: PhantomData,
		})
	}

	/// Dial the onion service `service_id` through the configured Tor, framing on
	/// `codec` with an inbound cap of `max_frame_bytes`.
	///
	/// `service_id` is the bare version 3 designator: 56 base32 characters with no
	/// `.onion` suffix, which a locator's transport label supplies. One that is
	/// not a well-formed v3 address is refused before any socket opens. Blocking:
	/// a Tor circuit takes seconds.
	pub fn connect(&self, service_id: &str, codec: Codec, max_frame_bytes: usize) -> Result<Connection<'_>> {
		let mut raw: *mut ffi::GlowcapOnionConn = core::ptr::null_mut();
		// SAFETY: `self.raw` is this `Netlayer`'s handle from `glowcap_onion_netlayer_new`, released only by `close` or
		// its `Drop`; `service_id` is a borrowed `str` whose pointer and length stay live for the call; `raw` is an
		// out-parameter the callee fills; the null error buffer with length zero asks for no error text.
		check_onion(unsafe {
			ffi::glowcap_onion_connect(
				self.raw,
				service_id.as_ptr(),
				service_id.len(),
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

	/// Return and clear the first listener failure retained by implicit drop.
	pub fn take_listener_close_failure(&self) -> Option<Error> {
		lock_failure(&self.listener_close_failure).take()
	}

	/// Release the netlayer and report any listener close failure retained by
	/// implicit destruction. The borrow checker guarantees every listener has
	/// already retired before this consuming barrier can run.
	pub fn close(mut self) -> Result<()> {
		let listener_failure = self.take_listener_close_failure();
		let raw = core::mem::replace(&mut self.raw, core::ptr::null_mut());
		// SAFETY: `raw` is the netlayer handle just taken out of `self.raw`, which now holds null so `Drop` will not
		// release it again; this is its single release, and every listener has retired because each borrows the
		// netlayer.
		let release = check_onion(unsafe {
			ffi::glowcap_onion_netlayer_release(raw, core::ptr::null_mut(), 0, core::ptr::null_mut())
		});
		if let Some(error) = listener_failure {
			return match release {
				Ok(()) => Err(error),
				Err(cleanup) => Err(error.with_secondary(cleanup)),
			};
		}
		release
	}
}

impl Drop for Netlayer {
	fn drop(&mut self) {
		if !self.raw.is_null() {
			// SAFETY: `self.raw` is this `Netlayer`'s handle from `glowcap_onion_netlayer_new`, released only by
			// `close` or its `Drop`; the null check above skips a handle `close` already released, so this is its
			// single release.
			if let Err(error) = check_onion(unsafe {
				ffi::glowcap_onion_netlayer_release(self.raw, core::ptr::null_mut(), 0, core::ptr::null_mut())
			}) {
				let listener_failure = lock_failure(&self.listener_close_failure).take();
				crate::record_runtime_failure(
					crate::FailureLayer::Transport,
					"onion-netlayer-drop-release",
					listener_failure.map_or(error.clone(), |primary| primary.with_secondary(error)),
				);
			} else if let Some(error) = lock_failure(&self.listener_close_failure).take() {
				crate::record_runtime_failure(crate::FailureLayer::Transport, "onion-listener-drop-release", error);
			}
		}
	}
}

impl Listener<'_> {
	/// The version 3 service id Tor minted or restored, without its `.onion`
	/// suffix. This is the designator a partner dials, and the one to put in an
	/// `ocapn://<id>.onion` locator.
	pub fn service_id(&self) -> &str {
		// The transport refuses any id that is not 56 base32 characters, so this
		// is ASCII by construction.
		core::str::from_utf8(&self.id[..self.id_len]).unwrap_or("")
	}

	/// The key that restores this exact service, or empty when the service was
	/// restored rather than minted. Store these bytes and pass them back as
	/// [`Config::service_key`] for an onion address that survives a restart.
	pub fn service_key(&self) -> &[u8] {
		&self.key[..self.key_len]
	}

	/// Block until Tor forwards a circuit to this service.
	///
	/// The partner's claimed location is unverified here: Tor tells a hidden
	/// service nothing about who dialed it.
	pub fn accept(&self, codec: Codec, max_frame_bytes: usize) -> Result<Connection<'_>> {
		let mut raw: *mut ffi::GlowcapOnionConn = core::ptr::null_mut();
		// SAFETY: `self.raw` is this `Listener`'s handle from `Netlayer::listen`, released only by `release` (its
		// `close` or `Drop`); its `'a` borrow keeps the netlayer alive; `raw` is an out-parameter the callee fills; the
		// null error buffer with length zero asks for no error text.
		check_onion(unsafe {
			ffi::glowcap_onion_accept(
				self.raw,
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

	/// The descriptor this listener's circuits arrive on, for a caller that polls
	/// rather than blocks.
	///
	/// This is what keeps an event-driven consumer off the blocking path: register
	/// it with your reactor and call [`Listener::accept`] only once it is readable.
	/// An onion service's forward target is an ordinary local socket, which is why a
	/// real descriptor is available here rather than a synthesized readiness fd.
	///
	/// Owned by the listener: do not close it, and do not use it after the listener
	/// drops.
	pub fn readiness_fd(&self) -> Result<i32> {
		let mut fd: i32 = -1;
		// SAFETY: `self.raw` is this `Listener`'s handle from `Netlayer::listen`, released only by `release` (its
		// `close` or `Drop`); its `'a` borrow keeps the netlayer alive; `fd` is an out-parameter the callee writes; the
		// listener keeps owning the descriptor.
		check_onion(unsafe { ffi::glowcap_onion_listener_readiness_fd(self.raw, &mut fd) })?;
		Ok(fd)
	}

	/// Wait up to `timeout_ms` for [`Listener::accept`] to be able to make
	/// progress. False on timeout.
	///
	/// This is what lets an accept loop check a stop flag instead of parking
	/// forever, without closing the listener from another thread.
	pub fn wait(&self, timeout_ms: i32) -> Result<bool> {
		let mut ready: core::ffi::c_uint = 0;
		// SAFETY: `self.raw` is this `Listener`'s handle from `Netlayer::listen`, released only by `release` (its
		// `close` or `Drop`); its `'a` borrow keeps the netlayer alive; `ready` is an out-parameter the callee writes;
		// the null error buffer with length zero asks for no error text.
		check_onion(unsafe {
			ffi::glowcap_onion_listener_wait(
				self.raw,
				timeout_ms,
				&mut ready,
				core::ptr::null_mut(),
				0,
				core::ptr::null_mut(),
			)
		})?;
		Ok(ready != 0)
	}

	fn release(&mut self) -> Result<()> {
		if self.raw.is_null() {
			return Ok(());
		}
		let raw = core::mem::replace(&mut self.raw, core::ptr::null_mut());
		// SAFETY: `raw` is the listener handle just taken out of `self.raw`, which now holds null so a second `release`
		// skips it; this is its single release.
		check_onion(unsafe {
			ffi::glowcap_onion_listener_release(raw, core::ptr::null_mut(), 0, core::ptr::null_mut())
		})
	}

	/// Close explicitly and return the FFI teardown failure, if any.
	pub fn close(mut self) -> Result<()> {
		self.release()
	}
}

// SAFETY: a `Listener` owns a self-contained payload, its own control session,
// bound local endpoint, and a copy of the netlayer's allocator, and shares no
// per-handle mutable state with the netlayer or sibling handles, so moving it to
// the accepting thread and calling `accept` there touches only its own state. What
// it shares with the netlayer is thread-safe: the allocator and the
// `std.Io.Threaded` backend. Borrowing the netlayer keeps it non-`'static`, so
// callers move it into a scoped thread.
unsafe impl Send for Listener<'_> {}

impl Drop for Listener<'_> {
	fn drop(&mut self) {
		if let Err(error) = self.release() {
			let mut retained = lock_failure(&self.close_failure);
			if retained.is_none() {
				*retained = Some(error);
			}
		}
	}
}

impl Connection<'_> {
	/// Seal this connection and interrupt blocking frame operations. Drop then
	/// releases its storage after callers have joined their operation threads.
	pub fn shutdown(&self) -> Result<()> {
		// SAFETY: `self.raw` is this `Connection`'s handle from `connect` or `accept`, released only by its `Drop`; its
		// `'a` borrow keeps the backend alive.
		check_onion(unsafe { ffi::glowcap_onion_conn_shutdown(self.raw) })
	}

	/// Close explicitly, reporting a shutdown failure to the caller. FFI
	/// storage is released as this value is consumed. A release-only refusal is
	/// retained by the process diagnostic fallback because `Drop` has no caller.
	pub fn close(self) -> Result<()> {
		self.shutdown()
	}

	/// Block for one whole frame. [`ErrorKind::Closed`](crate::ErrorKind::Closed)
	/// reports a clean EOF.
	pub fn read_frame(&mut self) -> Result<Vec<u8>> {
		// SAFETY: `GlowcapManagedFrame` is a plain C struct of integers, null pointers, and an `Option` function
		// pointer; all-zero is a valid value, and the callee fills it before it is read.
		let mut frame: crate::sys::GlowcapManagedFrame = unsafe { core::mem::zeroed() };
		// SAFETY: `self.raw` is this `Connection`'s handle from `connect` or `accept`, released only by its `Drop`; its
		// `'a` borrow keeps the backend alive; `frame` is an out-parameter the callee fills; the null error buffer with
		// length zero asks for no error text.
		check_onion(unsafe {
			ffi::glowcap_onion_conn_read_frame(self.raw, &mut frame, core::ptr::null_mut(), 0, core::ptr::null_mut())
		})?;
		// SAFETY: on success `read_frame` filled `frame.bytes` and `frame.len` with a view the frame owns until
		// `glowcap_managed_frame_release` runs on the next line, and `owned_from_view` copies it first; it handles a
		// null pointer or zero length.
		let out = unsafe { crate::owned_from_view(frame.bytes, frame.len) };
		// SAFETY: `frame` was filled by the successful `read_frame` call above and is released exactly once, after the
		// copy.
		unsafe { crate::sys::glowcap_managed_frame_release(&mut frame) };
		Ok(out)
	}

	/// The descriptor this connection's bytes flow over, for a caller that polls
	/// rather than blocks. Same contract as [`Listener::readiness_fd`].
	pub fn readiness_fd(&self) -> Result<i32> {
		let mut fd: i32 = -1;
		// SAFETY: `self.raw` is this `Connection`'s handle from `connect` or `accept`, released only by its `Drop`; its
		// `'a` borrow keeps the backend alive; `fd` is an out-parameter the callee writes; the connection keeps owning
		// the descriptor.
		check_onion(unsafe { ffi::glowcap_onion_conn_readiness_fd(self.raw, &mut fd) })?;
		Ok(fd)
	}

	/// Write one frame's bytes to the partner.
	pub fn write_frame(&mut self, bytes: &[u8]) -> Result<()> {
		let f = crate::sys::GlowcapFrame {
			bytes: bytes.as_ptr(),
			len: bytes.len(),
			shape: crate::sys::FRAME_SHAPE_BYTE,
		};
		// SAFETY: `self.raw` is this `Connection`'s handle from `connect` or `accept`, released only by its `Drop`; its
		// `'a` borrow keeps the backend alive; `f` is a local `GlowcapFrame` whose `bytes` and `len` come from the
		// borrowed `bytes` slice, live for the call, and the callee reads it only during the call; the null error
		// buffer with length zero asks for no error text.
		check_onion(unsafe {
			ffi::glowcap_onion_conn_write_frame(self.raw, &f, core::ptr::null_mut(), 0, core::ptr::null_mut())
		})
	}
}

// SAFETY: as `Listener` above: a `Connection` owns its own stream plus a copy of
// the netlayer's allocator, and the state it shares is thread-safe under the
// concurrent blocking calls a borrowed handle makes off-thread.
unsafe impl Send for Connection<'_> {}

impl Drop for Connection<'_> {
	fn drop(&mut self) {
		// SAFETY: `self.raw` is this `Connection`'s handle from `connect` or `accept`, released only by its `Drop`; its
		// `'a` borrow keeps the backend alive, so the release runs once after every borrow of it ends.
		if let Err(error) = check_onion(unsafe {
			ffi::glowcap_onion_conn_release(self.raw, core::ptr::null_mut(), 0, core::ptr::null_mut())
		}) {
			crate::record_runtime_failure(crate::FailureLayer::Transport, "onion-connection-drop-release", error);
		}
	}
}
