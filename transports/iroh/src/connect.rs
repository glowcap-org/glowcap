//! Connection establishment: the dial state machine (blocking and
//! start/finish/cancel), the acceptor stash, and the failure-code mapping
//! every establishment path reports through.

use super::*;

/// The acceptor side of an endpoint's scale surface: connections the acceptor
/// task has pulled off the wire, waiting for `endpoint_try_accept` to claim
/// them. Built (and the task spawned) by `endpoint_set_nonblocking_accept`.
pub(crate) struct AcceptState {
	pub(crate) ready: Mutex<VecDeque<AcceptedRaw>>,
}

/// One accepted connection the acceptor task produced but the loop has not yet
/// claimed: the QUIC connection and its first bidirectional stream, carried by
/// value (every part is `Send`) so the task never holds a raw handle pointer.
pub(crate) struct AcceptedRaw {
	pub(crate) conn: Connection,
	pub(crate) send: SendStream,
	pub(crate) recv: RecvStream,
}

/// One endpoint's in-flight and completed outbound dials. A request id exists
/// in exactly one state until `finish_connect` consumes it. The endpoint owns a
/// successful raw connection until that transfer.
pub(crate) struct DialState {
	entries: Mutex<HashMap<usize, DialEntry>>,
	readiness: Arc<Readiness>,
}

enum DialEntry {
	Pending { abort: Option<tokio::task::AbortHandle> },
	Terminal(Result<AcceptedRaw, i32>),
}

impl DialState {
	fn complete(&self, request_id: usize, result: Result<AcceptedRaw, i32>) {
		let publish = {
			let mut entries = self.entries.lock().unwrap();
			match entries.get_mut(&request_id) {
				Some(entry @ DialEntry::Pending { .. }) => {
					*entry = DialEntry::Terminal(result);
					true
				}
				Some(DialEntry::Terminal(_)) | None => false,
			}
		};
		if publish {
			self.readiness.signal(request_id, EV_CONNECT);
		}
	}

	fn cancel(&self, request_id: usize) -> bool {
		let (found, publish, abort) = {
			let mut entries = self.entries.lock().unwrap();
			match entries.get_mut(&request_id) {
				Some(entry @ DialEntry::Pending { .. }) => {
					let abort = match entry {
						DialEntry::Pending { abort } => abort.take(),
						DialEntry::Terminal(_) => unreachable!(),
					};
					*entry = DialEntry::Terminal(Err(DIAL_CANCELED));
					(true, true, abort)
				}
				Some(DialEntry::Terminal(_)) => (true, false, None),
				None => (false, false, None),
			}
		};
		if let Some(abort) = abort {
			abort.abort();
		}
		if publish {
			self.readiness.signal(request_id, EV_CONNECT);
		}
		found
	}

	pub(crate) fn cancel_all(&self) {
		let mut signals = Vec::new();
		let mut aborts = Vec::new();
		{
			let mut entries = self.entries.lock().unwrap();
			for (request_id, entry) in entries.iter_mut() {
				if let DialEntry::Pending { abort } = entry {
					if let Some(abort) = abort.take() {
						aborts.push(abort);
					}
					*entry = DialEntry::Terminal(Err(DIAL_CANCELED));
					signals.push(*request_id);
				}
			}
		}
		for abort in aborts {
			abort.abort();
		}
		for request_id in signals {
			self.readiness.signal(request_id, EV_CONNECT);
		}
	}
}

/// Parse the borrowed public target representation into an owned iroh address.
pub(crate) fn parse_target(
	node_id: *const u8,
	node_id_len: usize,
	addr_hints: *const u8,
	addr_hints_len: usize,
) -> Result<EndpointAddr, i32> {
	if node_id.is_null() || (addr_hints.is_null() && addr_hints_len != 0) {
		return Err(DIAL_INVALID);
	}
	let id_str =
		std::str::from_utf8(unsafe { std::slice::from_raw_parts(node_id, node_id_len) }).map_err(|_| DIAL_INVALID)?;
	let id = EndpointId::from_str(id_str).map_err(|_| DIAL_INVALID)?;
	let mut addr = EndpointAddr::new(id);
	if addr_hints_len > 0 {
		let hints = std::str::from_utf8(unsafe { std::slice::from_raw_parts(addr_hints, addr_hints_len) })
			.map_err(|_| DIAL_INVALID)?;
		for hint in hints.split(',') {
			let hint = hint.trim();
			if hint.is_empty() {
				continue;
			}
			let sock = SocketAddr::from_str(hint).map_err(|_| DIAL_INVALID)?;
			addr = addr.with_ip_addr(sock);
		}
	}
	Ok(addr)
}

pub(crate) fn connection_failure_code(error: &ConnectionError) -> i32 {
	match error {
		ConnectionError::TimedOut => DIAL_TIMEOUT,
		_ => DIAL_UNREACHABLE,
	}
}

