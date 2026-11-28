//! Charge forwarded workspace operations to their initiating access.
use super::*;

impl<P: Tasks + Deadline + Clone + 'static> loam::ForwardAdmission for SessionContent<P> {
	fn admit_forward(&self, call: &mut Call<'_>, input: loam::ForwardWork<'_>) -> Result<()> {
		let owner = self.owner(input.selector)?;
		if super::super::admission::admitted_effect(input.selector) {
			return Ok(());
		}
		use rooms_application::{admission::Class, protocol_data as wire};
		let class = match input.method {
			"leave"
			| "withdraw"
			| "discard"
			| "revoke"
			| rooms_application::signaling::DONE
			| rooms_application::signaling::DECLINE
			| "close"
			| "removeLease"
			| "closeConnection" => Class::Cleanup,
			wire::POST
			| wire::POST_FILES
			| wire::EDIT
			| wire::DM
			| wire::REFILE
			| wire::SET_SUBJECT
			| rooms_application::room::receipt::POST
			| rooms_application::room::receipt::POST_FILES
			| rooms_application::room::correlation::POST
			| rooms_application::room::correlation::POST_FILES
			| rooms_application::open_graph::ROOM_POST_VERB
			| rooms_application::open_graph::ROOM_POST_FILES_VERB => Class::Message,
			wire::TYPING | wire::AWAY | wire::SET_PROFILE => Class::Transient,
			"subscribe" => Class::Join,
			"ready" => Class::Recipient,
			wire::WRITE => Class::Transfer,
			wire::ATTACH | rooms_application::room::receipt::ATTACH => Class::Upload,
			"offerRoom"
			| "handRoom"
			| "offerArchive"
			| "handArchive"
			| "addLease"
			| rooms_application::room::invitation::MINT
			| rooms_application::bridge::SUBMIT => Class::Create,
			"read" if matches!(input.selector, "activity-file" | "file-reader") => Class::Transfer,
			_ if input.selector == "signaling-route" => Class::Signal,
			_ => Class::Read,
		};
		owner
			.admission
			.borrow_mut()
			.work(
				call,
				class,
				(class == Class::Message).then_some(input.material_bytes),
				owner.platform.monotonic_millis(),
			)
			.map_err(super::super::admission::callback_error)
	}
}
