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
/// successful raw connection, or the failure that replaced it, until that
/// transfer.
pub(crate) struct DialState {
	entries: Mutex<HashMap<usize, DialEntry>>,
	readiness: Arc<Readiness>,
}

enum DialEntry {
	Pending { abort: Option<tokio::task::AbortHandle> },
	Terminal(Result<AcceptedRaw, DialFailure>),
}

/// The bounded text of one failed dial: iroh's own account of the fault,
/// kept beside the code that classifies it. A descriptive failure allocates
/// one fixed-size block rather than growing a `String`; code-only failures
/// allocate nothing. Text past the bound is dropped at the last whole UTF-8
/// sequence that fits, and a caller's copy into a smaller buffer truncates the
/// same way, so a consumer may treat the bytes as a string on either side.
pub(crate) struct DialText {
	len: usize,
	bytes: [u8; DIAL_TEXT_BYTES],
}

impl DialText {
	const EMPTY: DialText = DialText {
		len: 0,
		bytes: [0; DIAL_TEXT_BYTES],
	};

	/// Render `args` into fresh bounded storage.
	pub(crate) fn describe(args: std::fmt::Arguments<'_>) -> DialText {
		let mut text = DialText::EMPTY;
		// The writer never reports an error: a full buffer drops the tail
		// rather than failing the format that produced it.
		let _ = std::fmt::Write::write_fmt(&mut text, args);
		text
	}

	pub(crate) fn as_str(&self) -> &str {
		// Every byte arrived through `write_str` at a char boundary.
		std::str::from_utf8(&self.bytes[..self.len]).unwrap_or("")
	}

	/// Copy the longest whole-UTF-8 prefix that fits `out_cap` bytes into
	/// `out` and report the copied count through `out_len`. A null `out`
	/// declines the text and reports zero.
	pub(crate) fn copy_to(&self, out: *mut u8, out_cap: usize, out_len: *mut usize) {
		let copied = if out.is_null() {
			0
		} else {
			char_boundary_at_most(self.as_str(), out_cap)
		};
		if copied > 0 {
			// Safety: the contract requires `out_cap` writable bytes at `out`.
			unsafe { std::ptr::copy_nonoverlapping(self.bytes.as_ptr(), out, copied) };
		}
		if !out_len.is_null() {
			// Safety: the contract requires a writable `usize` when non-null.
			unsafe { *out_len = copied };
		}
	}
}

/// The largest index at or under `limit` that is a char boundary of `s`.
/// Index zero is always one, so the walk terminates.
fn char_boundary_at_most(s: &str, limit: usize) -> usize {
	let mut end = limit.min(s.len());
	while !s.is_char_boundary(end) {
		end -= 1;
	}
	end
}

impl std::fmt::Write for DialText {
	fn write_str(&mut self, s: &str) -> std::fmt::Result {
		let room = DIAL_TEXT_BYTES - self.len;
		let take = char_boundary_at_most(s, room);
		self.bytes[self.len..self.len + take].copy_from_slice(&s.as_bytes()[..take]);
		self.len += take;
		Ok(())
	}
}

/// Why one dial failed: the classification every caller branches on, and the
/// text only a diagnostic reads. It lives in the endpoint's dial table from
/// completion until `finish_connect` removes the row, and dies with it; the
/// blocking dial never stores one, handing the text straight to its caller.
pub(crate) struct DialFailure {
	code: i32,
	// Most classifications need no prose. Keep the comparatively large bounded
	// diagnostic off the async state machine and allocate it only for failures
	// that actually have transport detail to retain.
	text: Option<Box<DialText>>,
}

impl DialFailure {
	fn code_only(code: i32) -> DialFailure {
		DialFailure { code, text: None }
	}

	fn described(code: i32, args: std::fmt::Arguments<'_>) -> DialFailure {
		DialFailure {
			code,
			text: Some(Box::new(DialText::describe(args))),
		}
	}
}

impl From<i32> for DialFailure {
	fn from(code: i32) -> DialFailure {
		DialFailure::code_only(code)
	}
}

/// Publish one failed dial's text through the caller's optional buffer. The
/// copied byte count lands in `out_text_len`: zero on success, for a pending
/// request, or when the caller passed no buffer.
fn report_text(failure: Option<&DialFailure>, out_text: *mut u8, out_text_cap: usize, out_text_len: *mut usize) {
	if let Some(text) = failure.and_then(|failure| failure.text.as_deref()) {
		text.copy_to(out_text, out_text_cap, out_text_len);
	} else if !out_text_len.is_null() {
		// Safety: the contract requires a writable `usize` when non-null.
		unsafe { *out_text_len = 0 };
	}
}

