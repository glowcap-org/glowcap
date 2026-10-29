//! A surviving exporter in another page keeps exact authority through reload.
//! The fixture pins both live Host keys while coordinating their RTC channels.
use super::{FIELDS, content, inspect_uris, limits, session_capacity, session_storage, targets};
use glowcap::{
	AcceptedTransport, Argument, ChannelDesignator, Host, PendingWork, Session, browser,
	loam::{Policy, Resource, Store},
};
use rooms_application::content::session::{self, records};
use std::{cell::Cell, rc::Rc, time::Duration};
use wasm_bindgen::{JsCast, prelude::*};
use wasm_bindgen_futures::JsFuture;
use web_sys::RtcDataChannel;

#[wasm_bindgen]
extern "C" {
	#[wasm_bindgen(js_namespace = globalThis, js_name = foreignExporterReady)]
	fn ready(location: &str, uris: &js_sys::Array);
	#[wasm_bindgen(js_namespace = globalThis, js_name = nextForeignChannel)]
	fn next_channel() -> js_sys::Promise;
	#[wasm_bindgen(js_namespace = globalThis, js_name = foreignSourceFinished)]
	fn source_finished() -> js_sys::Promise;
	#[wasm_bindgen(js_namespace = globalThis, js_name = foreignExporterRetired)]
	fn retired();
	#[wasm_bindgen(js_namespace = globalThis, js_name = foreignSourceReady)]
	fn source_ready(key: &str) -> js_sys::Promise;
	#[wasm_bindgen(js_namespace = globalThis, js_name = foreignChannelPrepared)]
	fn channel_prepared();
}

#[wasm_bindgen]
pub async fn rooms_session_foreign_exporter() {
	crate::async_host::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async {
			let targets = targets::Targets::browser();
			let location = glowcap::format_locator_uri(&targets.locator).unwrap();
			let uris = js_sys::Array::new();
			for uri in &targets.uris[0] {
				uris.push(&JsValue::from_str(uri));
			}
			ready(&location, &uris);
			let key = targets.host.designator().unwrap();
			for _ in 0..2 {
				let pair: js_sys::Array = JsFuture::from(next_channel()).await.unwrap().dyn_into().unwrap();
				let channel: RtcDataChannel = pair.get(0).dyn_into().unwrap();
				let source_key = pair.get(1).as_string().unwrap();
				let channel = browser::data_channel(channel);
				channel_prepared();
				// The fixture coordinates these exact peer connections. It does
				// not claim deployment signaling or exporter restart coverage.
				let accepted = Session::accept_channel(
					&targets.host,
					AcceptedTransport {
						transport: "webrtc",
						designator: ChannelDesignator::Key(&key),
						local_address: "",
						verified_channel_key: Some(&source_key),
					},
					channel,
					Some(Duration::from_secs(5)),
				)
				.await
				.unwrap();
				JsFuture::from(source_finished()).await.unwrap();
				accepted.close(PendingWork::Cancel).await.unwrap();
				retired();
			}
			targets.close().await;
		})
		.await;
}

#[wasm_bindgen]
pub async fn rooms_session_foreign_reload(
	channel: RtcDataChannel,
	location: &str,
	uris: js_sys::Array,
	resource: &[u8],
) -> Vec<u8> {
	crate::async_host::install_panic_hook();
	let uris: Vec<_> = uris.iter().map(|uri| uri.as_string().unwrap()).collect();
	assert_eq!(uris.len(), FIELDS);
	let locator = glowcap::parse_locator(location).unwrap();
	tokio::task::LocalSet::new()
		.run_until(async {
			let source = Host::from_seed([95; 32]).unwrap();
			let channel = browser::data_channel(channel);
			// Both readers exist before either handshake emits a packet.
			JsFuture::from(source_ready(&source.designator().unwrap()))
				.await
				.unwrap();
			let session = Session::dial_channel(
				&source,
				&locator,
				channel,
				Some(Duration::from_secs(5)),
				Some(&locator.designator),
			)
			.await
			.unwrap();
			assert_eq!(
				session.partner_identity().unwrap().provenance,
				glowcap::DurableProvenance::AuthenticatedTransport
			);
			let creating = resource.is_empty();
			let mut store = Store::open(
				"rooms-session-foreign-reload",
				[96; 16],
				creating,
				&session_storage::schemas(),
				limits(3662),
			)
			.await
			.unwrap();
			let population = if creating {
				targets::population(&session, &uris).await
			} else {
				Vec::new()
			};
			let resource = if creating {
				let policy = Policy::new([97; 16], &[10, 20], &[]).unwrap();
				let payload = records::encode_workspace(&session_capacity::intent(), Default::default())
					.unwrap()
					.remove(0);
				store
					.create_resource(&policy, session_storage::schemas()[0], session::KIND, &payload, 2)
					.await
					.unwrap()
			} else {
				Resource::decode(resource.try_into().unwrap())
			};
			let invocations = Rc::new(Cell::new(0));
			let application = content::Application {
				targets: population,
				invocations: Rc::clone(&invocations),
				wrong_uri: Rc::new(Cell::new(false)),
			};
			let mut attachment = store.attach(&source, vec![content::registration(application)]).unwrap();
			let (root, control) = attachment.restore(resource).await.unwrap();
			let mutation = [
				Argument::Integer(1),
				Argument::String("write".into()),
				Argument::Integer(1),
			];
			if creating {
				assert_eq!(
					session.send(&root, "mutate", &mutation).await.unwrap().as_i64(),
					Some((records::MAX_PAGES - 1) as i64)
				);
			}
			// Reloaded source has no imported targets or actor-id reconstruction.
			// The full graph restores before independent expected URI lookups.
			inspect_uris(&uris, &session, &root, 1).await;
			assert_eq!(invocations.get(), usize::from(creating));
			assert_eq!(super::sequence(&session, &root).await, 2);
			assert_eq!(
				session.send(&root, "mutate", &mutation).await.unwrap().as_i64(),
				Some((records::MAX_PAGES - 1) as i64)
			);
			assert_eq!(
				invocations.get(),
				usize::from(creating),
				"receipt replay does not reinvoke"
			);
			drop((root, control));
			attachment.close().await.unwrap();
			drop(attachment);
			session.close(PendingWork::Cancel).await.unwrap();
			drop(session);
			source.close(PendingWork::Cancel).await.unwrap();
			drop(source);
			store.close().await.unwrap();
			resource.encode().to_vec()
		})
		.await
}
