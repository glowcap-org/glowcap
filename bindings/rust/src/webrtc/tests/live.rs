//! The live proofs through the C provider (`zig build rust-webrtc-driver-provider`):
//! a dial of the Zig WebRTC answerer, an accept of the Zig WebRTC offerer, and
//! two listening Hosts in one process, one of which dials the other.
//!
//! The Zig peers are separate processes that speak one JSON object per line
//! on stdio. The authorities here write to their stdin and read their stdout.

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};

use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::*;
use crate::driver_loop::Provider;
use crate::webrtc::{Config, ListenOptions, Server, listen, provider, refusal};
use crate::{Argument, ConnectOptions, DurableProvenance, PendingWork, Runtime, RuntimeConfig, Session};

const LIVE_DEADLINE: Duration = Duration::from_secs(25);
const GREETING: &str = "hello over webrtc";

/// Kills the Zig peer however the test ends.
struct Peer(Child);

impl Drop for Peer {
	fn drop(&mut self) {
		let _ = self.0.kill();
		let _ = self.0.wait();
	}
}

/// Start one Zig peer under `zig-out/bin` with piped stdio. Its stdout lines
/// arrive parsed on the returned channel.
fn spawn_peer(name: &str, args: &[&str]) -> (Peer, ChildStdin, mpsc::UnboundedReceiver<Value>) {
	let bin = format!("{}/../../zig-out/bin/{name}", env!("CARGO_MANIFEST_DIR"));
	let mut child = Command::new(bin)
		.args(args)
		.stdin(Stdio::piped())
		.stdout(Stdio::piped())
		.spawn()
		.unwrap();
	let stdin = child.stdin.take().unwrap();
	let stdout = child.stdout.take().unwrap();
	let (lines_tx, lines) = mpsc::unbounded_channel::<Value>();
	std::thread::spawn(move || {
		for line in BufReader::new(stdout).lines().map_while(std::result::Result::ok) {
			// A line that is not JSON reaches the router as a kind it refuses.
			let value = serde_json::from_str(&line).unwrap_or_else(|_| json!({ "type": "unparsed", "line": line }));
			if lines_tx.send(value).is_err() {
				break;
			}
		}
	});
	(Peer(child), stdin, lines)
}

/// Wait for the Zig peer to exit, and require that it exited cleanly.
async fn expect_clean_exit(peer: &mut Peer) {
	loop {
		if let Some(status) = peer.0.try_wait().unwrap() {
			assert!(status.success(), "the Zig peer exited with {status}");
			return;
		}
		tokio::time::sleep(Duration::from_millis(50)).await;
	}
}

/// Run `body` on a `LocalSet` in a fresh single-thread runtime with time and
/// I/O, under the deadline every live proof keeps.
fn live<F: Future<Output = ()>>(body: F) {
	let runtime = tokio::runtime::Builder::new_current_thread()
		.enable_all()
		.build()
		.unwrap();
	runtime.block_on(LocalSet::new().run_until(async move {
		tokio::time::timeout(LIVE_DEADLINE, body).await.unwrap();
	}));
}

fn greeter() -> crate::Behavior {
	Box::new(|verb, _args| {
		if verb == "greet" {
			Ok(Argument::String(GREETING.to_string()))
		} else {
			Err(format!("no such method: {verb}"))
		}
	})
}

/// Where one target's far candidates go. The far peer may trickle before the
/// netlayer subscribes, so they are held until then, as the trait asks of an
/// authority. A candidate after the exchange ended has no route and is dropped.
enum Candidates {
	Early(Vec<String>),
	Subscribed(Rc<dyn Fn(String)>),
	Ended,
}

type Sink = Rc<RefCell<Candidates>>;

fn new_sink() -> Sink {
	Rc::new(RefCell::new(Candidates::Early(Vec::new())))
}

