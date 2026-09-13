//! Received archive shares have a transient owner. Snapshot lists metadata only;
//! live archive refs and their delivering Direct session stay here until redeem.
use crate::{
	Error,
	directories::runtime::AcceptedDirect,
	entropy::{self, Entropy},
};
use glowcap::{Argument, Ref, Session};
use rooms_application::{
	archive::ShareKind,
	fields::Nullable,
	session::snapshot::{
		Field, Id, Text,
		views::{ArchiveShare, Custody, ShareStatus},
	},
};
use std::{
	cell::RefCell,
	rc::{Rc, Weak},
};
use tokio::sync::watch;

pub const LIMIT: usize = 16;

pub struct ArchiveShares(Rc<State>);
#[derive(Clone)]
pub struct ShareReceiver(Weak<State>);
struct State {
	entropy: RefCell<Box<dyn Entropy>>,
	rows: RefCell<Vec<Row>>,
	changed: watch::Sender<()>,
	stop: watch::Sender<bool>,
}
struct Row {
	view: ArchiveShare,
	archive: Option<Ref>,
	/// Delivering Direct session. A view: dropping it does not close the route.
	session: Option<Session>,
}
/// What a received share carries: a durable link to redeem later, or a live
/// archive capability on the session that delivered it.
enum Received {
	Durable { link: String },
	Live { archive: Ref, session: Session },
}
impl ArchiveShares {
	pub fn new(entropy: impl Entropy + 'static) -> Self {
		let (changed, _) = watch::channel(());
		let (stop, _) = watch::channel(false);
		Self(Rc::new(State {
			entropy: RefCell::new(Box::new(entropy)),
			rows: RefCell::new(Vec::new()),
			changed,
			stop,
		}))
	}
	pub fn receiver(&self) -> ShareReceiver {
		ShareReceiver(Rc::downgrade(&self.0))
	}
	pub fn changes(&self) -> watch::Receiver<()> {
		self.0.changed.subscribe()
	}
	pub fn close(&self) {
		self.0.stop.send_replace(true);
		self.0.rows.borrow_mut().clear();
		self.0.changed.send_replace(());
	}
}
impl Drop for ArchiveShares {
	fn drop(&mut self) {
		self.close();
	}
}
impl ShareReceiver {
	pub fn views(&self) -> Vec<ArchiveShare> {
		self.0
			.upgrade()
			.map(|state| state.rows.borrow().iter().map(|row| row.view.clone()).collect())
			.unwrap_or_default()
	}
	pub fn get(&self, id: &str) -> Option<(ArchiveShare, Option<Ref>, Option<Session>)> {
		self.0.upgrade().and_then(|state| {
			state
				.rows
				.borrow()
				.iter()
				.find(|row| row.view.id.text().as_str() == Some(id))
				.map(|row| {
					(
						row.view.clone(),
						row.archive.clone(),
						row.session.as_ref().map(Session::borrowed),
					)
				})
		})
	}
	pub fn drop_share(&self, id: &str) -> bool {
		let Some(state) = self.0.upgrade() else {
			return false;
		};
		let mut rows = state.rows.borrow_mut();
		let Some(index) = rows.iter().position(|row| row.view.id.text().as_str() == Some(id)) else {
			return false;
		};
		rows.remove(index);
		state.changed.send_replace(());
		true
	}
	pub fn offer(
		&self,
		context: &AcceptedDirect,
		directory: &str,
		kind: ShareKind,
		conversation: Option<&str>,
		link: &str,
	) -> Result<Argument, Error> {
		self.push(
			context,
			directory,
			kind,
			conversation,
			Received::Durable { link: link.to_owned() },
		)
	}
	pub fn hand(
		&self,
		context: &AcceptedDirect,
		session: Session,
		directory: &str,
		kind: ShareKind,
		conversation: Option<&str>,
		archive: Ref,
	) -> Result<Argument, Error> {
		self.push(
			context,
			directory,
			kind,
			conversation,
			Received::Live { archive, session },
		)
	}
	fn push(
		&self,
		context: &AcceptedDirect,
		directory: &str,
		kind: ShareKind,
		conversation: Option<&str>,
		received: Received,
	) -> Result<Argument, Error> {
		let (custody, status, link, archive, session) = match received {
			Received::Durable { link } => (Custody::Durable, ShareStatus::Offered, link, None, None),
			Received::Live { archive, session } => (
				Custody::Live,
				ShareStatus::Offered,
				String::new(),
				Some(archive),
				Some(session),
			),
		};
		if !context.current() {
			return Err(Error::closed("the archive share's direct conversation has retired"));
		}
		let state = self
			.0
			.upgrade()
			.ok_or_else(|| Error::closed("the archive-share owner has ended"))?;
		if *state.stop.borrow() {
			return Err(Error::closed("the archive-share owner has ended"));
		}
		if state.rows.borrow().len() >= LIMIT {
			return Err(Error::exhausted(
				"this Rooms session has reached its archive-share custody limit",
			));
		}
		let directory = if directory.is_empty() {
			context.directory().clone()
		} else {
			Id::new(directory.into()).ok_or_else(|| Error::invalid("archive share directory exceeds snapshot field"))?
		};
		let view = ArchiveShare {
			id: entropy::random_id(state.entropy.borrow_mut().as_mut(), "archive-share-")?,
			directory,
			conversation_id: context.conversation().clone(),
			from: Text::new(context.peer().text().clone())
				.ok_or_else(|| Error::invalid("archive share sender exceeds snapshot field"))?,
			status,
			error: Field::new("".into()).ok_or_else(|| Error::invalid("archive share error exceeds snapshot field"))?,
			kind,
			scope_conversation: match conversation.filter(|value| !value.is_empty()) {
				Some(value) => Nullable::Value(value.into()),
				None => Nullable::Null,
			},
			custody,
			sturdyref: Field::new(link.into())
				.ok_or_else(|| Error::invalid("archive share link exceeds snapshot field"))?,
		};
		state.rows.borrow_mut().push(Row { view, archive, session });
		state.changed.send_replace(());
		Ok(Argument::Void)
	}
}
