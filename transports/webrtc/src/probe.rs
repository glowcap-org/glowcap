//! Phase-1 de-risk probe for the WebRTC DataChannel netlayer (ADR-0089).
//!
//! This is the native peer: an answerer over the `webrtc` crate that a browser
//! offerer connects to over a reliable, ordered `RTCDataChannel`. It proves the
//! four riskiest unknowns of the netlayer in this environment, before any engine
//! integration exists:
//!
//! * the `webrtc` crate builds and drives a peer connection here;
//! * ICE gathers usable candidates on loopback inside a headless container
//!   (host candidates, no STUN — `set_include_loopback_candidate(true)`);
//! * DTLS brings the encrypted channel up between Chromium and this crate;
//! * bytes round-trip both directions over the open channel.
//!
//! Signaling is out of band, over stdio, one JSON object per line. This is *not*
//! the OCapN signaling capability (that is ADR-0089 phase 5); it is a direct
//! SDP/ICE exchange whose only job is to bring the channel up so the byte path
//! can be proven. The Deno/Playwright harness in `test/` is the counterpart: it
//! runs the browser peer, ferries these lines between the browser and this
//! process, and asserts the round-trip.
//!
//! Wire (newline-delimited JSON):
//!   in   {"type":"offer","sdp":"…"}                     browser's SDP offer
//!   in   {"type":"candidate","candidate":{…}}           a trickled ICE candidate
//!   out  {"type":"answer","sdp":"…"}                    this peer's SDP answer
//!   out  {"type":"candidate","candidate":{…}}           a trickled ICE candidate
//!   out  {"type":"native_recv","text":"…"}              a message reached this peer
//!   out  {"type":"result","ok":true|false,"reason":"…"} terminal verdict

use std::io::Write as _;
use std::sync::Arc;
use std::time::Duration;

use bytes::BytesMut;
use serde_json::json;
use tokio::io::{AsyncBufReadExt, BufReader};
use webrtc::data_channel::{DataChannel, DataChannelEvent};
use webrtc::peer_connection::{
	register_default_interceptors, MediaEngine, PeerConnection, PeerConnectionBuilder,
	PeerConnectionEventHandler, RTCConfigurationBuilder, RTCIceCandidateInit,
	RTCPeerConnectionIceEvent, RTCSessionDescription, Registry, SettingEngine,
};
use webrtc::runtime::TokioRuntime;

/// The message the browser sends first, and the reply this peer sends back. The
/// harness asserts both, so both directions of the channel are proven.
const EXPECTED_FROM_BROWSER: &str = "ping-from-browser";

/// Write one JSON line to stdout and flush. The harness reads stdout
/// line-buffered, and a piped Rust stdout is block-buffered, so every emit must
/// flush or the harness stalls waiting for the answer.
fn emit(value: &serde_json::Value) {
	let mut out = std::io::stdout().lock();
	let _ = writeln!(out, "{value}");
	let _ = out.flush();
}

#[derive(Clone)]
struct ProbeHandler {
	done_tx: tokio::sync::mpsc::Sender<bool>,
}

#[async_trait::async_trait]
impl PeerConnectionEventHandler for ProbeHandler {
	async fn on_ice_candidate(&self, event: RTCPeerConnectionIceEvent) {
		if let Ok(init) = event.candidate.to_json() {
			if !init.candidate.is_empty() {
				emit(&json!({ "type": "candidate", "candidate": init }));
			}
		}
	}

	async fn on_data_channel(&self, dc: Arc<dyn DataChannel>) {
		let done_tx = self.done_tx.clone();
		tokio::spawn(async move {
			while let Some(event) = dc.poll().await {
				match event {
					DataChannelEvent::OnMessage(msg) => {
						let text = String::from_utf8_lossy(&msg.data).to_string();
						emit(&json!({ "type": "native_recv", "text": text }));
						// Reply so the browser can prove the reverse direction. The
						// reply names what we received, so a stray message cannot
						// masquerade as the expected one.
						let reply = format!("pong-from-native:{text}");
						let ok = text == EXPECTED_FROM_BROWSER;
						let _ = dc.send(BytesMut::from(reply.as_bytes())).await;
						let _ = done_tx.send(ok).await;
					}
					DataChannelEvent::OnClose
					| DataChannelEvent::OnClosing
					| DataChannelEvent::OnError => break,
					_ => {}
				}
			}
		});
	}
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
	// Loopback host candidates are the whole ICE path here: no STUN, no TURN, no
	// discovery. `set_include_loopback_candidate(true)` is what makes the webrtc
	// crate offer 127.0.0.1 as a candidate; the browser offers its own host
	// candidates (the harness disables Chromium's mDNS obfuscation so they are
	// raw IPs), and the two connect directly on the same host.
	let mut setting_engine = SettingEngine::default();
	setting_engine.set_include_loopback_candidate(true);

