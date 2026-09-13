//! One browser peer connection, its single reliable OCapN data channel, and
//! bounded signaling work. The application supplies its signaling authority.
mod events;
mod promise;
mod signal;
mod state;

use super::{Failure, Shared, data_channel_status};
use crate::{Channel, ChannelClose, Host};
use state::{Inner, Remote, State};
use std::{
	cell::RefCell,
	future::poll_fn,
	io,
	rc::Rc,
	task::{Context, Poll},
};
use tokio::sync::oneshot;
use web_sys::{RtcConfiguration, RtcPeerConnection, RtcSdpType, RtcSessionDescriptionInit};

/// Whether this connection creates or answers the SDP offer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RtcRole {
	Offerer,
	Answerer,
}

/// Unadmitted WebRTC resource ownership. Dropping it closes the peer and wakes
/// its pending operations. `close` observes their retirement; `into_channel`
/// transfers that barrier to a Channel, then its admitted Session. Methods run
/// inside the Host's LocalSet. The Host owns admitted SDP transitions and ICE
/// operations even when their observers are dropped. The application supplies
/// its signaling authority, attempt deadline, and expected identity association.
pub struct RtcPeer {
	inner: Rc<Inner>,
	transferred: bool,
}

impl RtcPeer {
	/// ICE configuration is supplied by the application's platform policy.
	/// The peer neither discovers signaling authorities nor chooses identities.
	pub fn new(host: &Host, role: RtcRole, config: &RtcConfiguration) -> io::Result<Self> {
		let host = host.shared();
		Inner::host_live(&host)?;
		let pc = RtcPeerConnection::new_with_configuration(config).map_err(super::socket::js_error)?;
		let inner = Rc::new(Inner {
			host,
			pc,
			role,
			state: RefCell::new(State::default()),
			events: RefCell::new(None),
			changed: tokio::sync::Notify::new(),
		});
		*inner.events.borrow_mut() = Some(events::Events::install(&inner));
		if role == RtcRole::Offerer {
			inner.wire(inner.pc.create_data_channel("ocapn"));
		}
		if let Err(error) = inner.monitor() {
			inner.close();
			return Err(error);
		}
		Ok(Self {
			inner,
			transferred: false,
		})
	}

	pub async fn create_offer(&self) -> io::Result<String> {
		self.create_description(RtcRole::Offerer).await
	}
	pub async fn create_answer(&self) -> io::Result<String> {
		self.create_description(RtcRole::Answerer).await
	}
	async fn create_description(&self, role: RtcRole) -> io::Result<String> {
		self.inner.live()?;
		{
			let mut state = self.inner.state.borrow_mut();
			state.live()?;
			if self.inner.role != role
				|| state.local_started
				|| (role == RtcRole::Answerer && state.remote != Remote::Installed)
			{
				return Err(io::Error::new(
					io::ErrorKind::InvalidInput,
					"WebRTC description is not valid in this phase",
				));
			}
			state.local_started = true;
		}
		self.inner
			.call(move |inner| async move {
				let value = inner
					.operation(|pc| match role {
						RtcRole::Offerer => pc.create_offer(),
						RtcRole::Answerer => pc.create_answer(),
					})
					.await?;
				let sdp = signal::description_value(&value)?;
				let description = RtcSessionDescriptionInit::new(match role {
					RtcRole::Offerer => RtcSdpType::Offer,
					RtcRole::Answerer => RtcSdpType::Answer,
				});
				description.set_sdp(&sdp);
				inner.operation(|pc| pc.set_local_description(&description)).await?;
				Ok(sdp)
			})
			.await
	}

	pub async fn set_remote_offer(&self, sdp: &str) -> io::Result<()> {
		self.set_remote(RtcRole::Answerer, sdp).await
	}
	pub async fn set_remote_answer(&self, sdp: &str) -> io::Result<()> {
		self.set_remote(RtcRole::Offerer, sdp).await
	}
	async fn set_remote(&self, role: RtcRole, sdp: &str) -> io::Result<()> {
		self.inner.live()?;
		signal::description(sdp)?;
		{
			let mut state = self.inner.state.borrow_mut();
			state.live()?;
			if self.inner.role != role || state.remote != Remote::Pending {
				return Err(io::Error::new(
					io::ErrorKind::InvalidInput,
					"WebRTC remote description already started or wrong role",
				));
			}
			state.remote = Remote::Installing;
		}
		let description = RtcSessionDescriptionInit::new(match role {
			RtcRole::Answerer => RtcSdpType::Offer,
			RtcRole::Offerer => RtcSdpType::Answer,
		});
		description.set_sdp(sdp);
		self.inner
			.call(move |inner| async move {
				inner.operation(|pc| pc.set_remote_description(&description)).await?;
				inner.state.borrow_mut().remote = Remote::Installed;
				inner.changed.notify_waiters();
				Ok(())
			})
			.await
	}

	/// Candidates admitted before remote SDP wait in a bounded FIFO. A completed
	/// observation means addIceCandidate settled; a dropped observer does not
	/// discard the admitted operation or its resource accounting.
	pub async fn add_remote_candidate(&self, text: &str) -> io::Result<()> {
		let candidate = signal::candidate(text)?;
		let (reply, receive) = oneshot::channel();
		self.inner.enqueue(candidate, text.len(), reply)?;
		let result = receive
			.await
			.map_err(|_| io::Error::new(io::ErrorKind::NotConnected, "WebRTC candidate owner ended"))?
			.map_err(|failure| failure.error());
		self.inner.live()?;
		result
	}

