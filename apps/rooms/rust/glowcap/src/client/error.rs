//! The one error a Rooms client reports, and how a binding failure is read
//! into the Rooms catalog. A code is carried as a value or read from the
//! reason a peer sent, never from rendered diagnostics.
use super::posted_line;
use rooms_application::{
	failure::{Failure, FailureCode, Retry},
	room::authority::Refusal,
};

#[derive(Clone, Debug)]
pub enum Error {
	PostedLine(posted_line::ReplyError),
	/// A local file reader failed. Its diagnostic does not establish a peer verdict.
	SourceRead(String),
	/// The peer proved that a stale workspace candidate installed no changes.
	WorkspaceConflict,
	/// A held management control explicitly rejected this revision or intent.
	#[cfg(feature = "loam")]
	ControlConflict(glowcap::loam::ControlConflict),
	/// The original terminal observation failed. This proves no absence and
	/// cannot authorize another dispatch of that effect.
	Observation(String),
	/// Host admission or a validated application verdict proved this effect was
	/// not dispatched. Its original receipt retains the reason and replay fence.
	RefusedObservation(String),
	/// The binding refused admission. This operation was never sent.
	Unsent(Box<glowcap::Error>),
	Receipt(rooms_application::room::receipt::Error),
	ArchiveShare(rooms_application::archive::shares::Error),
	Archive(rooms_application::archive::Error),
	Inbox(rooms_application::direct::publication::Error),
	Sources(rooms_application::files::sources::Error),
	Direct(rooms_application::direct::Error),
	Signaling(rooms_application::signaling::Error),
	Introduction(rooms_application::directory::introduction::Error),
	Binding(Box<glowcap::Error>),
	Timeout(&'static str),
	Reply(Refusal),
	Custody(rooms_application::room::stewardship::Error),
	Membership(rooms_application::room::membership::Error),
	History(rooms_application::room::history::Error),
	Transfer(rooms_application::files::transfer::Error),
	Invitation(rooms_application::room::invitation::Error),
	Query(rooms_application::room::queries::Error),
	Bridge(rooms_application::bridge::Error),
	Directory(rooms_application::directory::Error),
	Registration(rooms_application::directory::registration::Error),
}
impl Error {
	/// Only validated admission advice can prove absence from a peer break.
	/// A lost observation stays uncertain even when its prose mentions a quota.
	pub fn admission_refusal(&self) -> Option<Failure<'_>> {
		let reason = match self {
			Self::Binding(error) => return binding_admission_refusal(error),
			Self::RefusedObservation(reason) => reason,
			_ => return None,
		};
		Failure::parse(reason).filter(|failure| failure.refused_before_dispatch())
	}
	/// The catalog failure this error names. A binding error is read from its
	/// typed cause and application message. A receipt's reason is the refusal
	/// line its executor wrote from the same two sources. Every other variant
	/// either carries its failure as a value or has none.
	pub fn failure(&self) -> Option<Failure<'_>> {
		match self {
			Self::Binding(error) | Self::Unsent(error) => binding_failure(error),
			Self::RefusedObservation(reason) => Failure::parse(reason),
			Self::Observation(reason) => uncertain_failure(reason),
			Self::Custody(error) => error.failure(),
			_ => None,
		}
	}
	pub fn failure_code(&self) -> Option<rooms_application::failure::FailureCode> {
		self.failure().map(|failure| failure.code)
	}
	/// Terminal absence permits retiring an admission observation. No receipt
	/// lookup or second dispatch is needed to establish that absence again.
	pub fn known_absent(&self) -> bool {
		match self {
			Self::WorkspaceConflict | Self::Unsent(_) | Self::RefusedObservation(_) => true,
			#[cfg(feature = "loam")]
			Self::ControlConflict(_) => true,
			_ => self.admission_refusal().is_some(),
		}
	}
	/// A protocol refusal leaves the selected capability usable. Transport loss
	/// and a missed deadline mean this client no longer has a proved live peer.
	pub fn connection_failed(&self) -> bool {
		match self {
			Self::Binding(error) | Self::Unsent(error) => binding_kind_connection_failed(error.kind()),
			Self::Timeout(_) => true,
			_ => false,
		}
	}
	/// Preserve a peer's canonical Rooms failure code when it supplied one.
	/// Untyped application refusals may depend on either a different request or
	/// changed peer state. Transport loss always needs the connection to change.
	pub fn retry(&self) -> Retry {
		if matches!(self, Self::Observation(_) | Self::RefusedObservation(_)) {
			return Retry::Never;
		}
		if let Self::Binding(error) | Self::Unsent(error) = self {
			return binding_retry(error);
		}
		if matches!(self, Self::Timeout(_) | Self::PostedLine(_)) {
			return Retry::AfterStateChange;
		}
		if matches!(self, Self::SourceRead(_)) {
			return Retry::AfterRequestOrStateChange;
		}
		self.failure_code()
			.map_or(Retry::AfterRequestOrStateChange, |code| code.definition().retry)
	}
}

