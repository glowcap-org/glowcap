//! The live timeline endpoint: one loopback port where producers publish
//! their trace over a WebSocket at `/publish` and viewers open a CapTP
//! session over a WebSocket at `/`, every socket presenting the trace swiss.
//! The room's own trace goes in through the same door every other peer's
//! does. The policy in `rooms_application::server::trace` decides what each
//! line means. This owns the sockets, the trace tap, and the trace object.

use super::super::notice::{Notice, Report};
use glowcap::{Argument, Host, Ref, Session, TraceEvent, TraceKind, current_session};
use rooms_application::server::trace::{self, Endpoint, MAX_SUBSCRIBERS, PUBLISH_PATH, SubscriberQueue};
use serde_json::{Map, Value};
use std::{
	cell::RefCell,
	collections::{BTreeMap, BTreeSet, VecDeque},
	rc::Rc,
	time::Instant,
};
use tokio::{
	net::TcpListener,
	sync::{Notify, mpsc},
	task::JoinHandle,
};
#[cfg(test)]
mod managed_tests;
mod sockets;

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
	ignored: BTreeMap<String, Option<String>>,
	/// Wire identities of this endpoint's active control connections. Remote
	/// producer replay must omit the other sighting of those same connections.
	ignored_wire: BTreeSet<String>,
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
	/// Every subscriber hears `line`. One that cannot keep up is closed, and
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
	/// orderly departure takes. Any other refusal is the viewer's own pace and
	/// goes through `retire`.
	///
	/// The distinction lives here rather than at the delivery site because
	/// `retire` takes its reason as words: a cause laundered into that string is
	/// how a viewer that left came to be journaled as one that could not
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

pub(crate) fn locator(
	port: u16,
	publish: Option<String>,
	connect: Option<String>,
) -> Result<glowcap::Locator, super::super::error::Error> {
	let producer = publish.unwrap_or_else(|| format!("ws://127.0.0.1:{port}{PUBLISH_PATH}"));
	trace::producer_endpoint(&producer).map_err(super::super::error::Error::refused)?;
	let channel = connect.unwrap_or_else(|| format!("ws://127.0.0.1:{port}{}", trace::CHANNEL_PATH));
	rooms_application::web_channel::endpoint(&channel).map_err(super::super::error::Error::refused)?;
	Ok(glowcap::tcp::locator("127.0.0.1", port)
		.with_hint("trace-publish", glowcap::HintValue::String(producer))
		.with_hint(
			rooms_application::web_channel::HINT,
			glowcap::HintValue::String(channel),
		))
}

impl Trace {
	/// Bind the endpoint on `port` (zero takes an ephemeral one) guarded by
	/// `swiss`, publish the trace object under the same swiss, and tap this
	/// process's own trace into the feed.
	pub async fn start(
		port: u16,
		swiss: String,
		publish: Option<String>,
		connect: Option<String>,
		report: Report,
	) -> Result<Self, super::super::error::Error> {
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
			.ok_or_else(|| super::super::error::Error::refused("the trace endpoint refused its own producer"))?;
		let feed: Shared = Rc::new(RefCell::new(Feed {
			endpoint,
			subscribers: Vec::new(),
			viewers: Vec::new(),
			start: Instant::now(),
			report: report.clone(),
			ignored: BTreeMap::new(),
			ignored_wire: BTreeSet::new(),
			own_designator,
			local_scope,
			weak: std::rc::Weak::new(),
		}));
		feed.borrow_mut().weak = Rc::downgrade(&feed);
		let locator = locator(port, publish, connect)?;
		let sturdyref = glowcap::format_sturdyref(&locator, swiss.as_bytes(), glowcap::CaptpVersion::V1_0)?;
		{
			let feed = feed.clone();
			trace_host.publish(&swiss, move || Box::new(trace_object(feed)))?;
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
		let accepting = sockets::accept(listener, feed.clone(), trace_host.clone(), swiss.clone(), port);
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
			let wire = rec.get("session_id").and_then(Value::as_str).map(str::to_owned);
			if let Some(wire) = &wire {
				self.ignored_wire.insert(wire.clone());
			}
			self.ignored.insert(session.into(), wire);
			return false;
		}
		if !self.ignored.contains_key(session) {
			return true;
		}
		if kind == trace::records::CLOSED
			&& let Some(wire) = self.ignored.remove(session).flatten()
		{
			self.ignored_wire.remove(&wire);
		}
		false
	}
	fn admits_remote(&self, rec: &Map<String, Value>) -> bool {
		// Refusing the open also refuses every later record for that producer
		// row at Endpoint::ingest. No remote session alias is kept here.
		!rec.get("session_id")
			.and_then(Value::as_str)
			.is_some_and(|wire| self.ignored_wire.contains(wire))
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
