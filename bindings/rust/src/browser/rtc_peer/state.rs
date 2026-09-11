use super::{
	events::Events,
	promise::{Cancellation, Observation},
	*,
};
use crate::{
	abi_constants::*,
	host::{HostShared, OwnedTaskRegistration},
};
use js_sys::Promise;
use std::{
	collections::{BTreeMap, VecDeque},
	future::Future,
	task::Waker,
};
use wasm_bindgen::JsValue;
use web_sys::{RtcDataChannel, RtcIceCandidateInit};

#[derive(Default, PartialEq, Eq)]
pub(super) enum Remote {
	#[default]
	Pending,
	Installing,
	Installed,
}

struct Candidate {
	value: RtcIceCandidateInit,
	bytes: usize,
	reply: oneshot::Sender<Result<(), Failure>>,
}

#[derive(Default)]
pub(super) struct State {
	pub(super) closing: bool,
	pub(super) failure: Option<Failure>,
	pub(super) remote: Remote,
	pub(super) local_started: bool,
	pub(super) signaling_finished: bool,
	pub(super) channel: Option<Channel>,
	pub(super) channel_transferred: bool,
	pub(super) channel_status: Option<Rc<Shared>>,
	pub(super) local: VecDeque<String>,
	pub(super) local_bytes: usize,
	pub(super) local_waker: Option<Waker>,
	pub(super) open_waker: Option<Waker>,
	jobs_waker: Option<Waker>,
	jobs: usize,
	monitor_running: bool,
	next_operation: u64,
	operations: BTreeMap<u64, Cancellation>,
	remote_queue: VecDeque<Candidate>,
	remote_count: usize,
	remote_bytes: usize,
	candidate_worker: bool,
}
impl State {
	pub(super) fn result(&self) -> io::Result<()> {
		self.failure.as_ref().map_or(Ok(()), |f| Err(f.error()))
	}
	pub(super) fn live(&self) -> io::Result<()> {
		self.result()?;
		if self.closing {
			Err(io::Error::new(io::ErrorKind::NotConnected, "WebRTC peer closed"))
		} else {
			Ok(())
		}
	}
	pub(super) fn wake(&mut self) {
		for waker in [&mut self.local_waker, &mut self.open_waker, &mut self.jobs_waker] {
			if let Some(waker) = waker.take() {
				waker.wake();
			}
		}
	}
}

pub(super) struct Inner {
	pub(super) host: Rc<HostShared>,
	pub(super) pc: RtcPeerConnection,
	pub(super) role: RtcRole,
	pub(super) state: RefCell<State>,
	pub(super) events: RefCell<Option<Events>>,
	pub(super) changed: tokio::sync::Notify,
}

struct Job {
	inner: Rc<Inner>,
	monitor: bool,
	_registration: OwnedTaskRegistration,
}
impl Drop for Job {
	fn drop(&mut self) {
		let mut state = self.inner.state.borrow_mut();
		if self.monitor {
			state.monitor_running = false;
		} else {
			state.jobs -= 1;
		}
		state.wake();
	}
}

impl Inner {
	pub(super) fn live(&self) -> io::Result<()> {
		Self::host_live(&self.host)?;
		self.state.borrow().live()
	}
	pub(super) fn host_live(host: &HostShared) -> io::Result<()> {
		host.guard_handle().map_err(io::Error::other)?;
		if host.closing() {
			return Err(io::Error::new(io::ErrorKind::NotConnected, "WebRTC Host closing"));
		}
		Ok(())
	}
	fn run_job(self: &Rc<Self>, work: impl Future<Output = ()> + 'static) -> io::Result<()> {
		self.spawn(false, work)
	}
	fn spawn(self: &Rc<Self>, monitor: bool, work: impl Future<Output = ()> + 'static) -> io::Result<()> {
		let registration = self.host.start_owned_task().map_err(io::Error::other)?;
		if monitor {
			self.state.borrow_mut().monitor_running = true;
		} else {
			self.state.borrow_mut().jobs += 1;
		}
		let job = Job {
			inner: self.clone(),
			monitor,
			_registration: registration,
		};
		crate::host::try_spawn_local_handle(async move {
			let _job = job;
			work.await;
		})
		.map(|_| ())
		.ok_or_else(|| io::Error::other("WebRTC operations require a running LocalSet"))
	}

