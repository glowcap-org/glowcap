//! A byte-transparent relay in Rust — the third-runtime reference for the
//! ADR-0086 relay contract, proving the contract is language-neutral and not a
//! TypeScript-and-Python shape with a doc wrapper.
//!
//! It carries the raw bytes of a keyed CapTP session between a browser peer's
//! WebSocket and a native host, without parsing them, so the keyed handshake and
//! session authority run end to end and the relay holds no capability. The same
//! five-part shape ADR-0086 names, in Rust: the WebSocket adapter is
//! tokio-tungstenite, the pump is the two tasks in `pump`, the byte channel is a
//! `TcpStream` or (with `--features iroh`) the binding's `Stream`, the dial
//! dispatcher is `handle`, and the config comes from generated binding policy.
//! Backpressure is the awaited write on both legs: the target leg blocks on the
//! kernel or the iroh sidecar, the browser-bound leg on tokio-tungstenite's sink.
//! Teardown is pair-atomic: whichever leg ends first aborts the other.
//!
//! Two transports, dispatched by what the WebSocket names:
//!   - `?to=host:port`  a raw TCP socket (byte-level, kernel-backpressured; no
//!                      glowcap dependency, the default build).
//!   - `?locator=<ocapn-uri>`  an iroh byte channel dialed through the glowcap
//!                      Rust binding's `Netlayer::connect_owned`, only with
//!                      `--features iroh`.
//!
//! Prints `RUST-RELAY-READY <port>` on stdout once listening.

use std::io::Write;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

mod policy_gen;

const READ_CHUNK: usize = policy_gen::RELAY_READ_CHUNK_BYTES;

/// The per-connection WebSocket buffers, named rather than inherited.
///
/// tungstenite 0.25 gave `read_buffer_size` a 128 KiB default and its changelog
/// warns that this costs memory "particularly for users expecting a high number
/// of connections", which is exactly what a relay is: `zig build relay-scaling`
/// exists to hold thousands at once and extrapolate a host's RAM ceiling. The
/// write buffer has defaulted to 128 KiB since 0.20 and is named here for the
/// same reason, so the whole per-connection cost is visible in one place.
///
/// 16 KiB per direction matches `steady_outbound_bytes`, the per-connection
/// steady figure the Zig side already budgets against, so the relay and the
/// sessions it carries answer to one number.
const WS_BUFFER_BYTES: usize = policy_gen::RELAY_WEBSOCKET_BUFFER_BYTES;
/// A WebSocket message is a transport chunk, independent from any CapTP frame
/// limit. The relay never needs to materialize a larger message to stay byte
/// transparent.
const WS_MESSAGE_BYTES: usize = policy_gen::WEBSOCKET_MESSAGE_CAP_BYTES;

fn ws_config() -> tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
	tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
		.read_buffer_size(WS_BUFFER_BYTES)
		.write_buffer_size(WS_BUFFER_BYTES)
		.max_message_size(Some(WS_MESSAGE_BYTES))
		.max_frame_size(Some(WS_MESSAGE_BYTES))
}

// The bounded resource defaults come from generated binding policy.
const IDLE_TIMEOUT: Duration = Duration::from_millis(policy_gen::RELAY_IDLE_TIMEOUT_MS);
const MAX_BYTES_PER_SESSION: usize = policy_gen::RELAY_MAX_BYTES_PER_SESSION;

#[derive(Debug)]
struct RelayFailure {
	primary: String,
	secondary: Vec<String>,
}

impl RelayFailure {
	fn new(message: impl Into<String>) -> Self {
		Self {
			primary: message.into(),
			secondary: Vec::new(),
		}
	}

	fn cleanup(mut self, message: impl Into<String>) -> Self {
		self.secondary.push(message.into());
		self
	}
}

impl std::fmt::Display for RelayFailure {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		write!(f, "{}", self.primary)?;
		for secondary in &self.secondary {
			write!(f, "; cleanup also failed: {secondary}")?;
		}
		Ok(())
	}
}

