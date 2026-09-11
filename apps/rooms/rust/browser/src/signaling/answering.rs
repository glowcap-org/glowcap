use super::*;
use glowcap::{AcceptedTransport, ChannelDesignator};
use std::{collections::BTreeMap, future::Future, sync::Arc};
use tokio::{
	sync::{mpsc, watch, OwnedSemaphorePermit, Semaphore},
	task::JoinSet,
};

// These are preparation resources, not established-session limits. Payloads
// are bounded by the shared Rooms signaling types before entering either queue.
const MAX_PENDING_OFFERS: usize = 32;

#[derive(Clone, Copy)]
enum Stop {
	Shutdown,
	Refused(&'static str),
}
struct Pending {
	candidates: mpsc::Sender<Candidate>,
	budget: Arc<Semaphore>,
	stop: watch::Sender<Option<Stop>>,
}
struct Candidate {
	value: policy::Candidate,
	// Capacity stays charged while addIceCandidate is awaiting the browser.
	_permit: OwnedSemaphorePermit,
}
impl Pending {
	fn candidate(&self, value: policy::Candidate) {
		let Ok(permit) = self.budget.clone().try_acquire_owned() else {
			self.stop
				.send_replace(Some(Stop::Refused("Rooms WebRTC candidate queue exceeded")));
			return;
		};
		let candidate = Candidate { value, _permit: permit };
		if let Err(mpsc::error::TrySendError::Full(_)) = self.candidates.try_send(candidate) {
			self.stop
				.send_replace(Some(Stop::Refused("Rooms WebRTC candidate queue exceeded")));
		}
	}
}

/// An inbox filed on one registered directory connection. Opening is a
/// readiness barrier; serve drives only offers that arrive after publication.
pub struct Listener<D: Tasks> {
	host: Host,
	directory: Directory<D>,
	inbox: rooms_glowcap::client::directory::signaling::Inbox<D>,
	handshake: Duration,
}
impl<D: Deadline + Tasks + Clone + 'static> Listener<D> {
	pub async fn open(directory: Directory<D>, handshake: Duration) -> Result<Self, Error> {
		if handshake.is_zero() {
			return Err(Error::Admission("Rooms WebRTC requires a finite handshake budget"));
		}
		let inbox = directory.signaling_inbox().await?;
		let host = directory.client().session().host();
		Ok(Self {
			host,
			directory,
			inbox,
			handshake,
		})
	}
	/// Drive all admitted preparations until shutdown or directory closure.
	/// Each obtains fresh application-supplied ICE configuration. The recipient
	/// takes custody of Sessions; stopping signaling leaves them alive.
	/// Shutdown retires and joins every preparation before returning.
	pub async fn serve<F: Future<Output = Result<RtcConfiguration, Error>> + 'static>(
		self,
		configuration: impl Fn() -> F,
		shutdown: impl Future<Output = ()>,
		mut accepted: impl FnMut(Result<Session, Error>),
	) -> Result<(), Error> {
		let Self {
			host,
			directory,
			mut inbox,
			handshake,
		} = self;
		let mut pending = BTreeMap::<String, Pending>::new();
		let mut workers = JoinSet::new();
		tokio::pin!(shutdown);
		let outcome = loop {
			tokio::select! {
				biased;
				() = &mut shutdown => break Ok(()),
				ended = workers.join_next(), if !workers.is_empty() => match ended {
					Some(Ok((id, outcome))) => {
						pending.remove(&id);
						match outcome { Ok(Some(session)) => accepted(Ok(session)), Ok(None) => {}, Err(error) => accepted(Err(error)) }
					},
					Some(Err(_)) => break Err(Error::Admission("Rooms WebRTC answering worker failed")),
					None => unreachable!("nonempty answering workers"),
				},
				event = inbox.next() => match event {
					Err(error) => break Err(error.into()),
					Ok(None) => break Ok(()),
					Ok(Some(policy::Incoming::Offer { id, description })) => {
						if pending.contains_key(id.as_str()) {
							accepted(Err(Error::Admission("duplicate Rooms WebRTC exchange")));
							continue;
						}
						if pending.len() == MAX_PENDING_OFFERS {
							accepted(Err(Error::Admission("too many pending Rooms WebRTC offers")));
							continue;
						}
						let (tx, candidates) = mpsc::channel(policy::MAX_EVENTS);
						let (stop, stopping) = watch::channel(None);
						let key = id.as_str().to_owned();
						pending.insert(key.clone(), Pending { candidates: tx, budget: Arc::new(Semaphore::new(policy::MAX_EVENTS)), stop });
						let (host, directory, config) = (host.clone(), directory.clone(), configuration());
						workers.spawn_local(async move {
							let offer = Offer { id, description, candidates, stop: stopping };
							let result = answer(&host, &directory, offer, config, handshake).await;
							(key, result)
						});
					},
					Ok(Some(policy::Incoming::Candidate { id, candidate })) => {
						// A finished exchange may still have a candidate already queued
						// on the directory connection. It cannot create a new peer.
						if let Some(attempt) = pending.get(id.as_str()) {
							attempt.candidate(candidate);
						}
					},
				}
			}
		};
		inbox.close();
		for attempt in pending.values() {
			attempt.stop.send_if_modified(|reason| {
				if reason.is_some() {
					false
				} else {
					*reason = Some(Stop::Shutdown);
					true
				}
			});
		}
		let mut outcome = outcome;
		while let Some(ended) = workers.join_next().await {
			let result = match ended {
				Ok((_, Ok(Some(session)))) => session.close(glowcap::PendingWork::Cancel).await.map_err(Error::from),
				Ok((_, Ok(None))) => Ok(()),
				Ok((_, Err(error))) => Err(error),
				Err(_) => Err(Error::Admission("Rooms WebRTC answering worker failed during shutdown")),
			};
			if let Err(error) = result {
				outcome = Err(match outcome {
					Ok(()) => error,
					Err(primary) => primary.retain(Err(error)),
				});
			}
		}
		outcome
	}
}