/// A validated application refusal proves absence before dispatch. The core
/// distinguishes wire breaks and explicit local Loam refusals from diagnostics.
pub fn binding_admission_refusal(error: &glowcap::Error) -> Option<Failure<'_>> {
	Failure::parse(error.application_message()?).filter(|failure| failure.refused_before_dispatch())
}

/// The failure an uncertain receipt's reason names. An admission code is
/// proof that nothing was dispatched, which an uncertain outcome never has,
/// so a reason that leads with one names no failure here.
fn uncertain_failure(reason: &str) -> Option<Failure<'_>> {
	Failure::parse(reason).filter(|failure| !failure.refused_before_dispatch())
}

/// Project binding provenance into the Rooms catalog before rendering text.
/// Application messages are decoded by the Rooms protocol. Local diagnostic
/// detail cannot borrow an application admission code or change its own cause.
pub fn binding_failure(error: &glowcap::Error) -> Option<Failure<'_>> {
	use glowcap::{BreakOrigin, BreakReason};
	let cause = error.cause();
	let detail = error.message().unwrap_or("");
	let code = if cause.context.restoration() {
		if cause.origin == BreakOrigin::Local && cause.reason == BreakReason::TransportUnavailable {
			FailureCode::SavedTransportUnavailable
		} else {
			FailureCode::SessionRestorationFailed
		}
	} else if cause.context.withdrawal() {
		match (cause.origin, cause.reason) {
			(BreakOrigin::Local, BreakReason::Closed) => FailureCode::MemberUnreachable,
			(BreakOrigin::Partner, BreakReason::Application) | (BreakOrigin::Local, BreakReason::Refused) => {
				FailureCode::IntroductionRefused
			}
			_ => return None,
		}
	} else if error.is_publication_not_found() {
		FailureCode::SessionCapabilityGone
	} else if let Some(message) = error.application_message() {
		return Failure::parse(message);
	} else {
		reach_failure(cause)?
	};
	Some(Failure { code, detail })
}

/// The code for a break that carries no application message and no
/// restoration or withdrawal context: how reaching the peer failed. This
/// layer does not know whether it dialed a member, a session or a server, so
/// a peer that is down or gone is named as a peer.
fn reach_failure(cause: glowcap::BreakCause) -> Option<FailureCode> {
	use glowcap::{BreakOrigin, BreakReason};
	Some(match (cause.origin, cause.reason) {
		(BreakOrigin::Local, BreakReason::IdentityUnverified) => FailureCode::SessionPeerUnverified,
		(BreakOrigin::Local, BreakReason::TransportUnavailable) => FailureCode::TransportNotDialed,
		(BreakOrigin::Local, BreakReason::PeerUnreachable | BreakReason::Closed) => FailureCode::PeerUnreachable,
		// An unspecified cause names nothing, so it is no refusal to hold.
		_ if cause.context.fetch() && cause.origin != BreakOrigin::Unspecified => FailureCode::SessionRestorationFailed,
		_ => return None,
	})
}

/// The causes that clear with time alone: this side could not reach the peer,
/// or lost it. A recovery timer reattempts these whatever catalog code names
/// them to a person.
pub fn clears_with_time(cause: glowcap::BreakCause) -> bool {
	use glowcap::{BreakOrigin, BreakReason};
	cause.origin == BreakOrigin::Local && matches!(cause.reason, BreakReason::PeerUnreachable | BreakReason::Closed)
}

