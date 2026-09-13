//! One-way websocket publisher for glowcap trace records.
#[cfg(test)]
mod tests;
use crate::Error;
use glowcap::{TraceEvent, TraceKind};
use rooms_glowcap::client::Deadline;
use std::future::Future;
use std::{
	cell::{Cell, RefCell},
	collections::{HashMap, VecDeque},
	rc::Rc,
};
use tokio::sync::watch;
pub enum Input {
	Text(String),
	Closed { code: u16, reason: String },
	Other,
}
/// One websocket to the visualizer. An adapter answers with the runtime's
/// classed error: `Error::closed` when the socket is gone, `Error::storage`
/// for its own I/O failure.
pub trait Socket {
	fn ready(&mut self) -> impl Future<Output = Result<(), Error>> {
		async { Ok(()) }
	}
	fn next(&mut self) -> impl Future<Output = Result<Input, Error>>;
	fn send(&mut self, text: String) -> impl Future<Output = Result<(), Error>>;
	fn close(&mut self) -> impl Future<Output = Result<(), Error>>;
}
pub trait Transport: Deadline + Clone + 'static {
	type Socket: Socket;
	fn connect(&self, target: &str) -> impl Future<Output = Result<Self::Socket, Error>>;
	fn sleep(&self, milliseconds: u64) -> impl Future<Output = ()>;
}

const REFUSED: u16 = 4403;
const RETRY_MS: u64 = 1_000;
const MAX_PENDING: usize = 4096;
const MAX_PENDING_BYTES: usize = 4 * 1024 * 1024;
const MAX_SESSIONS: usize = 256;
// JSON escaping expands an input byte by at most six bytes. Check borrowed
// fields before constructing the JSON tree, including reconnect snapshots.
const MAX_RECORD_TEXT: usize = 2048;
/// The longest one connect, write, or close to the endpoint may take.
const IO_TIMEOUT_MS: u64 = 15_000;

#[derive(Clone)]
pub struct Publisher(Rc<Inner>);
struct Inner {
	pending: RefCell<VecDeque<String>>,
	pending_bytes: Cell<usize>,
	opens: RefCell<HashMap<String, String>>,
	metas: RefCell<HashMap<String, String>>,
	connected: Cell<bool>,
	/// The failure the session shows for a refused or stopped publisher. Keep
	/// its class until the callback edge renders it for the session document.
	refusal: RefCell<Option<Error>>,
	stopped: Cell<bool>,
	dirty: watch::Sender<()>,
	ended: watch::Receiver<Option<Result<(), Error>>>,
}
impl Publisher {
	pub fn start<T: Transport>(
		transport: T,
		scope: String,
		swiss: String,
		on_status: Rc<dyn Fn(bool)>,
		on_refused: Rc<dyn Fn(String)>,
	) -> Self {
		let (dirty, changes) = watch::channel(());
		let (finished, ended) = watch::channel(None);
		let inner = Rc::new(Inner {
			pending: RefCell::new(VecDeque::new()),
			pending_bytes: Cell::new(0),
			opens: RefCell::new(HashMap::new()),
			metas: RefCell::new(HashMap::new()),
			connected: Cell::new(false),
			refusal: RefCell::new(None),
			stopped: Cell::new(false),
			dirty,
			ended,
		});
		let publisher = Self(inner.clone());
		let target = match publish_target(&scope, &swiss) {
			Ok(target) => target,
			Err(reason) => {
				inner.stopped.set(true);
				inner.refusal.borrow_mut().replace(reason.clone());
				finished.send_replace(Some(Err(reason.clone())));
				on_refused(reason.to_string());
				return publisher;
			}
		};
		tokio::task::spawn_local(async move {
			finished.send_replace(Some(
				run(transport, inner, target, on_status, on_refused, changes).await,
			));
		});
		publisher
	}
	pub fn record(&self, event: &TraceEvent) {
		if self.0.stopped.get() {
			return;
		}
		if !record_fits(event) {
			self.refuse(Error::invalid("visualizer trace record exceeds its text budget"));
			return;
		}
		if matches!(event.kind, TraceKind::SessionOpened | TraceKind::SessionMeta) {
			let records = if event.kind == TraceKind::SessionOpened {
				&self.0.opens
			} else {
				&self.0.metas
			};
			let full = {
				let records = records.borrow();
				records.len() >= MAX_SESSIONS && !records.contains_key(&event.session)
			};
			if full {
				self.refuse(Error::exhausted("visualizer trace session capacity reached"));
				return;
			}
		}
		let line = record_line(event);
		match event.kind {
			TraceKind::SessionOpened => {
				self.0.opens.borrow_mut().insert(event.session.clone(), line.clone());
			}
			TraceKind::SessionMeta => {
				self.0.metas.borrow_mut().insert(event.session.clone(), line.clone());
			}
			TraceKind::SessionClosed => {
				self.0.opens.borrow_mut().remove(&event.session);
				self.0.metas.borrow_mut().remove(&event.session);
			}
			TraceKind::MessageDecoded => {}
		}
		// A new publisher receives current sessions once, then live events.
		// Queuing the same opens while disconnected would replay them twice.
		if !self.0.connected.get() {
			return;
		}
		let mut pending = self.0.pending.borrow_mut();
		self.0.pending_bytes.set(self.0.pending_bytes.get() + line.len());
		pending.push_back(line);
		while pending.len() > MAX_PENDING || self.0.pending_bytes.get() > MAX_PENDING_BYTES {
			if let Some(line) = pending.pop_front() {
				self.0.pending_bytes.set(self.0.pending_bytes.get() - line.len());
			}
		}
		self.0.dirty.send_replace(());
	}
	fn refuse(&self, error: Error) {
		self.0.refusal.borrow_mut().replace(error);
		self.stop();
	}
	pub fn connected(&self) -> bool {
		self.0.connected.get()
	}
	pub fn refusal(&self) -> Option<String> {
		self.0.refusal.borrow().as_ref().map(ToString::to_string)
	}
	pub async fn close(&self) -> Result<(), Error> {
		self.stop();
		let mut ended = self.0.ended.clone();
		loop {
			if let Some(result) = ended.borrow().clone() {
				return result;
			}
			ended
				.changed()
				.await
				.map_err(|_| Error::closed("visualizer publisher lost its shutdown owner"))?;
		}
	}

