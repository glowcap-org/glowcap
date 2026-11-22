//! Access the terminal issues and manages through the running session. The
//! session issues with its own management control and keeps each control in
//! the workspace's `accesses` rows, the rows the page keeps its controls in,
//! so the terminal and the page list and change one set. A row's id is how
//! the terminal names an access. No bearer name leaves the session except the
//! use link of an access just issued, in that one reply.
//!
//! Issuing commits its row first, with the place the access is derived at,
//! then issues there, then saves the control into that row. Issuing again at
//! a used place with the same request returns the same access, so an issue
//! the session stopped in the middle of is finished by issuing again with the
//! same id, label, and rights, and no issued access is ever left without the
//! row that can end it.
use super::{Application, Failure, peer_failure};
use crate::session::attached::{self, Error, Grant, GrantId, Lifecycle, State};
use rooms_application::content::session::{
	Preset, Terms,
	custody::{Coordinate, FieldKey, Role, SessionControl},
	workspace::{self, Entry, Issue},
};
use rooms_application::failure::Retry;
use rooms_glowcap::client::{
	Error as ClientError,
	access::Control,
	workspace::{Import, Workspace},
};
use rooms_platform::HostPlatform;
use serde_json::{Value, json};

/// Attempts at saving a control when another writer moves the workspace
/// between the read and the commit.
const SAVE_ATTEMPTS: usize = 3;

/// The rights an access can be issued with. An administrator also takes part,
/// so it holds the collaborator's rights and the custody rights on top.
pub fn rights(name: &str) -> Result<Terms, String> {
	let collaborator = || Terms::new(Preset::Collaborator.values());
	let terms = match name {
		"observer" => Terms::new(Preset::Observer.values()),
		"collaborator" => collaborator(),
		"administrator" => collaborator().and_then(|terms| terms.apply(Preset::Administrator)),
		_ => return Err("--rights must be observer, collaborator, or administrator".into()),
	};
	terms.map_err(|error| error.to_string())
}

/// Issue an access and keep its control under row `id`. The access starts
/// paused and is resumed only once its control is saved, so an access the
/// session cannot manage is never usable. A failed save revokes it.
pub(super) async fn issue(app: &Application, id: &str, label: &str, rights_name: &str) -> Result<Value, Failure> {
	let row = row_id(id)?;
	let terms = rights(rights_name).map_err(Failure::invalid)?;
	let at = reserve(app, &row).await?;
	let issued = attached::issue_at(&app.management, at, label, &terms, true)
		.await
		.map_err(|error| {
			let error = failure(error);
			let message = format!(
				"{error}. The issue under {id} did not finish. Issue again with the same id, label, and rights to finish it"
			);
			error.explained(message)
		})?;
	ended_after_issue();
	let control = local_control(app, issued.control);
	let grant = attached::describe(&control).await.map_err(failure)?;
	if let Err(unsaved) = save(app, &row, &control, grant.as_ref().map(|grant| grant.id)).await {
		let error = match unsaved {
			// An issue at the same place returns the same access, so a second
			// issue under this id finished it, and its link works.
			Unsaved::Elsewhere => {
				return Err(Failure::new(
					"conflict",
					Retry::Never,
					format!("another issue under {id} finished this access first and printed its link"),
				));
			}
			Unsaved::Failed(error) => error,
		};
		return Err(match attached::change(&control, Lifecycle::Revoke).await {
			Ok(()) => {
				let message = format!(
					"the access was revoked unused because its control could not be saved: {error}. Issue again with the same id, label, and rights, then forget it"
				);
				error.explained(message)
			}
			Err(revoke) => Failure::uncertain(format!(
				"the access could not be saved ({error}) or revoked ({}). It is paused and its link was never shown, so nobody can use it. Issue again with the same id, label, and rights to finish it",
				failure(revoke)
			)),
		});
	}
	let Some(grant) = grant else {
		return Err(Failure::invalid(format!(
			"the access issued under {id} was revoked before its issue finished. Forget it and issue again"
		)));
	};
	let saved_paused = |error: Error| {
		let error = failure(error);
		let message = format!(
			"the access is saved paused as {id}, and its link was not shown: {error}. Revoke it, forget it, and issue again"
		);
		error.explained(message)
	};
	let name = Workspace::local(app.host.clone(), HostPlatform, issued.access)
		.durable_name()
		.await
		.map_err(|error| saved_paused(attached::failed(error)))?;
	let link = glowcap::format_sturdyref(&app.locator, name.as_bytes(), glowcap::CaptpVersion::V1_0)
		.map_err(|_| saved_paused(Error::Malformed("the access name does not make a link")))?;
	if grant.state == State::Paused {
		attached::change(&control, Lifecycle::Resume)
			.await
			.map_err(saved_paused)?;
	}
	Ok(json!({"ok": true, "link": link, "id": id, "label": label, "rights": names(&terms)}))
}

