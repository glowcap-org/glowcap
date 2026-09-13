//! One outbound connection per peer, shared by Rooms clients on one Host.
//! Cache entries hold weak client custody. The binding retires the transport
//! when the final owning client leaves; a replacement waits for that outcome.
use crate::Error;
use glowcap::{Locator, Runtime};
use rooms_glowcap::client::{Client, Deadline, Tasks, WeakClient};
use std::{
	cell::{Cell, RefCell},
	collections::BTreeMap,
	rc::Rc,
};
use tokio::sync::{Mutex, watch};

const MAX_PEERS: usize = 64;
pub trait Platform: Deadline + Tasks + Clone + 'static {}
impl<T: Deadline + Tasks + Clone + 'static> Platform for T {}
type Result<T> = std::result::Result<T, Error>;
pub type Terminal = watch::Receiver<Option<Result<()>>>;
pub struct Connection<P> {
	pub client: Client<P>,
	pub ended: Terminal,
}
#[derive(Clone)]
enum Opening<P> {
	Pending,
	Ready(Result<Client<P>>),
	Abandoned,
}
struct Observer<P> {
	active: Rc<Cell<bool>>,
	result: watch::Sender<Opening<P>>,
}
impl<P> Drop for Observer<P> {
	fn drop(&mut self) {
		self.active.set(false);
		// Releasing a completed but unobserved client closes its owned handle.
		self.result.send_replace(Opening::Abandoned);
	}
}
struct State<P: Platform> {
	live: Option<WeakClient>,
	ended: Option<Terminal>,
	worker: Option<P::Task>,
}
impl<P: Platform> Default for State<P> {
	fn default() -> Self {
		Self {
			live: None,
			ended: None,
			worker: None,
		}
	}
}
type PeerSlots<P> = BTreeMap<(String, String), Rc<Mutex<State<P>>>>;
struct Inner<P: Platform> {
	runtime: Rc<Runtime>,
	platform: P,
	peers: RefCell<PeerSlots<P>>,
}
#[derive(Clone)]
pub struct Connections<P: Platform>(Rc<Inner<P>>);
impl<P: Platform> Connections<P> {
	pub fn new(runtime: Rc<Runtime>, platform: P) -> Self {
		Self(Rc::new(Inner {
			runtime,
			platform,
			peers: Default::default(),
		}))
	}
	pub fn runtime(&self) -> &Rc<Runtime> {
		&self.0.runtime
	}
	pub async fn connect(&self, locator: &Locator) -> Result<Connection<P>> {
		let mut bytes = locator.transport.len().saturating_add(locator.designator.len());
		for (key, value) in &locator.hints {
			let value = match value {
				glowcap::HintValue::String(value) => value.len(),
				glowcap::HintValue::Bytes(value) => value.len(),
				glowcap::HintValue::Boolean(_) | glowcap::HintValue::Integer(_) => 8,
			};
			bytes = bytes.saturating_add(key.len()).saturating_add(value).saturating_add(64);
		}
		if bytes > 65_536 {
			return Err(Error::invalid("Rooms peer route exceeds its input bound"));
		}
		let slot = {
			let mut peers = self.0.peers.borrow_mut();
			peers.retain(|_, slot| {
				if Rc::strong_count(slot) > 1 {
					return true;
				}
				let Ok(state) = slot.try_lock() else {
					return true;
				};
				state.ended.as_ref().is_some_and(|ended| ended.borrow().is_none())
			});
			let key = (locator.transport.clone(), locator.designator.clone());
			if peers.len() >= MAX_PEERS && !peers.contains_key(&key) {
				return Err(Error::exhausted("Rooms peer connection capacity is exhausted"));
			}
			peers.entry(key).or_default().clone()
		};
		let mut state = slot.lock().await;
		if let Some(client) = state
			.live
			.as_ref()
			.and_then(|weak| weak.upgrade(self.0.platform.clone()))
			&& client.session().is_open()
		{
			return Ok(Connection {
				client,
				ended: state.ended.as_ref().expect("live connection outcome").clone(),
			});
		}
		if let Some(ended) = state.ended.as_mut() {
			let result = terminal(ended).await;
			state.ended.take();
			state.worker.take();
			state.live.take();
			result?;
		}
		let (published, mut opening) = watch::channel(Opening::Pending);
		let active = Rc::new(Cell::new(true));
		let _observer = Observer {
			active: active.clone(),
			result: published.clone(),
		};
		let (finished, ended) = watch::channel(None);
		state.ended = Some(ended.clone());
		let runtime = self.0.runtime.clone();
		let platform = self.0.platform.clone();
		let locator = locator.clone();
		state.worker = Some(self.0.platform.spawn(async move {
			// The slot owns the dial even when its readiness observer leaves.
			// Its terminal receiver remains installed across that cancellation.
			let session = match runtime.connect(&locator, Default::default()).await {
				Ok(session) => session,
				Err(error) => {
					if active.get() {
						published.send_replace(Opening::Ready(Err(error.into())));
					}
					finished.send_replace(Some(Ok(())));
					return;
				}
			};
			let serving = session.serve();
			let observer = session.borrowed();
			let client = Client::new(session, platform);
			if active.get() {
				published.send_replace(Opening::Ready(Ok(client)));
			} else {
				drop(client);
			}
			let served = serving.await.map_err(Error::from);
			let closed = observer.closed().await.map_err(Error::from);
			// The same failure reported by both halves is one failure, not a
			// failure and its cleanup.
			let outcome = match (&served, &closed) {
				(Err(a), Err(b)) if a.to_string() == b.to_string() => served,
				_ => Error::fold(served, closed),
			};
			finished.send_replace(Some(outcome));
		}));
		let client = loop {
			let observed = opening.borrow().clone();
			match observed {
				Opening::Ready(result) => break result?,
				Opening::Abandoned => return Err(Error::closed("Rooms connection observation retired")),
				Opening::Pending => opening
					.changed()
					.await
					.map_err(|_| Error::closed("Rooms connection opening lost its owner"))?,
			}
		};
		state.live = Some(client.downgrade());
		state.ended = Some(ended.clone());
		Ok(Connection { client, ended })
	}
}
pub async fn terminal(ended: &mut Terminal) -> Result<()> {
	while ended.borrow().is_none() {
		ended
			.changed()
			.await
			.map_err(|_| Error::closed("Rooms connection retirement lost its owner"))?;
	}
	ended.borrow().as_ref().expect("terminal connection").clone()
}