/// Whether `code` is one of the two a cause that clears with time is written
/// as outside restoration. A receipt's reason keeps the code and drops the
/// cause, so its reader asks by code.
pub fn reach_code(code: FailureCode) -> bool {
	matches!(code, FailureCode::PeerUnreachable | FailureCode::MemberUnreachable)
}

/// Classify retry conditions without confusing transport loss with a remote
/// application refusal. Frame-size failures can arise in either direction.
pub fn binding_retry(error: &glowcap::Error) -> Retry {
	match binding_failure(error) {
		Some(failure) => failure.code.definition().retry,
		None => binding_kind_retry(error.kind()),
	}
}

fn binding_kind_connection_failed(kind: glowcap::ErrorKind) -> bool {
	matches!(
		kind,
		glowcap::ErrorKind::Closed | glowcap::ErrorKind::Io | glowcap::ErrorKind::TimedOut
	)
}

/// The retry condition of a binding failure the catalog does not name.
fn binding_kind_retry(kind: glowcap::ErrorKind) -> Retry {
	use glowcap::ErrorKind;
	match kind {
		ErrorKind::Broken => Retry::AfterRequestOrStateChange,
		ErrorKind::NullPointer
		| ErrorKind::InvalidArgument
		| ErrorKind::UnsupportedValue
		| ErrorKind::BufferTooSmall => Retry::AfterRequestChange,
		ErrorKind::FrameTooLarge | ErrorKind::NotFound => Retry::AfterRequestOrStateChange,
		_ => Retry::AfterStateChange,
	}
}

impl From<rooms_application::archive::shares::Error> for Error {
	fn from(error: rooms_application::archive::shares::Error) -> Self {
		Self::ArchiveShare(error)
	}
}
impl From<rooms_application::archive::Error> for Error {
	fn from(error: rooms_application::archive::Error) -> Self {
		Self::Archive(error)
	}
}
impl From<rooms_application::files::sources::Error> for Error {
	fn from(error: rooms_application::files::sources::Error) -> Self {
		Self::Sources(error)
	}
}
impl From<rooms_application::direct::publication::Error> for Error {
	fn from(error: rooms_application::direct::publication::Error) -> Self {
		Self::Inbox(error)
	}
}
impl From<rooms_application::direct::Error> for Error {
	fn from(error: rooms_application::direct::Error) -> Self {
		Self::Direct(error)
	}
}
impl From<rooms_application::signaling::Error> for Error {
	fn from(error: rooms_application::signaling::Error) -> Self {
		Self::Signaling(error)
	}
}
impl From<rooms_application::directory::introduction::Error> for Error {
	fn from(error: rooms_application::directory::introduction::Error) -> Self {
		Self::Introduction(error)
	}
}
impl From<rooms_application::directory::registration::Error> for Error {
	fn from(error: rooms_application::directory::registration::Error) -> Self {
		Self::Registration(error)
	}
}
impl From<rooms_application::directory::Error> for Error {
	fn from(error: rooms_application::directory::Error) -> Self {
		Self::Directory(error)
	}
}
impl From<rooms_application::bridge::Error> for Error {
	fn from(error: rooms_application::bridge::Error) -> Self {
		Self::Bridge(error)
	}
}
impl From<rooms_application::room::invitation::Error> for Error {
	fn from(error: rooms_application::room::invitation::Error) -> Self {
		Self::Invitation(error)
	}
}
impl From<rooms_application::room::queries::Error> for Error {
	fn from(error: rooms_application::room::queries::Error) -> Self {
		Self::Query(error)
	}
}
impl From<rooms_application::files::transfer::Error> for Error {
	fn from(error: rooms_application::files::transfer::Error) -> Self {
		Self::Transfer(error)
	}
}
impl From<rooms_application::room::history::Error> for Error {
	fn from(error: rooms_application::room::history::Error) -> Self {
		Self::History(error)
	}
}
impl From<rooms_application::room::membership::Error> for Error {
	fn from(error: rooms_application::room::membership::Error) -> Self {
		Self::Membership(error)
	}
}
impl From<rooms_application::room::stewardship::Error> for Error {
	fn from(error: rooms_application::room::stewardship::Error) -> Self {
		Self::Custody(error)
	}
}
impl From<posted_line::ReplyError> for Error {
	fn from(error: posted_line::ReplyError) -> Self {
		Self::PostedLine(error)
	}
}
impl From<Refusal> for Error {
	fn from(error: Refusal) -> Self {
		Self::Reply(error)
	}
}
impl From<glowcap::Error> for Error {
	fn from(error: glowcap::Error) -> Self {
		Self::Binding(Box::new(error))
	}
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::PostedLine(error) => error.fmt(f),
			Self::SourceRead(reason) => f.write_str(reason),
			Self::WorkspaceConflict => f.write_str("workspace revision changed; this acquisition installed no changes"),
			#[cfg(feature = "loam")]
			Self::ControlConflict(conflict) => conflict.fmt(f),
			Self::Observation(reason) | Self::RefusedObservation(reason) => f.write_str(reason),
			Self::Binding(e) | Self::Unsent(e) => e.fmt(f),
			Self::Timeout(what) => f.write_str(what),
			Self::Reply(e) => e.fmt(f),
			Self::Custody(e) => e.fmt(f),
			Self::Membership(e) => e.fmt(f),
			Self::Receipt(e) => e.fmt(f),
			Self::History(e) => e.fmt(f),
			Self::Transfer(e) => e.fmt(f),
			Self::Invitation(e) => e.fmt(f),
			Self::Query(e) => e.fmt(f),
			Self::Bridge(e) => e.fmt(f),
			Self::Directory(e) => e.fmt(f),
			Self::Archive(e) => e.fmt(f),
			Self::ArchiveShare(e) => e.fmt(f),
			Self::Registration(e) => e.fmt(f),
			Self::Introduction(e) => e.fmt(f),
			Self::Signaling(e) => e.fmt(f),
			Self::Direct(e) => e.fmt(f),
			Self::Inbox(e) => e.fmt(f),
			Self::Sources(e) => e.fmt(f),
		}
	}
}
impl core::error::Error for Error {}

