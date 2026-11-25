//! Dial what an attached page saved: its workspace access, first or again
//! after its link broke, and each management control it holds. A dial that
//! fails says whether the session went unreached or was lost, which time
//! clears, or failed in a way that stands. The Host reuses a live session to
//! the same peer, so the session a dial reaches may be one the page's link or
//! another held control already uses. A dial whose later steps fail closes
//! nothing here, because closing that session would cut every other holder
//! off. The page closes the session of a relinked workspace it could not
//! adopt (`RoomsManagedWorkspace::retire`).
use super::*;
use rooms_runtime::Error as RuntimeError;

/// Which saved capability of an access row a dial restores.
#[derive(Clone, Copy)]
enum Saved {
	Workspace,
	Control,
}

impl Saved {
	fn missing(self) -> &'static str {
		match self {
			Self::Workspace => "No held workspace access for this row",
			Self::Control => "No held management control for this row",
		}
	}
	fn timed_out(self) -> &'static str {
		match self {
			Self::Workspace => "Saved workspace connection timed out",
			Self::Control => "Saved management connection timed out",
		}
	}
}

/// Restore the `saved` capability of the access row `id` from local custody,
/// dialing the session it names within a request's time. A descriptive
/// inventory id is never a restoration credential: only the row's own custody
/// is dialed.
async fn dial(
	environment: &Environment,
	opened: &Opened<Platform>,
	id: &str,
	saved: Saved,
) -> Result<(Ref, Option<String>)> {
	let snapshot = opened
		.workspace()
		.map_err(RuntimeError::from)?
		.snapshot()
		.await
		.map_err(RuntimeError::from)?;
	let selected = snapshot
		.intent
		.accesses
		.as_slice()
		.iter()
		.find(|row| row.id.text().as_str() == Some(id))
		.and_then(|row| match saved {
			Saved::Workspace => row
				.access
				.map(|key| custody::Coordinate::new(custody::Role::SessionAccess, key)),
			Saved::Control => row
				.control
				.map(|key| custody::Coordinate::new(custody::Role::SessionControl, key)),
		})
		.ok_or_else(|| RuntimeError::invalid(saved.missing()))?;
	let fields = [selected];
	let mut held = rooms_glowcap::client::dial_session(
		&environment.platform,
		saved.timed_out(),
		opened.session().restore_publication_custody(&fields),
	)
	.await
	.map_err(RuntimeError::from)?;
	Ok(held.remove(0))
}

/// Restore the saved workspace access `id` from local custody and dial it.
/// Custody dials through the opened workspace one at a time, so the dial waits
/// for its turn as `restore_control` does, and a turn that never comes ends as
/// `session-not-reached-yet`, which the link waits out and dials again.
async fn restore_workspace(driver: Driver, environment: &Environment, id: &str) -> Result<RoomsManagedWorkspace> {
	let owner = owner(environment)?;
	let opened = rooms_glowcap::client::dial_turn(&environment.platform, owner.opened.lock())
		.await
		.map_err(|code| RuntimeError::coded(code, "Saved workspace dial waited too long for its turn"))?;
	let (reference, uri) = dial(environment, &opened, id, Saved::Workspace).await?;
	let home = PublicationHome::restored(&driver, uri)?;
	let workspace = driver.hold(
		served::workspace_at(environment, &home, reference),
		size_of::<Workspace<Platform>>(),
	)?;
	Ok(RoomsManagedWorkspace {
		driver,
		workspace,
		home,
	})
}

/// Restore the saved management control `id` from local custody and dial it,
/// within one call's bound. Custody dials through the opened workspace one at
/// a time, and another dial or a close may hold it, so the dial waits for its
/// turn as `dial_turn` bounds it. A dial that starts runs to its own bound,
/// which nothing cuts short.
async fn restore_control(driver: Driver, environment: &Environment, id: &str) -> Result<RoomsManagedControl> {
	let owner = owner(environment)?;
	let opened = rooms_glowcap::client::dial_turn(&environment.platform, owner.opened.lock())
		.await
		.map_err(|code| RuntimeError::coded(code, "Saved management dial waited too long for its turn"))?;
	let (reference, uri) = dial(environment, &opened, id, Saved::Control).await?;
	drop(opened);
	let home = PublicationHome::restored(&driver, uri)?;
	RoomsManagedControl::new(driver, served::control_at(environment, &home, reference), home)
}

#[wasm_bindgen]
impl RoomsManagedApplication {
	/// Dial the saved workspace `id` again after its link broke. `stale` is the
	/// workspace the page held over that link. Its session is closed first, so a
	/// half-open connection is never reused. Everything held over it stops
	/// answering, and the page releases it.
	pub fn relink(&self, id: js_sys::JsString, stale: &RoomsManagedWorkspace) -> js_sys::Promise {
		let id = match scalar(id, 1024) {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		let driver = self.driver.clone();
		let stale = stale.workspace.clone();
		self.driver.submit(id.len(), move |environment| async move {
			stale.retire().await.map_err(RuntimeError::from)?;
			restore_workspace(driver, &environment, &id).await.map(Into::into)
		})
	}
	#[wasm_bindgen(js_name = savedWorkspace)]
	pub fn saved_workspace(&self, id: js_sys::JsString) -> js_sys::Promise {
		let id = match scalar(id, 1024) {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		let driver = self.driver.clone();
		self.driver.submit(id.len(), move |environment| async move {
			restore_workspace(driver, &environment, &id).await.map(Into::into)
		})
	}
	/// Restore the management control saved for the access row `id`.
	#[wasm_bindgen(js_name = savedControl)]
	pub fn saved_control(&self, id: js_sys::JsString) -> js_sys::Promise {
		let id = match scalar(id, 1024) {
			Ok(value) => value,
			Err(error) => return rejected(error),
		};
		let driver = self.driver.clone();
		self.driver.submit(id.len(), move |environment| async move {
			restore_control(driver, &environment, &id).await.map(Into::into)
		})
	}
}

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	/// Close the connection to the session that serves this workspace, if one
	/// remains. The page closes a relinked workspace it could not adopt this
	/// way, or the next dial would reuse its session.
	pub fn retire(&self) -> js_sys::Promise {
		let workspace = self.workspace.clone();
		self.driver.submit(0, move |_| async move {
			workspace.retire().await.map_err(RuntimeError::from)?;
			Ok(JsValue::UNDEFINED)
		})
	}
}
