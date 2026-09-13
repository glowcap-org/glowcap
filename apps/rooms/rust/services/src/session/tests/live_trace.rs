use super::*;
use futures_util::{SinkExt, StreamExt};
use glowcap::{Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig, tcp};
use rooms_application::grants::Access;
use std::time::Duration;
use tokio_tungstenite::{
	accept_async,
	tungstenite::{Message, protocol::frame::coding::CloseCode},
};
#[tokio::test]
async fn session_peer_publishes_trace_trace_to_the_endpoint() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), trace())
				.await
				.expect("host session trace deadline");
		})
		.await;
}
async fn trace() {
	let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
	let addr = listener.local_addr().unwrap();
	let scope = format!("ws://{addr}/trace");
	let (connected, ready) = tokio::sync::oneshot::channel();
	let server = tokio::task::spawn(async move {
		let (stream, _) = listener.accept().await.unwrap();
		let mut ws = accept_async(stream).await.unwrap();
		ws.send(Message::text(
			r#"{"v":1,"sim_t_ns":0,"kind":"trace.publish-ready","epoch":1}"#,
		))
		.await
		.unwrap();
		let _ = connected.send(());
		while let Some(Ok(_)) = ws.next().await {}
		let _ = ws
			.close(Some(tokio_tungstenite::tungstenite::protocol::CloseFrame {
				code: CloseCode::Normal,
				reason: "".into(),
			}))
			.await;
	});
	let temp = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let running = start_session(temp.0.clone()).await;
	let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
	let session = runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let root = session.enliven(&running.link).await.unwrap();
	let snapshot = parse_snapshot(&session.send(&root, "snapshot", &[]).await.unwrap());
	session
		.send(
			&root,
			"adoptWorkspace",
			&[
				"adopt-trace".into(),
				Argument::Integer(0),
				snapshot.checkpoint.encode_for(Access::Admin).unwrap().into(),
			],
		)
		.await
		.unwrap();
	session
		.send(
			&root,
			"command",
			&[
				"trace-cap".into(),
				Argument::Integer(1),
				"replaceOperationsCapabilities".into(),
				serde_json::json!([{"capability":"trace","scope":scope,"swiss":"trace-cap"}])
					.to_string()
					.into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), ready)
		.await
		.expect("trace endpoint admitted the publisher")
		.unwrap();
	let json = tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			match session
				.send(&root, "operationsSnapshot", &[scope.clone().into(), "trace".into()])
				.await
			{
				Ok(Argument::String(text)) if text.contains("\"connected\":true") => return text,
				_ => tokio::task::yield_now().await,
			}
		}
	})
	.await
	.expect("operationsSnapshot reports the live trace socket");
	assert!(json.contains(&scope), "trace snapshot {json}");
	stop_session(running, session).await;
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.abort();
}
#[tokio::test]
async fn session_peer_records_trace_refusal_from_close_4403() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), trace_refused())
				.await
				.expect("host session trace refusal deadline");
		})
		.await;
}
async fn trace_refused() {
	let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
	let addr = listener.local_addr().unwrap();
	let scope = format!("ws://{addr}/trace");
	let (closed, done) = tokio::sync::oneshot::channel();
	let server = tokio::task::spawn(async move {
		let (stream, _) = listener.accept().await.unwrap();
		let mut ws = accept_async(stream).await.unwrap();
		let _ = ws
			.close(Some(tokio_tungstenite::tungstenite::protocol::CloseFrame {
				code: CloseCode::from(4403),
				reason: "the endpoint refused this capability".into(),
			}))
			.await;
		while let Some(Ok(_)) = ws.next().await {}
		let _ = closed.send(());
	});
	let temp = Temp::new();
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let running = start_session(temp.0.clone()).await;
	let parsed = glowcap::parse_sturdyref(&running.link, glowcap::CaptpVersion::V1_0).unwrap();
	let session = runtime
		.connect(&parsed.locator, ConnectOptions::default())
		.await
		.unwrap()
		.with_gc();
	let root = session.enliven(&running.link).await.unwrap();
	adopt_admin(&session, &root, "adopt-trace-refuse").await;
	session
		.send(
			&root,
			"command",
			&[
				"trace-cap".into(),
				Argument::Integer(1),
				"replaceOperationsCapabilities".into(),
				serde_json::json!([{"capability":"trace","scope":scope,"swiss":"trace-cap"}])
					.to_string()
					.into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), done)
		.await
		.expect("trace endpoint refused the publisher")
		.unwrap();
	let json = tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			match session
				.send(&root, "operationsSnapshot", &[scope.clone().into(), "trace".into()])
				.await
			{
				Ok(Argument::String(text)) if text.contains("\"refusal\"") && text.contains("refused") => return text,
				_ => tokio::time::sleep(Duration::from_millis(50)).await,
			}
		}
	})
	.await
	.expect("operationsSnapshot reports the trace refusal");
	assert!(json.contains("\"connected\":false"), "trace refusal snapshot {json}");
	stop_session(running, session).await;
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.abort();
}
