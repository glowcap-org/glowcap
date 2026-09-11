//! Persisted grants and their durable publications have one lifecycle.
//! Attached-view notices remain the session behavior's effect, after apply.
use crate::{
	documents::{Completion, Document},
	grants::{DurableGrants, LoadError},
};
use glowcap::{Argument, Host};
use rooms_application::grants::{
	derive_entropy, ApplyError, Change, Command, Error as PolicyError, Grant, GrantPolicy,
};
use std::{cell::Cell, collections::BTreeMap, fmt, rc::Rc};

/// Every delivered call receives the current committed grant, including its
/// suspension and independent history permission. No issuance-time policy copy.
pub type GrantedBehavior = Box<dyn FnMut(&GrantAuthority, &Grant, &str, &[Argument]) -> Result<Argument, String>>;

/// A live publication permission, including publication shutdown/recovery.
/// Deferred effects retain this handle, never a copy of committed rights.
#[derive(Clone)]
pub struct GrantAuthority {
	policy: GrantPolicy,
	ready: Rc<Cell<bool>>,
}
impl GrantAuthority {
	pub fn read<T>(&self, use_grant: impl FnOnce(&Grant) -> T) -> Result<T, String> {
		if !self.ready.get() {
			return Err("Rooms grant publications are unavailable".into());
		}
		self.policy.read(use_grant).map_err(|error| error.to_string())
	}
}

pub struct PublishedGrants<D: Document> {
	grants: DurableGrants<D>,
	host: Host,
	root: [u8; Host::DURABLE_ENTROPY_BYTES],
	names: BTreeMap<String, String>,
	make: Box<dyn FnMut() -> GrantedBehavior>,
	ready: Rc<Cell<bool>>,
	closed: bool,
}

#[derive(Debug)]
pub struct PublicationFailure {
	pub id: String,
	pub error: glowcap::Error,
}

#[derive(Debug)]
pub enum Error<E> {
	Policy(PolicyError),
	NotPublished(String),
	Load(LoadError<E>),
	Apply(ApplyError<E>),
	/// Policy is already committed when change is Some. Failed removal stays
	/// indexed so a later reconcile/close retries it; live refs are refused now.
	Publication {
		change: Option<Change>,
		failures: Vec<PublicationFailure>,
	},
}
impl<E> From<PolicyError> for Error<E> {
	fn from(e: PolicyError) -> Self {
		Self::Policy(e)
	}
}
impl<E: std::error::Error> fmt::Display for Error<E> {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Policy(e) => e.fmt(f),
			Self::NotPublished(id) => write!(f, "Rooms grant {id} is persisted but not published"),
			Self::Load(e) => e.fmt(f),
			Self::Apply(e) => write!(f, "grant persistence refused: {e:?}"),
			Self::Publication { change, failures } => {
				write!(f, "grant publication failed (committed change: {change:?})")?;
				for failure in failures {
					write!(f, "; {}: {}", failure.id, failure.error)?;
				}
				Ok(())
			}
		}
	}
}
impl<E: std::error::Error> std::error::Error for Error<E> {}

