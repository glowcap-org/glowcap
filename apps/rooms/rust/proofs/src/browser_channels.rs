//! Actual browser APIs under the same Rust Host and Rooms client. The fixture
//! owns local RTC signaling. It does not exercise production identity binding.
#[path = "browser_media.rs"]
mod media_execution;
use glowcap::{AcceptedTransport, Argument, ChannelDesignator, Host, Locator, PendingWork, Session, browser};
use rooms_glowcap::client::{Client, directory::Directory, room::Room};
use std::{io, time::Duration};
use wasm_bindgen::prelude::*;
use web_sys::{RtcDataChannel, WebSocket};

#[wasm_bindgen]
pub async fn rooms_browser_websocket_contract(location: String) {
	super::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async move {
			let host = Host::with_options(rooms_glowcap::host_options()).unwrap();
			let ice = rooms_browser::ice::Source::deployment();
			let runtime = std::rc::Rc::new(
				rooms_browser::transport::open::<rooms_browser::platform::Platform, _>(
					&host,
					rooms_browser::transport::WebFront::deployment().unwrap(),
					|_, _| Err("this scenario has no signaling directory".into()),
					ice.clone(),
				)
				.await
				.unwrap(),
			);
			let locator = glowcap::parse_locator(&location).unwrap();
			let session = runtime.connect(&locator, Default::default()).await.unwrap();
			if locator.transport == glowcap::TRANSPORT_IROH {
				assert_eq!(
					session.partner_identity().unwrap().provenance,
					glowcap::DurableProvenance::AuthenticatedTransport
				);
			}
			let platform = rooms_browser::platform::Platform::new().unwrap();
			let directory = Directory::fetch(Client::new(session, platform)).await.unwrap();
			let first = directory.open("rust-browser-one").await.unwrap();
			let second = directory.open("rust-browser-two").await.unwrap();
			assert_ne!(first, second);
			let advertised = rooms_glowcap::routes::locator(&directory.advertised_location().await.unwrap()).unwrap();
			assert_eq!(advertised.transport, locator.transport);
			assert_eq!(advertised.designator, locator.designator);
			// Opening grants an entrance; subscribing makes this room live and
			// discoverable. Keep that membership while testing directory custody.
			let (room, mut messages) =
				Room::subscribe(directory.client().clone(), first.clone(), "browser", Default::default())
					.await
					.unwrap();
			media_execution::exercise(&room, &mut messages).await;
			room.leave().await.unwrap();
			drop((room, messages));
			drop((first, second, directory));
			runtime.close(PendingWork::Cancel).await.unwrap();
			ice.close().await.unwrap();
		})
		.await;
}

#[wasm_bindgen]
pub async fn rooms_browser_rtc_contract(left: RtcDataChannel, right: RtcDataChannel) {
	super::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async move {
			let caller = Host::with_options(rooms_glowcap::host_options()).unwrap();
			let server = Host::with_options(rooms_glowcap::host_options()).unwrap();
			rtc_sessions(
				caller,
				server,
				browser::data_channel(left),
				browser::data_channel(right),
			)
			.await;
		})
		.await;
}

async fn rtc_sessions(caller: Host, server: Host, left: glowcap::Channel, right: glowcap::Channel) {
	server
		.publish("echo", || Box::new(|_, args| Ok(Argument::List(args.to_vec()))))
		.unwrap();
	let caller_key = caller.designator().unwrap();
	let server_key = server.designator().unwrap();
	let locator = Locator::bare("webrtc", &server_key);
	let budget = Some(Duration::from_secs(5));
	let (dialed, accepted) = tokio::join!(
		Session::dial_channel(&caller, &locator, left, budget, Some(&server_key)),
		Session::accept_channel(
			&server,
			AcceptedTransport {
				transport: "webrtc",
				designator: ChannelDesignator::Key(&server_key),
				local_address: "",
				verified_channel_key: Some(&caller_key),
			},
			right,
			budget
		),
	);
	let (dialed, accepted) = (dialed.unwrap(), accepted.unwrap());
	let echo = dialed.fetch("echo").await.unwrap();
	for size in [1, 4096, 8192] {
		let payload = vec![Argument::Bytes(vec![0x5a; size])];
		assert_eq!(
			dialed.send(&echo, "roundtrip", &payload).await.unwrap(),
			Argument::List(payload)
		);
	}
	drop((echo, dialed, accepted));
	let (left, right) = tokio::join!(caller.close(PendingWork::Cancel), server.close(PendingWork::Cancel));
	left.unwrap();
	right.unwrap();
}