/// Hand one far candidate to the subscribed sink, or hold it until there is
/// one. The sink runs with no borrow held, because it calls into the library.
fn deliver(sink: &Sink, ice: String) {
	let subscribed = match &mut *sink.borrow_mut() {
		Candidates::Early(held) => {
			held.push(ice);
			return;
		}
		Candidates::Subscribed(subscribed) => Rc::clone(subscribed),
		Candidates::Ended => return,
	};
	subscribed(ice);
}

/// The `on_candidate` every authority here shares: replay what arrived early,
/// then route the rest straight to `subscribed`.
fn subscribe(sink: &Sink, subscribed: Box<dyn Fn(String)>) -> Box<dyn FnOnce()> {
	let subscribed: Rc<dyn Fn(String)> = Rc::from(subscribed);
	let early = match std::mem::replace(&mut *sink.borrow_mut(), Candidates::Subscribed(Rc::clone(&subscribed))) {
		Candidates::Early(held) => held,
		Candidates::Subscribed(_) | Candidates::Ended => Vec::new(),
	};
	for ice in early {
		subscribed(ice);
	}
	let slot = Rc::clone(sink);
	Box::new(move || *slot.borrow_mut() = Candidates::Ended)
}

/// Route a Zig peer's stdout lines until it closes. `route` panics on a line
/// outside the stdio protocol, and the caller races the returned task against
/// the step the lines feed, so a broken peer fails the proof with its line.
fn route_lines(
	mut lines: mpsc::UnboundedReceiver<Value>,
	mut route: impl FnMut(Value) + 'static,
) -> tokio::task::JoinHandle<()> {
	tokio::task::spawn_local(async move {
		while let Some(line) = lines.recv().await {
			route(line);
		}
	})
}

/// Await `step` unless the router stops first: a panic there names the line
/// that broke the protocol, and a clean end means the peer left early.
async fn unless_router_stops<T>(step: impl Future<Output = T>, router: &mut tokio::task::JoinHandle<()>) -> T {
	tokio::select! {
		value = step => value,
		ended = router => match ended {
			Ok(()) => panic!("the Zig peer closed its stdout before the step finished"),
			Err(error) => std::panic::resume_unwind(error.into_panic()),
		},
	}
}

type Answer = RefCell<Option<oneshot::Sender<String>>>;

/// A Zig peer's stdin, the signaling carrier. The harness closes it once the
/// channel is open, and the peer exits cleanly after its reader ends.
type Carrier = RefCell<Option<ChildStdin>>;

/// Write one JSON line to a Zig peer's stdin.
fn write_line(carrier: &Carrier, line: &Value) -> Result<()> {
	let mut carrier = carrier.borrow_mut();
	let stdin = carrier
		.as_mut()
		.ok_or_else(|| refusal("the peer's signaling carrier is closed"))?;
	writeln!(stdin, "{line}")
		.and_then(|()| stdin.flush())
		.map_err(|error| Error::with_detail(sys::ERR_IO, format!("writing the peer's stdin failed: {error}")))
}

fn candidate_json(ice: &str) -> Result<Value> {
	serde_json::from_str(ice)
		.map_err(|error| Error::with_detail(sys::ERR_INVALID_ARGUMENT, format!("candidate is not JSON: {error}")))
}

/// The dialing side's authority: the answerer's stdio is the carrier.
struct StdioSignaling {
	stdin: Carrier,
	answer: Answer,
	sink: Sink,
}

impl SignalingAuthority for StdioSignaling {
	fn offer(&self, _exchange: u64, _target: Target<'_>, sdp: &str) -> Pin<Box<dyn Future<Output = Result<String>>>> {
		let (tx, rx) = oneshot::channel();
		*self.answer.borrow_mut() = Some(tx);
		let written = write_line(&self.stdin, &json!({ "type": "offer", "sdp": sdp }));
		Box::pin(async move {
			written?;
			rx.await
				.map_err(|_| Error::with_detail(sys::ERR_IO, "the answerer sent no answer".to_string()))
		})
	}