pub(crate) fn connect_failure_code(error: &ConnectError) -> i32 {
	match error {
		ConnectError::Connection { source, .. } => connection_failure_code(source),
		_ => DIAL_UNREACHABLE,
	}
}

async fn dial_raw(ep: Endpoint, addr: EndpointAddr, connect_timeout: std::time::Duration) -> Result<AcceptedRaw, i32> {
	let conn = match tokio::time::timeout(connect_timeout, ep.connect(addr, ALPN)).await {
		Ok(Ok(conn)) => conn,
		Ok(Err(error)) => return Err(connect_failure_code(&error)),
		Err(_) => return Err(DIAL_TIMEOUT),
	};
	let (send, recv) = match tokio::time::timeout(connect_timeout, conn.open_bi()).await {
		Ok(Ok(streams)) => streams,
		Ok(Err(_)) => return Err(DIAL_LOST),
		Err(_) => return Err(DIAL_TIMEOUT),
	};
	Ok(AcceptedRaw { conn, send, recv })
}

pub(crate) fn make_conn(ep: &PancakeIrohEndpoint, raw: AcceptedRaw) -> Option<*mut PancakeIrohConn> {
	let id = ep
		.next_conn_id
		.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |next| next.checked_add(1))
		.ok()?;
	Some(Box::into_raw(Box::new(PancakeIrohConn {
		id,
		rt: ep.rt.handle().clone(),
		conn: raw.conn,
		send: Mutex::new(Some(raw.send)),
		recv: Mutex::new(Some(raw.recv)),
		nonblocking_transition: Mutex::new(()),
		nb: OnceLock::new(),
		nb_tasks: OnceLock::new(),
		writers: ep.writers.clone(),
	})))
}

pub(crate) fn endpoint_dials(ep: &PancakeIrohEndpoint) -> Option<&Arc<DialState>> {
	if ep.dials.get().is_none() {
		let readiness = endpoint_readiness(ep)?.clone();
		let _ = ep.dials.set(Arc::new(DialState {
			entries: Mutex::new(HashMap::new()),
			readiness,
		}));
	}
	ep.dials.get()
}

/// Deliberately blocking convenience for the explicit blocking resident. The
/// evented backend and public ABI use start/finish/cancel below.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_connect_blocking(
	ep: *mut PancakeIrohEndpoint,
	node_id: *const u8,
	node_id_len: usize,
	addr_hints: *const u8,
	addr_hints_len: usize,
	out_code: *mut i32,
) -> *mut PancakeIrohConn {
	let result = catch_unwind(AssertUnwindSafe(|| -> Result<*mut PancakeIrohConn, i32> {
		if ep.is_null() {
			return Err(DIAL_INVALID);
		}
		let ep = unsafe { &*ep };
		let addr = parse_target(node_id, node_id_len, addr_hints, addr_hints_len)?;
		let raw = ep.rt.block_on(dial_raw(ep.ep.clone(), addr, ep.connect_timeout))?;
		make_conn(ep, raw).ok_or(DIAL_LOST)
	}));
	let (handle, code) = match result {
		Ok(Ok(handle)) => (handle, DIAL_OK),
		Ok(Err(code)) => (std::ptr::null_mut(), code),
		Err(_) => (std::ptr::null_mut(), DIAL_LOST),
	};
	if !out_code.is_null() {
		unsafe { *out_code = code };
	}
	handle
}

/// Admit one outbound dial without blocking. Borrowed target bytes are parsed
/// before return; the endpoint owns the Tokio task and terminal result. The
/// bounded request table returns `DIAL_BUSY` without minting an event when full.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_start_connect(
	ep: *mut PancakeIrohEndpoint,
	request_id: usize,
	node_id: *const u8,
	node_id_len: usize,
	addr_hints: *const u8,
	addr_hints_len: usize,
) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| -> Result<(), i32> {
		if ep.is_null() || request_id == 0 {
			return Err(DIAL_INVALID);
		}
		let ep = unsafe { &*ep };
		let addr = parse_target(node_id, node_id_len, addr_hints, addr_hints_len)?;
		let dials = endpoint_dials(ep).ok_or(DIAL_LOST)?.clone();
		{
			let mut entries = dials.entries.lock().unwrap();
			if entries.contains_key(&request_id) {
				return Err(DIAL_INVALID);
			}
			if entries.len() >= DIAL_ADMISSION_BOUND {
				return Err(DIAL_BUSY);
			}
			entries.insert(request_id, DialEntry::Pending { abort: None });
		}
		let task_dials = dials.clone();
		let endpoint = ep.ep.clone();
		let timeout = ep.connect_timeout;
		let task = ep.rt.spawn(async move {
			let result = dial_raw(endpoint, addr, timeout).await;
			task_dials.complete(request_id, result);
		});
		let abort = task.abort_handle();
		drop(task);
		let should_abort = {
			let mut entries = dials.entries.lock().unwrap();
			match entries.get_mut(&request_id) {
				Some(DialEntry::Pending { abort: slot }) => {
					*slot = Some(abort.clone());
					false
				}
				Some(DialEntry::Terminal(_)) | None => true,
			}
		};
		if should_abort {
			abort.abort();
		}
		Ok(())
	}));
	match result {
		Ok(Ok(())) => DIAL_OK,
		Ok(Err(code)) => code,
		Err(_) => DIAL_LOST,
	}
}

