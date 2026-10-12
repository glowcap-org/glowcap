//! Production startup follows exact saved trace custody and managed admission.
use crate::session::{Config, Peer, Transport};
use futures_util::{SinkExt, StreamExt};
use rooms_application::{
	content::{
		permissions::Permission,
		session::{self, custody, workspace::Operations},
	},
	fields::List,
	session::operations::{Snapshot, mutation::Kind},
};
use rooms_glowcap::client::workspace::Import;
use std::{num::NonZeroU64, rc::Rc, time::Duration};
use tokio_tungstenite::tungstenite::{
	Message,
	protocol::{CloseFrame, frame::coding::CloseCode},
};

fn coordinate(slot: u64) -> custody::Coordinate {
	custody::Coordinate {
		role: custody::Role::Operations,
		key: custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap()),
	}
}
async fn connected(local: &crate::session::Local, selected: custody::Coordinate, expected: bool) -> String {
	tokio::time::timeout(Duration::from_secs(5), async {
		loop {
			if let Snapshot::Trace(status) = local.workspace.trace_snapshot(selected).await.unwrap()
				&& status.connected == expected
				&& (expected || (status.refusal.as_ref().is_some() && status.url.text().utf16().next().is_some()))
			{
				return serde_json::to_string(&status).unwrap();
			}
			tokio::time::sleep(Duration::from_millis(10)).await;
		}
	})
	.await
	.expect("trace publication state deadline")
}
struct CaptureRequest(Rc<std::cell::RefCell<String>>);
impl tokio_tungstenite::tungstenite::handshake::server::Callback for CaptureRequest {
	fn on_request(
		self,
		request: &tokio_tungstenite::tungstenite::handshake::server::Request,
		response: tokio_tungstenite::tungstenite::handshake::server::Response,
	) -> std::result::Result<
		tokio_tungstenite::tungstenite::handshake::server::Response,
		tokio_tungstenite::tungstenite::handshake::server::ErrorResponse,
	> {
		*self.0.borrow_mut() = request.uri().to_string();
		Ok(response)
	}
}
#[tokio::test]
async fn session_peer_trace_uses_exact_recipe_retires_on_narrowing_and_recovers() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(25), scenario(false))
				.await
				.expect("managed trace deadline");
		})
		.await;
}
#[tokio::test]
async fn session_peer_trace_records_exporter_close_4403() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(25), scenario(true))
				.await
				.expect("managed trace refusal deadline");
		})
		.await;
}
async fn scenario(refused: bool) {
	let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
	let endpoint = format!("ws://{}/deployment/publish", listener.local_addr().unwrap());
	let (closed, mut endings) = tokio::sync::mpsc::channel(4);
	let server = tokio::task::spawn_local(async move {
		loop {
			let (stream, _) = listener.accept().await.unwrap();
			let request = Rc::new(std::cell::RefCell::new(String::new()));
			let mut ws = tokio_tungstenite::accept_hdr_async(stream, CaptureRequest(request.clone()))
				.await
				.unwrap();
			assert_eq!(
				&*request.borrow(),
				"/deployment/publish?cap=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
			);
			if refused {
				ws.close(Some(CloseFrame {
					code: CloseCode::from(4403),
					reason: "exact exporter refused this capability".into(),
				}))
				.await
				.unwrap();
			} else {
				ws.send(Message::text(
					r#"{"v":1,"sim_t_ns":0,"kind":"trace.publish-ready","epoch":1}"#,
				))
				.await
				.unwrap();
			}
			while let Some(Ok(message)) = ws.next().await {
				if matches!(message, Message::Close(_)) {
					// The WebSocket reader queued its protocol reply. Complete that
					// handshake before retiring the TCP stream.
					let _ = ws.flush().await;
					break;
				}
			}
			let _ = closed.send(()).await;
		}
	});
	let timeline = super::Trace::start(
		0,
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".into(),
		Some(endpoint.clone()),
		None,
		Rc::new(|_| {}),
	)
	.await
	.unwrap();
	let temp = Temp::new();
	let mut peer = Peer::open(tcp_config(temp.0.clone()), Rc::new(|_| {})).await.unwrap();
	let local = peer.local().unwrap();
	let reference = local.host.enliven(&timeline.sturdyref).await.unwrap();
	let mut snapshot = local.workspace.snapshot().await.unwrap();
	snapshot.intent.operations = List::new(vec![Operations {
		kind: Kind::Trace,
		handle: coordinate(1),
		connection: None,
	}])
	.unwrap();
	local
		.workspace
		.prepare_acquisition(
			snapshot.revision,
			vec![Import {
				coordinate: coordinate(1),
				reference,
				uri: Some(timeline.sturdyref.clone()),
			}],
			&[],
			&snapshot.intent,
		)
		.unwrap()
		.submit()
		.await
		.unwrap();
	assert_eq!(
		local.workspace.custody_recipe(coordinate(1)).await.unwrap(),
		Some(timeline.sturdyref.clone())
	);
	let status = connected(&local, coordinate(1), !refused).await;
	if refused {
		assert!(status.contains("refused"), "{status}");
	} else {
		assert!(status.contains(&endpoint));
		let permissions: Vec<_> = session::SUPPORTED
			.iter()
			.filter(|permission| **permission != Permission::ShareCustody)
			.map(|permission| permission.key())
			.collect();
		let policy = rooms_glowcap::policy::descriptor().unwrap();
		let terms = policy.value_for_kind(session::KIND, &permissions, &[]).unwrap();
		let revision = glowcap::loam::control_revision(&local.host, local.management.reference())
			.await
			.unwrap();
		local
			.management
			.set_policy(local.management.mutation_sequence().await.unwrap(), revision, terms)
			.await
			.unwrap();
		tokio::time::timeout(Duration::from_secs(5), endings.recv())
			.await
			.expect("narrowing retires the exact producer socket")
			.unwrap();
		assert!(!connected(&local, coordinate(1), false).await.is_empty());
		let all: Vec<_> = session::SUPPORTED.iter().map(|permission| permission.key()).collect();
		let terms = policy.value_for_kind(session::KIND, &all, &[]).unwrap();
		let revision = glowcap::loam::control_revision(&local.host, local.management.reference())
			.await
			.unwrap();
		local
			.management
			.set_policy(local.management.mutation_sequence().await.unwrap(), revision, terms)
			.await
			.unwrap();
		connected(&local, coordinate(1), true).await;
		let mut snapshot = local.workspace.snapshot().await.unwrap();
		snapshot.intent.operations = List::new(vec![]).unwrap();
		local
			.workspace
			.prepare_acquisition(snapshot.revision, vec![], &[], &snapshot.intent)
			.unwrap()
			.submit()
			.await
			.unwrap();
		tokio::time::timeout(Duration::from_secs(5), endings.recv())
			.await
			.expect("selection replacement retires its producer socket")
			.unwrap();
	}
	peer.close().await.unwrap();
	timeline.close().await;
	server.abort();
}