	fn answer(&self, _exchange: u64, _target: Target<'_>, _sdp: &str) -> Result<()> {
		Err(refusal("this authority only dials"))
	}

	fn candidate(&self, _exchange: u64, ice: &str) -> Result<()> {
		write_line(
			&self.stdin,
			&json!({ "type": "candidate", "candidate": candidate_json(ice)? }),
		)
	}

	fn on_candidate(&self, _exchange: u64, _target: Target<'_>, sink: Box<dyn Fn(String)>) -> Box<dyn FnOnce()> {
		subscribe(&self.sink, sink)
	}
}

/// The Rust binding dials the Zig WebRTC answerer through the C provider with
/// its own signaling, fetches `greeter`, and calls `greet`.
#[test]
#[ignore = "live WebRTC; run via `zig build rust-webrtc-driver-provider`"]
fn webrtc_provider_dials_live() {
	let (mut peer, stdin, mut lines) = spawn_peer("glowcap-webrtc-answerer", &[]);
	live(async move {
		let identity = lines.recv().await.unwrap();
		assert_eq!(identity["type"], "identity");
		let designator = identity["designator"].as_str().unwrap().to_string();

		let signaling = Rc::new(StdioSignaling {
			stdin: RefCell::new(Some(stdin)),
			answer: RefCell::new(None),
			sink: new_sink(),
		});
		// Route the answerer's lines: its answer to the waiting offer, each
		// candidate to the subscribed sink.
		let pump = Rc::clone(&signaling);
		let mut router = route_lines(lines, move |line| match line["type"].as_str() {
			Some("answer") => {
				let waiting = pump
					.answer
					.borrow_mut()
					.take()
					.expect("an answer arrived with no offer waiting");
				let sdp = line["sdp"].as_str().expect("an answer line carries its sdp");
				// The dial may have given up already, and its result says why.
				let _ = waiting.send(sdp.to_string());
			}
			Some("candidate") => deliver(&pump.sink, line["candidate"].to_string()),
			_ => panic!("the answerer wrote a line outside the protocol: {line}"),
		});

		let provider = provider(
			Rc::clone(&signaling) as Rc<dyn SignalingAuthority>,
			Config {
				include_loopback_candidates: true,
				..Default::default()
			},
		);
		let runtime = Runtime::open(RuntimeConfig::providers([provider])).await.unwrap();
		let session = unless_router_stops(
			runtime.connect(&locator(&designator), ConnectOptions::default()),
			&mut router,
		)
		.await
		.unwrap();
		// The channel is open, so signaling is over: close the carrier.
		signaling.stdin.borrow_mut().take();
		let greeter = session.fetch("greeter").await.unwrap();
		let reply = session.send(&greeter, "greet", &[]).await.unwrap();
		match reply {
			Argument::String(text) => assert!(!text.is_empty()),
			other => panic!("greet returned {other:?}"),
		}
		session.close(PendingWork::Cancel).await.unwrap();
		runtime.close(PendingWork::Cancel).await.unwrap();
		expect_clean_exit(&mut peer).await;
	});
}

/// The listening side's authority: the offerer's stdio is the carrier. The
/// authority exists before the offerer does, because the listener's
/// designator is the offerer's argument, so its stdin arrives later.
struct OffererStdio {
	stdin: Carrier,
	sink: Sink,
}

impl SignalingAuthority for OffererStdio {
	fn offer(&self, _exchange: u64, _target: Target<'_>, _sdp: &str) -> Pin<Box<dyn Future<Output = Result<String>>>> {
		Box::pin(std::future::ready(Err(refusal("this authority only answers"))))
	}

	fn answer(&self, _exchange: u64, _target: Target<'_>, sdp: &str) -> Result<()> {
		write_line(&self.stdin, &json!({ "type": "answer", "sdp": sdp }))
	}

	fn candidate(&self, _exchange: u64, ice: &str) -> Result<()> {
		write_line(
			&self.stdin,
			&json!({ "type": "candidate", "candidate": candidate_json(ice)? }),
		)
	}

