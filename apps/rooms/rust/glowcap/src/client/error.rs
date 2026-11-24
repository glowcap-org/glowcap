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
	/// A call to a peer other than the attached session missed its deadline.
	/// The caller treats that peer as unproved and names no Rooms failure.
	Timeout(&'static str),
	/// The session this page is attached to was not reached or was lost. The
	/// caller ends its link and dials again, and only time clears it. `cause` is the
	/// binding failure when the connection closed or broke under a call. It is
	/// none when a call and one more request both missed their deadlines, or
	/// when a dial or a close missed its own.
	Unreached {
		detail: &'static str,
		cause: Option<Box<glowcap::Error>>,
	},
	/// A call through the session this page is attached to missed its
	/// deadline while the session still answers. The caller keeps its link and
	/// may ask again soon. A call that changes nothing, or that a repeat cannot
	/// double (an attenuation is asked again by its sequence), shows it. An
	/// effect that times out stays uncertain under its receipt, because it may
	/// still land.
	RequestTimedOut(&'static str),
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
/// How a submitted request whose reply failed stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubmissionStatus {
	/// The peer proved the request's base stale and installed nothing, so
	/// only this permits applying it again.
	Conflict,
	/// The peer admitted nothing of the request, which is freed with its reason.
	Refused,
	/// Nothing settled the question, so the request stays held for its receipt.
	Uncertain,
}
impl SubmissionStatus {
	pub const fn wire(self) -> &'static str {
		match self {
			Self::Conflict => "conflict",
			Self::Refused => "refused",
			Self::Uncertain => "uncertain",
		}
	}
}
impl Error {
	/// The attached session was not reached within a call's bound, with no
	/// binding failure to carry: `detail` names the call.
	pub const fn unreached(detail: &'static str) -> Self {
		Self::Unreached { detail, cause: None }
	}
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
	/// line its executor wrote from the same two sources, as `observed` reads
	/// it. Every other variant either carries its failure as a value or has
	/// none.
	pub fn failure(&self) -> Option<Failure<'_>> {
		match self {
			Self::Binding(error) | Self::Unsent(error) => binding_failure(error),
			Self::RefusedObservation(reason) => Failure::parse(reason).map(observed),
			Self::Observation(reason) => uncertain_failure(reason).map(observed),
			Self::Unreached { detail, cause } => Some(Failure {
				code: FailureCode::SessionUnreachable,
				detail: cause.as_ref().and_then(|cause| cause.message()).unwrap_or(detail),
			}),
			Self::RequestTimedOut(what) => Some(Failure {
				code: FailureCode::SessionRequestTimedOut,
				detail: what,
			}),
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
			Self::ControlConflict(_) => true,
			_ => self.admission_refusal().is_some(),
		}
	}
	/// How a submitted request whose reply failed with this error stands. A
	/// missed deadline proves nothing, so it is `Uncertain`.
	pub fn submission_status(&self) -> SubmissionStatus {
		if matches!(self, Self::WorkspaceConflict | Self::ControlConflict(_)) {
			SubmissionStatus::Conflict
		} else if self.known_absent() {
			SubmissionStatus::Refused
		} else {
			SubmissionStatus::Uncertain
		}
	}
	/// A protocol refusal leaves the selected capability usable. Transport loss,
	/// a peer this side could not reach, and a missed deadline mean this client
	/// no longer has a proved live peer.
	pub fn connection_failed(&self) -> bool {
		match self {
			Self::Binding(error) | Self::Unsent(error) => binding_connection_failed(error.kind(), error.cause()),
			Self::Timeout(_) | Self::Unreached { .. } => true,
			_ => false,
		}
	}
	/// This failure as a call to an attached session sees it: a binding
	/// failure that says the connection is gone is `Error::Unreached`, named
	/// by `detail` with that failure as its cause. Any other failure is
	/// unchanged, so a request the session answered late stays
	/// `RequestTimedOut` and keeps the link.
	pub fn unreached_if_lost(self, detail: &'static str) -> Self {
		match self {
			Self::Binding(error) if binding_connection_failed(error.kind(), error.cause()) => Self::Unreached {
				detail,
				cause: Some(error),
			},
			error => error,
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
		if matches!(self, Self::Timeout(_) | Self::Unreached { .. } | Self::PostedLine(_)) {
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

/// A receipt's failure as this side reads it. The executor that wrote it
/// reached the session's other peers over links of its own, and one of them
/// may have named its own session unreachable. To this side that is a peer it
/// could not reach, so the code that names this side's own link to its
/// session comes only from `Error::Unreached`.
fn observed(failure: Failure<'_>) -> Failure<'_> {
	match failure.code {
		FailureCode::SessionUnreachable => Failure {
			code: FailureCode::PeerUnreachable,
			..failure
		},
		_ => failure,
	}
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

/// Classify retry conditions without confusing transport loss with a remote
/// application refusal. Frame-size failures can arise in either direction.
pub fn binding_retry(error: &glowcap::Error) -> Retry {
	match binding_failure(error) {
		Some(failure) => failure.code.definition().retry,
		None => binding_kind_retry(error.kind()),
	}
}

/// Whether a binding failure says the connection to its peer is gone: the
/// transport closed, failed or timed out, or the break's cause is one that
/// clears with time, as a dial that never reached its peer is.
fn binding_connection_failed(kind: glowcap::ErrorKind, cause: glowcap::BreakCause) -> bool {
	matches!(
		kind,
		glowcap::ErrorKind::Closed | glowcap::ErrorKind::Io | glowcap::ErrorKind::TimedOut
	) || clears_with_time(cause)
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
			Self::ControlConflict(conflict) => conflict.fmt(f),
			Self::Observation(reason) | Self::RefusedObservation(reason) => f.write_str(reason),
			Self::Binding(e) | Self::Unsent(e) => e.fmt(f),
			Self::Unreached { cause: Some(cause), .. } => cause.fmt(f),
			Self::Unreached { detail, cause: None } => f.write_str(detail),
			Self::Timeout(what) | Self::RequestTimedOut(what) => f.write_str(what),
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
			assert!(reach_failure(BreakCause::local(reason)).is_some_and(FailureCode::reach));
		}
		assert!(FailureCode::SessionUnreachable.reach());
		assert!(!FailureCode::NickTaken.reach());
	}

	#[test]
	fn a_missed_deadline_names_the_attached_session_only() {
		assert_eq!(
			Error::unreached("late").failure_code(),
			Some(FailureCode::SessionUnreachable)
		);
		assert_eq!(Error::Timeout("late").failure_code(), None);
	}

	#[test]
	fn only_a_lost_connection_reads_as_an_unreached_session() {
		let lost = |error: Error| error.unreached_if_lost("lost");
		assert!(matches!(
			lost(Error::RequestTimedOut("late")),
			Error::RequestTimedOut("late")
		));
		let refused = lost(Error::from(glowcap::loam::refusal("nick-taken: Ann")));
		assert!(matches!(refused, Error::Binding(_)), "{refused}");
		assert!(matches!(lost(Error::Timeout("late")), Error::Timeout("late")));
		let unreached = lost(Error::unreached("gone"));
		assert!(matches!(unreached, Error::Unreached { detail: "gone", .. }));
	}

	#[test]
	fn an_effect_that_times_out_at_the_session_stays_uncertain() {
		let late = Error::RequestTimedOut("late");
		assert_eq!(late.submission_status(), SubmissionStatus::Uncertain);
		assert!(!late.known_absent());
		assert!(!late.connection_failed(), "the session still answers");
		assert_eq!(late.failure_code(), Some(FailureCode::SessionRequestTimedOut));
		assert_eq!(late.retry(), Retry::Soon);
		assert_eq!(Error::WorkspaceConflict.submission_status(), SubmissionStatus::Conflict);
		assert_eq!(
			Error::RefusedObservation("refused".into()).submission_status(),
			SubmissionStatus::Refused
		);
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
			assert!(binding_admission_refusal(&glowcap::loam::refusal(reason)).is_none());
			let read = Error::SourceRead(reason.into());
			assert!(!read.known_absent());
			assert!(read.admission_refusal().is_none());
			assert_eq!(read.retry(), Retry::AfterRequestOrStateChange);
		}
		assert!(Error::RefusedObservation("original Host admission failed".into()).known_absent());
	}

	/// Only this side's own call names its link to the session unreachable.
	/// A receipt that says so speaks of a link another peer holds.
	#[test]
	fn a_receipt_naming_its_session_unreachable_is_a_peer_this_side_could_not_reach() {
		let line = FailureCode::SessionUnreachable.line("the archive peer lost its session");
		for error in [Error::Observation(line.clone()), Error::RefusedObservation(line)] {
			assert_eq!(error.failure_code(), Some(FailureCode::PeerUnreachable));
			assert_eq!(
				error.failure().map(|failure| failure.detail),
				Some("the archive peer lost its session")
			);
		}
		assert_eq!(
			Error::unreached("a call").failure_code(),
			Some(FailureCode::SessionUnreachable)
		);
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
		use glowcap::{BreakCause, BreakReason, ErrorKind};
		for kind in [ErrorKind::Closed, ErrorKind::Io, ErrorKind::TimedOut] {
			assert!(binding_connection_failed(kind, BreakCause::default()), "{kind:?}");
		}
		for kind in [
			ErrorKind::Broken,
			ErrorKind::InvalidArgument,
			ErrorKind::Malformed,
			ErrorKind::FrameTooLarge,
		] {
			assert!(!binding_connection_failed(kind, BreakCause::default()), "{kind:?}");
		}
		// A break this side could not reach past, as a dial that never reached
		// its peer ends, is a lost connection whatever kind carries it.
		for reason in [BreakReason::PeerUnreachable, BreakReason::Closed] {
			let cause = BreakCause::local(reason).with_fetch();
			assert!(binding_connection_failed(ErrorKind::Broken, cause), "{reason:?}");
		}
		// The peer's own break and a refusal leave the connection proved.
		for cause in [
			BreakCause::partner(),
			BreakCause::local(BreakReason::Refused),
			BreakCause::local(BreakReason::PublicationAbsent).with_fetch(),
		] {
			assert!(!binding_connection_failed(ErrorKind::Broken, cause), "{cause:?}");
		}
		assert!(Error::Timeout("late").connection_failed());
		assert!(!Error::Reply(Refusal::Policy).connection_failed());
	}
}