	pub(super) fn monitor(self: &Rc<Self>) -> io::Result<()> {
		let inner = self.clone();
		self.spawn(true, async move {
			loop {
				let changed = inner.changed.notified();
				let closing = inner.host.close_activity();
				tokio::pin!(changed, closing);
				changed.as_mut().enable();
				closing.as_mut().enable();
				// Transfer gives the channel owner the close point after its
				// terminal frames flush, even if Host shutdown raced this wake.
				if inner.state.borrow().channel_transferred {
					return;
				}
				if inner.host.closing() {
					inner.close();
				}
				if inner.state.borrow().closing {
					// DOM callbacks only request retirement. The standing task
					// owns asynchronous close inside the Host's LocalSet.
					let channel = inner.state.borrow_mut().channel.take();
					if let Some(channel) = channel {
						let result = channel.close().await;
						inner.close_transport();
						if let Err(error) = result {
							inner
								.host
								.record_background_failure(crate::session_shared::io_err(io::Error::new(
									error.kind(),
									error.to_string(),
								)));
							inner.fail(error.kind(), error.to_string());
						}
					}
					return;
				}
				tokio::select! { () = changed => {}, () = closing => {} }
			}
		})
	}

	pub(super) fn poll_operations(&self, cx: &mut Context<'_>) -> Poll<()> {
		let mut state = self.state.borrow_mut();
		if state.jobs == 0 {
			Poll::Ready(())
		} else {
			state.jobs_waker = Some(cx.waker().clone());
			Poll::Pending
		}
	}

	pub(super) fn poll_retired(&self, cx: &mut Context<'_>) -> Poll<()> {
		let mut state = self.state.borrow_mut();
		if state.jobs == 0 && !state.monitor_running {
			Poll::Ready(())
		} else {
			state.jobs_waker = Some(cx.waker().clone());
			Poll::Pending
		}
	}

	pub(super) async fn call<T: 'static, F: Future<Output = io::Result<T>> + 'static>(
		self: &Rc<Self>,
		work: impl FnOnce(Rc<Self>) -> F + 'static,
	) -> io::Result<T> {
		self.live()?;
		let (reply, receive) = oneshot::channel();
		let inner = self.clone();
		if let Err(error) = self.run_job(async move {
			let outcome = work(inner.clone()).await;
			if let Err(error) = &outcome {
				if !inner.state.borrow().closing && !inner.host.closing() {
					inner.fail(error.kind(), error.to_string());
				}
			}
			let _ = reply.send(outcome);
		}) {
			self.fail(error.kind(), error.to_string());
			return Err(error);
		}
		let result = receive
			.await
			.map_err(|_| io::Error::other("WebRTC operation owner ended"))?;
		self.live()?;
		result
	}

	pub(super) async fn operation(&self, start: impl FnOnce(&RtcPeerConnection) -> Promise) -> io::Result<JsValue> {
		self.live()?;
		let id = {
			let mut state = self.state.borrow_mut();
			state.live()?;
			let id = state.next_operation;
			state.next_operation = id
				.checked_add(1)
				.ok_or_else(|| io::Error::other("WebRTC operation identities exhausted"))?;
			id
		};
		let mut observation = Observation::new(start(&self.pc));
		self.state
			.borrow_mut()
			.operations
			.insert(id, observation.cancellation());
		let outcome = observation.finish().await.map_err(super::super::socket::js_error);
		self.state.borrow_mut().operations.remove(&id);
		self.live()?;
		outcome
	}

	pub(super) fn wire(self: &Rc<Self>, channel: RtcDataChannel) {
		let state = self.state.borrow();
		if state.closing || state.channel_status.is_some() || channel.label() != "ocapn" {
			drop(state);
			channel.close();
			self.fail(
				io::ErrorKind::InvalidData,
				"WebRTC requires exactly one ocapn data channel",
			);
			return;
		}
		drop(state);
		let (channel, status) = data_channel_status(channel);
		let mut state = self.state.borrow_mut();
		state.channel = Some(channel);
		state.channel_status = Some(status);
		state.wake();
	}

