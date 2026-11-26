//! Access the terminal issues and manages through the running session. The
//! session issues with its own management control and keeps each control in
//! the workspace's `accesses` rows. An attached page manages the controls
//! held in that page's custody. A row's id is how
//! the terminal names an access. No bearer name leaves the session except the
//! use link of an access just issued and the management link `share` answers,
//! each in its one reply.
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
use rooms_runtime::session::fault::{SessionFault, armed};
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

/// Issue an access and keep its control under row `id`. A fresh grant starts
/// paused. A replay may recover a grant another holder already uses, so the
/// session changes its lifecycle only after saving its control.
pub(super) async fn issue(app: &Application, id: &str, label: &str, rights_name: &str) -> Result<Value, Failure> {
	let row = row_id(id)?;
	let terms = rights(rights_name).map_err(Failure::invalid)?;
	attached::validate_label(label).map_err(failure)?;
	let at = reserve(app, &row).await?;
	end_issue_at(SessionFault::AfterIssueReservation);
	let issued = attached::issue_at(&app.management, at, label, &terms, true)
		.await
		.map_err(|error| unfinished_issue(id, error))?;
	end_issue_at(SessionFault::AfterIssue);
	let control = local_control(app, issued.control);
	let grant = attached::describe(&control).await.map_err(failure)?;
	save(app, &row, at, &control, grant.as_ref().map(|grant| grant.id))
		.await
		.map_err(|error| {
			let message = format!(
				"could not confirm the control was saved under {id}: {error}. Run session access list to see its state"
			);
			error.explained(message)
		})?;
	let Some(grant) = grant else {
		return Err(Failure::invalid(format!(
			"the access issued under {id} was revoked before its issue finished. Forget it and issue again"
		)));
	};
	let saved_control = |error: Error| {
		let error = failure(error);
		let message = format!(
			"the control is saved as {id}, but this issue returned no link: {error}. Run session access list to see its state"
		);
		error.explained(message)
	};
	let name = Workspace::local(app.host.clone(), HostPlatform, issued.access)
		.durable_name()
		.await
		.map_err(|error| saved_control(attached::failed(error)))?;
	let link = glowcap::format_sturdyref(&app.locator, name.as_bytes(), glowcap::CaptpVersion::V1_0)
		.map_err(|_| saved_control(Error::Malformed("the access name does not make a link")))?;
	if grant.state == State::Paused {
		attached::change(&control, Lifecycle::Resume)
			.await
			.map_err(saved_control)?;
	}
	Ok(json!({"ok": true, "link": link, "id": id, "label": label, "rights": names(&terms)}))
}

/// Stop at a durable boundary when the process proof has armed that fault.
fn end_issue_at(point: SessionFault) {
	if armed() == Some(point) {
		std::process::abort();
	}
}

/// Another holder of the root control shares its derivation sequence. Only
/// an exact request still in the root's receipt window can recover a used place.
fn unfinished_issue(id: &str, error: Error) -> Failure {
	match error {
		Error::Peer(ClientError::ControlConflict(glowcap::loam::ControlConflict::Operation)) => Failure::new(
			"conflict",
			Retry::AfterRequestChange,
			format!(
				"a different request used the issue position for {id}. Retry with the original label and rights, or forget {id} and issue again"
			),
		),
		Error::Peer(ClientError::Binding(ref cause))
			if cause.kind() == glowcap::ErrorKind::Broken && cause.message() == Some("ReceiptExpired") =>
		{
			Failure::new(
				"receipt-expired",
				Retry::AfterStateChange,
				format!(
					"the issue receipt for {id} has expired. The session can no longer recover its control. Run session access forget --id {id}, then issue again"
				),
			)
		}
		other => {
			let error = failure(other);
			let message = format!(
				"{error}. The issue under {id} did not finish. Retry with the same id, label, and rights, or forget the unfinished issue"
			);
			error.explained(message)
		}
	}
}