/// The idle timeout, overridable by `GLOWCAP_RELAY_IDLE_MS` for the conformance
/// idle-timeout proof; a production run leaves it unset and gets the default.
fn idle_timeout() -> Duration {
	std::env::var("GLOWCAP_RELAY_IDLE_MS")
		.ok()
		.and_then(|s| s.parse::<u64>().ok())
		.map(Duration::from_millis)
		.unwrap_or(IDLE_TIMEOUT)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
	let port: u16 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(0);
	let listener = TcpListener::bind(("127.0.0.1", port)).await?;
	let bound = listener.local_addr()?.port();
	let mut stdout = std::io::stdout().lock();
	writeln!(stdout, "RUST-RELAY-READY {bound}")?;
	stdout.flush()?;
	drop(stdout);
	loop {
		let (stream, _) = listener.accept().await?;
		tokio::spawn(handle(stream));
	}
}

fn lock_relay<'a, T>(mutex: &'a Mutex<T>, source: &str) -> std::sync::MutexGuard<'a, T> {
	match mutex.lock() {
		Ok(guard) => guard,
		Err(poisoned) => {
			eprintln!("relay: recovered poisoned {source} mutex");
			mutex.clear_poison();
			poisoned.into_inner()
		}
	}
}

async fn handle(stream: TcpStream) {
	// Capture `?to=host:port` and `?locator=<ocapn-uri>` from the upgrade request.
	let parsed: Arc<Mutex<(Option<String>, Option<String>)>> = Arc::new(Mutex::new((None, None)));
	let parsed_cb = parsed.clone();
	let callback = move |req: &Request, resp: Response| -> Result<Response, ErrorResponse> {
		if let Some(query) = req.uri().query() {
			for pair in query.split('&') {
				if let Some(value) = pair.strip_prefix("to=") {
					lock_relay(&parsed_cb, "upgrade-target").0 = Some(value.to_string());
				} else if let Some(value) = pair.strip_prefix("locator=") {
					lock_relay(&parsed_cb, "upgrade-target").1 = Some(percent_decode(value));
				}
			}
		}
		Ok(resp)
	};
	let ws = match tokio_tungstenite::accept_hdr_async_with_config(stream, callback, Some(ws_config())).await {
		Ok(ws) => ws,
		Err(_) => return,
	};
	let (target_to, target_locator) = lock_relay(&parsed, "upgrade-target").clone();

	if let Some(locator) = target_locator {
		dial_iroh_and_pump(ws, &locator).await;
	} else if let Some(to) = target_to.filter(|t| t.contains(':')) {
		match TcpStream::connect(&to).await {
			Ok(tcp) => {
				if let Err(error) = pump(ws, tcp).await {
					eprintln!("relay: session failed: {error}");
				}
			}
			Err(e) => {
				eprintln!("relay: dial failed: {e}");
				if let Err(close) = close_with(ws, CloseCode::Error, "relay dial failed").await {
					eprintln!("relay: WebSocket close after dial failure failed: {close}");
				}
			}
		}
	} else {
		if let Err(close) = close_with(ws, CloseCode::Policy, "relay requires ?to=host:port or ?locator=<uri>").await {
			eprintln!("relay: WebSocket policy close failed: {close}");
		}
	}
}

/// Close the socket with a code and a reason, so the peer learns which leg
/// failed. The three sibling relays (Deno, Python, Racket) send `1008` for a
/// missing or malformed target and `1011` for a dial that could not land;
/// ADR-0086 is one contract with four implementations, so this one says the
/// same thing.
async fn close_with(
	mut ws: WebSocketStream<TcpStream>,
	code: CloseCode,
	reason: &'static str,
) -> Result<(), tokio_tungstenite::tungstenite::Error> {
	ws.close(Some(CloseFrame {
		code,
		reason: reason.into(),
	}))
	.await
}