#[cfg(test)]
mod tests {
	use super::*;
	use rooms_application::failure::FailureCode;

	#[test]
	fn only_a_lost_or_unreachable_peer_clears_with_time() {
		use glowcap::{BreakCause, BreakReason};
		assert!(clears_with_time(BreakCause::local(BreakReason::PeerUnreachable)));
		assert!(clears_with_time(BreakCause::local(BreakReason::Closed)));
		for standing in [
			BreakCause::local(BreakReason::TransportUnavailable),
			BreakCause::local(BreakReason::IdentityUnverified),
			BreakCause::local(BreakReason::Refused),
			BreakCause::local(BreakReason::Application),
			BreakCause::partner(),
			BreakCause::default(),
		] {
			assert!(!clears_with_time(standing), "{standing:?}");
		}
		// A receipt reader recognizes both by the code they are written as.
		for reason in [BreakReason::PeerUnreachable, BreakReason::Closed] {
			assert!(reach_failure(BreakCause::local(reason)).is_some_and(reach_code));
		}
		assert!(!reach_code(FailureCode::NickTaken));
	}

	#[test]
	fn a_failed_reach_is_named_by_its_cause() {
		use glowcap::{BreakCause, BreakReason};
		let local = |reason| reach_failure(BreakCause::local(reason));
		// Waiting never registers a transport, so this is not "unreachable".
		assert_eq!(
			local(BreakReason::TransportUnavailable),
			Some(FailureCode::TransportNotDialed)
		);
		// Whom the dial was for is the caller's to say, even on a fetch.
		assert_eq!(local(BreakReason::PeerUnreachable), Some(FailureCode::PeerUnreachable));
		assert_eq!(local(BreakReason::Closed), Some(FailureCode::PeerUnreachable));
		assert_eq!(
			reach_failure(BreakCause::local(BreakReason::PeerUnreachable).with_fetch()),
			Some(FailureCode::PeerUnreachable)
		);
		assert_eq!(
			reach_failure(BreakCause::partner().with_fetch()),
			Some(FailureCode::SessionRestorationFailed)
		);
		// A fetch that broke with no named cause is no refusal to hold.
		assert_eq!(reach_failure(BreakCause::default().with_fetch()), None);
		assert_eq!(reach_failure(BreakCause::partner()), None);
	}

