//! Attachment decisions retain the controller being replaced. Verification
//! never grants permission to overwrite a later browser controller choice.
use super::{Controller, Workspace};
use crate::{
	fields::Text,
	session::checkpoint::{Checkpoint, Routes},
	text::DocumentText,
};
use alloc::{rc::Rc, string::String};

pub struct Attachment {
	prior: Controller,
	next: Controller,
	pub same_peer: bool,
	pub unchanged: bool,
}
impl Controller {
	pub fn link(&self) -> Option<&str> {
		match self {
			Self::Attached { sturdyref } | Self::Hosted { sturdyref } => sturdyref.text().as_str(),
			_ => None,
		}
	}
}
impl Attachment {
	pub fn new(prior: &Controller, link: String, routes: &impl Routes) -> Result<Self, &'static str> {
		let mut text = DocumentText::from(link);
		text.trim_js();
		if !Text::<16384>::accepts_utf16(text.utf16()) {
			return Err("The shared session capability exceeds its input bound");
		}
		let next = Controller::Attached { sturdyref: Text(text) };
		super::validate_controller(&next, routes).map_err(|_| "The shared session capability is invalid")?;
		let link = next.link().expect("validated scalar capability");
		let authority = routes.sturdyref_authority(link);
		Ok(Self {
			same_peer: prior
				.link()
				.is_some_and(|prior| routes.sturdyref_authority(prior) == authority),
			unchanged: prior.link() == Some(link),
			prior: prior.clone(),
			next,
		})
	}
	pub fn link(&self) -> &str {
		self.next.link().expect("validated scalar capability")
	}
	pub fn adopts_local(&self) -> bool {
		matches!(self.prior, Controller::Local {})
	}
	pub fn keeps_hosting(&self) -> bool {
		self.same_peer && matches!(self.prior, Controller::Hosted { .. })
	}
	pub fn check(&self, current: &Controller) -> Result<(), &'static str> {
		if current == &self.prior {
			Ok(())
		} else {
			Err("The Rooms controller changed during attachment; repeat from the current view")
		}
	}
	pub fn commit(
		self,
		mut workspace: Workspace,
		checkpoint: Option<Rc<Checkpoint>>,
	) -> Result<Workspace, &'static str> {
		self.check(workspace.controller())?;
		workspace.controller = self.next;
		if let Some(checkpoint) = checkpoint {
			workspace.session = checkpoint;
		}
		Ok(workspace)
	}
}
