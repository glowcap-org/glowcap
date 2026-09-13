use super::*;

impl Stream {
	/// The far end's node id, as QUIC proved it: this connection completed only
	/// because the peer held the secret for this key. `None` when the
	/// connection is gone or the handshake proved nothing.
	///
	/// This is the fact a session is otherwise missing. glowcap cannot see it —
	/// it did not open this connection — so whoever did passes it on with
	/// [`Session::bind_verified_channel_key`], which the accept and dial paths
	/// below do for every session this module establishes.
	pub(super) fn remote_node_id(&self) -> Option<String> {
		let mut buf = [0u8; 64];
		let mut len: usize = 0;
		let code = unsafe {
			ffi::glowcap_iroh_conn_remote_node_id(
				self.conn.as_ref().expect("live iroh stream").0,
				buf.as_mut_ptr(),
				buf.len(),
				&mut len,
			)
		};
		if code != crate::abi_constants::OK {
			return None;
		}
		Some(String::from_utf8_lossy(&buf[..len]).into_owned())
	}

	pub(super) fn new(
		conn: *mut GlowcapIrohConn,
		iloop: Arc<IrohLoop>,
		owned_netlayer: Option<Netlayer>,
		owns_loop: bool,
	) -> Stream {
		let key = unsafe { ffi::glowcap_iroh_conn_id(conn) };
		Stream {
			conn: Some(ConnPtr(conn)),
			key,
			registered: true,
			iloop,
			owns_loop,
			owned_netlayer,
		}
	}

	/// Dial an iroh partner by endpoint id and direct-address hints, returning the
	/// byte stream the [`Session`] driver carries the
	/// session over. The local endpoint is ephemeral, created with the caller's
	/// chosen [`Reachability`] (no default), and released with the stream.
	pub async fn connect(node_id: &str, direct_addresses: &str, reachability: Reachability) -> Result<Stream> {
		let netlayer = Netlayer::new(Config::new(reachability)).await?;
		netlayer.connect_owned(node_id, direct_addresses).await
	}

	/// Tear down this stream and, for a dialer, its private endpoint. The
	/// readiness loop is joined before the connection is released, and the
	/// endpoint release task is awaited before this future completes.
	pub async fn close(self) -> Result<()> {
		let mut this = self;
		let conn = this.conn.take();
		let key = this.key;
		let iloop = Arc::clone(&this.iloop);
		let owns_loop = this.owns_loop;
		let owned_netlayer = this.owned_netlayer.take();

		let loop_result = if owns_loop {
			iloop.shutdown_and_join().await
		} else {
			Ok(())
		};
		if this.registered {
			iloop.unregister(key);
			this.registered = false;
		}
		// The connection must be gone before an owned endpoint can be released.
		drop(conn);
		let release_result = match owned_netlayer {
			Some(netlayer) => netlayer.release().await,
			None => Ok(()),
		};
		match loop_result {
			Ok(()) => release_result,
			Err(primary) => Err(crate::retain_cleanup_failure(primary, release_result)),
		}
	}
}

impl Drop for Stream {
	fn drop(&mut self) {
		if self.owns_loop {
			// The dialer owns the loop and netlayer: stop the dispatcher so it
			// wakes its waiters and drops its netlayer `Arc`. The endpoint is
			// released once both this stream and the task have dropped their Arc.
			self.iloop.shutdown();
		}
		// Remove the routing entry on every path so an endpoint teardown can wait
		// for the last connection, including a dialer's private loop slot.
		if self.registered {
			self.iloop.unregister(self.key);
			self.registered = false;
		}
		drop(self.conn.take());
		// Leave the fields to Rust's declaration-order drop: ConnPtr is released
		// before the owned endpoint Arc, so the fallback cannot release an
		// endpoint while its connection is still live.
	}
}

impl AsyncRead for Stream {
	fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
		let me = self.get_mut();
		loop {
			let dst = buf.initialize_unfilled();
			if dst.is_empty() {
				return Poll::Ready(Ok(())); // the caller's buffer is full
			}
			let mut count: usize = 0;
			let rc = unsafe {
				ffi::glowcap_iroh_conn_try_read(
					me.conn.as_ref().expect("live iroh stream").0,
					dst.as_mut_ptr(),
					dst.len(),
					&mut count,
				)
			};
			if rc == sys::WOULD_BLOCK {
				// Nothing buffered yet: park on this connection's readiness. A
				// missing/closed slot means the connection was torn down, a clean
				// EOF (zero bytes filled).
				let mut st = lock_iroh(&me.iloop.state, "iroh-loop-state-lock-poison");
				match st.conns.get_mut(&me.key) {
					None => return Poll::Ready(Ok(())),
					Some(slot) if slot.closed => return Poll::Ready(Ok(())),
					Some(slot) if slot.readable => {
						slot.readable = false;
						continue; // an edge arrived first; re-read before parking
					}
					Some(slot) => {
						slot.read_waker = Some(cx.waker().clone());
						return Poll::Pending;
					}
				}
			}
			if rc == sys::ERR_CLOSED {
				return Poll::Ready(Ok(())); // clean end of stream
			}
			if rc != sys::OK {
				return Poll::Ready(Err(io::Error::other(format!("iroh try_read failed (code {rc})"))));
			}
			buf.advance(count);
			return Poll::Ready(Ok(()));
		}
	}
}

impl AsyncWrite for Stream {
	fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, src: &[u8]) -> Poll<io::Result<usize>> {
		let me = self.get_mut();
		if src.is_empty() {
			return Poll::Ready(Ok(0));
		}
		loop {
			let mut count: usize = 0;
			let rc = unsafe {
				ffi::glowcap_iroh_conn_try_write(
					me.conn.as_ref().expect("live iroh stream").0,
					src.as_ptr(),
					src.len(),
					&mut count,
				)
			};
			if rc == sys::WOULD_BLOCK {
				// No byte fit: park on writability and retry this slice after the
				// next writable record.
				let mut st = lock_iroh(&me.iloop.state, "iroh-loop-state-lock-poison");
				match st.conns.get_mut(&me.key) {
					None => return Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, "iroh session closed"))),
					Some(slot) if slot.closed => {
						return Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, "iroh session closed")));
					}
					Some(slot) if slot.writable => {
						slot.writable = false;
						continue;
					}
					Some(slot) => {
						slot.write_waker = Some(cx.waker().clone());
						return Poll::Pending;
					}
				}
			}
			if rc != sys::OK {
				return Poll::Ready(Err(io::Error::other(format!("iroh try_write failed (code {rc})"))));
			}
			return Poll::Ready(Ok(count));
		}
	}

	fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		// Writes go straight to the sidecar in `poll_write`; nothing is buffered
		// here to flush.
		Poll::Ready(Ok(()))
	}

	fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		Poll::Ready(Ok(()))
	}
}
