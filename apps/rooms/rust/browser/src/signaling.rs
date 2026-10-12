//! WebRTC carried by one held Rooms directory connection per attempt. The
//! directory client owns protocol exchanges. The Rust browser binding owns
//! SDP/ICE effects and channel retirement. Call these inside the Host LocalSet.
mod answering;
mod connector;
mod error;
pub use answering::Listener;
pub use connector::connector;
pub use error::Error;

use glowcap::{
	Host, Locator, Session,
	browser::{RtcPeer, RtcRole},
};
use rooms_application::signaling as policy;
use rooms_glowcap::client::{
	Deadline, Tasks,
	directory::signaling::{Exchange, Route},
};
use std::time::Duration;
use web_sys::RtcConfiguration;

/// Dial through this exact directory, already selected by the application for
/// the target. No fallback directory is guessed from other live connections.
/// The deadline covers SDP/ICE preparation. Session admission separately owns
/// its OCapN handshake budget. Dropping the observer retires its exchange and
/// asks the Host-owned peer jobs to close. `Host.close` observes that retirement.
pub async fn dial<D: Deadline + Tasks + Clone + 'static>(
	directory: &Route<D>,
	locator: &Locator,
	config: &RtcConfiguration,
	handshake: Duration,
) -> Result<Session, Error> {
	if handshake.is_zero() {
		return Err(Error::Admission("Rooms WebRTC requires a finite handshake budget"));
	}
	if locator.transport != glowcap::TRANSPORT_WEBRTC {
		return Err(Error::Admission("Rooms WebRTC dial requires a webrtc locator"));
	}
	directory.check().await?;
	let exchange = directory.signaling_exchange(&locator.designator)?;
	let host = directory.host();
	let mut peer = RtcPeer::new(&host, RtcRole::Offerer, config)?;
	let result = directory
		.platform()
		.within(policy::TIMEOUT_MS, async {
			prepare(&peer, &exchange).await?;
			directory.check().await.map_err(Error::from)
		})
		.await
		.unwrap_or(Err(Error::Timeout));
	if let Err(error) = result {
		let cleanup = match error.channel() {
			Some(primary) => peer.retire_after_error(primary).await,
			None => peer.close().await,
		};
		let error = error.retain(cleanup.map_err(Error::from));
		return Err(error.retain(exchange.close().map_err(Error::from)));
	}
	let result: Result<Session, Error> = async {
		let channel = peer.into_channel().await?;
		// This directory exchange is scoped to the requested key. Browser DTLS
		// binds the connected channel to the SDP carried by that exchange.
		let session =
			Session::dial_channel(&host, locator, channel, Some(handshake), Some(&locator.designator)).await?;
		if let Err(error) = directory.check().await {
			return Err(
				Error::from(error).retain(session.close(glowcap::PendingWork::Cancel).await.map_err(Error::from))
			);
		}
		Ok(session)
	}
	.await;
	match (result, exchange.close()) {
		(Err(error), cleanup) => Err(error.retain(cleanup.map_err(Error::from))),
		(Ok(session), Ok(())) => Ok(session),
		(Ok(session), Err(error)) => {
			Err(Error::from(error).retain(session.close(glowcap::PendingWork::Cancel).await.map_err(Error::from)))
		}
	}
}

async fn prepare<D: Deadline + Tasks + Clone + 'static>(peer: &RtcPeer, exchange: &Exchange<D>) -> Result<(), Error> {
	tokio::select! {
		result = async {
			let description = policy::Description::parse(&peer.create_offer().await?)?;
			exchange.offer(&description)?;
			peer.set_remote_answer(exchange.answer().await?.as_str()).await?;
			peer.wait_open().await?;
			Ok(())
		} => result,
		result = async {
			while let Some(candidate) = peer.next_local_candidate().await? {
				exchange.candidate(&policy::Candidate::parse(&candidate)?).await?;
			}
			Err(Error::Stopped)
		} => result,
		result = async {
			while let Some(candidate) = exchange.next_candidate().await? {
				peer.add_remote_candidate(candidate.as_str()).await?;
			}
			Err(Error::Stopped)
		} => result,
	}
}
