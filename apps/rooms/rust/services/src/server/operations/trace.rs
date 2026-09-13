//! The live timeline endpoint: one loopback port where producers publish
//! their trace over a WebSocket at `/publish` and viewers open a CapTP
//! session over a WebSocket at `/`, every socket presenting the trace swiss.
//! The room's own trace goes in through the same door every other peer's
//! does. The policy in `rooms_application::server::trace` decides what each
//! line means; this owns the sockets, the trace tap, and the trace object.

use super::super::notice::{Notice, Report};
use glowcap::{Argument, Host, Ref, Session, TraceEvent, TraceKind, current_session};
use rooms_application::server::trace::{
	self, Endpoint, MAX_SUBSCRIBERS, NOT_A_SOCKET, PRODUCER_LIMIT_CLOSE_CODE, PUBLISH_PATH, REFUSED_CLOSE_CODE,
	REFUSED_REASON, SubscriberQueue, constant_time_equals, records::parse_record,
};
use rooms_platform::websocket::WsBytes;
use serde_json::{Map, Value};
use std::{
	cell::RefCell,
	collections::{BTreeSet, VecDeque},
	rc::Rc,
	time::{Duration, Instant},
};
use tokio::{
	net::{TcpListener, TcpStream},
	sync::{Notify, mpsc},
	task::{JoinHandle, JoinSet},
};
use tokio_tungstenite::tungstenite::{
	Message,
	handshake::server::{Request, Response},
	protocol::{CloseFrame, frame::coding::CloseCode},
};

const HANDSHAKE: Duration = Duration::from_secs(10);
/// How long a connection has to say what it is before it is dropped.
const HEAD_DEADLINE: Duration = Duration::from_secs(5);
const TRACE_OBJECT_SUBSCRIBE: &str = "subscribe";

struct Subscriber {
	session: Session,
	inbox: Ref,
	lines: mpsc::Sender<String>,
	queue: SubscriberQueue,
	draining: JoinHandle<()>,
}

/// One viewer's session, with the signal that asks its connection task to
/// close it: retiring a subscriber never spawns a task of its own.
struct Viewer {
	session: Session,
	retire: Rc<Notify>,
}

/// What the tap and the sockets share.
struct Feed {
	endpoint: Endpoint,
	subscribers: Vec<Subscriber>,
	viewers: Vec<Viewer>,
	start: Instant,
	report: Report,
	/// The endpoint's own viewer sessions, kept out of the feed they carry.
	ignored: BTreeSet<String>,
	own_designator: String,
	local_scope: String,
	/// A handle a drain task holds without keeping the feed alive.
	weak: std::rc::Weak<RefCell<Feed>>,
}

type Shared = Rc<RefCell<Feed>>;

impl Feed {
	fn now_ns(&self) -> u64 {
		u64::try_from(self.start.elapsed().as_nanos()).unwrap_or(u64::MAX)
	}
	/// Every subscriber hears `line`; one that cannot keep up is closed, and
	/// a fresh viewer replays.
	fn broadcast(&mut self, line: &str) {
		let mut gone = Vec::new();
		for (at, subscriber) in self.subscribers.iter_mut().enumerate() {
			if !subscriber.queue.admit(line.len()) || subscriber.lines.try_send(line.to_owned()).is_err() {
				gone.push(at);
			}
		}
		for at in gone.into_iter().rev() {
			self.retire(at, "its queue overflowed".into());
		}
	}
	/// A record that did not reach its viewer. A partner that has left is the
	/// ordinary end of a viewer, so it goes quietly through the same removal an
	/// orderly departure takes; any other refusal is the viewer's own pace and
	/// goes through `retire`.
	///
	/// The distinction lives here rather than at the delivery site because
	/// `retire` takes its reason as words: a cause laundered into that string is
	/// how a viewer that simply left came to be journaled as one that could not
	/// keep up, which sent an operator looking for a slow consumer that was
	/// never there.
	fn undeliverable(&mut self, at: usize, session: &Session, cause: &glowcap::Error) {
		if rooms_platform::serving::left(cause) {
			self.remove_subscriber_of(session);
		} else {
			self.retire(at, cause.to_string());
		}
	}
	/// A subscriber that cannot keep up goes: its drain stops, its
	/// connection task closes the session, and the operator's journal says
	/// why. A fresh viewer replays.
	fn retire(&mut self, at: usize, why: String) {
		let subscriber = self.subscribers.remove(at);
		subscriber.draining.abort();
		(self.report)(Notice::Trouble {
			source: "a trace viewer could not keep up".into(),
			reason: why,
		});
		if let Some(viewer) = self
			.viewers
			.iter()
			.find(|viewer| viewer.session.same_session(&subscriber.session))
		{
			viewer.retire.notify_one();
		}
	}
	fn remove_subscriber_of(&mut self, session: &Session) {
		if let Some(at) = self
			.subscribers
			.iter()
			.position(|subscriber| subscriber.session.same_session(session))
		{
			let subscriber = self.subscribers.remove(at);
			subscriber.draining.abort();
			// tolerant: the session is ending or replacing its subscriber.
			let _ = subscriber.session.release(subscriber.inbox);
		}
	}
}

