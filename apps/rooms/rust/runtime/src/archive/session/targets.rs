use super::*;

use glowcap::{PendingWork, Session};
use rooms_glowcap::client::{Client, archive::Archive};
use std::cell::RefCell;
use tokio::sync::Notify;
const MAX_TARGETS: usize = 16;
pub struct KeptRecord<P: Platform> {
	pub record: Arc<Record>,
	pub keeper: Keeper<P>,
}
#[derive(Clone)]
pub enum Keeper<P: Platform> {
	Local(Local<P>),
	Peer(Peer<P>),
}
#[derive(Clone)]
pub struct Local<P: Platform> {
	pub(super) owner: std::rc::Weak<State<P>>,
}
/// A view holds the exact archive that supplied its record through selection
/// changes. The session owner can revoke all leases during final shutdown.
pub struct Peer<P: Platform>(Rc<Target<P>>);
impl<P: Platform> Clone for Peer<P> {
	fn clone(&self) -> Self {
		self.0.lease()
	}
}
impl<P: Platform> Drop for Peer<P> {
	fn drop(&mut self) {
		self.0.uses.set(self.0.uses.get() - 1);
		self.0.notify.notify_one();
	}
}
impl<P: Platform> Peer<P> {
	pub(super) async fn page(&self, filter: &Filter, after: u64, limit: usize) -> Result<Page, Error> {
		if self.0.closed.get() {
			return Err(Error::closed("archive source is closed"));
		}
		let result = self.0.archive.read(filter, after, limit).await.map_err(Error::peer);
		if self.0.closed.get() {
			return Err(Error::closed("archive source is closed"));
		}
		result
	}