	/// One bounded JSON candidate to ferry through the caller's signaling route.
	pub async fn next_local_candidate(&self) -> io::Result<Option<String>> {
		poll_fn(|cx| {
			let mut state = self.inner.state.borrow_mut();
			if let Some(failure) = &state.failure {
				return Poll::Ready(Err(failure.error()));
			}
			if let Some(candidate) = state.local.pop_front() {
				state.local_bytes -= candidate.len();
				return Poll::Ready(Ok(Some(candidate)));
			}
			if state.closing || state.signaling_finished {
				return Poll::Ready(Ok(None));
			}
			state.local_waker = Some(cx.waker().clone());
			Poll::Pending
		})
		.await
	}

	pub async fn wait_open(&self) -> io::Result<()> {
		poll_fn(|cx| {
			self.inner.live()?;
			let mut state = self.inner.state.borrow_mut();
			state.live()?;
			let Some(status) = state.channel_status.clone() else {
				state.open_waker = Some(cx.waker().clone());
				return Poll::Pending;
			};
			drop(state);
			let mut channel = status.state.borrow_mut();
			channel.result()?;
			if status.socket.open() {
				return Poll::Ready(Ok(()));
			}
			if channel.closed || channel.closing {
				return Poll::Ready(Err(io::ErrorKind::NotConnected.into()));
			}
			channel.writer = Some(cx.waker().clone());
			Poll::Pending
		})
		.await
	}

	/// End signaling admission, join admitted browser work, and transfer the
	/// entire peer's close barrier along with its open packet channel.
	pub async fn into_channel(mut self) -> io::Result<Channel> {
		let result = self.transfer_channel().await;
		if let Err(primary) = result {
			// Refusing the transfer still owns physical retirement. Drop alone
			// would request cleanup but return before its Host jobs finish.
			return match self.retire_after_error(&primary).await {
				Ok(()) => Err(primary),
				Err(cleanup) => Err(io::Error::new(
					primary.kind(),
					format!("{primary}; peer retirement: {cleanup}"),
				)),
			};
		}
		result
	}
	async fn transfer_channel(&mut self) -> io::Result<Channel> {
		self.wait_open().await?;
		{
			let mut state = self.inner.state.borrow_mut();
			state.signaling_finished = true;
			state.local.clear();
			state.local_bytes = 0;
			state.wake();
		}
		self.inner.pc.set_onicecandidate(None);
		// Preparation is no longer an independent Host resource. Once this
		// returns, the Channel owner (then its admitted Session) chooses the
		// physical close point after the Host has flushed its terminal frames.
		self.inner.changed.notify_waiters();
		poll_fn(|cx| self.inner.poll_operations(cx)).await;
		self.inner.live()?;
		let mut channel = {
			let mut state = self.inner.state.borrow_mut();
			state.live()?;
			let channel = state
				.channel
				.take()
				.ok_or_else(|| io::Error::other("WebRTC channel already transferred"))?;
			state.channel_transferred = true;
			channel
		};
		let close = channel.close.take().expect("browser data channel close owner");
		channel.close = Some(Box::new(PeerClose {
			inner: self.inner.clone(),
			channel: close,
			result: None,
		}));
		self.inner.changed.notify_waiters();
		self.transferred = true;
		Ok(channel)
	}

	pub async fn close(&mut self) -> io::Result<()> {
		self.inner.close();
		poll_fn(|cx| self.inner.poll_retired(cx)).await;
		self.inner.state.borrow().result()
	}

	/// Retire this peer after one of its operations returned `primary`. Suppress
	/// the peer's stored failure only when it is that exact observed outcome;
	/// preserve a distinct failure as the cleanup result.
	pub async fn retire_after_error(&mut self, primary: &io::Error) -> io::Result<()> {
		let primary_is_peer_failure = self
			.inner
			.state
			.borrow()
			.failure
			.as_ref()
			.is_some_and(|failure| failure.0 == primary.kind() && failure.1 == primary.to_string());
		self.inner.close();
		poll_fn(|cx| self.inner.poll_retired(cx)).await;
		if primary_is_peer_failure {
			Ok(())
		} else {
			self.inner.state.borrow().result()
		}
	}
}
impl Drop for RtcPeer {
	fn drop(&mut self) {
		if !self.transferred {
			self.inner.close();
		}
	}
}

struct PeerClose {
	inner: Rc<Inner>,
	channel: Box<dyn ChannelClose>,
	result: Option<Result<(), Failure>>,
}
impl ChannelClose for PeerClose {
	fn poll_close(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
		self.inner.close();
		if self.result.is_none() {
			self.result =
				Some(std::task::ready!(self.channel.poll_close(cx)).map_err(|e| Failure(e.kind(), e.to_string())));
			self.inner.close_transport();
		}
		std::task::ready!(self.inner.poll_retired(cx));
		self.inner.state.borrow().result()?;
		Poll::Ready(
			self.result
				.as_ref()
				.unwrap()
				.as_ref()
				.map(|_| ())
				.map_err(Failure::error),
		)
	}
}
impl Drop for PeerClose {
	fn drop(&mut self) {
		self.inner.close();
		// Dropping an unobserved Channel cannot drive graceful retirement.
		self.inner.close_transport();
	}
}