/// Test-only: with the `test-support` feature,
/// `GLOWCAP_ROOMS_SESSION_FAULT=after-issue`
/// ends the session process between issuing an access and saving its
/// control, so a process test can prove the next issue finishes it. A build
/// without the feature contains no trace of this.
fn ended_after_issue() {
	#[cfg(feature = "test-support")]
	if std::env::var_os("GLOWCAP_ROOMS_SESSION_FAULT").is_some_and(|point| point == "after-issue") {
		std::process::abort();
	}
}

/// The place to issue row `id`'s access at. A new id commits a row holding a
/// fresh place. A row whose issue did not finish keeps its place once the
/// session has used it, and takes a fresh one otherwise.
async fn reserve(app: &Application, id: &workspace::Id) -> Result<workspace::Place, Failure> {
	for attempt in 1..=SAVE_ATTEMPTS {
		let snapshot = app.workspace.snapshot().await.map_err(peer_failure)?;
		let mut intent = snapshot.intent;
		let fresh = attached::place(&app.management).await.map_err(failure)?;
		let rows = &mut intent.accesses;
		match rows.as_slice().iter().position(|row| row.id == *id) {
			Some(index) => match rows.as_slice()[index].issue {
				Some(Issue::Unsaved(at)) if fresh.sequence > at.sequence || at == fresh => return Ok(at),
				Some(Issue::Unsaved(_)) => rows.as_mut_slice()[index].issue = Some(Issue::Unsaved(fresh)),
				_ => return Err(Failure::invalid("an access is already kept under this id")),
			},
			None => rows
				.try_push(workspace::Access {
					id: id.clone(),
					access: None,
					control: None,
					issue: Some(Issue::Unsaved(fresh)),
				})
				.map_err(|_| {
					Failure::exhausted("the session keeps as many accesses as it can. Revoke and forget one first")
				})?,
		}
		let submitted = app
			.workspace
			.prepare_acquisition(snapshot.revision, Vec::new(), &[], &intent)
			.map_err(Failure::invalid)?
			.submit()
			.await;
		match submitted {
			Ok(()) => return Ok(fresh),
			Err(ClientError::WorkspaceConflict) if attempt < SAVE_ATTEMPTS => {}
			Err(error) => return Err(peer_failure(error)),
		}
	}
	Err(conflict())
}

/// Every access issued under the session's management, each with the row id
/// it is managed by. An access whose control the session did not keep, such
/// as one issued with the management link by another process, has no id. A
/// revoked access's control no longer says which access it managed, so a row
/// finds its revoked access by the inventory entry it saved. A row saved
/// without one is listed on its own, revoked, with a note that says so, until
/// it is forgotten. A row whose issue did not finish is listed as
/// `unfinished`. Every row says whether the session keeps its control.
pub(super) async fn list(app: &Application) -> Result<Value, Failure> {
	let issued = attached::inventory(&app.management).await.map_err(failure)?;
	let snapshot = app.workspace.snapshot().await.map_err(peer_failure)?;
	let mut kept = Vec::new();
	let mut unfinished = Vec::new();
	for saved in snapshot.intent.accesses.as_slice() {
		let Some(id) = saved.id.text().as_str().map(str::to_owned) else {
			continue;
		};
		let Some(key) = saved.control else {
			if matches!(saved.issue, Some(Issue::Unsaved(_))) {
				unfinished.push(id);
			}
			continue;
		};
		let described = match restore(app, key).await {
			Ok(control) => attached::describe(&control).await.map_err(failure),
			Err(error) => Err(error),
		};
		let entry = match saved.issue {
			Some(Issue::Saved(Entry { slot, generation })) => Some(GrantId { slot, generation }),
			_ => None,
		};
		kept.push((id, entry, described));
	}
	let manages = |entry: &Option<GrantId>, described: &Result<Option<Grant>, Failure>, grant: &Grant| match described {
		Ok(Some(kept)) => kept.id == grant.id,
		Ok(None) => *entry == Some(grant.id),
		Err(_) => false,
	};
	let mut rows = Vec::with_capacity(issued.len());
	for grant in &issued {
		let id = kept
			.iter()
			.find(|(_, entry, described)| manages(entry, described, grant))
			.map(|(id, _, _)| id.as_str());
		rows.push(row(id, grant));
	}
	for (id, entry, described) in &kept {
		if issued.iter().any(|grant| manages(entry, described, grant)) {
			continue;
		}
		match described {
			Ok(Some(grant)) => rows.push(row(Some(id), grant)),
			Ok(None) => rows.push(json!({
				"id": id,
				"state": "revoked",
				"effective": "revoked",
				"saved": true,
				"note": REVOKED_NOTE,
			})),
			// One kept control that cannot be read is reported in its row, so
			// the rest of the list still shows.
			Err(error) => rows.push(json!({"id": id, "saved": true, "error": error})),
		}
	}
	for id in unfinished {
		rows.push(json!({"id": id, "saved": true, "state": "unfinished", "note": UNFINISHED_NOTE}));
	}
	Ok(json!({"ok": true, "accesses": rows}))
}

