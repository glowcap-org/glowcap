//! Rust relay profiles over the actual native web front's rendezvous service.
use glowcap::{Argument, HintValue, Host, Locator, PendingWork, browser::relay};
use rooms_browser::{ice, platform::Platform, transport};
use std::time::Duration;
use wasm_bindgen::prelude::*;

fn locator(transport: &str, designator: &str, route: &str) -> Locator {
	let mut locator = Locator::bare(transport, designator);
	locator.hint_wire_form = glowcap::HintWireForm::Map;
	locator
		.hints
		.insert("rendezvous-relay".into(), HintValue::String(route.into()));
	locator
}

#[wasm_bindgen]
pub fn rooms_browser_relay_routes_contract() {
	let corpus: serde_json::Value =
		serde_json::from_str(include_str!("../../../../../test/net/fixtures/relay_routes.json")).unwrap();
	let designator = corpus["designator"].as_str().unwrap();
	for profile in [glowcap::TRANSPORT_KEYED_RELAY, glowcap::TRANSPORT_NOISE_RELAY] {
		for accepted in corpus["accepted"].as_array().unwrap() {
			let route = accepted["route"].as_str().unwrap();
			let rendered = relay::dial_url(&locator(profile, designator, route)).unwrap();
			assert_eq!(
				rendered,
				format!(
					"{route}{}rendezvous={designator}",
					if route.contains('?') { '&' } else { '?' }
				)
			);
			let url = web_sys::Url::new(&rendered).unwrap();
			assert_eq!(
				format!("{}{}", url.pathname(), url.search()),
				accepted["request_target"].as_str().unwrap()
			);
		}
		for rejected in corpus["rejected"].as_array().unwrap() {
			assert!(relay::dial_url(&locator(profile, designator, rejected.as_str().unwrap())).is_err());
		}
		let oversized = format!("ws://localhost/{}", "x".repeat(4096));
		assert!(relay::dial_url(&locator(profile, designator, &oversized)).is_err());
		assert!(relay::dial_url(&locator(profile, "not-a-key", "ws://localhost/relay")).is_err());
	}
}

#[wasm_bindgen]
pub async fn rooms_browser_relay_contract(
	route: String,
	register: String,
	profile: String,
	registered: js_sys::Promise,
) {
	super::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async move {
			let caller = Host::with_options(rooms_glowcap::host_options()).unwrap();
			let receiver = Host::with_options(rooms_glowcap::host_options()).unwrap();
			let ice = ice::Source::deployment();
			let runtime = transport::open::<Platform, _>(
				&caller,
				transport::WebFront::deployment().unwrap(),
				|_, _| Err("relay fixture has no signaling directory".into()),
				ice.clone(),
			)
			.await
			.unwrap();
			let locator = locator(&profile, &receiver.designator().unwrap(), &route);
			receiver.set_advertised_locator(&locator).unwrap();
			receiver
				.publish("echo", || Box::new(|_, args| Ok(Argument::List(args.to_vec()))))
				.unwrap();
			caller.publish("callback", || Box::new(|_, _| Ok(true.into()))).unwrap();
			let accepting = relay::accept(&receiver, &locator, &register, Duration::from_secs(5));
			let dialing = async {
				// The fixture observes the native registration's WebSocket OPEN,
				// which follows admission. No timing delay guesses that it is ready.
				js_sys::futures::JsFuture::from(registered).await.unwrap();
				runtime.connect(&locator, Default::default()).await.unwrap()
			};
			let (accepted, session) = tokio::join!(accepting, dialing);
			let accepted = accepted.unwrap();
			let authenticated = profile == glowcap::TRANSPORT_NOISE_RELAY;
			for session in [&accepted, &session] {
				assert_eq!(
					session.partner_identity().unwrap().provenance
						== glowcap::DurableProvenance::AuthenticatedTransport,
					authenticated
				);
			}
			let echo = session.fetch("echo").await.unwrap();
			let payload = vec![Argument::String("Rust browser rendezvous".into())];
			assert_eq!(
				session.send(&echo, "echo", &payload).await.unwrap(),
				Argument::List(payload)
			);
			let callback = accepted.fetch("callback").await.unwrap();
			assert_eq!(accepted.send(&callback, "call", &[]).await.unwrap(), true.into());
			drop((echo, callback, accepted, session));
			let (a, b) = tokio::join!(runtime.close(PendingWork::Cancel), receiver.close(PendingWork::Cancel));
			a.unwrap();
			b.unwrap();
			ice.close().await.unwrap();
		})
		.await;
}
