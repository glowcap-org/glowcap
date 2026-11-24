//! Dial the saved access of an attached page, first or again after its link
//! broke. The Host reuses a live session to the same peer, so a half-open one is
//! closed before a dial again. A dial that fails says whether the session was
//! never reached, which time clears, or failed in a way that stands.
use super::*;
use rooms_application::failure::FailureCode;
use rooms_glowcap::client::Deadline;
use rooms_runtime::Error as RuntimeError;

/// The session could not be reached within a request's time.
fn unreached(detail: &'static str) -> RuntimeError {
	RuntimeError::coded(FailureCode::SessionUnreachable, detail)
}

/// A failed dial is unreached when the session was never reached, and
/// otherwise is the failure as it came: the session's own answer, or a fault
/// no later dial changes. The dial's own cause stays with the code.
fn dialed(error: RuntimeError) -> RuntimeError {
	if error.peer_never_reached() {
		error.named(FailureCode::SessionUnreachable, "The session did not answer")
	} else {
		error
	}
}

/// Restore the saved `fields` from local custody, dialing the session each
/// names, within a request's time.
pub(super) async fn dial(
	environment: &Environment,
	opened: &Opened<Platform>,
	fields: &[custody::Coordinate],
	detail: &'static str,
) -> Result<(Ref, Option<String>)> {
	let mut held = environment
		.platform
		.within(
			rooms_application::room::authority::REQUEST_TIMEOUT_MS,
			opened.session().restore_publication_custody(fields),
		)
		.await
		.ok_or_else(|| unreached(detail))?
		.map_err(|error| dialed(RuntimeError::from(error)))?;
	Ok(held.remove(0))
}

/// Restore the saved workspace access `id` from local custody and dial it.
pub(super) async fn saved_workspace(
	driver: Driver,
	environment: &Environment,
	id: &str,
) -> Result<RoomsManagedWorkspace> {
	let opened = owner(environment)?.opened.lock().await;
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
		.and_then(|row| row.access)
		.ok_or_else(|| RuntimeError::invalid("No held workspace access for this row"))?;
	let fields = [custody::Coordinate::new(custody::Role::SessionAccess, selected)];
	let (reference, uri) = dial(environment, &opened, &fields, "Saved workspace connection timed out").await?;
	let home = PublicationHome::restored(&driver, uri)?;
	// A capability another process serves answers through a connection that can
	// break. One this page serves has none, and a late answer is only late.
	let remote = environment
		.runtime
		.host()
		.reference_session(&reference)
		.map_err(RuntimeError::from)?
		.is_some();
	let host = environment.runtime.host().clone();
	let workspace = if remote {
		Workspace::attached(host, environment.platform.clone(), reference)
	} else {
		Workspace::local(host, environment.platform.clone(), reference)
	};
	let workspace = driver.hold(workspace, size_of::<Workspace<Platform>>())?;
	Ok(RoomsManagedWorkspace {
		driver,
		workspace,
		home,
	})
}

/// Close the live session that homes `reference`, if one remains. A local or
/// already retired capability has none, and nothing is closed.
async fn retire(environment: &Environment, reference: &Ref) -> Result<()> {
	let Some(session) = environment
		.runtime
		.host()
		.reference_session(reference)
		.map_err(RuntimeError::from)?
	else {
		return Ok(());
	};
	let closed = environment
		.platform
		.within(
			rooms_application::room::authority::REQUEST_TIMEOUT_MS,
			session.close(glowcap::PendingWork::Cancel),
		)
		.await;
	// A close that outlasts the bound is a link that cannot be retired yet, so
	// the page waits and dials again.
	let Some(result) = closed else {
		return Err(unreached("Closing the stale session timed out"));
	};
	// tolerant: a session that already failed reports its failure again on close,
	// and the stale link is gone either way.
	drop(result);
	Ok(())
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
			retire(&environment, stale.reference()).await?;
			saved_workspace(driver, &environment, &id).await.map(Into::into)
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
			saved_workspace(driver, &environment, &id).await.map(Into::into)
		})
	}
}