/// What a row whose issue did not finish says about itself in the list.
const UNFINISHED_NOTE: &str =
	"The issue under this id did not finish. Issue again with the same id, label, and rights to finish it";

/// What forgetting a row whose issue did not finish says about an access the
/// issue may have made.
const FORGOTTEN_UNFINISHED_NOTE: &str = "The issue under this id did not finish. If it made an access, that access is paused, its link was never shown, \
	and the list shows it without an id";

/// What a kept control of a revoked access says about itself in the list.
const REVOKED_NOTE: &str = "This access is revoked and its control is kept under this id. A revoked access no longer names its control, \
	so a revoked access listed without an id may be this one. Forget this id to drop the row";

/// Pause, resume, or revoke the access row `id` keeps the control of.
pub(super) async fn change(app: &Application, id: &str, lifecycle: Lifecycle) -> Result<Value, Failure> {
	let control = restore(app, kept(app, id).await?.1).await?;
	attached::change(&control, lifecycle).await.map_err(failure)?;
	let now = attached::describe(&control).await.map_err(failure)?;
	Ok(json!({"ok": true, "id": id, "state": now.map_or("revoked", |grant| state(grant.state))}))
}

/// Stop keeping the control of a revoked access, which frees its row. An
/// access that can still be used is refused, because forgetting its control
/// would leave nothing that can end it. A row whose issue did not finish is
/// dropped too. Once the session has used its place, the access there may be
/// this row's or another issuer's, and nothing tells them apart, so the
/// answer says that any access this row made stays paused with its link
/// never shown.
pub(super) async fn forget(app: &Application, id: &str) -> Result<Value, Failure> {
	for attempt in 1..=SAVE_ATTEMPTS {
		let snapshot = app.workspace.snapshot().await.map_err(peer_failure)?;
		let Some(index) = snapshot
			.intent
			.accesses
			.as_slice()
			.iter()
			.position(|row| row.id.text().as_str() == Some(id))
		else {
			return Err(unknown(id));
		};
		let saved = snapshot.intent.accesses.as_slice()[index].clone();
		let mut used = false;
		let releases = match (saved.control, saved.issue) {
			(Some(key), _) => {
				let control = restore(app, key).await?;
				if let Some(grant) = attached::describe(&control).await.map_err(failure)?
					&& grant.effective != State::Revoked
				{
					return Err(Failure::invalid(format!(
						"access {id} is {}. Revoke it before forgetting it",
						state(grant.state)
					)));
				}
				vec![Coordinate::new(Role::SessionControl, key)]
			}
			(None, Some(Issue::Unsaved(at))) => {
				used = attached::place(&app.management).await.map_err(failure)?.sequence > at.sequence;
				Vec::new()
			}
			(None, _) => return Err(unknown(id)),
		};
		let mut intent = snapshot.intent;
		let rows = &mut intent.accesses;
		if saved.access.is_some() {
			let row = &mut rows.as_mut_slice()[index];
			row.control = None;
			row.issue = None;
		} else {
			rows.remove(index);
		}
		let submitted = app
			.workspace
			.prepare_acquisition(snapshot.revision, Vec::new(), &releases, &intent)
			.map_err(Failure::invalid)?
			.submit()
			.await;
		match submitted {
			Ok(()) if used => {
				return Ok(json!({"ok": true, "id": id, "forgotten": true, "note": FORGOTTEN_UNFINISHED_NOTE}));
			}
			Ok(()) => return Ok(json!({"ok": true, "id": id, "forgotten": true})),
			Err(ClientError::WorkspaceConflict) if attempt < SAVE_ATTEMPTS => {}
			Err(error) => return Err(peer_failure(error)),
		}
	}
	Err(conflict())
}

/// Why an issued access's control was not saved.
enum Unsaved {
	/// Another issue under the same id saved this same access first.
	Elsewhere,
	Failed(Failure),
}
impl From<Failure> for Unsaved {
	fn from(failure: Failure) -> Self {
		Self::Failed(failure)
	}
}