	// Fires once the round-trip completes (browser message received and reply
	// sent), so main can emit its verdict and exit after a grace window.
	let (done_tx, mut done_rx) = tokio::sync::mpsc::channel::<bool>(1);

	// The data-channel-only setup, mirroring the webrtc crate's own
	// data-channels example: a default media engine with default interceptors.
	let mut media_engine = MediaEngine::default();
	media_engine.register_default_codecs()?;
	let registry = register_default_interceptors(Registry::new(), &mut media_engine)?;

	let pc = PeerConnectionBuilder::new()
		.with_configuration(RTCConfigurationBuilder::default().build())
		.with_media_engine(media_engine)
		.with_interceptor_registry(registry)
		.with_setting_engine(setting_engine)
		.with_handler(Arc::new(ProbeHandler { done_tx }))
		.with_runtime(Arc::new(TokioRuntime))
		.with_udp_addrs(vec!["127.0.0.1:0".to_string()])
		.build()
		.await?;
	let pc: Arc<dyn PeerConnection> = Arc::new(pc);

	// Read signaling from stdin: the browser's offer and its trickled candidates.
	let pc_reader = pc.clone();
	tokio::spawn(async move {
		let mut lines = BufReader::new(tokio::io::stdin()).lines();
		while let Ok(Some(line)) = lines.next_line().await {
			let line = line.trim();
			if line.is_empty() {
				continue;
			}
			let value: serde_json::Value = match serde_json::from_str(line) {
				Ok(value) => value,
				Err(_) => continue,
			};
			match value.get("type").and_then(|t| t.as_str()) {
				Some("offer") => {
					let sdp = value
						.get("sdp")
						.and_then(|s| s.as_str())
						.unwrap_or_default();
					let offer = match RTCSessionDescription::offer(sdp.to_string()) {
						Ok(offer) => offer,
						Err(_) => continue,
					};
					if pc_reader.set_remote_description(offer).await.is_err() {
						continue;
					}
					let answer = match pc_reader.create_answer(None).await {
						Ok(answer) => answer,
						Err(_) => continue,
					};
					if pc_reader
						.set_local_description(answer.clone())
						.await
						.is_err()
					{
						continue;
					}
					emit(&json!({ "type": "answer", "sdp": answer.sdp }));
				}
				Some("candidate") => {
					let init: RTCIceCandidateInit =
						match value.get("candidate").cloned().map(serde_json::from_value) {
							Some(Ok(init)) => init,
							_ => continue,
						};
					let _ = pc_reader.add_ice_candidate(init).await;
				}
				_ => {}
			}
		}
	});

	// Wait for the round-trip, or fail closed on a deadline so a stuck ICE or
	// DTLS negotiation never hangs the gate.
	let verdict = tokio::select! {
		received = done_rx.recv() => received.unwrap_or(false),
		_ = tokio::time::sleep(Duration::from_secs(25)) => {
			emit(&json!({ "type": "result", "ok": false, "reason": "timeout waiting for the channel" }));
			std::process::exit(2);
		}
	};

	if verdict {
		emit(&json!({ "type": "result", "ok": true }));
	} else {
		emit(
			&json!({ "type": "result", "ok": false, "reason": "unexpected message from the browser" }),
		);
	}

	// Give the reply time to reach the browser over the channel before this
	// process (and its DTLS transport) tears down. The harness kills us once the
	// browser confirms the reply, so this is only a floor.
	tokio::time::sleep(Duration::from_secs(3)).await;
	if !verdict {
		std::process::exit(1);
	}
	Ok(())
}