/// The running endpoint.
pub(crate) struct Trace {
	pub sturdyref: String,
	pub port: u16,
	feed: Shared,
	accepting: JoinHandle<()>,
	trace_host: Host,
	uninstall: Option<Box<dyn FnOnce()>>,
	draining: JoinHandle<()>,
}

impl Trace {
	/// Bind the endpoint on `port` (zero takes an ephemeral one) guarded by
	/// `swiss`, publish the trace object under the same swiss, and tap this
	/// process's own trace into the feed.
	pub async fn start(port: u16, swiss: String, report: Report) -> Result<Self, super::super::error::Error> {
		let listener = TcpListener::bind(("127.0.0.1", port)).await?;
		let port = listener.local_addr()?.port();
		let mut seed = [0u8; 32];
		rooms_platform::entropy::fill(&mut seed)
			.map_err(|e| super::super::error::Error::refused(format!("drawing the trace host seed failed: {e}")))?;
		let trace_host = Host::from_seed_with_options(seed, rooms_glowcap::host_options())?;
		let own_designator = trace_host.designator()?;
		let epoch = super::super::state::State::wall_clock();
		let mut endpoint = Endpoint::new(epoch);
		let local_scope = endpoint
			.admit_producer(false)
			.expect("the endpoint's own producer is never bounded");
		let feed: Shared = Rc::new(RefCell::new(Feed {
			endpoint,
			subscribers: Vec::new(),
			viewers: Vec::new(),
			start: Instant::now(),
			report: report.clone(),
			ignored: BTreeSet::new(),
			own_designator,
			local_scope,
			weak: std::rc::Weak::new(),
		}));
		feed.borrow_mut().weak = Rc::downgrade(&feed);
		let locator = glowcap::tcp::locator("127.0.0.1", port);
		let sturdyref = glowcap::format_sturdyref(&locator, swiss.as_bytes(), glowcap::CaptpVersion::V1_0)?;
		{
			let feed = feed.clone();
			trace_host.publish_giftable(&swiss, move || Box::new(trace_object(feed)))?;
		}
		// The tap runs at the fact site, inside the host; it only queues.
		// Everything that touches a session happens in the drain below.
		let taps: Rc<RefCell<VecDeque<Map<String, Value>>>> = Rc::new(RefCell::new(VecDeque::new()));
		let wake = Rc::new(Notify::new());
		let uninstall = {
			let (taps, wake) = (taps.clone(), wake.clone());
			glowcap::enable_trace(
				Box::new(move |event: &TraceEvent| {
					taps.borrow_mut().push_back(project(event));
					wake.notify_one();
				}),
				Some("rooms"),
			)
		};
		let drain = {
			let feed = feed.clone();
			async move {
				loop {
					wake.notified().await;
					loop {
						let next = taps.borrow_mut().pop_front();
						let Some(rec) = next else {
							break;
						};
						{
							let mut feed = feed.borrow_mut();
							if feed.admits_own(&rec) {
								let now = feed.now_ns();
								let scope = feed.local_scope.clone();
								for stamped in feed.endpoint.ingest(&scope, rec, now) {
									feed.broadcast(&stamped.line);
								}
							}
						}
						// A burst of the room's own records must not starve
						// the subscribers' drains: a viewer's queue is bounded
						// against a viewer that cannot keep up, not against a
						// tap that never let it try.
						tokio::task::yield_now().await;
					}
				}
			}
		};
		let draining = tokio::task::spawn_local(drain);
		let accepting = accept(listener, feed.clone(), trace_host.clone(), swiss.clone(), port);
		let accepting = tokio::task::spawn_local(accepting);
		Ok(Self {
			sturdyref,
			port,
			feed,
			accepting,
			trace_host,
			uninstall: Some(Box::new(uninstall)),
			draining,
		})
	}
	/// Stop tapping, stop accepting, and retire the trace host with every
	/// viewer session on it.
	pub async fn close(mut self) {
		if let Some(uninstall) = self.uninstall.take() {
			uninstall();
		}
		self.accepting.abort();
		self.draining.abort();
		let subscribers = std::mem::take(&mut self.feed.borrow_mut().subscribers);
		for subscriber in subscribers {
			subscriber.draining.abort();
		}
		if let Err(cause) = self.trace_host.close(glowcap::PendingWork::Cancel).await {
			self.feed.borrow().report.clone()(Notice::Trouble {
				source: "closing the trace trace host".into(),
				reason: cause.to_string(),
			});
		}
	}
}

