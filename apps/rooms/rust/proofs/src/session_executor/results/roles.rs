//! A room result saves into the row its request named, through the authority
//! that request used, and needs no live seat.
use super::*;
use rooms_application::fields::{List, Text};
use rooms_glowcap::client::workspace::{ResultAcquisition, ResultImport, Workspace};

/// The slot of the result field the receipt holds.
const RESULT: u64 = 1;
/// The slot every proof saves its result to.
const LANDING: u64 = 7;
/// The slot a row's link or entrance moves to.
const MOVED: u64 = 2;

fn set(room: &mut session::workspace::Room, case: ResultCase) {
	match case {
		ResultCase::Moderator => room.moderator = Some(field(LANDING)),
		ResultCase::Link | ResultCase::Entrance => room.access = Some(field(LANDING)),
	}
}
/// The candidate that saves the result into the row field its route names.
fn landed(mut intent: Intent, case: ResultCase) -> Intent {
	set(room(&mut intent), case);
	intent
}
/// The candidate that saves the result into the field its route does not name.
fn misplaced(mut intent: Intent, case: ResultCase) -> Intent {
	let row = room(&mut intent);
	match case {
		ResultCase::Moderator => row.access = Some(field(LANDING)),
		ResultCase::Link | ResultCase::Entrance => row.moderator = Some(field(LANDING)),
	}
	intent
}
/// A second row holding the result and nothing else.
fn other_row(intent: &mut Intent, case: ResultCase) {
	let mut other = room(intent).clone();
	other.id = Text::new("other".into()).unwrap();
	(other.control, other.seat, other.access, other.moderator) = (None, None, None, None);
	set(&mut other, case);
	let mut rows = intent.conversations.as_slice().to_vec();
	rows.push(session::workspace::Conversation::Room(Box::new(other)));
	intent.conversations = List::new(rows).unwrap();
}
/// The candidate that saves the result into a second row only.
fn elsewhere(mut intent: Intent, case: ResultCase) -> Intent {
	other_row(&mut intent, case);
	intent
}
/// The candidate that also saves the result into a second row.
fn aliased_elsewhere(intent: Intent, case: ResultCase) -> Intent {
	let mut intent = landed(intent, case);
	other_row(&mut intent, case);
	intent
}
/// The candidate that saves the result into both fields of its row.
fn aliased_fields(intent: Intent, case: ResultCase) -> Intent {
	let mut intent = misplaced(intent, case);
	set(room(&mut intent), case);
	intent
}
/// The candidate that saves the result and replaces the row's manager link.
fn replaced_control(mut intent: Intent) -> Intent {
	room(&mut intent).control = Some(field(MOVED));
	intent
}

