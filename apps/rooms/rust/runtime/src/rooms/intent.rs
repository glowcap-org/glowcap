//! Exact committed inputs to a room membership. Learned facts update this
//! retained intent only after the corresponding durable acknowledgement.
use rooms_application::{
	bridge::Answers,
	session::{
		checkpoint::{RoomIntent, RoomReconnect},
		snapshot::Id,
	},
	text::DocumentText,
};

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Bridge {
	pub scope: DocumentText,
	pub action: DocumentText,
	pub answers: Answers,
	pub secrets_given: bool,
	pub credential_revision: Option<DocumentText>,
}
impl Bridge {
	pub fn read(intent: RoomIntent<'_>) -> Option<Self> {
		let bridge = intent.bridge?;
		Some(Self {
			scope: bridge.scope.clone(),
			action: bridge.action.clone(),
			answers: bridge.answers.clone(),
			secrets_given: bridge.secrets_given,
			credential_revision: bridge.credential_revision.cloned(),
		})
	}
}

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Intent {
	pub id: String,
	pub directory: Id,
	pub name: String,
	pub held: bool,
	pub reconnect: Option<RoomReconnect>,
	pub link: Option<String>,
	pub manager: Option<String>,
	pub steward: Option<String>,
	pub publication: Option<String>,
	pub subject: String,
}
impl Intent {
	/// Bearer rotation changes custody, not the identity of an existing seat.
	pub fn same_membership(&self, other: &Self) -> bool {
		self.id == other.id
			&& self.directory == other.directory
			&& self.name == other.name
			&& self.held == other.held
			&& self.publication == other.publication
	}
	pub fn remains_terminal(&self, ended: &Self) -> bool {
		self.reconnect != Some(RoomReconnect::Requested) && self.same_membership(ended)
	}

	pub fn read(intent: RoomIntent<'_>) -> Option<Self> {
		let text = |field: Option<&rooms_application::session::checkpoint::reconciliation::Bearer>| {
			field.and_then(|value| value.text().as_str().map(str::to_owned))
		};
		Some(Self {
			id: intent.id.text().as_str()?.into(),
			directory: intent.directory.clone(),
			name: intent.name.text().as_str()?.into(),
			held: intent.held,
			reconnect: intent.reconnect,
			link: text(intent.link),
			manager: text(intent.manager),
			steward: text(intent.steward),
			publication: intent
				.publication_id
				.and_then(|id| id.text().as_str().map(str::to_owned)),
			subject: super::subject(intent),
		})
	}
}