	fn on_candidate(&self, _exchange: u64, _target: Target<'_>, sink: Box<dyn Fn(String)>) -> Box<dyn FnOnce()> {
		subscribe(&self.sink, sink)
	}
}

fn expect_authenticated(session: &Session, designator: &str) {
	let partner = session.partner_identity().unwrap();
	assert_eq!(partner.designator, designator, "the accepted session names the offerer");
	assert_eq!(partner.provenance, DurableProvenance::AuthenticatedTransport);
}

/// The Rust binding listens through the C provider, the Zig WebRTC offerer
/// dials it, and the accepted session names the offerer's key.
#[test]
#[ignore = "live WebRTC; run via `zig build rust-webrtc-driver-provider`"]
fn webrtc_provider_listens_live() {
	live(async move {
		let signaling = Rc::new(OffererStdio {
			stdin: RefCell::new(None),
			sink: new_sink(),
		});
		let sink = Rc::clone(&signaling.sink);
		let server = Rc::new(
			listen(
				Rc::clone(&signaling) as Rc<dyn SignalingAuthority>,
				Config {
					include_loopback_candidates: true,
					..Default::default()
				},
				ListenOptions::default(),
			)
			.await
			.unwrap(),
		);
		server.host().publish("greeter", greeter).unwrap();
		// The advertised locator carries the Host's feature hints as well.
		let advertised = server.locator().unwrap();
		assert_eq!(advertised.transport, locator(server.designator()).transport);
		assert_eq!(advertised.designator, server.designator());

		let (mut peer, stdin, mut lines) = spawn_peer("glowcap-webrtc-offerer", &[server.designator()]);
		*signaling.stdin.borrow_mut() = Some(stdin);
		let identity = lines.recv().await.unwrap();
		assert_eq!(identity["type"], "identity");
		let offerer = identity["designator"].as_str().unwrap().to_string();

		// Route the offerer's lines: its offer into the library, each
		// candidate to the subscribed sink.
		let routed = Rc::clone(&server);
		let from = offerer.clone();
		let mut router = route_lines(lines, move |line| match line["type"].as_str() {
			Some("offer") => {
				let sdp = line["sdp"].as_str().expect("an offer line carries its sdp");
				routed.provide_offer(&from, sdp).unwrap();
			}
			Some("candidate") => deliver(&sink, line["candidate"].to_string()),
			_ => panic!("the offerer wrote a line outside the protocol: {line}"),
		});

		let session = unless_router_stops(server.accept(), &mut router).await.unwrap();
		// The channel is open, so signaling is over: close the carrier.
		signaling.stdin.borrow_mut().take();
		expect_authenticated(&session, &offerer);
		tokio::task::spawn_local(session.serve());
		expect_clean_exit(&mut peer).await;
		server.close().await.unwrap();
		server.host().close(PendingWork::Cancel).await.unwrap();
	});
}

/// What one in-process peer holds for the other: the answer its offer waits
/// for and the sink for the other's candidates.
struct Inbox {
	answer: Answer,
	sink: Sink,
}

impl Default for Inbox {
	fn default() -> Self {
		Self {
			answer: RefCell::new(None),
			sink: new_sink(),
		}
	}
}

type ServerSlot = Rc<RefCell<Option<Rc<Server>>>>;

/// An authority wired straight to another listening Host in this process.
/// The servers are filled in after `listen` returns them.
struct Wire {
	me: Rc<Inbox>,
	far: Rc<Inbox>,
	me_server: ServerSlot,
	far_server: ServerSlot,
}