	#[test]
	fn lost_observation_cannot_become_absence_from_its_diagnostic() {
		for reason in [
			"rate-limited: retry-after-ms=1000; scope=message; owner=session",
			"admission-busy: accounting table is full",
			"request-too-large: scope=message-bytes",
		] {
			let error = Error::Observation(reason.into());
			assert!(!error.known_absent());
			assert!(error.admission_refusal().is_none());
			assert_eq!(error.failure_code(), None, "{reason}");
			// A local failure's diagnostic does not prove remote absence.
			#[cfg(feature = "loam")]
			assert!(binding_admission_refusal(&glowcap::loam::refusal(reason)).is_none());
			let read = Error::SourceRead(reason.into());
			assert!(!read.known_absent());
			assert!(read.admission_refusal().is_none());
			assert_eq!(read.retry(), Retry::AfterRequestOrStateChange);
		}
		assert!(Error::RefusedObservation("original Host admission failed".into()).known_absent());
	}

	/// A variant names its code as a value. Text that merely starts like a
	/// code selects nothing, so a diagnostic cannot choose a retry class.
	#[test]
	fn a_typed_variant_carries_its_code_and_rendered_text_selects_none() {
		use rooms_application::room::stewardship;
		assert_eq!(
			Error::Custody(stewardship::Error::StewardRetired).failure_code(),
			Some(FailureCode::NotSteward)
		);
		assert_eq!(Error::Custody(stewardship::Error::Busy).failure_code(), None);
		let coded_text = format!("{}: alice", FailureCode::NickTaken.wire());
		assert_eq!(
			Error::RefusedObservation(coded_text.clone()).failure_code(),
			Some(FailureCode::NickTaken)
		);
		assert_eq!(
			Error::Observation(coded_text.clone()).failure_code(),
			Some(FailureCode::NickTaken)
		);
		assert_eq!(Error::SourceRead(coded_text).failure_code(), None);
	}

	#[test]
	fn a_code_is_read_from_the_head_and_an_uncoded_kind_from_its_class() {
		let coded = format!(
			"{}: detail mentioning {}",
			FailureCode::IntroductionTimedOut.wire(),
			FailureCode::NickTaken.wire()
		);
		assert_eq!(
			Failure::parse(&coded).map(|failure| failure.code),
			Some(FailureCode::IntroductionTimedOut)
		);
		assert_eq!(
			binding_kind_retry(glowcap::ErrorKind::Broken),
			Retry::AfterRequestOrStateChange
		);
		assert_eq!(
			binding_kind_retry(glowcap::ErrorKind::InvalidArgument),
			Retry::AfterRequestChange
		);
		assert_eq!(
			binding_kind_retry(glowcap::ErrorKind::Malformed),
			Retry::AfterStateChange
		);
		assert_eq!(Error::Timeout("late").retry(), Retry::AfterStateChange);
		assert_eq!(Error::Reply(Refusal::Policy).retry(), Retry::AfterRequestOrStateChange);
	}

	#[test]
	fn only_connection_loss_retires_a_selected_peer() {
		use glowcap::ErrorKind;
		for kind in [ErrorKind::Closed, ErrorKind::Io, ErrorKind::TimedOut] {
			assert!(binding_kind_connection_failed(kind));
		}
		for kind in [
			ErrorKind::Broken,
			ErrorKind::InvalidArgument,
			ErrorKind::Malformed,
			ErrorKind::FrameTooLarge,
		] {
			assert!(!binding_kind_connection_failed(kind));
		}
		assert!(Error::Timeout("late").connection_failed());
		assert!(!Error::Reply(Refusal::Policy).connection_failed());
	}
}
