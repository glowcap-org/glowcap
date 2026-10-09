//! Local views hold the managed use/control endpoints independently. Event
//! delivery is bounded and lag is explicit; it cannot change session authority.
use glowcap::Host;
use rooms_glowcap::client::{access::Control, workspace::Workspace};
use rooms_platform::HostPlatform;
use rooms_runtime::session::managed;
use std::rc::Rc;

pub type Event = Rc<managed::Event<HostPlatform>>;

#[derive(Clone)]
pub struct Local {
	pub workspace: Workspace<HostPlatform>,
	pub management: Control<HostPlatform>,
	pub host: Host,
	pub activity: Rc<managed::Activity<HostPlatform>>,
	pub archive: Rc<crate::session_archive::SessionArchive>,
}