impl DialState {
	fn complete(&self, request_id: usize, result: Result<AcceptedRaw, DialFailure>) {
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
					*entry = DialEntry::Terminal(Err(DialFailure::code_only(DIAL_CANCELED)));
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
					*entry = DialEntry::Terminal(Err(DialFailure::code_only(DIAL_CANCELED)));
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
///
/// # Safety
/// `node_id` must address `node_id_len` readable bytes. When non-null,
/// `addr_hints` must address `addr_hints_len` readable bytes.
pub(crate) unsafe fn parse_target(
	node_id: *const u8,
	node_id_len: usize,
	addr_hints: *const u8,
	addr_hints_len: usize,
) -> Result<EndpointAddr, i32> {
	if node_id.is_null()
		|| (addr_hints.is_null() && addr_hints_len != 0)
		|| isize::try_from(node_id_len).is_err()
		|| isize::try_from(addr_hints_len).is_err()
	{
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
		ConnectionError::ConnectionClosed(_) | ConnectionError::ApplicationClosed(_) => DIAL_REFUSED,
		_ => DIAL_UNREACHABLE,
	}
}

/// Every iroh connect error maps onto one dial code by what an embedder may do
/// about it: retry a path fault, refuse to retry a closed endpoint or a
/// rejected handshake, reject an invalid target. Folding all of them into
/// "unreachable" once made a closed endpoint look like a transient network
/// fault, and the driver retried a dial that could never succeed.
pub(crate) fn connect_failure_code(error: &ConnectError) -> i32 {
	use iroh::endpoint::{ConnectWithOptsError, ConnectingError};
	match error {
		ConnectError::Connect { source, .. } => match source {
			ConnectWithOptsError::EndpointClosed { .. } => DIAL_CLOSED,
			ConnectWithOptsError::SelfConnect { .. } | ConnectWithOptsError::InvalidAlpn { .. } => DIAL_INVALID,
			ConnectWithOptsError::LocallyRejected { .. } => DIAL_REFUSED,
			_ => DIAL_UNREACHABLE,
		},
		ConnectError::Connecting { source, .. } => match source {
			ConnectingError::ConnectionError { source, .. } => connection_failure_code(source),
			ConnectingError::HandshakeFailure { .. } | ConnectingError::LocallyRejected { .. } => DIAL_REFUSED,
			_ => DIAL_UNREACHABLE,
		},
		ConnectError::Connection { source, .. } => connection_failure_code(source),
		_ => DIAL_UNREACHABLE,
	}
}

/// Establish the QUIC connection and its one bidirectional stream, or say
/// exactly why not. The code classifies; the text is iroh's own account, or
/// for a local deadline the deadline itself.
async fn dial_raw(
	ep: Endpoint,
	addr: EndpointAddr,
	connect_timeout: std::time::Duration,
) -> Result<AcceptedRaw, DialFailure> {
	let ms = connect_timeout.as_millis();
	let conn = match tokio::time::timeout(connect_timeout, ep.connect(addr, ALPN)).await {
		Ok(Ok(conn)) => conn,
		// `{:#}` is iroh's one-line report: the error and its source chain
		// joined by ": ", which is where the relay, the address, or the QUIC
		// close reason lives.
		Ok(Err(error)) => {
			return Err(DialFailure::described(
				connect_failure_code(&error),
				format_args!("{error:#}"),
			));
		}
		Err(_) => {
			return Err(DialFailure::described(
				DIAL_TIMEOUT,
				format_args!("no QUIC connection within {ms} ms"),
			));
		}
	};
	let (send, recv) = match tokio::time::timeout(connect_timeout, conn.open_bi()).await {
		Ok(Ok(streams)) => streams,
		Ok(Err(error)) => {
			return Err(DialFailure::described(
				DIAL_LOST,
				format_args!("connected, then the stream open failed: {error}"),
			));
		}
		Err(_) => {
			return Err(DialFailure::described(
				DIAL_TIMEOUT,
				format_args!("connected, but no bidirectional stream within {ms} ms"),
			));
		}
	};
	Ok(AcceptedRaw { conn, send, recv })
}

pub(crate) fn make_conn(ep: &GlowcapIrohEndpoint, raw: AcceptedRaw) -> Option<*mut GlowcapIrohConn> {
	let id = ep
		.next_conn_id
		.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |next| next.checked_add(1))
		.ok()?;
	Some(Box::into_raw(Box::new(GlowcapIrohConn {
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

pub(crate) fn endpoint_dials(ep: &GlowcapIrohEndpoint) -> Option<&Arc<DialState>> {
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
/// evented backend and public ABI use start/finish/cancel below. The failure
/// text is handed to the caller's buffer directly; nothing is retained.
///
/// # Safety
/// `ep` must be a live endpoint handle. Target pointers must address their
/// declared readable lengths, and non-null output pointers must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_connect_blocking(
	ep: *mut GlowcapIrohEndpoint,
	node_id: *const u8,
	node_id_len: usize,
	addr_hints: *const u8,
	addr_hints_len: usize,
	out_code: *mut i32,
	out_text: *mut u8,
	out_text_cap: usize,
	out_text_len: *mut usize,
) -> *mut GlowcapIrohConn {
	let result = catch_unwind(AssertUnwindSafe(|| -> Result<*mut GlowcapIrohConn, DialFailure> {
		if ep.is_null() {
			return Err(DIAL_INVALID.into());
		}
		let ep = unsafe { &*ep };
		let addr = unsafe { parse_target(node_id, node_id_len, addr_hints, addr_hints_len) }?;
		let raw = ep.rt.block_on(dial_raw(ep.ep.clone(), addr, ep.connect_timeout))?;
		make_conn(ep, raw).ok_or(DialFailure::code_only(DIAL_LOST))
	}));
	let (handle, failure) = match result {
		Ok(Ok(handle)) => (handle, None),
		Ok(Err(failure)) => (std::ptr::null_mut(), Some(failure)),
		Err(_) => (std::ptr::null_mut(), Some(DialFailure::code_only(DIAL_LOST))),
	};
	if !out_code.is_null() {
		unsafe { *out_code = failure.as_ref().map_or(DIAL_OK, |failure| failure.code) };
	}
	report_text(failure.as_ref(), out_text, out_text_cap, out_text_len);
	handle
}

/// Admit one outbound dial without blocking. Borrowed target bytes are parsed
/// before return; the endpoint owns the Tokio task and terminal result. The
/// bounded request table returns `DIAL_BUSY` without minting an event when full.
///
/// # Safety
/// `ep` must be a live endpoint handle. Target pointers must address their
/// declared readable lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_start_connect(
	ep: *mut GlowcapIrohEndpoint,
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
		let addr = unsafe { parse_target(node_id, node_id_len, addr_hints, addr_hints_len) }?;
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
/// the owned connection on success, or the retained failure text into the
/// caller's buffer. A pending request returns DIAL_PENDING and leaves its row.
///
/// # Safety
/// `ep` must be a live endpoint handle, `out_conn` must be writable, and
/// non-null text outputs must address their declared capacities.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_finish_connect(
	ep: *mut GlowcapIrohEndpoint,
	request_id: usize,
	out_conn: *mut *mut GlowcapIrohConn,
	out_text: *mut u8,
	out_text_cap: usize,
	out_text_len: *mut usize,
) -> i32 {
	let result = catch_unwind(AssertUnwindSafe(|| -> Result<(), DialFailure> {
		if ep.is_null() || out_conn.is_null() {
			return Err(DIAL_INVALID.into());
		}
		unsafe { *out_conn = std::ptr::null_mut() };
		let ep = unsafe { &*ep };
		let Some(dials) = ep.dials.get() else {
			return Err(DIAL_INVALID.into());
		};
		let terminal = {
			let mut entries = dials.entries.lock().unwrap();
			match entries.remove(&request_id) {
				Some(DialEntry::Terminal(result)) => result,
				Some(pending @ DialEntry::Pending { .. }) => {
					entries.insert(request_id, pending);
					return Err(DIAL_PENDING.into());
				}
				None => return Err(DIAL_INVALID.into()),
			}
		};
		let conn = make_conn(ep, terminal?).ok_or(DialFailure::code_only(DIAL_LOST))?;
		unsafe { *out_conn = conn };
		Ok(())
	}));
	let failure = match result {
		Ok(Ok(())) => None,
		Ok(Err(failure)) => Some(failure),
		Err(_) => Some(DialFailure::code_only(DIAL_LOST)),
	};
	report_text(failure.as_ref(), out_text, out_text_cap, out_text_len);
	failure.map_or(DIAL_OK, |failure| failure.code)
}

/// Cancel one admitted dial. The pending-to-canceled winner emits the request's
/// sole terminal event; canceling an already-terminal request is idempotent.
///
/// # Safety
/// `ep` must be null or a live endpoint handle. Null is refused.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_endpoint_cancel_connect(
	ep: *mut GlowcapIrohEndpoint,
	request_id: usize,
) -> i32 {
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

async fn accept_one(ep: &GlowcapIrohEndpoint) -> Option<AcceptedRaw> {
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
///
/// # Safety
/// `ep` must be a live endpoint handle and `out_code` must be writable. Null
/// pointers are refused defensively.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glowcap_iroh_sidecar_accept_timeout(
	ep: *mut GlowcapIrohEndpoint,
	timeout_ms: i32,
	out_code: *mut i32,
) -> *mut GlowcapIrohConn {
	if out_code.is_null() {
		return std::ptr::null_mut();
	}
	let result = catch_unwind(AssertUnwindSafe(|| -> Result<usize, i32> {
		if ep.is_null() || timeout_ms < 0 {
			return Err(DIAL_INVALID);
		}
		let ep = unsafe { &*ep };
		ep.rt.block_on(async {
			match tokio::time::timeout(
				std::time::Duration::from_millis(u64::try_from(timeout_ms).map_err(|_| DIAL_INVALID)?),
				accept_one(ep),
			)
			.await
			{
				Err(_) => Err(DIAL_TIMEOUT),
				Ok(None) => Err(DIAL_LOST),
				Ok(Some(raw)) => make_conn(ep, raw).map(|handle| handle as usize).ok_or(DIAL_LOST),
			}
		})
	}));
	let (handle, code) = match result {
		Ok(Ok(handle)) => (handle as *mut GlowcapIrohConn, DIAL_OK),
		Ok(Err(code)) => (std::ptr::null_mut(), code),
		Err(_) => (std::ptr::null_mut(), DIAL_LOST),
	};
	unsafe {
		*out_code = code;
	}
	handle
}