impl Feed {
	/// The endpoint's own viewer sessions are not rows in the trace they
	/// deliver: an open naming this host's designator as `a` is remembered,
	/// and every later record for that session is dropped through its close.
	fn admits_own(&mut self, rec: &Map<String, Value>) -> bool {
		let session = rec.get("session").and_then(Value::as_str).unwrap_or("");
		let kind = rec.get("kind").and_then(Value::as_str).unwrap_or("");
		if kind == trace::records::OPENED && rec.get("a").and_then(Value::as_str) == Some(self.own_designator.as_str())
		{
			self.ignored.insert(session.into());
			return false;
		}
		if !self.ignored.contains(session) {
			return true;
		}
		if kind == trace::records::CLOSED {
			self.ignored.remove(session);
		}
		false
	}
}

/// Accept sockets for as long as the endpoint stands. Every connection task
/// is owned here: a panic in one is reported, and aborting this task takes
/// them all with it.
async fn accept(listener: TcpListener, feed: Shared, trace_host: Host, swiss: String, port: u16) {
	let mut connections = JoinSet::new();
	loop {
		tokio::select! {
			accepted = listener.accept() => match accepted {
				Ok((stream, _)) => {
					connections.spawn_local(connection(
						stream,
						feed.clone(),
						trace_host.clone(),
						swiss.clone(),
						port,
					));
				}
				Err(error) => {
					feed.borrow().report.clone()(Notice::Trouble {
						source: "the trace endpoint could not accept a socket".into(),
						reason: error.to_string(),
					});
					tokio::time::sleep(rooms_platform::serving::ACCEPT_RETRY).await;
				}
			},
			Some(ended) = connections.join_next(), if !connections.is_empty() => {
				if let Err(join) = ended {
					feed.borrow().report.clone()(Notice::Trouble {
						source: "a trace connection task failed".into(),
						reason: join.to_string(),
					});
				}
			}
		}
	}
}

/// One trace fact in the versioned timeline schema.
fn project(event: &TraceEvent) -> Map<String, Value> {
	let mut rec = Map::new();
	rec.insert("v".into(), Value::from(1));
	rec.insert("sim_t_ns".into(), Value::from(event.sim_t_ns));
	let kind = match event.kind {
		TraceKind::SessionOpened => trace::records::OPENED,
		TraceKind::MessageDecoded => trace::records::MESSAGE,
		TraceKind::SessionClosed => trace::records::CLOSED,
		TraceKind::SessionMeta => trace::records::META,
	};
	rec.insert("kind".into(), Value::from(kind));
	rec.insert("session".into(), Value::from(event.session.as_str()));
	fn text(rec: &mut Map<String, Value>, name: &str, value: Option<&str>) {
		if let Some(value) = value {
			rec.insert(name.into(), Value::from(value));
		}
	}
	match event.kind {
		TraceKind::SessionOpened => {
			text(&mut rec, "a", event.a.as_deref());
			text(&mut rec, "b", event.b.as_deref());
			text(&mut rec, "transport", event.transport.as_deref());
			text(&mut rec, "a_label", event.a_label.as_deref());
			text(&mut rec, "a_profile", event.a_profile);
			text(&mut rec, "session_id", event.session_id.as_deref());
			text(&mut rec, "codec", event.codec);
			text(&mut rec, "captp_version", event.captp_version);
			text(
				&mut rec,
				"provenance",
				Some(match event.provenance {
					glowcap::DurableProvenance::AuthenticatedTransport => "authenticated-transport",
					glowcap::DurableProvenance::Unauthenticated => "unauthenticated",
				}),
			);
		}
		TraceKind::MessageDecoded => {
			rec.insert("outbound".into(), Value::from(event.outbound));
			text(&mut rec, "op", event.op.as_deref());
			text(&mut rec, "digest", event.digest.as_deref());
			if let Some(len) = event.len {
				rec.insert("len".into(), Value::from(len));
			}
			text(&mut rec, "bytes_b64", event.bytes_b64.as_deref());
			if let Some(summary) = &event.summary {
				let mut head = Map::new();
				head.insert("len".into(), Value::from(summary.len));
				head.insert("head_b64".into(), Value::from(summary.head_b64.as_str()));
				rec.insert("summary".into(), Value::Object(head));
			}
		}
		TraceKind::SessionMeta => {
			let mut meta = Map::new();
			if let Some(annotation) = &event.meta {
				// A withdrawn claim is an explicit null: a viewer treats a
				// missing label as nothing to change.
				meta.insert(
					"label".into(),
					annotation.label.as_deref().map_or(Value::Null, Value::from),
				);
			}
			rec.insert("meta".into(), Value::Object(meta));
		}
		TraceKind::SessionClosed => {}
	}
	rec
}