async fn stopped(stop: &mut watch::Receiver<Option<Stop>>) -> Stop {
	loop {
		if let Some(reason) = *stop.borrow_and_update() {
			return reason;
		}
		if stop.changed().await.is_err() {
			return Stop::Shutdown;
		}
	}
}

struct Offer {
	id: policy::Id,
	description: policy::Description,
	candidates: mpsc::Receiver<Candidate>,
	stop: watch::Receiver<Option<Stop>>,
}

async fn answer<D: Deadline + Tasks + Clone + 'static>(
	host: &Host,
	directory: &Directory<D>,
	offer: Offer,
	config: impl Future<Output = Result<RtcConfiguration, Error>>,
	handshake: Duration,
) -> Result<Option<Session>, Error> {
	let key = host.designator()?;
	let Offer {
		id,
		description,
		mut candidates,
		mut stop,
	} = offer;
	let mut peer = None;
	// A selected-away ICE observer does not cancel its admitted browser job.
	// Retain its permit until peer.close/into_channel has joined that job.
	let mut applying = None;
	let prepared = {
		let work = async {
			peer = Some(RtcPeer::new(host, RtcRole::Answerer, &config.await?)?);
			let peer = peer.as_ref().expect("created answering peer");
			tokio::select! {
				result = async {
					peer.set_remote_offer(description.as_str()).await?;
					directory.signal_answer(&id, &policy::Description::parse(&peer.create_answer().await?)?)?;
					peer.wait_open().await?;
					Ok(())
				} => result,
				result = async {
					while let Some(candidate) = peer.next_local_candidate().await? {
						directory.signal_candidate(&id, &policy::Candidate::parse(&candidate)?)?;
					}
					Err(Error::Stopped)
				} => result,
				result = async {
					while let Some(candidate) = candidates.recv().await {
						applying = Some(candidate);
						peer.add_remote_candidate(applying.as_ref().expect("held candidate").value.as_str()).await?;
						applying = None;
					}
					Err(Error::Stopped)
				} => result,
			}
		};
		tokio::select! { biased;
			reason = stopped(&mut stop) => Err(match reason { Stop::Shutdown => Error::Stopped, Stop::Refused(reason) => Error::Admission(reason) }),
			result = directory.client().platform().within(policy::TIMEOUT_MS, work) => result.unwrap_or(Err(Error::Timeout)),
		}
	};
	if let Err(error) = prepared {
		let cleanup = match peer.as_mut() {
			Some(peer) => peer.close().await.map_err(Error::from),
			None => Ok(()),
		};
		return match error {
			Error::Stopped if matches!(*stop.borrow(), Some(Stop::Shutdown)) => cleanup.map(|()| None),
			error => Err(error.retain(cleanup)),
		};
	}
	let channel = peer.expect("prepared answering peer").into_channel().await?;
	drop(applying);
	let stopping = *stop.borrow();
	if let Some(reason) = stopping {
		return cancelled(reason, channel.close().await.map_err(Error::from));
	}
	let accepted = Session::accept_channel(
		host,
		AcceptedTransport {
			transport: glowcap::TRANSPORT_WEBRTC,
			designator: ChannelDesignator::Key(&key),
			local_address: "",
			// An offer names an exchange, not the caller's authenticated key.
			verified_channel_key: None,
		},
		channel,
		Some(handshake),
	)
	.await?;
	let stopping = *stop.borrow();
	if let Some(reason) = stopping {
		return cancelled(
			reason,
			accepted.close(glowcap::PendingWork::Cancel).await.map_err(Error::from),
		);
	}
	Ok(Some(accepted))
}

fn cancelled(reason: Stop, cleanup: Result<(), Error>) -> Result<Option<Session>, Error> {
	match reason {
		Stop::Shutdown => cleanup.map(|()| None),
		Stop::Refused(reason) => Err(Error::Admission(reason).retain(cleanup)),
	}
}