#[wasm_bindgen]
pub async fn rooms_browser_rtc_peer_contract() {
	super::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async {
			let caller = Host::with_options(rooms_glowcap::host_options()).unwrap();
			let server = Host::with_options(rooms_glowcap::host_options()).unwrap();
			let config = web_sys::RtcConfiguration::new();
			let left = browser::RtcPeer::new(&caller, browser::RtcRole::Offerer, &config).unwrap();
			let right = browser::RtcPeer::new(&server, browser::RtcRole::Answerer, &config).unwrap();
			async fn forward(from: &browser::RtcPeer, to: &browser::RtcPeer) -> std::io::Result<()> {
				while let Some(candidate) = from.next_local_candidate().await? {
					to.add_remote_candidate(&candidate).await?;
				}
				Ok(())
			}
			tokio::select! {
				result = async {
					let offer = left.create_offer().await?;
					{
						// The peer owns the complete admitted SDP transition. Dropping
						// its observer must not strand queued ICE in Installing.
						let remote = right.set_remote_offer(&offer);
						tokio::pin!(remote);
						tokio::select! { biased;
							result = &mut remote => panic!("SDP applied before its owner ran: {result:?}"),
							() = tokio::task::yield_now() => {}
						}
					}
					right.add_remote_candidate(r#"{"candidate":"","sdpMid":"0","sdpMLineIndex":0}"#).await?;
					left.set_remote_answer(&right.create_answer().await?).await?;
					let (a, b) = tokio::join!(left.wait_open(), right.wait_open());
					a?; b?;
					Ok::<_, std::io::Error>(())
				} => result.unwrap(),
				result = forward(&left, &right) => panic!("local ICE forwarding ended before open: {result:?}"),
				result = forward(&right, &left) => panic!("remote ICE forwarding ended before open: {result:?}"),
			}
			let left = left.into_channel().await.unwrap();
			let right = right.into_channel().await.unwrap();
			rtc_sessions(caller, server, left, right).await;

			// Host shutdown must retire an idle answering peer and a candidate
			// waiting for SDP without requiring the caller to drop either handle.
			let host = Host::with_options(rooms_glowcap::host_options()).unwrap();
			let mut peer = browser::RtcPeer::new(&host, browser::RtcRole::Answerer, &config).unwrap();
			{
				let candidate = peer.add_remote_candidate(r#"{"candidate":"","sdpMid":"0","sdpMLineIndex":0}"#);
				tokio::pin!(candidate);
				tokio::select! { biased;
					result = &mut candidate => panic!("candidate applied before SDP: {result:?}"),
					() = tokio::task::yield_now() => {}
				}
				host.close(PendingWork::Cancel).await.unwrap();
				assert!(candidate.await.is_err());
			}
			peer.close().await.unwrap();

			// Closing during a real browser createOffer must not wait forever for
			// the WebRTC operation chain's unsettled promise.
			let host = Host::with_options(rooms_glowcap::host_options()).unwrap();
			let mut peer = browser::RtcPeer::new(&host, browser::RtcRole::Offerer, &config).unwrap();
			{
				let offer = peer.create_offer();
				tokio::pin!(offer);
				tokio::select! { biased;
					result = &mut offer => panic!("offer completed without polling its owner: {result:?}"),
					() = tokio::task::yield_now() => {}
				}
				host.close(PendingWork::Cancel).await.unwrap();
				assert!(offer.await.is_err());
			}
			peer.close().await.unwrap();

			// Browser callbacks run outside LocalSet polling. Both roles must
			// retire through their standing owner, including an offered channel.
			for role in [browser::RtcRole::Offerer, browser::RtcRole::Answerer] {
				let host = Host::with_options(rooms_glowcap::host_options()).unwrap();
				let mut peer = browser::RtcPeer::new(&host, role, &config).unwrap();
				let failure = peer.wait_open().await.unwrap_err();
				match role {
					browser::RtcRole::Offerer => {
						// The caller already owns the injected route failure. Retirement
						// must not report that same stored outcome as a cleanup failure.
						peer.retire_after_error(&failure).await.unwrap();
					}
					browser::RtcRole::Answerer => {
						// A signaling failure does not own a different, concurrently stored
						// peer failure. Retirement must preserve the latter for reconciliation.
						let primary = io::Error::new(io::ErrorKind::TimedOut, "injected signaling timeout");
						let cleanup = peer.retire_after_error(&primary).await.unwrap_err();
						assert_eq!(cleanup.kind(), failure.kind());
						assert_eq!(cleanup.to_string(), failure.to_string());
					}
				}
				host.close(PendingWork::Cancel).await.unwrap();
			}
		})
		.await;
}

#[wasm_bindgen]
pub async fn rooms_browser_websocket_refusal(socket: WebSocket, location: String) {
	super::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async move {
			let host = Host::with_options(rooms_glowcap::host_options()).unwrap();
			let locator = glowcap::parse_locator(&location).unwrap();
			let error = Session::dial_channel(
				&host,
				&locator,
				browser::websocket(socket),
				Some(Duration::from_secs(5)),
				None,
			)
			.await
			.err()
			.expect("cross-origin relay must refuse");
			assert_eq!(error.kind(), glowcap::ErrorKind::Io);
			assert!(error.to_string().contains("browser channel error"));
			// The close barrier reports that this WebSocket failed to establish.
			assert!(host.close(PendingWork::Cancel).await.is_err());
		})
		.await;
}
