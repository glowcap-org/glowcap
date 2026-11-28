//! Local views hold the managed use/control endpoints independently. Event
//! delivery is bounded and lag is explicit. The management control and the
//! private custody restore let the terminal issue and manage access the way
//! the page does as the session's local owner.
use glowcap::{Host, Locator};
use rooms_glowcap::client::{access::Control, workspace::Workspace};
use rooms_platform::HostPlatform;
use rooms_runtime::session::managed;
use std::rc::Rc;

pub type Event = Rc<managed::Event<HostPlatform>>;

#[derive(Clone)]
pub struct Local {
	pub workspace: Workspace<HostPlatform>,
	pub(super) registrations: managed::DirectoryRegistrations<HostPlatform>,
	pub management: Control<HostPlatform>,
	/// Restores what the session saved, such as the control of an access the
	/// terminal issued.
	pub custody: managed::Custody,
	/// Where the session is reached, which an issued access's link names.
	pub locator: Locator,
	pub host: Host,
	pub activity: Rc<managed::Activity<HostPlatform>>,
	pub archive: Rc<crate::session_archive::SessionArchive>,
}