/// Pump bytes between the WebSocket and any byte channel, both directions, until
/// either leg ends. Generic over the channel so the TCP socket and the iroh
/// stream share one pump. Backpressure is the awaited write on each leg;
/// teardown is pair-atomic.
async fn pump<C>(ws: WebSocketStream<TcpStream>, channel: C) -> Result<(), RelayFailure>
where
	C: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
	let (mut ch_read, mut ch_write) = tokio::io::split(channel);
	let (mut ws_write, mut ws_read) = ws.split();

	// Shared across both legs: a running byte total (the runaway backstop) and a
	// last-activity stamp any chunk re-arms (the idle timeout reclaims a stall).
	let transferred = Arc::new(AtomicUsize::new(0));
	let last_activity = Arc::new(Mutex::new(Instant::now()));

	let transferred_a = transferred.clone();
	let activity_a = last_activity.clone();
	let mut leg_a = tokio::spawn(async move {
		let mut failure = None;
		while let Some(next) = ws_read.next().await {
			let msg = match next {
				Ok(msg) => msg,
				Err(error) => {
					failure = Some(RelayFailure::new(format!("reading WebSocket failed: {error}")));
					break;
				}
			};
			let bytes = match msg {
				Message::Binary(b) => b,
				// A byte relay cannot reinterpret a typed text message as protocol
				// bytes. Ending this leg tears the pair down through the select below.
				Message::Text(_) => {
					failure = Some(RelayFailure::new("WebSocket sent text to the byte relay"));
					break;
				}
				Message::Close(_) => break,
				_ => continue,
			};
			*lock_relay(&activity_a, "activity") = Instant::now();
			if transferred_a.fetch_add(bytes.len(), Ordering::Relaxed) + bytes.len() > MAX_BYTES_PER_SESSION {
				failure = Some(RelayFailure::new("relay session exceeded its byte budget"));
				break;
			}
			if let Err(error) = ch_write.write_all(&bytes).await {
				failure = Some(RelayFailure::new(format!("writing target channel failed: {error}")));
				break;
			}
		}
		if let Err(error) = ch_write.shutdown().await {
			failure = Some(match failure {
				Some(primary) => primary.cleanup(format!("shutting down target writer failed: {error}")),
				None => RelayFailure::new(format!("shutting down target writer failed: {error}")),
			});
		}
		failure.map_or(Ok(()), Err)
	});

	let transferred_b = transferred.clone();
	let activity_b = last_activity.clone();
	let mut leg_b = tokio::spawn(async move {
		let mut buf = vec![0u8; READ_CHUNK];
		let mut failure = None;
		loop {
			let n = match ch_read.read(&mut buf).await {
				Ok(0) => break,
				Ok(n) => n,
				Err(error) => {
					failure = Some(RelayFailure::new(format!("reading target channel failed: {error}")));
					break;
				}
			};
			*lock_relay(&activity_b, "activity") = Instant::now();
			if transferred_b.fetch_add(n, Ordering::Relaxed) + n > MAX_BYTES_PER_SESSION {
				failure = Some(RelayFailure::new("relay session exceeded its byte budget"));
				break;
			}
			// Named boundary copy: tokio-tungstenite's `Message::binary` owns its
			// bytes, so the read chunk is copied once into an owned buffer before
			// the async send. Bounded by `READ_CHUNK` and off glowcap's
			// own wire path — the WebSocket-sink shape of memory.md's binding
			// outbound flush copy.
			if let Err(error) = ws_write.send(Message::binary(buf[..n].to_vec())).await {
				failure = Some(RelayFailure::new(format!("writing WebSocket failed: {error}")));
				break;
			}
		}
		if let Err(error) = ws_write.close().await {
			failure = Some(match failure {
				Some(primary) => primary.cleanup(format!("closing WebSocket writer failed: {error}")),
				None => RelayFailure::new(format!("closing WebSocket writer failed: {error}")),
			});
		}
		failure.map_or(Ok(()), Err)
	});

	// Reclaim a stalled pair: complete once neither leg has moved a chunk for
	// the idle timeout, tearing both legs down through the select below.
	let idle = idle_timeout();
	let activity_w = last_activity.clone();
	let mut watchdog = tokio::spawn(async move {
		loop {
			let idle_for = lock_relay(&activity_w, "activity").elapsed();
			if idle_for >= idle {
				break;
			}
			tokio::time::sleep(idle - idle_for).await;
		}
	});

	let outcome = tokio::select! {
		result = &mut leg_a => {
			leg_b.abort();
			watchdog.abort();
			// Cancellation is the pair-atomic consequence of the selected leg's
			// terminal outcome; join both owners before returning.
			let _cancelled = leg_b.await;
			let _cancelled = watchdog.await;
			result
		}
		result = &mut leg_b => {
			leg_a.abort();
			watchdog.abort();
			let _cancelled = leg_a.await;
			let _cancelled = watchdog.await;
			result
		}
		_ = &mut watchdog => {
			leg_a.abort();
			leg_b.abort();
			let _cancelled = leg_a.await;
			let _cancelled = leg_b.await;
			return Ok(());
		}
	};
	outcome.map_err(|error| RelayFailure::new(format!("relay leg task failed: {error}")))?
}

