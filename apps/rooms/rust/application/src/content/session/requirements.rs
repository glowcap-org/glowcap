//! Declared admission requirements. Matching workspace permissions is only one
//! check: every target denotes an exact held capability, checked again after
//! waits. A name or resource ID cannot satisfy a target requirement.
use crate::{
	content::permissions::Permission,
	session::{
		checkpoint::commands::{Command, results},
		command::{Effect, Route},
		verbs::Method,
	},
};
use Permission::*;
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Target {
	DirectoryPresence,
	DirectoryIntroduction,
	DirectoryCreation,
	DirectoryPublication,
	DirectoryAdmission,
	RoomAdmission,
	MembershipInbox,
	MembershipPresence,
	MembershipRetirement,
	AcceptedOffer,
	DirectAccess,
	HeldRoomShare,
	ExactLeaseRevoke,
	ConversationPost,
	ConversationUpload,
	RoomSubject,
	RoomModeration,
	ExactLineEdit,
	ExactLineWithdraw,
	RoomBridgeInspection,
	RoomBridgeSubmission,
	ExactRoomIssue,
	SavedRoomRole,
	CreationReceipt,
	RoomRevoke,
	RoomPublication,
	RoomPublicOffer,
	ArchiveRead,
	ArchiveFile,
	ArchiveIssue,
	ArchiveInspect,
	ArchiveRevoke,
	Operator,
	PendingEffect,
	NestedCommand,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Conditional {
	/// A checked import adds ManageCustody. Existing intent may only select an
	/// already retained exact field without this extra permission.
	ImportsAuthority,
	/// A result containing file bytes adds ReadFile to the session projection.
	/// The exact upstream file/history scope remains an additional check.
	ReturnsFiles,
	/// Replacing attachments requires Upload as well as exact line edit rights.
	UploadsFiles,
}
impl Conditional {
	pub const fn workspace(self) -> &'static [Permission] {
		match self {
			Self::ImportsAuthority => &[ManageCustody],
			Self::ReturnsFiles => &[ReadFile],
			Self::UploadsFiles => &[],
		}
	}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Requirements {
	pub workspace: &'static [Permission],
	pub targets: &'static [Target],
	pub conditional: &'static [Conditional],
}
const fn required(
	workspace: &'static [Permission],
	targets: &'static [Target],
	conditional: &'static [Conditional],
) -> Requirements {
	Requirements {
		workspace,
		targets,
		conditional,
	}
}

/// None marks retired lifecycle methods, which the new content dispatcher must
/// refuse. Shared exact use/control methods own their replacements.
pub const fn method(method: Method) -> Option<Requirements> {
	use Method::*;
	use Target::*;
	Some(match method {
		Snapshot | Watch => required(&[ObserveWorkspace], &[], &[]),
		Command => required(&[InteractWorkspace], &[NestedCommand], &[]),
		Typing => required(&[InteractWorkspace], &[ConversationPost], &[]),
		SendFiles => required(&[InteractWorkspace], &[ConversationUpload], &[]),
		RefileLine => required(&[InteractWorkspace], &[ExactLineEdit], &[Conditional::UploadsFiles]),
		RoomBridgeForm => required(&[ObserveWorkspace], &[RoomBridgeInspection], &[]),
		ReadHistory | ReadHistoryView => required(&[History], &[ArchiveRead], &[Conditional::ReturnsFiles]),
		ArchivedAttachment => required(&[History, ReadFile], &[ArchiveFile], &[]),
		ReadArchiveShare => required(&[ReadArchive], &[ArchiveRead], &[Conditional::ReturnsFiles]),
		AdoptWorkspace | ReplaceCheckpoint => required(&[ReplaceWorkspace], &[], &[Conditional::ImportsAuthority]),
		ResolveEffect | ResumeEffect => required(&[ResolvePending], &[PendingEffect], &[]),
		OperationsSnapshot | OperatorSnapshot | OperatorPage | OperatorRetire => {
			required(&[UseOperations], &[Operator], &[])
		}
		ShareArchive | OfferDurableArchive => required(&[InteractWorkspace], &[ArchiveIssue], &[]),
		ListArchiveShares => required(&[InteractWorkspace], &[ArchiveInspect], &[]),
		RevokeArchiveShare => required(&[InteractWorkspace], &[ArchiveRevoke], &[]),
		DropArchiveShare => required(&[InteractWorkspace], &[], &[]),
		Facet | Revoke => return None,
	})
}

/// Exhaustive over the same enums used by Route::parse. LinkRoom is a plan
/// builder operation and is absent from the dispatched grammar.
pub const fn command(route: Route) -> Option<Requirements> {
	use Target::*;
	let (workspace, targets, conditional): (&'static [Permission], &'static [Target], &'static [Conditional]) =
		match route {
			Route::Checkpoint(command) => match command {
				Command::ClearWorkspace => (&[ReplaceWorkspace, ManageCustody], &[], &[]),
				Command::SetDraft
				| Command::Select
				| Command::SetStanding
				| Command::ChooseDirectoryNickname
				| Command::SetDirectoryStanding
				| Command::SetRoomStanding
				| Command::SetEffectiveStanding
				| Command::SetIgnoredNames
				| Command::SetIgnoredName
				| Command::ChooseHistoryRetention
				| Command::ChooseConnection
				| Command::DismissInvitation
				| Command::LeaveDirectory
				| Command::LeaveConversation
				| Command::CloseDirect => (&[InteractWorkspace], &[], &[]),
				Command::JoinDirectory | Command::SetDirectoryNick => (&[InteractWorkspace], &[DirectoryPresence], &[]),
				Command::JoinRoom => (&[InteractWorkspace], &[RoomAdmission, MembershipInbox], &[]),
				Command::StartDirect => (&[InteractWorkspace], &[DirectoryIntroduction], &[]),
				Command::OpenDirect => (&[InteractWorkspace], &[DirectAccess], &[]),
				Command::AcceptInvitation => (&[InteractWorkspace], &[AcceptedOffer], &[Conditional::ImportsAuthority]),
				Command::ReceiveRoomLinkInvitation => {
					(&[InteractWorkspace], &[HeldRoomShare], &[Conditional::ImportsAuthority])
				}
				Command::PublishPeeredRoom => (
					&[InteractWorkspace, UseOperations],
					&[DirectoryPublication, HeldRoomShare],
					&[],
				),
				Command::RevokePeeredRoom => (&[InteractWorkspace], &[ExactLeaseRevoke], &[]),
				Command::ReplaceOperationsCapabilities
				| Command::ReplaceOperationsBundle
				| Command::SelectArchive
				| Command::DropRoomModerator
				| Command::DropRoomManager => (&[InteractWorkspace, ManageCustody], &[], &[]),
				Command::SubmitRoomBridgeForm => (&[InteractWorkspace], &[RoomBridgeSubmission], &[]),
			},
			Route::Result(command) => match command {
				results::Command::TakeRoomLink
				| results::Command::TakeRoomModerator
				| results::Command::TakeRoomManager => (&[InteractWorkspace, ManageCustody], &[SavedRoomRole], &[]),
				results::Command::EnsureRoomLink => (&[InteractWorkspace, ManageCustody], &[ExactRoomIssue], &[]),
				results::Command::RecoverRoomManager => (&[InteractWorkspace, ManageCustody], &[CreationReceipt], &[]),
				results::Command::OpenManagedRoom => (&[InteractWorkspace, ManageCustody], &[DirectoryCreation], &[]),
				results::Command::LinkRoom => return None,
			},
			Route::Effect(effect) => match effect {
				Effect::EnterRoom => (&[InteractWorkspace], &[DirectoryAdmission], &[]),
				Effect::OfferRoom => (&[InteractWorkspace], &[HeldRoomShare], &[]),
				Effect::ShareArchiveHistory => (
					&[InteractWorkspace, ReadArchive, ReadFile],
					&[ArchiveRead, DirectAccess],
					&[],
				),
				Effect::OfferDurableArchive => (&[InteractWorkspace], &[ArchiveIssue, DirectAccess], &[]),
				Effect::RevokeIssuedArchiveShare => (&[InteractWorkspace], &[ArchiveRevoke], &[]),
				Effect::SetRoomSubject => (&[InteractWorkspace], &[RoomSubject], &[]),
				Effect::SetRoomAway => (&[InteractWorkspace], &[MembershipPresence], &[]),
				Effect::RetireRoomMembership => (&[InteractWorkspace], &[MembershipRetirement], &[]),
				Effect::KickRoomMember => (&[InteractWorkspace], &[RoomModeration], &[]),
				Effect::IssueRoomModerator => (&[InteractWorkspace, ManageCustody], &[ExactRoomIssue], &[]),
				Effect::Say => (&[InteractWorkspace], &[ConversationPost], &[]),
				Effect::DirectReady => (&[InteractWorkspace], &[DirectAccess], &[]),
				Effect::OfferDirectInbox => (&[InteractWorkspace], &[DirectoryIntroduction], &[]),
				Effect::EditLine => (&[InteractWorkspace], &[ExactLineEdit], &[]),
				Effect::WithdrawLine => (&[InteractWorkspace], &[ExactLineWithdraw], &[]),
				Effect::RevokeManagedRoomAuthority => (&[InteractWorkspace], &[RoomRevoke], &[]),
				Effect::UnregisterManagedRoom => (&[InteractWorkspace], &[RoomPublication], &[]),
				Effect::SetManagedRoomPolicy => (&[InteractWorkspace], &[RoomPublicOffer], &[]),
				Effect::Operator | Effect::Operations => (&[InteractWorkspace, UseOperations], &[Operator], &[]),
			},
		};
	Some(required(workspace, targets, conditional))
}