	pub fn stop(&self) {
		self.0.stopped.set(true);
		self.0.connected.set(false);
		self.0.pending.borrow_mut().clear();
		self.0.pending_bytes.set(0);
		self.0.opens.borrow_mut().clear();
		self.0.metas.borrow_mut().clear();
		self.0.dirty.send_replace(());
	}
}

async fn run<T: Transport>(
	transport: T,
	inner: Rc<Inner>,
	target: String,
	on_status: Rc<dyn Fn(bool)>,
	on_refused: Rc<dyn Fn(String)>,
	mut changes: watch::Receiver<()>,
) -> Result<(), Error> {
	while !inner.stopped.get() {
		match bounded(&transport, transport.connect(&target)).await {
			Ok(mut socket) => {
				let mut failed = bounded(&transport, socket.ready()).await.is_err();
				if !failed && !inner.stopped.get() {
					failed = bounded(&transport, await_ready(&mut socket, &inner, &on_refused))
						.await
						.is_err();
				}
				let announced = if inner.stopped.get() || failed {
					Vec::new()
				} else {
					let snapshot = announce(&inner);
					set_connected(&inner, true, &on_status);
					snapshot
				};
				for line in announced {
					if inner.stopped.get() {
						break;
					}
					if deliver(&transport, &mut socket, line).await {
						failed = true;
						break;
					}
				}
				if !failed {
					failed = flush(&transport, &inner, &mut socket).await;
				}
				while !failed && !inner.stopped.get() {
					tokio::select! {
						message = socket.next() => match message {
							Ok(Input::Text(text)) => {
								if ready(&text) {
									set_connected(&inner, true, &on_status);
								}
							}
							Ok(Input::Closed { code, reason }) => {
								set_connected(&inner, false, &on_status);
								if code == REFUSED {
									let reason = if reason.is_empty() { "the endpoint refused this capability".into() } else { reason };
									inner.stopped.set(true);
									inner.refusal.borrow_mut().replace(Error::refused(reason.clone()));
									on_refused(reason);
									break;
								}
								break;
							}
							Ok(Input::Other) => {}
							Err(_) => {
								set_connected(&inner, false, &on_status);
								break;
							}
						},
						result = changes.changed() => {
							if result.is_err() || inner.stopped.get() {
								break;
							}
							failed = flush(&transport, &inner, &mut socket).await;
						}
					}
				}
				set_connected(&inner, false, &on_status);
				// Do not open a replacement while physical retirement is unproven.
				if let Err(error) = bounded(&transport, socket.close()).await {
					set_connected(&inner, false, &on_status);
					inner.stopped.set(true);
					if let Some(primary) = inner.refusal.borrow().clone() {
						// The refusal already stands; the retirement that also
						// failed is retained behind it.
						return Err(primary.retain(error));
					}
					inner.refusal.borrow_mut().replace(error.clone());
					on_refused(error.to_string());
					return Err(error);
				}
			}
			Err(_) => set_connected(&inner, false, &on_status),
		}
		if inner.stopped.get() {
			break;
		}
		transport.sleep(RETRY_MS).await;
	}
	if let Some(reason) = inner.refusal.borrow().as_ref() {
		on_refused(reason.to_string());
	}
	Ok(())
}

