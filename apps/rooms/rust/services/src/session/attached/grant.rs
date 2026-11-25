//! Issuing and managing access to a session. [`Grants`] does it through the
//! management link the session writes beside its use link, for a process that
//! holds only that link. Issuing returns a use link another process attaches a
//! `View` with, and a management name the issuer keeps to change that one
//! access later. Inventory only describes accesses, so changing one always
//! goes through its control. The free functions here are the same steps over
//! a control already held, which the session's own control socket uses for
//! the controls it saved.
use super::{Error, link};
use glowcap::{
	CaptpVersion, Locator, Runtime,
	loam::{AccessStatus, ControlDescription, ControlPowers, GrantDescription},
};
use rooms_application::{
	content::{
		permissions::Permission,
		session::{KIND, Terms, workspace::Place},
	},
	room::authority::REQUEST_TIMEOUT_MS,
};
use rooms_glowcap::client::{
	Client, Deadline, Error as ClientError,
	access::{Control, Issuance, IssuedAccess},
	workspace::Workspace,
};

/// The longest label an access carries, in bytes.
pub const MAX_LABEL_BYTES: usize = 120;
/// Accesses read from one inventory page.
const PAGE: u8 = 32;
/// Pages read before an inventory that never ends is refused.
const MAX_PAGES: usize = 32;

/// Whether an access can be used.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum State {
	Active,
	Paused,
	Revoked,
}
impl From<AccessStatus> for State {
	fn from(status: AccessStatus) -> Self {
		match status {
			AccessStatus::Active => Self::Active,
			AccessStatus::Paused => Self::Paused,
			AccessStatus::Revoked => Self::Revoked,
		}
	}
}

/// The exact identity of one issued access, which a name's grant and an
/// inventory row share.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct GrantId {
	pub slot: u32,
	pub generation: u64,
}

/// One access as the session describes it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Grant {
	pub id: GrantId,
	/// The revision a change to this access is checked against.
	pub revision: u64,
	pub label: String,
	pub rights: Terms,
	/// The state of this access itself.
	pub state: State,
	/// The state once the accesses it descends from are counted.
	pub effective: State,
}
impl Grant {
	pub(crate) fn read(row: &GrantDescription<'_>) -> Result<Self, Error> {
		let rights = row
			.configured
			.permissions()
			.map(|key| Permission::from_key(key).ok_or(Error::Malformed("an access names an unknown permission")))
			.collect::<Result<Vec<_>, _>>()?;
		Ok(Self {
			id: GrantId {
				slot: row.slot,
				generation: row.generation,
			},
			revision: row.revision,
			label: row.label.into(),
			rights: Terms::new(&rights)
				.map_err(|_| Error::Malformed("an access holds an unsupported permission set"))?,
			state: row.status.into(),
			effective: row.effective_status.into(),
		})
	}
}

/// A change to one access's lifecycle.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Lifecycle {
	/// Stop it from being used until it is resumed.
	Pause,
	/// Let a paused access be used again.
	Resume,
	/// End it for good. Revoking a revoked access changes nothing and succeeds.
	Revoke,
}

/// Issue under `management` an access holding `rights` and no more, which can
/// never be edited to hold others. Its control keeps the lifecycle powers
/// management has, so its issuer can change it later. A paused access is
/// issued that way, so it cannot be used before its issuer is ready.
pub async fn issue_under<D: Deadline + Clone>(
	management: &Control<D>,
	label: &str,
	rights: &Terms,
	paused: bool,
) -> Result<IssuedAccess, Error> {
	issue_at(management, place(management).await?, label, rights, paused).await
}

/// Where `management` derives its next access: its derivation sequence and
/// its revision now. A sequence below the one this reads has been used.
pub async fn place<D: Deadline>(management: &Control<D>) -> Result<Place, Error> {
	let (revision, _) = powers(management).await?;
	let sequence = management.derivation_sequence().await.map_err(failed)?;
	Ok(Place { sequence, revision })
}

