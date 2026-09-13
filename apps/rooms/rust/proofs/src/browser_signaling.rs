//! Both Rust browser signaling halves carried by the actual native directory.
use glowcap::{Argument, Host, PendingWork, Session, browser};
use rooms_browser::platform::Platform;
use rooms_browser::signaling;
use rooms_glowcap::client::{
	Client,
	directory::{Directory, registration::Registration},
};
use std::{
	cell::{Cell, RefCell},
	rc::Rc,
	time::Duration,
};
use wasm_bindgen::prelude::*;

async fn registered(
	host: &Host,
	url: &str,
	location: &str,
	nick: &str,
) -> (Directory<Platform>, Registration<Platform>) {
	host.set_advertised_locator(&glowcap::Locator::bare(
		glowcap::TRANSPORT_WEBRTC,
		&host.designator().unwrap(),
	))
	.unwrap();
	let locator = glowcap::parse_locator(location).unwrap();
	let session = Session::dial_channel(
		host,
		&locator,
		browser::open_websocket(url).unwrap(),
		Some(Duration::from_secs(5)),
		None,
	)
	.await
	.unwrap();
	let directory = Directory::fetch(Client::new(session, Platform::new().unwrap()))
		.await
		.unwrap();
	let mut registration = directory.registration();
	let advertised = glowcap::format_locator_uri(&glowcap::Locator::bare(
		glowcap::TRANSPORT_WEBRTC,
		&host.designator().unwrap(),
	))
	.unwrap();
	registration.register(nick, &advertised, None).await.unwrap();
	(directory, registration)
}

#[wasm_bindgen]
pub async fn rooms_browser_signaling_contract(url: String, location: String) {
	super::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async move {
			for handoff in [false, true] {
				runtime_dial(&url, &location, handoff).await;
			}
		})
		.await;
}

async fn runtime_dial(url: &str, location: &str, handoff: bool) {
	let caller = Host::with_options(Default::default()).unwrap();
	let receiver = Host::with_options(Default::default()).unwrap();
	let selected = Rc::new(RefCell::new(None::<Directory<Platform>>));
	let attempts = Rc::new(Cell::new(0));
	let ice = rooms_browser::ice::Source::deployment();
	let route = selected.clone();
	let observed = attempts.clone();
	let select = move |_: &glowcap::Locator, origin: &glowcap::DialOrigin| {
		let directory = route.borrow().clone().ok_or("no selected directory")?;
		match origin {
			glowcap::DialOrigin::Explicit => assert!(!handoff),
			glowcap::DialOrigin::Pending { introducer } => {
				assert!(handoff);
				assert!(introducer.as_ref().unwrap().same_session(directory.client().session()));
			}
		}
		observed.set(observed.get() + 1);
		Ok(directory)
	};
	let runtime = rooms_browser::transport::open(
		&caller,
		rooms_browser::transport::WebFront::deployment().unwrap(),
		select,
		ice.clone(),
	)
	.await
	.unwrap();
	receiver
		.publish_giftable("echo", || Box::new(|_, args| Ok(Argument::List(args.to_vec()))))
		.unwrap();
	let left_name = if handoff {
		"rust-handoff-left"
	} else {
		"rust-signaling-left"
	};
	let right_name = if handoff {
		"rust-handoff-right"
	} else {
		"rust-signaling-right"
	};
	let (left, left_registration) = registered(&caller, url, location, left_name).await;
	let (right, right_registration) = registered(&receiver, url, location, right_name).await;
	*selected.borrow_mut() = Some(left.clone());
	if handoff {
		let inbox = right.client().session().published_ref("echo").unwrap().unwrap();
		let recipient = right.member_registration(left_name).await.unwrap();
		right.offer_inbox(left_name, &recipient, &inbox).await.unwrap();
	}
	let locator = glowcap::Locator::bare(glowcap::TRANSPORT_WEBRTC, &receiver.designator().unwrap());
	let (accepted, incoming) = tokio::sync::oneshot::channel();
	let mut accepted = Some(accepted);
	let (stop, stopped) = tokio::sync::oneshot::channel();
	let listener = signaling::Listener::open(right.clone(), Duration::from_secs(5))
		.await
		.unwrap();
	let serving = listener.serve(
		|| {
			let ice = ice.clone();
			async move {
				ice.configuration()
					.await
					.map_err(|_| signaling::Error::Admission("deployment ICE failed"))
			}
		},
		async {
			let _ = stopped.await;
		},
		move |result| {
			accepted.take().expect("one RTC connection").send(result).ok().unwrap();
		},
	);
	let dialing = async {
		let (session, echo) = if handoff {
			let introduced = left.introduce(right_name, None).await.unwrap();
			assert!(!introduced.session().same_session(left.client().session()));
			let session = introduced
				.session()
				.host()
				.reference_session(&introduced.inbox)
				.unwrap()
				.expect("introduced inbox retains its exporter session");
			(session, introduced.inbox)
		} else {
			let session = runtime.connect(&locator, Default::default()).await.unwrap();
			let echo = session.fetch("echo").await.unwrap();
			(session, echo)
		};
		let accepted = incoming.await.unwrap().unwrap();
		stop.send(()).unwrap();
		(session, echo, accepted)
	};
	let (served, (session, echo, accepted)) = tokio::join!(biased; serving, dialing);
	served.unwrap();
	assert_eq!(attempts.get(), 1);
	selected.borrow_mut().take();
	ice.close().await.unwrap();
	left.client().session().close(PendingWork::Cancel).await.unwrap();
	right.client().session().close(PendingWork::Cancel).await.unwrap();
	drop((left_registration, right_registration, left, right));
	// The selected directory and its transport have retired. The capability
	// reached by this exact handoff still calls directly over WebRTC.
	let payload = vec![Argument::String("Rooms signaling in Rust".into())];
	assert_eq!(
		session.send(&echo, "roundtrip", &payload).await.unwrap(),
		Argument::List(payload)
	);
	drop((echo, session, accepted));
	let (a, b) = tokio::join!(runtime.close(PendingWork::Cancel), receiver.close(PendingWork::Cancel));
	a.unwrap();
	b.unwrap();
}