/// Every wait on the endpoint is bounded, so a stalled relay costs one
/// timeout and a reconnect rather than a publisher that never notices it was
/// stopped. The elapsed timeout reads as the same failure as a refused write.
async fn bounded<T>(transport: &impl Deadline, work: impl Future<Output = Result<T, Error>>) -> Result<T, Error> {
	transport
		.within(IO_TIMEOUT_MS, work)
		.await
		.ok_or_else(|| Error::closed("visualizer I/O timed out"))?
}
async fn deliver(transport: &impl Deadline, socket: &mut impl Socket, line: String) -> bool {
	bounded(transport, socket.send(line)).await.is_err()
}
/// Send one queued record, then return to the socket select. Trace production
/// can be continuous (including the calls inspecting this publisher), so
/// draining to empty here would starve close frames and endpoint refusals.
async fn flush(transport: &impl Deadline, inner: &Inner, socket: &mut impl Socket) -> bool {
	if inner.stopped.get() {
		return false;
	}
	let next = inner.pending.borrow_mut().pop_front();
	let Some(line) = next else {
		return false;
	};
	inner.pending_bytes.set(inner.pending_bytes.get() - line.len());
	if deliver(transport, socket, line).await {
		return true;
	}
	if !inner.pending.borrow().is_empty() {
		// Keep the coalescing watch edge live without monopolizing this task.
		inner.dirty.send_replace(());
	}
	false
}

fn announce(inner: &Inner) -> Vec<String> {
	let opens = inner.opens.borrow();
	let metas = inner.metas.borrow();
	let mut lines: Vec<_> = opens.values().cloned().collect();
	for (session, line) in metas.iter() {
		if opens.contains_key(session) {
			lines.push(line.clone());
		}
	}
	lines
}

async fn await_ready(socket: &mut impl Socket, inner: &Inner, on_refused: &Rc<dyn Fn(String)>) -> Result<(), Error> {
	let mut changes = inner.dirty.subscribe();
	loop {
		if inner.stopped.get() {
			return Ok(());
		}
		let input = tokio::select! {
			input = socket.next() => input?,
			result = changes.changed() => {
				if result.is_err() || inner.stopped.get() {
					return Ok(());
				}
				continue;
			}
		};
		match input {
			Input::Text(text) if ready(&text) => {
				return Ok(());
			}
			Input::Closed { code, reason } => {
				if code == REFUSED {
					let reason = if reason.is_empty() {
						"the endpoint refused this capability".into()
					} else {
						reason
					};
					inner.stopped.set(true);
					inner.refusal.borrow_mut().replace(Error::refused(reason.clone()));
					on_refused(reason);
				}
				return Err(Error::closed("visualization endpoint closed before admission"));
			}
			_ => {}
		}
	}
}

fn ready(text: &str) -> bool {
	if text.len() > 1024 {
		return false;
	}
	let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
		return false;
	};
	value.get("v") == Some(&serde_json::json!(1))
		&& value.get("kind") == Some(&serde_json::json!("trace.publish-ready"))
}

fn set_connected(inner: &Inner, connected: bool, on_status: &Rc<dyn Fn(bool)>) {
	if inner.connected.get() == connected {
		return;
	}
	inner.connected.set(connected);
	if !connected {
		inner.pending.borrow_mut().clear();
		inner.pending_bytes.set(0);
	}
	on_status(connected);
}

