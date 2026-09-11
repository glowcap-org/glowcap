use super::*;
use futures_util::{SinkExt, StreamExt};
use glowcap::{tcp, Argument, ConnectOptions, PendingWork, Runtime, RuntimeConfig};
use rooms_application::grants::Access;
use std::time::Duration;
use tokio_tungstenite::{
	accept_async,
	tungstenite::{protocol::frame::coding::CloseCode, Message},
};
#[tokio::test]
async fn session_service_publishes_viz_trace_to_the_endpoint() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), viz())
				.await
				.expect("native session viz deadline");
		})
		.await;
}
async fn viz() {
	let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
	let addr = listener.local_addr().unwrap();
	let scope = format!("ws://{addr}/viz");
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
				"adopt-viz".into(),
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
				"viz-cap".into(),
				Argument::Integer(1),
				"replaceOperationsCapabilities".into(),
				serde_json::json!([{"capability":"viz","scope":scope,"swiss":"viz-cap"}])
					.to_string()
					.into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), ready)
		.await
		.expect("viz endpoint admitted the publisher")
		.unwrap();
	let json = tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			match session
				.send(&root, "operationsSnapshot", &[scope.clone().into(), "viz".into()])
				.await
			{
				Ok(Argument::String(text)) if text.contains("\"connected\":true") => return text,
				_ => tokio::task::yield_now().await,
			}
		}
	})
	.await
	.expect("operationsSnapshot reports the live viz socket");
	assert!(json.contains(&scope), "viz snapshot {json}");
	stop_session(running, session).await;
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.abort();
}
#[tokio::test]
async fn session_service_records_viz_refusal_from_close_4403() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(20), viz_refused())
				.await
				.expect("native session viz refusal deadline");
		})
		.await;
}
async fn viz_refused() {
	let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
	let addr = listener.local_addr().unwrap();
	let scope = format!("ws://{addr}/viz");
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
	adopt_admin(&session, &root, "adopt-viz-refuse").await;
	session
		.send(
			&root,
			"command",
			&[
				"viz-cap".into(),
				Argument::Integer(1),
				"replaceOperationsCapabilities".into(),
				serde_json::json!([{"capability":"viz","scope":scope,"swiss":"viz-cap"}])
					.to_string()
					.into(),
			],
		)
		.await
		.unwrap();
	tokio::time::timeout(Duration::from_secs(8), done)
		.await
		.expect("viz endpoint refused the publisher")
		.unwrap();
	let json = tokio::time::timeout(Duration::from_secs(8), async {
		loop {
			match session
				.send(&root, "operationsSnapshot", &[scope.clone().into(), "viz".into()])
				.await
			{
				Ok(Argument::String(text)) if text.contains("\"refusal\"") && text.contains("refused") => return text,
				_ => tokio::time::sleep(Duration::from_millis(50)).await,
			}
		}
	})
	.await
	.expect("operationsSnapshot reports the viz refusal");
	assert!(json.contains("\"connected\":false"), "viz refusal snapshot {json}");
	stop_session(running, session).await;
	runtime.close(PendingWork::Cancel).await.unwrap();
	server.abort();
}
