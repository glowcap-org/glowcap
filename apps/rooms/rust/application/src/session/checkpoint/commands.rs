//! Command names and authority checks shared by workspace dispatch and views.
pub mod results;
use super::Routes;
use alloc::string::String;

pub trait CommandRoutes: Routes {
	fn authority_token(&self, sturdyref: &str) -> Option<String>;
}

crate::session::command::catalog! { Command {
	ClearWorkspace,
	SetDraft,
	Select,
	AcceptInvitation,
	DismissInvitation,
	ReceiveRoomLinkInvitation,
	SetStanding,
	JoinDirectory,
	LeaveDirectory,
	SetDirectoryNick,
	ChooseDirectoryNickname,
	JoinRoom,
	StartDirect,
	OpenDirect,
	PublishPeeredRoom,
	RevokePeeredRoom,
	ReplaceOperationsCapabilities,
	ReplaceOperationsBundle,
	LeaveConversation,
	CloseDirect,
	SetDirectoryStanding,
	SetRoomStanding,
	SetEffectiveStanding,
	DropRoomModerator,
	DropRoomManager,
	SubmitRoomBridgeForm,
	SetIgnoredNames,
	SetIgnoredName,
	ChooseHistoryRetention,
	ChooseConnection,
	SelectArchive,
} }
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Arguments,
	Size,
	Json,
	Missing,
	Conflict,
	NamedDirectory,
	Generation,
	Publication,
	Checkpoint(super::Refusal),
}
impl From<super::Refusal> for Error {
	fn from(value: super::Refusal) -> Self {
		Self::Checkpoint(value)
	}
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Arguments => "invalid Rooms command arguments",
			Self::Size => "Rooms command exceeds its text or collection limit",
			Self::Json => "Rooms command received invalid JSON data",
			Self::Missing => "Rooms command names no current entry in this session",
			Self::Conflict => "Rooms command conflicts with the current checkpoint",
			Self::NamedDirectory => "choose an acceptable directory nickname before continuing",
			Self::Generation => "the room's retained capability generation changed",
			Self::Publication => "the room's source has no matching current publication",
			Self::Checkpoint(error) => return error.fmt(f),
		})
	}
}
impl core::error::Error for Error {}