/// [`issue_under`] at a place read before. Issuing again at a place already
/// used, with the same label, rights, and pause, returns the access the first
/// issue made. Any other request there is refused.
pub async fn issue_at<D: Deadline + Clone>(
	management: &Control<D>,
	at: Place,
	label: &str,
	rights: &Terms,
	paused: bool,
) -> Result<IssuedAccess, Error> {
	if label.len() > MAX_LABEL_BYTES {
		return Err(Error::Input(format!("a label holds at most {MAX_LABEL_BYTES} bytes")));
	}
	let keys: Vec<u64> = rights.permissions().iter().map(|right| right.key()).collect();
	let terms = rooms_glowcap::policy::descriptor()
		.and_then(|policy| policy.value_for_kind(KIND, &keys, &[]))
		.map_err(|error| Error::Input(error.to_string()))?;
	let (_, powers) = powers(management).await?;
	let issuance = Issuance::new(
		terms.with_ceiling(terms),
		at.sequence,
		at.revision,
		0,
		powers,
		label,
		paused,
	);
	management.issue(&issuance).await.map_err(failed)
}

/// Every access issued under `management`, with its label, rights, and state,
/// up to `MAX_PAGES` pages. One row the session describes in a shape this
/// reader does not know fails the whole read, because a list that skipped it
/// would claim an access is absent that is not.
pub async fn inventory<D: Deadline>(management: &Control<D>) -> Result<Vec<Grant>, Error> {
	let mut grants = Vec::new();
	let mut cursor: Option<Vec<u8>> = None;
	for _ in 0..MAX_PAGES {
		let page = management.inventory(cursor.as_deref(), PAGE).await.map_err(failed)?;
		let view = page.view();
		for row in view.rows() {
			grants.push(Grant::read(&row)?);
		}
		match view.cursor {
			Some(next) => cursor = Some(next.to_vec()),
			None => return Ok(grants),
		}
	}
	Err(Error::Malformed(
		"the inventory did not end within the pages a list reads",
	))
}

/// The access one control manages, as the session describes it now, or
/// `None` once that access is revoked: revoking an access ends its control
/// too, and an ended control no longer says which access it managed.
pub async fn describe<D: Deadline>(control: &Control<D>) -> Result<Option<Grant>, Error> {
	if matches!(
		control.describe().await.map_err(failed)?.view(),
		ControlDescription::Unavailable
	) {
		return Ok(None);
	}
	let described = control.inspect().await.map_err(failed)?;
	Grant::read(&described.view()).map(Some)
}

/// Change the access one control manages, checked against the revision read
/// just before. A change made by someone else in between is `Conflict`, and
/// the caller reads the access again to decide whether its change still
/// applies.
pub async fn change<D: Deadline>(control: &Control<D>, lifecycle: Lifecycle) -> Result<(), Error> {
	let revision = match (revision(control).await, lifecycle) {
		(Err(Error::Revoked), Lifecycle::Revoke) => return Ok(()),
		(revision, _) => revision?,
	};
	match lifecycle {
		Lifecycle::Pause => control.pause(revision).await,
		Lifecycle::Resume => control.resume(revision).await,
		Lifecycle::Revoke => control.revoke(revision).await,
	}
	.map_err(failed)
}

/// The revision a change is checked against. A control the session no longer
/// describes was revoked.
async fn revision<D: Deadline>(control: &Control<D>) -> Result<u64, Error> {
	let state = control.describe().await.map_err(failed)?;
	match state.view() {
		ControlDescription::Available(view) => Ok(view.revision),
		ControlDescription::Unavailable => Err(Error::Revoked),
	}
}

/// What a control holds to hand on: its revision and the lifecycle powers it
/// has, which an issued control keeps so its issuer can change it later.
async fn powers<D: Deadline>(control: &Control<D>) -> Result<(u64, ControlPowers), Error> {
	let state = control.describe().await.map_err(failed)?;
	match state.view() {
		ControlDescription::Available(view) => Ok((
			view.revision,
			ControlPowers {
				inspect: view.inspect,
				pause: view.pause,
				resume: view.resume,
				revoke: view.revoke,
				..ControlPowers::default()
			},
		)),
		ControlDescription::Unavailable => Err(Error::Revoked),
	}
}