#[cfg(feature = "iroh")]
async fn dial_iroh_and_pump(ws: WebSocketStream<TcpStream>, locator: &str) {
	use glowcap_rust_dogfood::iroh::{Config, Netlayer, Reachability};
	use glowcap_rust_dogfood::parse_locator;

	let loc = match parse_locator(locator) {
		Ok(loc) if loc.transport == "iroh" => loc,
		Ok(loc) => {
			eprintln!("relay: not an iroh locator (transport {})", loc.transport);
			return;
		}
		Err(e) => {
			eprintln!("relay: unparseable iroh locator: {e}");
			return;
		}
	};
	// The conformance host advertises loopback direct addresses, so the relay
	// reaches it directly; a deployment relay resolves node ids by discovery.
	let direct = match loc.string_hint("direct-addresses") {
		Ok(value) => value.unwrap_or(""),
		Err(e) => {
			eprintln!("relay: invalid iroh locator: {e}");
			return;
		}
	};
	let mut config = Config::new(Reachability::Direct);
	config.worker_threads = Some(1);
	let netlayer = match Netlayer::new(config).await {
		Ok(netlayer) => netlayer,
		Err(e) => {
			eprintln!("relay: iroh netlayer: {e}");
			return;
		}
	};
	match netlayer.connect_owned(&loc.designator, direct).await {
		Ok(stream) => {
			if let Err(error) = pump(ws, stream).await {
				eprintln!("relay: iroh session failed: {error}");
			}
		}
		Err(e) => eprintln!("relay: iroh dial failed: {e}"),
	}
}

#[cfg(not(feature = "iroh"))]
async fn dial_iroh_and_pump(_ws: WebSocketStream<TcpStream>, _locator: &str) {
	eprintln!("relay: iroh not compiled in (build with --features iroh)");
}

/// Percent-decode a `?locator=` value the browser encoded with
/// `encodeURIComponent`. `?to=` values are plain `host:port` and skip this.
fn percent_decode(s: &str) -> String {
	// Decode from the bytes throughout. Slicing `s` here would panic when a
	// `%` sits before a multi-byte character, because `i + 1 .. i + 3` can
	// land inside a UTF-8 sequence — and this string is an inbound query
	// parameter, so that is reachable from inbound bytes.
	fn hex(b: u8) -> Option<u8> {
		match b {
			b'0'..=b'9' => Some(b - b'0'),
			b'a'..=b'f' => Some(b - b'a' + 10),
			b'A'..=b'F' => Some(b - b'A' + 10),
			_ => None,
		}
	}
	let bytes = s.as_bytes();
	let mut out = Vec::with_capacity(bytes.len());
	let mut i = 0;
	while i < bytes.len() {
		if bytes[i] == b'%' && i + 2 < bytes.len() {
			if let (Some(hi), Some(lo)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
				out.push(hi << 4 | lo);
				i += 3;
				continue;
			}
		}
		out.push(bytes[i]);
		i += 1;
	}
	String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
	use super::{percent_decode, RelayFailure};

	#[test]
	fn relay_failure_keeps_cleanup_after_the_primary() {
		let error = RelayFailure::new("write failed").cleanup("close failed");
		assert_eq!(error.primary, "write failed");
		assert_eq!(error.secondary, ["close failed"]);
		assert_eq!(error.to_string(), "write failed; cleanup also failed: close failed");
	}

	#[test]
	fn percent_decode_survives_a_multibyte_char_after_a_percent() {
		// The query value is peer-supplied. Decoding by slicing `&str`
		// panics here, because `i + 1 .. i + 3` lands inside the euro sign's
		// UTF-8 sequence.
		assert_eq!(percent_decode("%\u{20AC}x"), "%\u{20AC}x");
		assert_eq!(percent_decode("%zz"), "%zz");
		assert_eq!(percent_decode("%2"), "%2");
	}

	#[test]
	fn percent_decode_decodes_what_encode_uri_component_produces() {
		assert_eq!(percent_decode("ocapn%3A%2F%2Fabc.iroh"), "ocapn://abc.iroh");
		assert_eq!(percent_decode("plain"), "plain");
	}
}
