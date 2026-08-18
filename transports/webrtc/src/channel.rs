//! The data-channel pump: event-handler wiring, the reader and drain tasks,
//! and the bounded inbound/outbound buffer operations they share with the
//! C-facing connection calls (ADR-0089).

use super::*;

#[derive(Clone)]
pub(crate) struct PeerEvents {
	pub(crate) shared: Arc<PeerShared>,
	pub(crate) runtime: Handle,
}

#[async_trait::async_trait]
impl PeerConnectionEventHandler for PeerEvents {
	async fn on_ice_candidate(&self, event: RTCPeerConnectionIceEvent) {
		let init = match event.candidate.to_json() {
			Ok(init) => init,
			Err(_) => return,
		};
		if init.candidate.is_empty() {
			return;
		}
		if let Ok(text) = serde_json::to_string(&init) {
			self.shared.local_candidates.lock().unwrap().push_back(text);
			self.shared.endpoint.signal(self.shared.id, EV_CANDIDATE);
		}
	}

	async fn on_connection_state_change(&self, state: RTCPeerConnectionState) {
		// This is the only terminal path for a peer that never opens a channel:
		// ICE can fail before any DataChannel close event exists. The once-only
		// publication path is unit-tested; forcing a real ICE timeout would make
		// the sidecar suite wait on network retry timers.
		if matches!(state, RTCPeerConnectionState::Failed | RTCPeerConnectionState::Closed) {
			publish_peer_closed(&self.shared);
		}
	}

	async fn on_data_channel(&self, dc: Arc<dyn DataChannel>) {
		let shared = self.shared.clone();
		self.runtime.spawn(async move {
			install_remote_channel(shared, dc).await;
		});
	}
}

pub(crate) async fn install_remote_channel(shared: Arc<PeerShared>, dc: Arc<dyn DataChannel>) {
	let label = match dc.label().await {
		Ok(label) => label,
		Err(_) => {
			publish_peer_closed(&shared);
			return;
		}
	};
	if label != CHANNEL_LABEL {
		// Only the `ocapn` channel is this transport. Any other label is a
		// peer-created side channel, not a CapTP byte source.
		let _ = dc.close().await;
		return;
	}
	let claimed = {
		let mut slot = shared.dc.lock().unwrap();
		if slot.is_some() {
			false
		} else {
			*slot = Some(dc.clone());
			true
		}
	};
	if claimed {
		wire_channel(dc, shared);
	} else {
		// A peer owns exactly one `ocapn` channel. A second one would interleave
		// bytes into the same inbound queue and compete for the one outbound writer,
		// so refuse it at the transport edge.
		let _ = dc.close().await;
	}
}

/// Wire one channel to the peer's blocking latches and endpoint readiness
/// surface. Used for both the offerer's created channel and the answerer's
/// received one.
pub(crate) fn wire_channel(dc: Arc<dyn DataChannel>, shared: Arc<PeerShared>) {
	let handle = shared.endpoint.runtime().handle().clone();
	handle.spawn(pump_channel(dc.clone(), shared.clone()));
	handle.spawn(drain_outbound(dc, shared));
}

pub(crate) async fn pump_channel(dc: Arc<dyn DataChannel>, shared: Arc<PeerShared>) {
	while let Some(event) = dc.poll().await {
		match event {
			DataChannelEvent::OnOpen => {
				if shared.inbound.0.lock().unwrap().closed {
					return;
				}
				{
					let mut gate = shared.open.lock().unwrap();
					if gate.closed {
						return;
					}
					gate.open = true;
				}
				shared.endpoint.signal(shared.id, EV_OPEN | EV_WRITABLE);
			}
			DataChannelEvent::OnMessage(msg) => {
				let incoming_len = msg.data.len();
				if incoming_len == 0 {
					continue;
				}
				if incoming_len > INBOUND_BUFFER_BOUND {
					publish_peer_closed(&shared);
					let _ = dc.close().await;
					return;
				}
				if !await_inbound_room(&shared.inbound, &shared.drained, incoming_len).await {
					return;
				}
				let (lock, cvar) = &*shared.inbound;
				lock.lock().unwrap().buf.extend(msg.data.iter().copied());
				cvar.notify_all();
				shared.endpoint.signal(shared.id, EV_READABLE);
			}
			DataChannelEvent::OnBufferedAmountLow => {}
			DataChannelEvent::OnClose | DataChannelEvent::OnClosing | DataChannelEvent::OnError => {
				publish_peer_closed(&shared);
				return;
			}
			DataChannelEvent::OnBufferedAmountHigh => {}
		}
	}
	publish_peer_closed(&shared);
}

/// Move C-admitted writes through the async WebRTC API without parking the
/// caller's reactor thread. `queued_bytes` includes each in-flight batch until
/// the send finishes, so the sidecar bound covers both queued and active send
/// storage.
pub(crate) async fn drain_outbound(dc: Arc<dyn DataChannel>, shared: Arc<PeerShared>) {
	loop {
		let mut batch = loop {
			let next = {
				let mut state = shared.outbound.lock().unwrap();
				if state.closed {
					return;
				}
				if state.buf.is_empty() {
					None
				} else {
					Some(std::mem::take(&mut state.buf))
				}
			};
			if let Some(batch) = next {
				break batch;
			}
			shared.outbound_ready.notified().await;
		};

		while !batch.is_empty() {
			let len = batch.len().min(STEADY_BUFFER_BYTES);
			let bytes = batch.split_to(len);
			if dc.send(bytes).await.is_err() {
				publish_peer_closed(&shared);
				return;
			}
			let writable = {
				let mut state = shared.outbound.lock().unwrap();
				state.queued_bytes = state.queued_bytes.saturating_sub(len);
				state.queued_bytes < OUTBOUND_BUFFER_BOUND
			};
			if writable {
				shared.endpoint.signal(shared.id, EV_WRITABLE);
			}
		}
	}
}