/// Keep `control`, which manages the access `issued` names, in the row `id`
/// reserved for it.
async fn save(
	app: &Application,
	id: &workspace::Id,
	control: &Control<HostPlatform>,
	issued: Option<GrantId>,
) -> Result<(), Unsaved> {
	for attempt in 1..=SAVE_ATTEMPTS {
		let snapshot = app.workspace.snapshot().await.map_err(peer_failure)?;
		let mut intent = snapshot.intent;
		let key = fresh_key()?;
		let saved_here = issued.map(|GrantId { slot, generation }| Issue::Saved(Entry { slot, generation }));
		let Some(row) = intent
			.accesses
			.as_mut_slice()
			.iter_mut()
			.find(|row| row.id == *id && (matches!(row.issue, Some(Issue::Unsaved(_))) || row.issue == saved_here))
		else {
			return Err(Failure::invalid("the access row changed while its access was issued").into());
		};
		if saved_here.is_some() && row.issue == saved_here {
			return Err(Unsaved::Elsewhere);
		}
		row.control = Some(key);
		row.issue = saved_here;
		let import = Import {
			coordinate: Coordinate::new(Role::SessionControl, key),
			reference: control.reference().clone(),
			uri: None,
		};
		let submitted = app
			.workspace
			.prepare_acquisition(snapshot.revision, vec![import], &[], &intent)
			.map_err(Failure::invalid)?
			.submit()
			.await;
		match submitted {
			Ok(()) => return Ok(()),
			Err(ClientError::WorkspaceConflict) if attempt < SAVE_ATTEMPTS => {}
			Err(error) => return Err(peer_failure(error).into()),
		}
	}
	Err(conflict().into())
}

/// The workspace now and the control key row `id` keeps.
async fn kept(
	app: &Application,
	id: &str,
) -> Result<(rooms_glowcap::client::workspace::Snapshot, FieldKey<SessionControl>), Failure> {
	let snapshot = app.workspace.snapshot().await.map_err(peer_failure)?;
	let key = snapshot
		.intent
		.accesses
		.as_slice()
		.iter()
		.find(|row| row.id.text().as_str() == Some(id))
		.and_then(|row| row.control)
		.ok_or_else(|| unknown(id))?;
	Ok((snapshot, key))
}

/// The control the session kept under `key`, restored through its private
/// custody.
async fn restore(app: &Application, key: FieldKey<SessionControl>) -> Result<Control<HostPlatform>, Failure> {
	let mut held = app
		.custody
		.restore_publication(&[Coordinate::new(Role::SessionControl, key)])
		.await
		.map_err(|error| peer_failure(error.into()))?;
	let (reference, _) = held
		.pop()
		.ok_or_else(|| Failure::uncertain("the session restored no control"))?;
	Ok(local_control(app, reference))
}

fn local_control(app: &Application, reference: glowcap::Ref) -> Control<HostPlatform> {
	Control::local(app.host.clone(), HostPlatform, reference)
}

fn fresh_key() -> Result<FieldKey<SessionControl>, Failure> {
	let mut entropy = [0; 16];
	rooms_platform::entropy::fill(&mut entropy)
		.map_err(|error| Failure::new("entropy", Retry::AfterStateChange, error))?;
	FieldKey::from_entropy(entropy)
		.ok_or_else(|| Failure::new("entropy", Retry::AfterStateChange, "entropy produced no key"))
}

fn row_id(id: &str) -> Result<workspace::Id, Failure> {
	if id.is_empty() || id.len() > 128 {
		return Err(Failure::invalid("an access id is 1 to 128 bytes"));
	}
	workspace::Id::new(id.into()).ok_or_else(|| Failure::invalid("not an access id"))
}

fn unknown(id: &str) -> Failure {
	Failure::invalid(format!(
		"no access is kept as {id}. Run session access list to see the ids"
	))
}

fn conflict() -> Failure {
	Failure::new(
		"conflict",
		Retry::Soon,
		"the workspace kept changing while the access was saved. Try again",
	)
}

fn names(rights: &Terms) -> Vec<&'static str> {
	rights.permissions().iter().map(|right| right.name()).collect()
}

fn state(state: State) -> &'static str {
	match state {
		State::Active => "active",
		State::Paused => "paused",
		State::Revoked => "revoked",
	}
}

fn row(id: Option<&str>, grant: &Grant) -> Value {
	let GrantId { slot, generation } = grant.id;
	json!({
		"id": id,
		"saved": id.is_some(),
		"label": grant.label,
		"rights": names(&grant.rights),
		"state": state(grant.state),
		"effective": state(grant.effective),
		"slot": slot,
		"generation": generation,
	})
}

/// A failed access command, classed by the one table for view calls. None
/// of the messages quotes a link.
fn failure(error: Error) -> Failure {
	Failure::from(&error)
}
