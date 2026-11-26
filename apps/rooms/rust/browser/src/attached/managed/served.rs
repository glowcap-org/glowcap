//! Hold a reference by who serves it. One another process serves is reached
//! through a connection that can break, so it is held attached, and one this
//! page serves is held local.
use super::*;

/// How a handle of one kind is held over a reference.
type Hold<T> = fn(glowcap::Host, Platform, Ref) -> T;

/// The handle `reference` reaches, held by `attached` when it came from
/// another process and by `local` when this page serves it.
fn held_at<T>(
	environment: &Environment,
	home: &PublicationHome,
	reference: Ref,
	attached: Hold<T>,
	local: Hold<T>,
) -> T {
	// By origin, which stays true after a session closes, so a reference whose session closed before it was held
	// fails as a lost connection. A Remote link naming this page's own Host is held attached too and still works.
	let hold = match home {
		PublicationHome::Remote(_) => attached,
		PublicationHome::LocalOwner => local,
	};
	hold(
		environment.runtime.host().clone(),
		environment.platform.clone(),
		reference,
	)
}

pub(super) fn workspace_at(environment: &Environment, home: &PublicationHome, reference: Ref) -> Workspace<Platform> {
	held_at(environment, home, reference, Workspace::attached, Workspace::local)
}

pub(super) fn control_at(environment: &Environment, home: &PublicationHome, reference: Ref) -> Control<Platform> {
	held_at(environment, home, reference, Control::attached, Control::local)
}