struct Temp(std::path::PathBuf);
impl Temp {
	fn new() -> Self {
		let mut nonce = [0; 8];
		rooms_platform::entropy::fill(&mut nonce).unwrap();
		let path = std::env::temp_dir().join(format!(
			"rooms-managed-trace-{}-{:x}",
			std::process::id(),
			u64::from_be_bytes(nonce)
		));
		std::fs::create_dir(&path).unwrap();
		Self(path)
	}
}
impl Drop for Temp {
	fn drop(&mut self) {
		let _ = std::fs::remove_dir_all(&self.0);
	}
}
fn tcp_config(state: std::path::PathBuf) -> Config {
	Config {
		admission: rooms_application::admission::Settings::defaults(4096, 8),
		state,
		transport: Transport::Tcp {
			bind: "127.0.0.1".into(),
			port: 0,
			announce: None,
		},
		checkpoint: None,
		readiness_file: None,
		relay_url: None,
		relay_alias_url: None,
		dial_transports: vec!["tcp".into()],
	}
}

#[tokio::test]
async fn trace_web_channel_requires_swiss_at_fetch_and_refuses_unknown_routes() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), async {
				let swiss = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
				let timeline = super::Trace::start(0, swiss.into(), None, None, Rc::new(|_| {}))
					.await
					.unwrap();
				let parsed = glowcap::parse_sturdyref(&timeline.sturdyref, glowcap::CaptpVersion::V1_0).unwrap();
				let glowcap::HintValue::String(endpoint) =
					parsed.locator.hints.get(rooms_application::web_channel::HINT).unwrap()
				else {
					panic!("exact browser channel missing");
				};
				let (ws, _) = tokio_tungstenite::connect_async(endpoint).await.unwrap();
				let host = glowcap::Host::from_seed([219; 32]).unwrap();
				let session = glowcap::Session::dial_channel(
					&host,
					&parsed.locator,
					rooms_platform::websocket::WsBytes::new(ws).into_channel(),
					Some(Duration::from_secs(5)),
					None,
				)
				.await
				.unwrap();
				assert!(
					session.fetch("wrong-swiss").await.is_err(),
					"opening the channel grants no trace capability"
				);
				let trace = session.fetch(swiss).await.unwrap();
				let inbox = host.spawn(|_, _| Ok(glowcap::Argument::Void)).unwrap();
				session.send(&trace, "subscribe", &[inbox.into()]).await.unwrap();
				for route in [
					format!("ws://127.0.0.1:{}/unknown?cap={swiss}", timeline.port),
					format!("ws://127.0.0.1:{}/captp?cap={swiss}", timeline.port),
					format!("ws://127.0.0.1:{}/", timeline.port),
				] {
					let (mut ws, _) = tokio_tungstenite::connect_async(route).await.unwrap();
					let Some(Ok(Message::Close(Some(close)))) = ws.next().await else {
						panic!("unadmitted route was not closed");
					};
					assert_eq!(close.code, CloseCode::from(4403));
				}
				drop(trace);
				session.close(glowcap::PendingWork::Cancel).await.unwrap();
				host.close(glowcap::PendingWork::Cancel).await.unwrap();
				timeline.close().await;
			})
			.await
			.expect("trace channel admission deadline");
		})
		.await;
}
