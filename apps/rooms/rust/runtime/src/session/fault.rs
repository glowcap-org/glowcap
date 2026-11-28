//! Test-only faults of the session process. With the `test-support` feature,
//! `GLOWCAP_ROOMS_SESSION_FAULT=<point>` arms one point of [`SessionFault`],
//! read once per process. A name that is not a point stops the process at its
//! first read, because a typo would otherwise arm nothing and pass. A build
//! without the feature arms nothing: [`armed`] answers none. The session's
//! process tests set the variable, and both the runtime and the services
//! crate ask this one table, so the variable has one grammar.

use rooms_application::session::effect::Reply;

macro_rules! points {
	($($(#[$doc:meta])* $variant:ident = $name:literal,)*) => {
		/// The points a session process test can arm. The name is what the
		/// variable carries.
		#[derive(Clone, Copy, Debug, PartialEq, Eq)]
		pub enum SessionFault {
			$($(#[$doc])* $variant,)*
		}

		#[cfg(feature = "test-support")]
		impl SessionFault {
			const ALL: &'static [Self] = &[$(Self::$variant,)*];

			fn name(self) -> &'static str {
				match self {
					$(Self::$variant => $name,)*
				}
			}
		}
	};
}

points! {
	/// The original first return capability arrives but the owner has not yet installed it.
	HoldReciprocalRoute = "hold-reciprocal-route",
	/// The session process ends after saving the issue's place, before issuing.
	AfterIssueReservation = "after-issue-reservation",
	/// The session process ends between issuing an access and saving its
	/// control.
	AfterIssue = "after-issue",
	/// The workspace for saving an issued control cannot be read.
	FailAccessSave = "fail-access-save",
	/// The first observation of a posted line expires at once, as the
	/// observation deadline does, so its executor pauses.
	ExpireFirstLineObservation = "expire-first-line-observation",
	/// The first observation of a direct-message open expires at once, as the
	/// observation deadline does, so its executor pauses.
	ExpireFirstOpenObservation = "expire-first-open-observation",
	/// Every observation of a posted line expires at once, so every line's
	/// executor pauses and keeps its receipt place.
	ExpireLineObservations = "expire-line-observations",
	/// Every line's settlement commits, and its executor then pauses as if the
	/// settlement's answer had missed its deadline.
	LateLineSettlements = "late-line-settlements",
	/// As [`Self::LateLineSettlements`], and no admission retires a settled
	/// job, so only a release of its receipt can.
	LateLineSettlementsHeld = "late-line-settlements-held",
	/// Hold room seat acquisition until a post reaches its admission fence.
	RoomPostBeforeSeat = "room-post-before-seat",
	/// Every append of an upload's fill takes [`UPLOAD_WRITE_DELAY_MS`] before
	/// it is sent, as a slow room does.
	SlowUploadWrites = "slow-upload-writes",
}

#[cfg(feature = "test-support")]
static ROOM_POST: tokio::sync::Notify = tokio::sync::Notify::const_new();

#[cfg(feature = "test-support")]
pub(crate) async fn before_room_seat() {
	if armed() == Some(SessionFault::RoomPostBeforeSeat) {
		ROOM_POST.notified().await;
	}
}

pub(crate) fn room_post_waited() {
	#[cfg(feature = "test-support")]
	if armed() == Some(SessionFault::RoomPostBeforeSeat) {
		ROOM_POST.notify_one();
	}
}

/// How long one append waits while [`SessionFault::SlowUploadWrites`] is armed.
pub const UPLOAD_WRITE_DELAY_MS: u64 = 6_000;

/// How long the next append of an upload's fill waits, while
/// [`SessionFault::SlowUploadWrites`] is armed.
pub(crate) fn upload_write_delay_ms() -> Option<u64> {
	(armed() == Some(SessionFault::SlowUploadWrites)).then_some(UPLOAD_WRITE_DELAY_MS)
}

/// The armed point, read from the variable once.
#[cfg(feature = "test-support")]
pub fn armed() -> Option<SessionFault> {
	static ARMED: std::sync::OnceLock<Option<SessionFault>> = std::sync::OnceLock::new();
	*ARMED.get_or_init(|| {
		let named = std::env::var_os("GLOWCAP_ROOMS_SESSION_FAULT")?;
		match SessionFault::ALL.iter().find(|point| named == point.name()) {
			Some(point) => Some(*point),
			None => panic!("GLOWCAP_ROOMS_SESSION_FAULT names no session fault point: {named:?}"),
		}
	})
}

/// The armed point. A build without `test-support` arms none.
#[cfg(not(feature = "test-support"))]
pub fn armed() -> Option<SessionFault> {
	None
}

/// Whether the observation of an executing request that answers `reply`
/// expires at once: every line's while [`SessionFault::ExpireLineObservations`]
/// is armed, and otherwise only the first such observation in the process,
/// while the point for its reply is armed.
pub(crate) fn expires_observation(reply: Reply) -> bool {
	if reply == Reply::Line && armed() == Some(SessionFault::ExpireLineObservations) {
		return true;
	}
	let point = match reply {
		Reply::Line => SessionFault::ExpireFirstLineObservation,
		Reply::DirectAccess => SessionFault::ExpireFirstOpenObservation,
		_ => return false,
	};
	if armed() != Some(point) {
		return false;
	}
	static SPENT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
	!SPENT.swap(true, std::sync::atomic::Ordering::SeqCst)
}
/// Whether an executor whose settlement of a request answering `reply` has
/// just committed pauses as if that answer came late: every line's while
/// [`SessionFault::LateLineSettlements`] is armed.
pub(crate) fn settles_late(reply: Reply) -> bool {
	reply == Reply::Line
		&& matches!(
			armed(),
			Some(SessionFault::LateLineSettlements | SessionFault::LateLineSettlementsHeld)
		)
}
/// Whether admissions leave a paused job whose receipt settled, so that only
/// a release retires it: while [`SessionFault::LateLineSettlementsHeld`] is
/// armed.
pub(crate) fn holds_settled_retirement() -> bool {
	armed() == Some(SessionFault::LateLineSettlementsHeld)
}

/// The process proof releases this single receiver's handoff independently
/// of its other conversations and the bot attached to the session.
#[cfg(feature = "test-support")]
pub(crate) async fn hold_reciprocal(platform: &impl rooms_glowcap::client::Deadline) {
	if armed() == Some(SessionFault::HoldReciprocalRoute)
		&& let Some(path) = std::env::var_os("GLOWCAP_ROOMS_TEST_ROUTE_LATCH")
	{
		while std::path::Path::new(&path).exists() {
			platform.within(20, std::future::pending::<()>()).await;
		}
	}
}