/// An access that was issued.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Issued {
	/// The use link a remote holder attaches a `View` with.
	pub link: String,
	/// The management name of this access. Keep it to change the access.
	pub name: String,
}

/// A session's management capability, held over one connection.
pub struct Grants<D: Deadline + Clone> {
	client: Client<D>,
	control: Control<D>,
	locator: Locator,
}
impl<D: Deadline + Clone> Grants<D> {
	/// Dial the session a management link names and hold its capability. A
	/// revoked management capability is refused as `Revoked`.
	pub async fn attach(runtime: &Runtime, platform: D, link: &str) -> Result<Self, Error> {
		let reached = link::reach(runtime, platform, link).await?;
		let grants = Self {
			control: Control::new(reached.client.clone(), reached.reference),
			client: reached.client,
			locator: reached.locator,
		};
		revision(&grants.control).await?;
		Ok(grants)
	}
	/// Issue an active access holding `rights` and no more. The holder of the
	/// returned link attaches a `View`, and the returned name is the only way
	/// to change it later: this process keeps nothing. A lost connection
	/// leaves it unknown whether the access exists. `list` describes one that
	/// does, but cannot recover its name.
	pub async fn issue(&self, label: &str, rights: &Terms) -> Result<Issued, Error> {
		let issued = issue_under(&self.control, label, rights, false).await?;
		let access = Workspace::new(self.client.clone(), issued.access);
		let name = access.durable_name().await.map_err(failed)?;
		let control = Control::new(self.client.clone(), issued.control);
		Ok(Issued {
			link: glowcap::format_sturdyref(&self.locator, name.as_bytes(), CaptpVersion::V1_0)
				.map_err(|_| Error::Malformed("the access name does not make a link"))?,
			name: control.durable_name().await.map_err(failed)?,
		})
	}
	/// Every access the session describes, as [`inventory`] reads them.
	pub async fn list(&self) -> Result<Vec<Grant>, Error> {
		inventory(&self.control).await
	}
	/// The access one management name controls.
	pub async fn grant(&self, name: &str) -> Result<Grant, Error> {
		describe(&self.held(name).await?).await?.ok_or(Error::Revoked)
	}
	/// Stop an access from being used until it is resumed.
	pub async fn pause(&self, name: &str) -> Result<(), Error> {
		change(&self.held(name).await?, Lifecycle::Pause).await
	}
	/// Let a paused access be used again.
	pub async fn resume(&self, name: &str) -> Result<(), Error> {
		change(&self.held(name).await?, Lifecycle::Resume).await
	}
	/// End an access for good. Revoking it again succeeds.
	pub async fn revoke(&self, name: &str) -> Result<(), Error> {
		change(&self.held(name).await?, Lifecycle::Revoke).await
	}
	/// The access this link's own control manages, or `None` once that access
	/// is revoked.
	pub async fn own(&self) -> Result<Option<Grant>, Error> {
		describe(&self.control).await
	}
	/// Pause, resume, or revoke the access this link's own control manages.
	pub async fn change_own(&self, lifecycle: Lifecycle) -> Result<(), Error> {
		change(&self.control, lifecycle).await
	}
	/// The control a management name publishes, fetched from this session.
	async fn held(&self, name: &str) -> Result<Control<D>, Error> {
		if name.is_empty() || name.len() > 64 {
			return Err(Error::Input("not a management name".into()));
		}
		let reference = self
			.client
			.platform()
			.within(REQUEST_TIMEOUT_MS, self.client.session().fetch(name))
			.await
			.ok_or(Error::Unreachable(ClientError::Timeout(link::NO_ANSWER)))?
			.map_err(|error| link::refused_or_failed(error.into()))?;
		Ok(Control::new(self.client.clone(), reference))
	}
}
/// A control conflict means the access changed since it was read.
pub(crate) fn failed(error: ClientError) -> Error {
	match error {
		ClientError::ControlConflict(_) => Error::Conflict,
		error if error.connection_failed() => Error::Unreachable(error),
		error => Error::Peer(error),
	}
}