pub(super) fn publish_target(scope: &str, swiss: &str) -> Result<String, Error> {
	if scope != scope.trim() {
		return Err(Error::invalid(
			"the visualizer endpoint cannot begin or end with whitespace",
		));
	}
	if scope.contains('#') {
		return Err(Error::invalid("the visualizer endpoint cannot include a fragment"));
	}
	if !(scope.starts_with("ws://") || scope.starts_with("wss://")) {
		return Err(Error::invalid("the visualizer endpoint must use ws:// or wss://"));
	}
	let (base, query) = scope.split_once('?').unwrap_or((scope, ""));
	// Viewer and publisher are sibling endpoints at the same origin. A viewer
	// scope commonly ends in /trace; appending would hit the web app's fallback.
	let authority_start = base.find("://").expect("scheme checked above") + 3;
	let authority_end = base[authority_start..]
		.find('/')
		.map_or(base.len(), |offset| authority_start + offset);
	if authority_end == authority_start {
		return Err(Error::invalid("the visualizer endpoint must include a host"));
	}
	let published = format!("{}/publish", &base[..authority_end]);
	let cap = format!("cap={swiss}");
	if query.is_empty() {
		Ok(format!("{published}?{cap}"))
	} else {
		let rest: Vec<_> = query
			.split('&')
			.filter(|part| !part.is_empty() && !part.starts_with("cap="))
			.collect();
		if rest.is_empty() {
			Ok(format!("{published}?{cap}"))
		} else {
			Ok(format!("{published}?{}&{cap}", rest.join("&")))
		}
	}
}

fn record_fits(event: &TraceEvent) -> bool {
	let fields = [
		Some(event.session.as_str()),
		event.a.as_deref(),
		event.b.as_deref(),
		event.transport.as_deref(),
		event.a_label.as_deref(),
		event.a_profile,
		event.session_id.as_deref(),
		event.codec,
		event.captp_version,
		event.op.as_deref(),
		event.digest.as_deref(),
		event.meta.as_ref().and_then(|meta| meta.label.as_deref()),
	];
	fields
		.into_iter()
		.flatten()
		.try_fold(0usize, |total, field| {
			total.checked_add(field.len()).filter(|total| *total <= MAX_RECORD_TEXT)
		})
		.is_some()
}

fn record_line(event: &TraceEvent) -> String {
	let mut record = serde_json::Map::new();
	record.insert("v".into(), serde_json::json!(1));
	record.insert("sim_t_ns".into(), event.sim_t_ns.into());
	record.insert("kind".into(), serde_json::Value::String(kind_name(event.kind).into()));
	record.insert("session".into(), serde_json::Value::String(event.session.clone()));
	match event.kind {
		TraceKind::SessionOpened => {
			if let Some(a) = &event.a {
				record.insert("a".into(), a.clone().into());
			}
			if let Some(profile) = event.a_profile {
				record.insert("a_profile".into(), profile.into());
			}
			if let Some(label) = &event.a_label {
				record.insert("a_label".into(), label.clone().into());
			}
			if let Some(b) = &event.b {
				record.insert("b".into(), b.clone().into());
			}
			if let Some(transport) = &event.transport {
				record.insert("transport".into(), transport.clone().into());
			}
			if let Some(session_id) = &event.session_id {
				record.insert("session_id".into(), session_id.clone().into());
			}
			if let Some(codec) = event.codec {
				record.insert("codec".into(), codec.into());
			}
			if let Some(version) = event.captp_version {
				record.insert("captp_version".into(), version.into());
			}
			record.insert("provenance".into(), provenance(event.provenance).into());
		}
		TraceKind::MessageDecoded => {
			record.insert("outbound".into(), event.outbound.into());
			if let Some(op) = &event.op {
				record.insert("op".into(), op.clone().into());
			}
			if let Some(digest) = &event.digest {
				record.insert("digest".into(), digest.clone().into());
			}
			if let Some(len) = event.len {
				record.insert("len".into(), len.into());
			}
		}
		TraceKind::SessionClosed => {}
		TraceKind::SessionMeta => {
			if let Some(meta) = &event.meta {
				record.insert("meta".into(), serde_json::json!({ "label": meta.label }));
			}
		}
	}
	serde_json::Value::Object(record).to_string()
}

fn kind_name(kind: TraceKind) -> &'static str {
	match kind {
		TraceKind::SessionOpened => "ocapn.session-opened",
		TraceKind::MessageDecoded => "ocapn.message-decoded",
		TraceKind::SessionClosed => "ocapn.session-closed",
		TraceKind::SessionMeta => "ocapn.session-meta",
	}
}

fn provenance(value: glowcap::DurableProvenance) -> &'static str {
	match value {
		glowcap::DurableProvenance::AuthenticatedTransport => "authenticated-transport",
		glowcap::DurableProvenance::Unauthenticated => "unauthenticated",
	}
}