#[wasm_bindgen]
pub async fn rooms_browser_signaling_cancel_contract(url: String, location: String) {
	super::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async move {
			let caller = Host::with_options(Default::default()).unwrap();
			let receiver = Host::with_options(Default::default()).unwrap();
			let (left, a) = registered(&caller, &url, &location, "rust-cancel-left").await;
			let (right, b) = registered(&receiver, &url, &location, "rust-cancel-right").await;
			let listener = signaling::Listener::open(right.clone(), Duration::from_secs(5))
				.await
				.unwrap();
			let exchange = left.signaling_exchange(&receiver.designator().unwrap()).unwrap();
			let mut peer =
				browser::RtcPeer::new(&caller, browser::RtcRole::Offerer, &web_sys::RtcConfiguration::new()).unwrap();
			let description =
				rooms_application::signaling::Description::parse(&peer.create_offer().await.unwrap()).unwrap();
			let (stop, stopped) = tokio::sync::oneshot::channel();
			let configuring = std::rc::Rc::new(tokio::sync::Notify::new());
			let observed = configuring.clone();
			let serving = listener.serve(
				move || {
					let configuring = configuring.clone();
					async move {
						configuring.notify_one();
						std::future::pending().await
					}
				},
				async {
					let _ = stopped.await;
				},
				|_| panic!("stopped preparation published a session"),
			);
			let cancel = async {
				exchange.offer(&description).unwrap();
				observed.notified().await;
				stop.send(()).unwrap();
			};
			let (result, ()) = tokio::join!(serving, cancel);
			result.unwrap();
			exchange.close().unwrap();
			peer.close().await.unwrap();
			drop((peer, exchange, left, right, a, b));
			let (a, b) = tokio::join!(caller.close(PendingWork::Cancel), receiver.close(PendingWork::Cancel));
			a.unwrap();
			b.unwrap();
		})
		.await;
}