	pub(super) fn fail(self: &Rc<Self>, kind: io::ErrorKind, message: impl Into<String>) {
		self.state
			.borrow_mut()
			.failure
			.get_or_insert_with(|| Failure(kind, message.into()));
		self.close();
	}
	pub(super) fn close(self: &Rc<Self>) {
		let (status, cancellations, graceful) = {
			let mut state = self.state.borrow_mut();
			if state.closing {
				return;
			}
			state.closing = true;
			state.local.clear();
			state.local_bytes = 0;
			while let Some(candidate) = state.remote_queue.pop_front() {
				state.remote_count -= 1;
				state.remote_bytes -= candidate.bytes;
				let _ = candidate
					.reply
					.send(Err(Failure(io::ErrorKind::NotConnected, "WebRTC peer closed".into())));
			}
			state.wake();
			let graceful =
				state.channel_transferred || state.channel_status.as_ref().is_some_and(|status| status.socket.open());
			(
				state.channel_status.clone(),
				state.operations.values().cloned().collect::<Vec<_>>(),
				graceful,
			)
		};
		if let Some(events) = self.events.borrow_mut().take() {
			events.detach(&self.pc);
		}
		if let Some(status) = status {
			status.request_close();
		}
		// RTCPeerConnection.close aborts SCTP rather than completing the data
		// channel's closing procedure. An established channel must finish its
		// bounded close barrier before its parent transport is torn down.
		// During preparation there may be no SCTP route to close gracefully.
		if !graceful {
			self.close_transport();
		}
		for cancellation in cancellations {
			cancellation.cancel();
		}
		self.changed.notify_waiters();
	}
	pub(super) fn close_transport(&self) {
		if self.pc.connection_state() != web_sys::RtcPeerConnectionState::Closed {
			self.pc.close();
		}
	}

	pub(super) fn enqueue(
		self: &Rc<Self>,
		value: RtcIceCandidateInit,
		bytes: usize,
		reply: oneshot::Sender<Result<(), Failure>>,
	) -> io::Result<()> {
		self.live()?;
		{
			let mut state = self.state.borrow_mut();
			state.live()?;
			if state.signaling_finished {
				return Err(io::Error::new(io::ErrorKind::NotConnected, "WebRTC signaling ended"));
			}
			if state.remote_count >= WEBRTC_MAX_PENDING_ICE_CANDIDATES
				|| bytes > WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES - state.remote_bytes
			{
				return Err(io::Error::new(
					io::ErrorKind::OutOfMemory,
					"WebRTC remote candidate queue exceeded",
				));
			}
			state.remote_count += 1;
			state.remote_bytes += bytes;
			state.remote_queue.push_back(Candidate { value, bytes, reply });
			if state.candidate_worker {
				self.changed.notify_waiters();
				return Ok(());
			}
			state.candidate_worker = true;
		}
		let inner = self.clone();
		if let Err(error) = self.run_job(async move {
			inner.candidates().await;
		}) {
			self.fail(error.kind(), error.to_string());
			return Err(error);
		}
		Ok(())
	}

	async fn candidates(self: Rc<Self>) {
		loop {
			let notified = self.changed.notified();
			tokio::pin!(notified);
			notified.as_mut().enable();
			let candidate = {
				let mut state = self.state.borrow_mut();
				if state.closing || state.remote_queue.is_empty() {
					state.candidate_worker = false;
					return;
				}
				if state.remote == Remote::Installed {
					state.remote_queue.pop_front()
				} else {
					None
				}
			};
			let Some(candidate) = candidate else {
				notified.await;
				continue;
			};
			let result = self
				.operation(|pc| pc.add_ice_candidate_with_opt_rtc_ice_candidate_init(Some(&candidate.value)))
				.await;
			{
				let mut state = self.state.borrow_mut();
				state.remote_count -= 1;
				state.remote_bytes -= candidate.bytes;
			}
			if let Err(error) = &result {
				if !self.state.borrow().closing && !self.host.closing() {
					self.fail(error.kind(), error.to_string());
				}
			}
			let _ = candidate
				.reply
				.send(result.map(|_| ()).map_err(|e| Failure(e.kind(), e.to_string())));
		}
	}
}