	pub async fn blob(&self, digest: &str) -> Result<Blob<P>, Error> {
		if self.0.closed.get() {
			return Err(Error::closed("archive source is closed"));
		}
		let reader = self.0.archive.blob(digest).await.map_err(Error::peer)?;
		if self.0.closed.get() {
			return Err(Error::closed("archive source is closed"));
		}
		Ok(Blob {
			reader,
			keeper: self.clone(),
		})
	}
}
pub struct Blob<P: Platform> {
	reader: rooms_glowcap::client::archive::Blob<P>,
	keeper: Peer<P>,
}
impl<P: Platform> Blob<P> {
	pub async fn read(&self, offset: u64, maximum: usize) -> Result<Vec<u8>, Error> {
		if self.keeper.0.closed.get() {
			return Err(Error::closed("archive source is closed"));
		}
		self.reader.read(offset, maximum).await.map_err(Error::peer)
	}
}
pub(super) struct Target<P: Platform> {
	pub archive: Archive<P>,
	pub standings: RefCell<rooms_application::archive::recording::Standings>,
	pub link: String,
	reference: glowcap::Ref,
	session: RefCell<Option<Session>>,
	closed: Cell<bool>,
	uses: Cell<usize>,
	notify: Rc<Notify>,
	_watch: P::Task,
}
impl<P: Platform> Target<P> {
	fn is_open(&self) -> bool {
		!self.closed.get() && self.session.borrow().as_ref().is_some_and(Session::is_open)
	}
	pub fn lease(self: &Rc<Self>) -> Peer<P> {
		self.uses.set(self.uses.get() + 1);
		Peer(self.clone())
	}
	async fn release(&self) -> Result<(), Error> {
		self.closed.set(true);
		let session = self.session.borrow_mut().take();
		match session {
			Some(session) => {
				let released = self.release_reference(&session);
				let closed = session.relinquish(PendingWork::Cancel).await.map_err(Error::from);
				Error::fold(released, closed)
			}
			None => Ok(()),
		}
	}
	fn release_reference(&self, session: &Session) -> Result<(), Error> {
		if session.is_open() {
			Ok(session.release(self.reference.clone())?)
		} else {
			Ok(())
		}
	}
	fn invalidate(&self) {
		self.closed.set(true);
		if let Some(session) = self.session.borrow_mut().take() {
			let _ = self.release_reference(&session);
		}
	}
}
/// What recordings and reads go to. `Unavailable` carries the link that was
/// selected but could not be opened, so reselecting it retries the open.
pub(super) enum Selection<P: Platform> {
	Local,
	Unavailable(String),
	Peer(Rc<Target<P>>),
}
pub(super) struct Targets<P: Platform> {
	platform: P,
	runtime: Rc<Runtime>,
	pub selected: Selection<P>,
	prepared: Option<Rc<Target<P>>>,
	retired: Vec<Rc<Target<P>>>,
	pub notify: Rc<Notify>,
	cleanup_failures: u64,
}
impl<P: Platform> Targets<P> {
	pub fn new(platform: P, runtime: Rc<Runtime>) -> Self {
		Self {
			platform,
			runtime,
			selected: Selection::Local,
			prepared: None,
			retired: Vec::new(),
			notify: Rc::new(Notify::new()),
			cleanup_failures: 0,
		}
	}
	async fn open(&mut self, link: String) -> Result<Rc<Target<P>>, Error> {
		// Retire unused predecessors before charging a replacement. Failures
		// remain in the worker's cleanup report even if lookup later refuses.
		self.cleanup_failures = self.collect(false).await;
		if self.retired.len()
			+ usize::from(self.prepared.is_some())
			+ usize::from(matches!(self.selected, Selection::Peer(_)))
			>= MAX_TARGETS
		{
			return Err(Error::exhausted("archive source leases are at their ceiling"));
		}
		let reference = self
			.platform
			.within(
				rooms_application::room::authority::REQUEST_TIMEOUT_MS,
				self.runtime
					.host()
					.enliven_for_version(&link, glowcap::CaptpVersion::V1_0),
			)
			.await
			.ok_or_else(|| Error::peer(rooms_glowcap::client::Error::Timeout("archive lookup timed out")))??;
		let session = self
			.runtime
			.host()
			.reference_session(&reference)?
			.ok_or_else(|| Error::closed("archive capability has no live exporter"))?;
		let client = Client::new(session.borrowed(), self.platform.clone());
		let opened = async {
			let archive = Archive::new(client.clone(), reference.clone());
			archive.read(&Filter::default(), 0, 1).await.map_err(Error::peer)?;
			Ok::<_, Error>(archive)
		}
		.await;
		match opened {
			Ok(archive) => {
				let watching = session.borrowed();
				let notify = self.notify.clone();
				let watch = self.platform.spawn(async move {
					let _ = watching.ended().await;
					notify.notify_one();
				});
				Ok(Rc::new(Target {
					archive,
					standings: Default::default(),
					link,
					reference,
					session: RefCell::new(Some(session)),
					closed: Cell::new(false),
					uses: Cell::new(0),
					notify: self.notify.clone(),
					_watch: watch,
				}))
			}
			Err(primary) => {
				drop(reference);
				let cleanup = session.relinquish(PendingWork::Cancel).await.map_err(Error::from);
				Err(primary.retain_result(cleanup))
			}
		}
	}
	pub async fn prepare(&mut self, link: String) -> Result<(), Error> {
		if self.prepared.as_ref().is_some_and(|p| p.link == link)
			|| matches!(&self.selected, Selection::Peer(p) if p.link == link)
		{
			return Ok(());
		}
		let target = if let Some(index) = self.retired.iter().position(|p| p.link == link) {
			self.retired.swap_remove(index)
		} else {
			self.open(link).await?
		};
		if let Some(old) = self.prepared.replace(target) {
			self.retired.push(old);
		}
		Ok(())
	}
	/// Reports a changed selection; a failed open leaves it explicitly unavailable.
	pub async fn select(&mut self, link: Option<String>) -> Result<bool, Error> {
		let unchanged = matches!((&self.selected, &link), (Selection::Local, None))
			|| matches!((&self.selected, &link), (Selection::Peer(peer), Some(link)) if &peer.link == link);
		if unchanged {
			// A preparation belongs to the candidate checkpoint, not merely to its
			// worker command. Reobserving the current selection after a failed write
			// retires that uncommitted target without disturbing the live one.
			if let Some(old) = self.prepared.take() {
				self.retired.push(old);
			}
			return Ok(false);
		}
		let next = match link {
			None => Selection::Local,
			Some(link) => Selection::Unavailable(link),
		};
		if let Selection::Peer(old) = core::mem::replace(&mut self.selected, next) {
			self.retired.push(old);
		}
		let link = match &self.selected {
			Selection::Unavailable(link) => link.clone(),
			_ => {
				if let Some(old) = self.prepared.take() {
					self.retired.push(old);
				}
				return Ok(true);
			}
		};
		let target = if self.prepared.as_ref().is_some_and(|p| p.link == link) {
			self.prepared.take().unwrap()
		} else if let Some(index) = self.retired.iter().position(|p| p.link == link) {
			self.retired.swap_remove(index)
		} else {
			self.open(link).await?
		};
		if !target.is_open() {
			self.retired.push(target);
			return Err(Error::closed(
				"the selected archive peer became unavailable before selection",
			));
		}
		self.selected = Selection::Peer(target);
		Ok(true)
	}
	/// A terminal call failure changes the realized outcome without changing
	/// durable selection intent. Later operations refuse specifically instead of
	/// writing into the local archive; reselecting the same link retries opening it.
	pub fn mark_selected_unavailable(&mut self) {
		let Selection::Peer(peer) = &self.selected else { return };
		let link = peer.link.clone();
		if let Selection::Peer(old) = core::mem::replace(&mut self.selected, Selection::Unavailable(link)) {
			self.retired.push(old);
		}
	}
	pub fn selected_closed(&self) -> bool {
		matches!(&self.selected, Selection::Peer(peer) if !peer.is_open())
	}
	pub async fn collect(&mut self, all: bool) -> u64 {
		if all {
			if let Selection::Peer(old) = core::mem::replace(&mut self.selected, Selection::Local) {
				self.retired.push(old);
			}
			if let Some(old) = self.prepared.take() {
				self.retired.push(old);
			}
		}
		let mut failures = core::mem::take(&mut self.cleanup_failures);
		let mut index = 0;
		while index < self.retired.len() {
			if all || self.retired[index].uses.get() == 0 {
				let target = self.retired.swap_remove(index);
				if target.release().await.is_err() {
					failures += 1;
				}
			} else {
				index += 1;
			}
		}
		failures
	}
}

impl<P: Platform> Drop for Targets<P> {
	fn drop(&mut self) {
		// Interrupted worker execution invalidates retained views immediately.
		// Explicit close remains the completion barrier for transport teardown.
		for target in self.retired.iter().chain(self.prepared.iter()) {
			target.invalidate();
		}
		if let Selection::Peer(target) = &self.selected {
			target.invalidate();
		}
	}
}