/// What the upgrade request asked for: its path and query, read during the
/// handshake and answered after it.
#[derive(Clone, Default)]
struct Asked(Rc<RefCell<Option<Uri>>>);
/// A request's path and query.
type Uri = (String, Option<String>);

impl tokio_tungstenite::tungstenite::handshake::server::Callback for Asked {
	// The refusal type is the handshake crate's; nothing here refuses.
	#[allow(clippy::result_large_err)]
	fn on_request(
		self,
		request: &Request,
		response: Response,
	) -> Result<Response, tokio_tungstenite::tungstenite::handshake::server::ErrorResponse> {
		*self.0.borrow_mut() = Some((
			request.uri().path().to_owned(),
			request.uri().query().map(str::to_owned),
		));
		Ok(response)
	}
}

/// One socket: a plain request is told where the doors are; an upgrade is
/// admitted only with the capability, then serves as a producer or a viewer.
async fn connection(stream: TcpStream, feed: Shared, trace_host: Host, swiss: String, port: u16) {
	let mut head = [0u8; 4096];
	let peeked = match tokio::time::timeout(HEAD_DEADLINE, stream.peek(&mut head)).await {
		Ok(Ok(peeked)) => peeked,
		_ => return,
	};
	let head = String::from_utf8_lossy(&head[..peeked]).to_ascii_lowercase();
	if !head.contains("upgrade: websocket") {
		let body = NOT_A_SOCKET;
		let response = format!(
			"HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
			body.len()
		);
		let mut stream = stream;
		use tokio::io::AsyncWriteExt;
		// tolerant: a refused plain request that cannot even be answered is
		// simply dropped.
		let _ = stream.write_all(response.as_bytes()).await;
		let _ = stream.shutdown().await;
		return;
	}
	let asked = Asked::default();
	let ws = tokio_tungstenite::accept_hdr_async(stream, asked.clone()).await;
	let Ok(mut ws) = ws else {
		return;
	};
	let (path, query) = asked.0.borrow().clone().unwrap_or_default();
	let presented = query
		.as_deref()
		.unwrap_or("")
		.split('&')
		.find_map(|pair| pair.strip_prefix("cap="))
		.unwrap_or("");
	use futures_util::{SinkExt, StreamExt};
	if !constant_time_equals(presented, &swiss) {
		// Refused with no handlers installed: nothing sent is parsed.
		let _ = ws
			.send(Message::Close(Some(CloseFrame {
				code: CloseCode::from(REFUSED_CLOSE_CODE),
				reason: REFUSED_REASON.into(),
			})))
			.await;
		return;
	}
	if path == PUBLISH_PATH {
		let scope = feed.borrow_mut().endpoint.admit_producer(true);
		let Some(scope) = scope else {
			let _ = ws
				.send(Message::Close(Some(CloseFrame {
					code: CloseCode::from(PRODUCER_LIMIT_CLOSE_CODE),
					reason: format!("rooms trace: producer limit {} reached", trace::MAX_REMOTE_PRODUCERS).into(),
				})))
				.await;
			return;
		};
		let ready = {
			let feed = feed.borrow();
			feed.endpoint.publish_ready_line(feed.now_ns())
		};
		if ws.send(Message::Text(ready.into())).await.is_err() {
			let mut feed = feed.borrow_mut();
			let now = feed.now_ns();
			for stamped in feed.endpoint.drop_producer(&scope, true, now) {
				feed.broadcast(&stamped.line);
			}
			return;
		}
		while let Some(Ok(message)) = ws.next().await {
			let Message::Text(text) = message else {
				continue;
			};
			let Some(rec) = parse_record(text.as_str()) else {
				continue;
			};
			{
				let mut feed = feed.borrow_mut();
				let now = feed.now_ns();
				for stamped in feed.endpoint.ingest(&scope, rec, now) {
					feed.broadcast(&stamped.line);
				}
			}
			// A producer's burst arrives already buffered on its socket, so
			// the socket never parks this loop; the drains get their turn
			// between records rather than after the whole burst.
			tokio::task::yield_now().await;
		}
		let mut feed = feed.borrow_mut();
		let now = feed.now_ns();
		for stamped in feed.endpoint.drop_producer(&scope, true, now) {
			feed.broadcast(&stamped.line);
		}
		return;
	}
	// A viewer: the socket is the byte channel of a CapTP session on the
	// trace host, where the trace object answers.
	let designator = format!("127.0.0.1:{port}");
	let session = match Session::accept_channel(
		&trace_host,
		glowcap::AcceptedTransport {
			transport: "tcp",
			designator: glowcap::ChannelDesignator::Address(&designator),
			local_address: &designator,
			verified_channel_key: None,
		},
		WsBytes::new(ws).into_channel(),
		Some(HANDSHAKE),
	)
	.await
	{
		Ok(session) => session,
		Err(cause) => {
			feed.borrow().report.clone()(Notice::Trouble {
				source: "a trace viewer could not open its session".into(),
				reason: cause.to_string(),
			});
			return;
		}
	};
	// Retiring the viewer's subscription asks this task to close the
	// session, so a viewer that cannot keep up ends here, on its own turn.
	let retire = Rc::new(Notify::new());
	feed.borrow_mut().viewers.push(Viewer {
		session: session.borrowed(),
		retire: retire.clone(),
	});
	let served = tokio::select! {
		served = session.serve() => served,
		_ = retire.notified() => Ok(()),
	};
	{
		let mut feed = feed.borrow_mut();
		feed.remove_subscriber_of(&session);
		feed.viewers.retain(|viewer| !viewer.session.same_session(&session));
	}
	let closed = session.close(glowcap::PendingWork::Cancel).await;
	for outcome in [served, closed] {
		if let Err(cause) = outcome
			&& !rooms_platform::serving::left(&cause)
		{
			feed.borrow().report.clone()(Notice::Trouble {
				source: "a trace viewer session ended".into(),
				reason: cause.to_string(),
			});
		}
	}
}