pub(super) struct Saves<'a> {
	pub host: &'a Host,
	pub owner: &'a managed::Session<Platform>,
	pub root: &'a Ref,
	pub target: &'a Ref,
	/// A capability other than the target, and the address that saves it.
	pub other: (&'a Ref, &'a str),
	pub reports: &'a Rc<std::cell::RefCell<Vec<String>>>,
	pub case: ResultCase,
	pub base: u64,
	pub args: &'a [String],
}
impl Saves<'_> {
	fn workspace(&self) -> Workspace<Platform> {
		Workspace::local(self.host.clone(), Platform::default(), self.root.clone())
	}
	async fn acquisition(&self, workspace: &Workspace<Platform>, candidate: &Intent) -> ResultAcquisition<Platform> {
		self.acquisition_to(workspace, candidate, &[LANDING]).await
	}
	/// Selects the one result field for each destination in `slots`.
	async fn acquisition_to(
		&self,
		workspace: &Workspace<Platform>,
		candidate: &Intent,
		slots: &[u64],
	) -> ResultAcquisition<Platform> {
		let imports: Vec<_> = slots
			.iter()
			.map(|slot| ResultImport {
				result: coordinate_at(custody::Role::RoomAccess, RESULT),
				destination: coordinate_at(custody::Role::RoomAccess, *slot),
			})
			.collect();
		let command = workspace
			.prepare_command("issued", self.base, self.case.name(), self.args)
			.await
			.unwrap();
		let revision = workspace.snapshot().await.unwrap().revision;
		command
			.prepare_result_acquisition(revision, &imports, &[], candidate)
			.unwrap()
	}
	async fn hold(&self, slot: u64, authority: &Ref, uri: Option<&str>) {
		self.owner
			.import(
				coordinate_at(self.case.role(), slot),
				authority.clone(),
				uri.map(str::to_owned),
			)
			.await
			.unwrap();
	}
	/// Points the row's link or entrance at the custody held at `slot` and
	/// releases the custody held at each of `released`.
	async fn point_at(&self, workspace: &Workspace<Platform>, slot: u64, released: &[u64]) {
		let role = self.case.role();
		let snapshot = workspace.snapshot().await.unwrap();
		let mut intent = snapshot.intent.clone();
		let held = room(&mut intent);
		match role {
			custody::Role::RoomControl => held.control = Some(field(slot)),
			_ => held.access = Some(field(slot)),
		}
		let releases: Vec<_> = released.iter().map(|slot| coordinate_at(role, *slot)).collect();
		workspace
			.prepare_acquisition(snapshot.revision, Vec::new(), &releases, &intent)
			.unwrap()
			.submit()
			.await
			.unwrap();
	}
	/// The runtime reports the cause of a refusal it makes before its callback
	/// runs. The proof reads that cause, so an unrelated failure cannot pass for
	/// it. The callback's own refusals report nothing.
	async fn refused(&self, workspace: &Workspace<Platform>, candidate: &Intent, cause: Option<&str>) {
		self.refused_to(workspace, candidate, &[LANDING], cause).await;
	}
	async fn refused_to(
		&self,
		workspace: &Workspace<Platform>,
		candidate: &Intent,
		slots: &[u64],
		cause: Option<&str>,
	) {
		let before = workspace.snapshot().await.unwrap();
		let reported = self.reports.borrow().len();
		assert!(
			self.acquisition_to(workspace, candidate, slots)
				.await
				.submit()
				.await
				.is_err()
		);
		assert_eq!(workspace.snapshot().await.unwrap().revision, before.revision);
		let reports = self.reports.borrow();
		match cause {
			Some(cause) => {
				assert_eq!(reports.len(), reported + 1, "one new cause: {reports:?}");
				assert!(reports[reported].contains(cause), "{cause}: {reports:?}");
			}
			None => assert_eq!(
				reports.len(),
				reported,
				"the callback's refusal reports nothing: {reports:?}"
			),
		}
	}
	pub(super) async fn run(&self) {
		let case = self.case;
		let (role, slot) = (case.role(), case.slot());
		let workspace = self.workspace();
		let before = workspace.snapshot().await.unwrap();
		assert!(room(&mut before.intent.clone()).seat.is_none(), "the row holds no seat");
		let candidates = [
			(
				elsewhere(before.intent.clone(), case),
				"not saved into the room its request named",
			),
			(
				misplaced(before.intent.clone(), case),
				"saved into a field its request does not name",
			),
			(
				aliased_fields(before.intent.clone(), case),
				"held by two fields of its room",
			),
			(aliased_elsewhere(before.intent.clone(), case), "held by another room"),
		];
		for (candidate, cause) in &candidates {
			self.refused(&workspace, candidate, Some(cause)).await;
		}
		let landed_before = landed(before.intent.clone(), case);
		self.refused_to(
			&workspace,
			&landed_before,
			&[LANDING, LANDING + 1],
			Some("one room result selects one field"),
		)
		.await;
		let mut dropped = landed_before.clone();
		dropped.conversations = List::new(Vec::new()).unwrap();
		self.refused(&workspace, &dropped, Some("must retain its original room"))
			.await;
		// The person forgets the room between the commit and the save.
		let forgotten = workspace.snapshot().await.unwrap();
		workspace
			.prepare_acquisition(forgotten.revision, Vec::new(), &[], &dropped)
			.unwrap()
			.submit()
			.await
			.unwrap();
		self.refused(&workspace, &landed_before, Some("original room was removed"))
			.await;
		// Forgetting the room released its custody. Hold the original target
		// again and restore the row, so the next cases start from the request's
		// own state.
		self.hold(slot, self.target, None).await;
		let removed = workspace.snapshot().await.unwrap();
		workspace
			.prepare_acquisition(removed.revision, Vec::new(), &[], &before.intent)
			.unwrap()
			.submit()
			.await
			.unwrap();
		// A second held copy of the target, for the row to move to.
		self.hold(MOVED, self.target, None).await;
		if role == custody::Role::RoomControl {
			let candidate = replaced_control(landed(before.intent.clone(), case));
			self.refused(&workspace, &candidate, Some("keep the manager link its request used"))
				.await;
		}
		// Another save moved the row's link away from the one the request used.
		self.point_at(&workspace, MOVED, &[slot]).await;
		let moved = workspace.snapshot().await.unwrap();
		self.refused(
			&workspace,
			&landed(moved.intent, case),
			Some("its request used was replaced"),
		)
		.await;
		// The original coordinate holds a different capability. Only the
		// callback that resolves both capabilities can tell.
		self.hold(slot, self.other.0, Some(self.other.1)).await;
		self.point_at(&workspace, slot, &[MOVED]).await;
		let swapped = workspace.snapshot().await.unwrap();
		self.refused(&workspace, &landed(swapped.intent, case), None).await;
		// Put the original target back at the original coordinate, by way of
		// the spare slot. The save that follows passes only against it.
		self.hold(MOVED, self.target, None).await;
		self.point_at(&workspace, MOVED, &[slot]).await;
		self.hold(slot, self.target, None).await;
		self.point_at(&workspace, slot, &[MOVED]).await;
		let current = workspace.snapshot().await.unwrap();
		let candidate = landed(current.intent.clone(), case);
		self.acquisition(&workspace, &candidate).await.submit().await.unwrap();
		let saved = workspace.snapshot().await.unwrap();
		assert_eq!(saved.intent, candidate, "the save needs no seat");
		assert!(saved.revision > current.revision);
		// A second viewer finds the receipt adopted and changes nothing, whatever
		// it would have saved.
		let viewer = self.workspace();
		for candidate in [&candidate, &elsewhere(current.intent, case)] {
			self.acquisition(&viewer, candidate).await.submit().await.unwrap();
			assert_eq!(viewer.snapshot().await.unwrap().revision, saved.revision);
		}
	}
}
