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
			let admitted = self.shared.local_candidates.lock().unwrap().admit(text);
			if admitted {
				self.shared.endpoint.signal(self.shared.id, EV_CANDIDATE);
			} else {
				publish_peer_failed(&self.shared);
			}
		}
	}

	async fn on_connection_state_change(&self, state: RTCPeerConnectionState) {
		// This is the only terminal path for a peer that never opens a channel:
		// ICE can fail before any DataChannel close event exists. The once-only
		// publication path is unit-tested; forcing a real ICE timeout would make
		// the sidecar suite wait on network retry timers.
		match state {
			RTCPeerConnectionState::Failed => publish_peer_failed(&self.shared),
			RTCPeerConnectionState::Closed => publish_peer_closed(&self.shared),
			_ => {}
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
			publish_peer_failed(&shared);
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
				if incoming_len > MAX_PACKET_BYTES {
					publish_peer_failed(&shared);
					let _ = dc.close().await;
					return;
				}
				if !await_inbound_room(&shared.inbound, &shared.drained, incoming_len).await {
					return;
				}
				let (lock, cvar) = &*shared.inbound;
				{
					let mut inbound = lock.lock().unwrap();
					inbound.queued_bytes += incoming_len;
					inbound.packets.push_back(msg.data);
				}
				cvar.notify_all();
				shared.endpoint.signal(shared.id, EV_READABLE);
			}
			DataChannelEvent::OnBufferedAmountLow => {}
			DataChannelEvent::OnClose | DataChannelEvent::OnClosing => {
				publish_peer_closed(&shared);
				return;
			}
			DataChannelEvent::OnError => {
				publish_peer_failed(&shared);
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
		let packet = loop {
			let next = {
				let mut state = shared.outbound.lock().unwrap();
				if state.closed {
					return;
				}
				state.packets.pop_front()
			};
			if let Some(packet) = next {
				break packet;
			}
			shared.outbound_ready.notified().await;
		};

		let len = packet.len();
		if dc.send(packet).await.is_err() {
			publish_peer_failed(&shared);
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
	if incoming_len > MAX_PACKET_BYTES || incoming_len > INBOUND_BUFFER_BOUND {
		return false;
	}
	loop {
		{
			let (lock, _) = &**inbound;
			let guard = lock.lock().unwrap();
			if guard.closed {
				return false;
			}
			if guard.queued_bytes <= INBOUND_BUFFER_BOUND - incoming_len {
				return true;
			}
		}
		// `notify_one` leaves a permit behind when nothing is parked yet, so a
		// reader that drains between the check above and this await still wakes
		// us.
		drained.notified().await;
	}
}

/// Close the peer and wake every blocking or async waiter. `failed` is read-side
/// terminal cause only: orderly close returns EOF, failure returns `ERR`.
/// Returns true only for the first transition, so `EV_CLOSED` is emitted once.
pub(crate) fn mark_peer_closed(shared: &PeerShared, failed: bool) -> bool {
	let (first, terminal_failed) = {
		let mut state = shared.open.lock().unwrap();
		let first = !state.closed;
		if first {
			state.closed = true;
			state.failed = failed;
		}
		(first, state.failed)
	};
	{
		let (lock, cvar) = &*shared.inbound;
		let mut state = lock.lock().unwrap();
		state.failed = terminal_failed;
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
/// handle release. `OpenGate.closed` owns once-only publication.
pub(crate) fn publish_peer_closed(shared: &PeerShared) {
	if mark_peer_closed(shared, false) {
		shared.endpoint.signal(shared.id, EV_CLOSED);
	}
}

pub(crate) fn publish_peer_failed(shared: &PeerShared) {
	if mark_peer_closed(shared, true) {
		shared.endpoint.signal(shared.id, EV_CLOSED);
		close_shared_async(shared);
	}
}

/// Copy exactly one inbound packet. A too-small destination leaves the packet
/// queued for retry, because splitting it would change the DataChannel message
/// boundary the Host profile relies on.
pub(crate) fn take_inbound_packet(state: &mut Inbound, dest: &mut [u8]) -> isize {
	let packet = match state.packets.front() {
		Some(packet) => packet,
		None => return 0,
	};
	if packet.len() > dest.len() {
		return BUFFER_TOO_SMALL as isize;
	}
	let packet = state.packets.pop_front().unwrap();
	dest[..packet.len()].copy_from_slice(&packet);
	state.queued_bytes = state.queued_bytes.saturating_sub(packet.len());
	packet.len() as isize
}

pub(crate) fn terminal_read_result(state: &Inbound) -> isize {
	if state.failed {
		ERR as isize
	} else if state.closed {
		0
	} else {
		WOULD_BLOCK as isize
	}
}

/// Admit one whole packet. A prefix would become a distinct DataChannel message,
/// so a packet either enters complete or the caller retries it unchanged.
pub(crate) fn enqueue_outbound(state: &mut Outbound, bytes: &[u8]) -> isize {
	if state.closed {
		return ERR as isize;
	}
	if bytes.is_empty() {
		return 0;
	}
	if bytes.len() > MAX_PACKET_BYTES {
		return BUFFER_TOO_SMALL as isize;
	}
	let room = OUTBOUND_BUFFER_BOUND.saturating_sub(state.queued_bytes);
	if room < bytes.len() {
		return WOULD_BLOCK as isize;
	}
	state.packets.push_back(BytesMut::from(bytes));
	state.queued_bytes += bytes.len();
	bytes.len() as isize
}

/// Start the crate-level close without waiting on the caller's thread. Terminal
/// state and readiness are published before this runs, so the task only performs
/// WebRTC teardown; it owns an `Arc` to the connection until that finishes.
pub(crate) fn close_peer_async(peer: &GlowcapWebrtcPeer) {
	close_shared_async(&peer.shared);
}

pub(crate) fn close_shared_async(shared: &PeerShared) {
	let pc = shared.pc.lock().unwrap().as_ref().and_then(|pc| pc.upgrade());
	let Some(pc) = pc else {
		return;
	};
	if shared.close_started.swap(true, Ordering::AcqRel) {
		return;
	}
	let permit = shared.endpoint.close_tasks.acquire();
	shared.endpoint.runtime().handle().spawn(async move {
		if tokio::time::timeout(PEER_CLOSE_TIMEOUT, pc.close())
			.await
			.is_ok_and(|result| result.is_ok())
		{
			permit.succeed();
		}
	});
}