/// The trace object: `subscribe(inbox)` replays the live topology to the
/// inbox and then every line as it goes out.
fn trace_object(feed: Shared) -> impl FnMut(&str, &[Argument]) -> Result<Argument, String> {
	move |verb, args| {
		let session = current_session()
			.map_err(|e| e.to_string())?
			.ok_or("trace.subscribe requires a session")?;
		let (TRACE_OBJECT_SUBSCRIBE, [Argument::Reference(inbox)]) = (verb, args) else {
			return Err("trace.subscribe expects one inbox capability".into());
		};
		let mut feed = feed.borrow_mut();
		feed.remove_subscriber_of(&session);
		if feed.subscribers.len() >= MAX_SUBSCRIBERS {
			// tolerant: a refused inbox goes back; a failed release ends with
			// the session that imported it.
			let _ = session.release(inbox.clone());
			return Err("trace subscriber limit reached".into());
		}
		let (lines, mut queued) = mpsc::channel::<String>(trace::MAX_SUBSCRIBER_QUEUE);
		let mut queue = SubscriberQueue::default();
		let now = feed.now_ns();
		for line in feed.endpoint.replay(now) {
			if !queue.admit(line.len()) || lines.try_send(line).is_err() {
				return Err("the replay outgrew the subscriber's queue".into());
			}
		}
		let drain = {
			let (session, inbox, feed) = (session.borrowed(), inbox.clone(), feed_handle(&feed));
			async move {
				while let Some(line) = queued.recv().await {
					let bytes = line.len();
					// A record is told, not asked: nothing here waits on the
					// viewer's answer, so a slow viewer shows up as outbound
					// pressure on its session rather than as one round trip
					// per record holding every later record back.
					let told = session.tell(&inbox, "record", &[Argument::String(line)]);
					let Some(feed) = feed.upgrade() else {
						return;
					};
					let mut feed = feed.borrow_mut();
					let Some(at) = feed
						.subscribers
						.iter()
						.position(|subscriber| subscriber.session.same_session(&session))
					else {
						return;
					};
					match told {
						Ok(()) => feed.subscribers[at].queue.drained(bytes),
						Err(cause) => {
							feed.undeliverable(at, &session, &cause);
							return;
						}
					}
				}
			}
		};
		let draining = tokio::task::spawn_local(drain);
		feed.subscribers.push(Subscriber {
			session: session.borrowed(),
			inbox: inbox.clone(),
			lines,
			queue,
			draining,
		});
		Ok(Argument::Void)
	}
}

/// A weak handle for a drain task, so a task never keeps the feed alive.
fn feed_handle(feed: &Feed) -> std::rc::Weak<RefCell<Feed>> {
	feed.weak.clone()
}