/// The place to issue row `id`'s access at. A new id commits a row holding a
/// fresh place. A row whose issue did not finish keeps its place once the
/// session has used it, and takes a fresh one otherwise.
async fn reserve(app: &Application, id: &workspace::Id) -> Result<workspace::Place, Failure> {
	for _ in 0..SAVE_ATTEMPTS {
		let snapshot = app.workspace.snapshot().await.map_err(peer_failure)?;
		let mut intent = snapshot.intent;
		let fresh = attached::place(&app.management).await.map_err(failure)?;
		let rows = &mut intent.accesses;
		let existing = rows.as_slice().iter().position(|row| row.id == *id);
		let reserved = match existing {
			Some(i) => match rows.as_slice()[i].issue {
				Some(Issue::Unsaved(at)) => Some(at),
				_ => return Err(Failure::invalid("an access is already kept under this id")),
			},
			None => None,
		};
		let at = reserved.filter(|at| at.sequence < fresh.sequence).unwrap_or(fresh);
		// A fresh issue would move the root's bounded receipt window past
		// a prior unfinished issue. Replaying a distinct used place consumes
		// no sequence, so older reservations can still be recovered.
		if let Some(owner) = rows.as_slice().iter().find(|row| {
			row.id != *id
				&& matches!(row.issue, Some(Issue::Unsaved(other)) if at == fresh || other.sequence == at.sequence)
		}) {
			let holder = owner.id.text().as_str().unwrap_or("(unnamed)");
			return Err(Failure::new(
				"conflict",
				Retry::AfterStateChange,
				format!("the issue under {holder} is unfinished. Finish or forget that issue, then try again"),
			));
		}
		if reserved == Some(at) {
			return Ok(at);
		}
		match existing {
			Some(i) => rows.as_mut_slice()[i].issue = Some(Issue::Unsaved(at)),
			None => rows
				.try_push(workspace::Access {
					id: id.clone(),
					access: None,
					control: None,
					issue: Some(Issue::Unsaved(at)),
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
			Ok(()) => return Ok(at),
			Err(ClientError::WorkspaceConflict) => {}
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
	"The issue under this id did not finish. Retry with the same id, label, and rights, or forget the unfinished issue";

/// What forgetting a row whose issue did not finish says about an access the
/// issue may have made.
const FORGOTTEN_UNFINISHED_NOTE: &str =
	"Forgetting an unfinished issue leaves any issued access as it was. Run session access list to see its state";

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

/// The management link of the access row `id` keeps the control of. The link
/// names that control, so its holder can read, pause, resume, and revoke the
/// access, the powers the control was issued with, and can neither change the
/// access's rights nor issue under it. It works until the access is revoked,
/// and it leaves the session only in this verb's reply.
pub(super) async fn share(app: &Application, id: &str) -> Result<Value, Failure> {
	let control = restore(app, kept(app, id).await?.1).await?;
	if attached::describe(&control).await.map_err(failure)?.is_none() {
		return Err(Failure::invalid(format!(
			"access {id} is revoked, so nothing is left to manage"
		)));
	}
	let name = control
		.durable_name()
		.await
		.map_err(|error| failure(attached::failed(error)))?;
	let link = glowcap::format_sturdyref(&app.locator, name.as_bytes(), glowcap::CaptpVersion::V1_0)
		.map_err(|_| failure(Error::Malformed("the control name does not make a link")))?;
	Ok(json!({"ok": true, "id": id, "link": link}))
}

/// Stop keeping the control of a revoked access, which frees its row. An
/// access that can still be used is refused, because forgetting its control
/// would leave nothing that can end it. A row whose issue did not finish is
/// dropped too. Another issuer can use the same place, so forgetting the
/// row leaves the grant's lifecycle alone.
pub(super) async fn forget(app: &Application, id: &str) -> Result<Value, Failure> {
	for _ in 0..SAVE_ATTEMPTS {
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
			Err(ClientError::WorkspaceConflict) => {}
			Err(error) => return Err(peer_failure(error)),
		}
	}
	Err(conflict())
}

/// Keep `control`, which manages the access `issued` names, in the row `id`
/// reserved for it.
async fn save(
	app: &Application,
	id: &workspace::Id,
	at: workspace::Place,
	control: &Control<HostPlatform>,
	issued: Option<GrantId>,
) -> Result<(), Failure> {
	if armed() == Some(SessionFault::FailAccessSave) {
		return Err(Failure::uncertain("could not read the workspace to save the control"));
	}
	for _ in 0..SAVE_ATTEMPTS {
		let snapshot = app.workspace.snapshot().await.map_err(peer_failure)?;
		let mut intent = snapshot.intent;
		let saved_here = issued.map(|GrantId { slot, generation }| Issue::Saved(Entry { slot, generation }));
		if saved_here.is_some()
			&& let Some(holder) = intent.accesses.as_slice().iter().find(|row| row.issue == saved_here)
		{
			let holder = holder.id.text().as_str().unwrap_or("(unnamed)");
			return Err(Failure::new(
				"conflict",
				Retry::AfterStateChange,
				format!(
					"this access was already saved under {holder}. Forget the unfinished issue before issuing again"
				),
			));
		}
		let Some(row) = intent
			.accesses
			.as_mut_slice()
			.iter_mut()
			.find(|row| row.id == *id && row.issue == Some(Issue::Unsaved(at)))
		else {
			return Err(Failure::invalid("the access row changed while its access was issued"));
		};
		let key = fresh_key()?;
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
			Err(ClientError::WorkspaceConflict) => {}
			Err(error) => return Err(peer_failure(error)),
		}
	}
	Err(conflict())
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
	Failure::conflict("the workspace kept changing while the access was saved. Try again")
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