/// Consume one terminal dial result. Returns the dial classification and writes
/// the owned connection on success. A pending request returns DIAL_PENDING.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_finish_connect(
	ep: *mut PancakeIrohEndpoint,
	request_id: usize,
	out_conn: *mut *mut PancakeIrohConn,
) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		if ep.is_null() || out_conn.is_null() {
			return DIAL_INVALID;
		}
		unsafe { *out_conn = std::ptr::null_mut() };
		let ep = unsafe { &*ep };
		let Some(dials) = ep.dials.get() else {
			return DIAL_INVALID;
		};
		let terminal = {
			let mut entries = dials.entries.lock().unwrap();
			match entries.remove(&request_id) {
				Some(DialEntry::Terminal(result)) => result,
				Some(pending @ DialEntry::Pending { .. }) => {
					entries.insert(request_id, pending);
					return DIAL_PENDING;
				}
				None => return DIAL_INVALID,
			}
		};
		match terminal {
			Ok(raw) => {
				if let Some(conn) = make_conn(ep, raw) {
					unsafe { *out_conn = conn };
					DIAL_OK
				} else {
					DIAL_LOST
				}
			}
			Err(code) => code,
		}
	}));
	result.unwrap_or(DIAL_LOST)
}

/// Cancel one admitted dial. The pending-to-canceled winner emits the request's
/// sole terminal event; canceling an already-terminal request is idempotent.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_endpoint_cancel_connect(ep: *mut PancakeIrohEndpoint, request_id: usize) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| {
		if ep.is_null() || request_id == 0 {
			return DIAL_INVALID;
		}
		let ep = unsafe { &*ep };
		match ep.dials.get() {
			Some(dials) if dials.cancel(request_id) => DIAL_OK,
			_ => DIAL_INVALID,
		}
	}));
	result.unwrap_or(DIAL_LOST)
}

async fn accept_one(ep: &PancakeIrohEndpoint) -> Option<AcceptedRaw> {
	loop {
		let incoming = ep.ep.accept().await?;
		let Ok(accepting) = incoming.accept() else {
			// Unsolicited or malformed datagrams are routine; keep accepting.
			continue;
		};
		let Ok(conn) = accepting.await else {
			continue;
		};
		// Bound the stream accept: a dialer that opens the QUIC connection but
		// never its bidirectional stream is dropped instead of holding the
		// acceptor. A stalled or failed accept keeps serving the next incoming.
		let Ok(Ok((send, recv))) = tokio::time::timeout(ep.connect_timeout, conn.accept_bi()).await else {
			continue;
		};
		return Some(AcceptedRaw { conn, send, recv });
	}
}

/// Wait at most `timeout_ms` for a partner connection and first bidirectional
/// stream, returning an owned connection handle or null with an exact dial code.
/// Timeout is distinct from endpoint close so the resident can retry only the
/// former. A negative timeout is invalid. This is the resident listener's
/// private bounded primitive; it never arms or drains the endpoint readiness
/// queue.
#[no_mangle]
pub extern "C" fn pancake_iroh_sidecar_accept_timeout(
	ep: *mut PancakeIrohEndpoint,
	timeout_ms: i32,
	out_code: *mut i32,
) -> *mut PancakeIrohConn {
	if out_code.is_null() {
		return std::ptr::null_mut();
	}
	let result = catch_unwind(AssertUnwindSafe(|| -> Result<usize, i32> {
		if ep.is_null() || timeout_ms < 0 {
			return Err(DIAL_INVALID);
		}
		let ep = unsafe { &*ep };
		ep.rt.block_on(async {
			match tokio::time::timeout(std::time::Duration::from_millis(timeout_ms as u64), accept_one(ep)).await {
				Err(_) => Err(DIAL_TIMEOUT),
				Ok(None) => Err(DIAL_LOST),
				Ok(Some(raw)) => make_conn(ep, raw).map(|handle| handle as usize).ok_or(DIAL_LOST),
			}
		})
	}));
	let (handle, code) = match result {
		Ok(Ok(handle)) => (handle as *mut PancakeIrohConn, DIAL_OK),
		Ok(Err(code)) => (std::ptr::null_mut(), code),
		Err(_) => (std::ptr::null_mut(), DIAL_LOST),
	};
	unsafe {
		*out_code = code;
	}
	handle
}