/// Park until the reader has taken enough out of `inbound` to leave room for the
/// whole incoming message under `INBOUND_BUFFER_BOUND`. Returns false once the
/// channel has closed, or when a single message is larger than the inbound
/// budget and cannot be admitted without breaking the bound.
///
/// The `webrtc` 0.20 channel pump awaits this before appending the message it
/// just polled and before polling another one. That serialization is the
/// invariant which makes the check and later append one-message-at-a-time:
/// parking here stops draining the crate's event stream, and the SCTP receive
/// window bounds the bytes the far peer can have in flight.
pub(crate) async fn await_inbound_room(
	inbound: &Arc<(Mutex<Inbound>, Condvar)>,
	drained: &Notify,
	incoming_len: usize,
) -> bool {
	if incoming_len > INBOUND_BUFFER_BOUND {
		return false;
	}
	loop {
		{
			let (lock, _) = &**inbound;
			let guard = lock.lock().unwrap();
			if guard.closed {
				return false;
			}
			if guard.buf.len() <= INBOUND_BUFFER_BOUND - incoming_len {
				return true;
			}
		}
		// `notify_one` leaves a permit behind when nothing is parked yet, so a
		// reader that drains between the check above and this await still wakes
		// us.
		drained.notified().await;
	}
}

/// Close the inbound staging area and wake every blocking or async waiter.
/// Returns true only for the first terminal transition, so `EV_CLOSED` is
/// emitted once.
pub(crate) fn mark_peer_closed(shared: &PeerShared) -> bool {
	let first = {
		let mut state = shared.open.lock().unwrap();
		let first = !state.closed;
		state.closed = true;
		first
	};
	{
		let (lock, cvar) = &*shared.inbound;
		let mut state = lock.lock().unwrap();
		state.closed = true;
		cvar.notify_all();
	}
	shared.drained.notify_waiters();
	shared.drained.notify_one();
	shared.outbound.lock().unwrap().closed = true;
	shared.outbound_ready.notify_waiters();
	shared.outbound_ready.notify_one();
	first
}

/// Publish the peer's terminal readiness exactly once, regardless of whether
/// close arrives from the channel poller, a failed send, explicit close, or
/// handle release. `OpenGate.closed` is the single terminal authority.
pub(crate) fn publish_peer_closed(shared: &PeerShared) {
	if mark_peer_closed(shared) {
		shared.endpoint.signal(shared.id, EV_CLOSED);
	}
}

/// Copy a contiguous prefix out of the inbound staging deque. When a burst drains,
/// return its excess capacity so one slow-reader episode does not pin the
/// 1 MiB high-water mark for the peer's lifetime.
pub(crate) fn take_inbound(state: &mut Inbound, dest: &mut [u8]) -> usize {
	let n = state.buf.len().min(dest.len());
	let (front, back) = state.buf.as_slices();
	let from_front = front.len().min(n);
	dest[..from_front].copy_from_slice(&front[..from_front]);
	if from_front < n {
		dest[from_front..n].copy_from_slice(&back[..n - from_front]);
	}
	state.buf.drain(..n);
	if state.buf.is_empty() && state.buf.capacity() > STEADY_BUFFER_BYTES {
		state.buf.shrink_to(STEADY_BUFFER_BYTES);
	}
	n
}

/// Admit as much of one try-write as currently fits. Returning a prefix instead
/// of rejecting every slice larger than the bound guarantees that a caller which
/// advances by the returned count can always make progress once the drain frees
/// room.
pub(crate) fn enqueue_outbound(state: &mut Outbound, bytes: &[u8]) -> isize {
	if state.closed {
		return ERR as isize;
	}
	if bytes.is_empty() {
		return 0;
	}
	let room = OUTBOUND_BUFFER_BOUND.saturating_sub(state.queued_bytes);
	if room == 0 {
		return WOULD_BLOCK as isize;
	}
	let accepted = room.min(bytes.len());
	state.buf.extend_from_slice(&bytes[..accepted]);
	state.queued_bytes += accepted;
	accepted as isize
}

/// Start the crate-level close without waiting on the caller's thread. Terminal
/// state and readiness are published before this runs, so the task only performs
/// WebRTC teardown; it owns an `Arc` to the connection until that finishes.
pub(crate) fn close_peer_async(peer: &PancakeWebrtcPeer) {
	if peer.shared.close_started.swap(true, Ordering::AcqRel) {
		return;
	}
	let pc = peer.pc.clone();
	let permit = peer.shared.endpoint.close_tasks.acquire();
	peer.shared.endpoint.runtime().handle().spawn(async move {
		if tokio::time::timeout(PEER_CLOSE_TIMEOUT, pc.close())
			.await
			.is_ok_and(|result| result.is_ok())
		{
			permit.succeed();
		}
	});
}