impl<D: Document> PublishedGrants<D> {
	pub fn new(
		grants: DurableGrants<D>,
		host: Host,
		root: [u8; Host::DURABLE_ENTROPY_BYTES],
		make: impl FnMut() -> GrantedBehavior + 'static,
	) -> Self {
		Self {
			grants,
			host,
			root,
			names: BTreeMap::new(),
			make: Box::new(make),
			ready: Rc::new(Cell::new(false)),
			closed: false,
		}
	}
	/// No restored facet answers until the complete active set is published.
	/// Failed startup keeps successful rows for retry without duplicating them.
	pub async fn restore(&mut self) -> Result<(), Error<D::Error>> {
		if self.closed {
			return Err(PolicyError::Revoked.into());
		}
		self.ready.set(false);
		self.grants.load().await.map_err(Error::Load)?;
		self.reconcile_change(None)?;
		self.ready.set(true);
		Ok(())
	}
	pub async fn finish_pending(&mut self) -> Option<Completion<D::Error>> {
		self.grants.finish_pending().await
	}
	pub fn grants(&self) -> Result<core::cell::Ref<'_, rooms_application::grants::GrantLedger>, Error<D::Error>> {
		self.require_ready()?;
		Ok(self.grants.ledger()?)
	}
	pub fn swiss(&self, id: &str) -> Result<Option<&str>, Error<D::Error>> {
		self.require_ready()?;
		let ledger = self.grants.ledger()?;
		if !ledger.get(id)?.is_some_and(|g| !g.revoked()) {
			return Ok(None);
		}
		self.names
			.get(id)
			.map(|name| Some(name.as_str()))
			.ok_or_else(|| Error::NotPublished(id.into()))
	}
	/// Verify actual publication custody and its current policy, not a cached
	/// grant view. The caller already established this Host's route identity.
	pub fn verify_name(&self, swiss: &[u8]) -> Result<(), String> {
		self.require_ready().map_err(|e| e.to_string())?;
		let (id, _) = self
			.names
			.iter()
			.find(|(_, name)| name.as_bytes() == swiss)
			.ok_or("Rooms session has no such published grant")?;
		let ledger = self.grants.ledger().map_err(|e| e.to_string())?;
		let grant = ledger
			.get(id)
			.map_err(|e| e.to_string())?
			.ok_or("Rooms grant is missing")?;
		if grant.access() == rooms_application::grants::Access::None {
			return Err("Rooms grant is revoked or suspended".into());
		}
		Ok(())
	}
	fn require_ready(&self) -> Result<(), Error<D::Error>> {
		if self.closed {
			Err(PolicyError::Revoked.into())
		} else if !self.ready.get() {
			Err(PolicyError::RecoveryRequired.into())
		} else {
			Ok(())
		}
	}
	pub async fn apply(&mut self, command: Command) -> Result<Change, Error<D::Error>> {
		self.require_ready()?;
		let change = self.grants.apply(command).await.map_err(Error::Apply)?;
		self.reconcile_change(Some(change))?;
		Ok(change)
	}
	/// Retry publication effects without rewriting policy. In particular, a
	/// retry of an already revoked id still removes its failed publication.
	pub fn reconcile(&mut self) -> Result<(), Error<D::Error>> {
		self.require_ready()?;
		self.reconcile_change(None)
	}
	fn reconcile_change(&mut self, change: Option<Change>) -> Result<(), Error<D::Error>> {
		if self.closed {
			return Err(PolicyError::Revoked.into());
		}
		let active: Vec<String> = self
			.grants
			.ledger()?
			.records()?
			.filter(|g| !g.revoked())
			.map(|g| g.id().to_owned())
			.collect();
		let retired: Vec<String> = self.names.keys().filter(|id| !active.contains(id)).cloned().collect();
		let mut failures = self.remove(&retired);
		for id in active {
			if self.names.contains_key(&id) {
				continue;
			}
			let policy = self.grants.policy(&id)?;
			let entropy = derive_entropy(&self.root, &id)?;
			let authority = GrantAuthority {
				policy,
				ready: self.ready.clone(),
			};
			let make = &mut self.make;
			match self.host.publish_durable_with_entropy(entropy, || {
				let mut behavior = make();
				Box::new(move |verb, args| authority.read(|grant| behavior(&authority, grant, verb, args))?)
			}) {
				Ok(name) => {
					self.names.insert(id, name);
				}
				Err(error) => failures.push(PublicationFailure { id, error }),
			}
		}
		if failures.is_empty() {
			Ok(())
		} else {
			Err(Error::Publication { change, failures })
		}
	}
	fn remove(&mut self, ids: &[String]) -> Vec<PublicationFailure> {
		let mut failures = Vec::new();
		for id in ids {
			let name = &self.names[id];
			match self.host.remove_durable(name) {
				Ok(_) => {
					self.names.remove(id);
				}
				Err(error) => failures.push(PublicationFailure { id: id.clone(), error }),
			}
		}
		failures
	}
	/// Terminal for every held facet even when Host cleanup needs a retry.
	/// The caller still owns Host shutdown and the other session documents.
	pub fn close(&mut self) -> Result<(), Error<D::Error>> {
		self.closed = true;
		self.ready.set(false);
		let ids: Vec<_> = self.names.keys().cloned().collect();
		let failures = self.remove(&ids);
		if failures.is_empty() {
			Ok(())
		} else {
			Err(Error::Publication { change: None, failures })
		}
	}
}
impl<D: Document> Drop for PublishedGrants<D> {
	fn drop(&mut self) {
		self.ready.set(false);
	}
}