impl SignalingAuthority for Wire {
	fn offer(&self, _exchange: u64, _target: Target<'_>, sdp: &str) -> Pin<Box<dyn Future<Output = Result<String>>>> {
		let (tx, rx) = oneshot::channel();
		*self.me.answer.borrow_mut() = Some(tx);
		let (me_server, far_server) = (Rc::clone(&self.me_server), Rc::clone(&self.far_server));
		let sdp = sdp.to_owned();
		Box::pin(async move {
			let me = me_server.borrow().clone().ok_or_else(|| refusal("no own listener"))?;
			let far = far_server.borrow().clone().ok_or_else(|| refusal("no far listener"))?;
			// The far Host answers inside this call, through its own `answer`.
			far.provide_offer(me.designator(), &sdp)?;
			rx.await.map_err(|_| refusal("the far listener sent no answer"))
		})
	}

	fn answer(&self, _exchange: u64, _target: Target<'_>, sdp: &str) -> Result<()> {
		let waiting = self
			.far
			.answer
			.borrow_mut()
			.take()
			.ok_or_else(|| refusal("no offer waits"))?;
		waiting.send(sdp.to_owned()).map_err(|_| refusal("the offerer left"))
	}

	fn candidate(&self, _exchange: u64, ice: &str) -> Result<()> {
		deliver(&self.far.sink, ice.to_owned());
		Ok(())
	}

	fn on_candidate(&self, _exchange: u64, _target: Target<'_>, sink: Box<dyn Fn(String)>) -> Box<dyn FnOnce()> {
		subscribe(&self.me.sink, sink)
	}
}

/// Listen on a fresh Host wired to the other, and fill its own slot.
async fn listen_wired(me: &Rc<Inbox>, far: &Rc<Inbox>, me_server: &ServerSlot, far_server: &ServerSlot) -> Rc<Server> {
	let wire = Rc::new(Wire {
		me: Rc::clone(me),
		far: Rc::clone(far),
		me_server: Rc::clone(me_server),
		far_server: Rc::clone(far_server),
	});
	let config = Config {
		include_loopback_candidates: true,
		..Default::default()
	};
	let server = Rc::new(listen(wire, config, ListenOptions::default()).await.unwrap());
	*me_server.borrow_mut() = Some(Rc::clone(&server));
	server
}

/// Two Hosts listen in one process. The first dials the second through the
/// same netlayer it listens with, by a `Runtime` that adopts its Host and adds
/// no provider, and the accepted session names the dialer.
#[test]
#[ignore = "live WebRTC; run via `zig build rust-webrtc-driver-provider`"]
fn a_listening_host_dials_another_in_process() {
	live(async move {
		let (inbox_a, inbox_b) = (Rc::new(Inbox::default()), Rc::new(Inbox::default()));
		let (slot_a, slot_b): (ServerSlot, ServerSlot) = (Rc::new(RefCell::new(None)), Rc::new(RefCell::new(None)));
		let a = listen_wired(&inbox_a, &inbox_b, &slot_a, &slot_b).await;
		let b = listen_wired(&inbox_b, &inbox_a, &slot_b, &slot_a).await;
		assert_ne!(a.designator(), b.designator());
		b.host().publish("greeter", greeter).unwrap();

		let runtime = Runtime::open(RuntimeConfig::providers(Vec::<Provider>::new()).adopt_host(&a.host()))
			.await
			.unwrap();
		let accepting = Rc::clone(&b);
		let accepted = tokio::task::spawn_local(async move { accepting.accept().await.unwrap() });
		let session = runtime
			.connect(&locator(b.designator()), ConnectOptions::default())
			.await
			.unwrap();
		expect_authenticated(&session, b.designator());

		let served = accepted.await.unwrap();
		expect_authenticated(&served, a.designator());
		tokio::task::spawn_local(served.serve());
		let greeter = session.fetch("greeter").await.unwrap();
		let reply = session.send(&greeter, "greet", &[]).await.unwrap();
		assert_eq!(reply, Argument::String(GREETING.to_string()));

		session.close(PendingWork::Cancel).await.unwrap();
		a.close().await.unwrap();
		b.close().await.unwrap();
		a.host().close(PendingWork::Cancel).await.unwrap();
		b.host().close(PendingWork::Cancel).await.unwrap();
	});
}
