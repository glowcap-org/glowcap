//! Test-only faults of the attached view. With the `test-support` feature,
//! `GLOWCAP_ROOMS_VIEW_FAULT=<point>` makes one point of [`ViewFault`] fail as
//! a lost connection or a moved workspace would, so a process test can prove a
//! committed command is still reported and its receipt given back. A name
//! that is not a point stops the process at its first read, because a typo
//! would otherwise arm nothing and pass. A build without the feature fails
//! nothing here: every function is a constant. The bot's fault points
//! (`product/src/bin/rooms-bot/fault.rs`) and the session's
//! (`rooms_runtime::session::fault`) take the same `points!` form, kept as a copy in
//! each crate because the only crates they share are release crates, and a
//! test-only macro does not belong in one.

use super::{ClientError, Error};

macro_rules! points {
	($($(#[$doc:meta])* $variant:ident = $name:literal,)*) => {
		/// The points a process test can fail. The name is what the variable
		/// carries.
		#[derive(Clone, Copy, Debug, PartialEq, Eq)]
		#[cfg_attr(
			not(feature = "test-support"),
			allow(dead_code, reason = "only test-support code reaches a point")
		)]
		pub(super) enum ViewFault {
			$($(#[$doc])* $variant,)*
		}

		#[cfg(feature = "test-support")]
		impl ViewFault {
			const ALL: &'static [Self] = &[$(Self::$variant,)*];

			fn name(self) -> &'static str {
				match self {
					$(Self::$variant => $name,)*
				}
			}

			/// The failure a lost connection gives at this point.
			fn lost(self) -> ClientError {
				ClientError::Timeout(match self {
					$(Self::$variant => concat!("the injected ", $name, " fault"),)*
				})
			}
		}
	};
}

points! {
	/// The workspace read that keeping a committed command's result starts with.
	KeepRead = "keep-read",
	/// Keeping an introduced route.
	AdoptDirect = "adopt-direct",
	/// Keeping a committed command's line or route commits, and its answer is
	/// lost.
	KeepLost = "keep-lost",
	/// The first keeper's acquisition finds the workspace moved on every
	/// attempt, so nothing is adopted and keeping reports a conflict. Later
	/// keepers in the process find it still.
	KeepConflict = "keep-conflict",
	/// Keeping a committed line meets the workspace's refusal that never
	/// clears, as a conversation that is gone or authority that changed does.
	KeepRefused = "keep-refused",
	/// A `say` finds the workspace moved.
	SayConflict = "say-conflict",
	/// A `send_files` finds the workspace moved.
	SendConflict = "send-conflict",
	/// A passed-through command finds the workspace moved.
	CommandConflict = "command-conflict",
	/// An open finds the workspace moved.
	OpenConflict = "open-conflict",
	/// The first open's answer is lost.
	OpenLost = "open-lost",
	/// The first open committed and its answer says it is still pending.
	OpenUnconfirmed = "open-unconfirmed",
	/// The first open's introduction never reaches the session.
	IntroduceUnsent = "introduce-unsent",
	/// The first `say` or `send_files` commits and its answer says it is still
	/// pending, as an answer that outlasts its bound leaves it, so what it
	/// returned is not kept yet.
	PostUnconfirmed = "post-unconfirmed",
	/// The first `say` or `send_files` commits and its answer is lost, so the
	/// caller holds an uncertain outcome and what it returned is not kept yet.
	PostLost = "post-lost",
	/// The outcome read of a committed upload fails as a lost connection, at
	/// the `send_files` that committed it and at the first look at its
	/// receipt after, so the line posted and the caller cannot tell how its
	/// files stand. The next look reads it.
	ResultLost = "result-lost",
	/// As `PostLost`, and the workspace read that keeping what a look found
	/// committed starts with fails, so the look finds the line committed and
	/// cannot keep it.
	PostLostUnkept = "post-lost-unkept",
}

/// Fail with the error a lost connection gives when `point` is armed.
#[cfg(feature = "test-support")]
pub(super) fn lose(point: ViewFault) -> Result<(), Error> {
	if armed() == Some(point) {
		return Err(Error::Unreachable(point.lost()));
	}
	Ok(())
}

#[cfg(not(feature = "test-support"))]
pub(super) fn lose(_point: ViewFault) -> Result<(), Error> {
	Ok(())
}

/// Fail the read of a committed upload's outcome while [`ViewFault::ResultLost`]
/// is armed, for its first two reads in the process.
#[cfg(feature = "test-support")]
pub(super) fn lose_result() -> Result<(), Error> {
	static READS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
	if armed() == Some(ViewFault::ResultLost) && READS.fetch_add(1, std::sync::atomic::Ordering::SeqCst) < 2 {
		return Err(Error::Unreachable(ViewFault::ResultLost.lost()));
	}
	Ok(())
}

#[cfg(not(feature = "test-support"))]
pub(super) fn lose_result() -> Result<(), Error> {
	Ok(())
}

/// Fail with a refusal that never clears when `point` is armed.
#[cfg(feature = "test-support")]
pub(super) fn refuse(point: ViewFault) -> Result<(), Error> {
	if armed() == Some(point) {
		return Err(Error::Input(format!("the injected {} fault", point.name())));
	}
	Ok(())
}

#[cfg(not(feature = "test-support"))]
pub(super) fn refuse(_point: ViewFault) -> Result<(), Error> {
	Ok(())
}

/// Whether a keeper's acquisition attempt finds the workspace moved: the
/// first `attempts` attempts in the process while [`ViewFault::KeepConflict`]
/// is armed, which is the whole of one keeper's tries.
#[cfg(feature = "test-support")]
pub(super) fn keep_moved(attempts: usize) -> bool {
	static SPENT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
	armed() == Some(ViewFault::KeepConflict) && SPENT.fetch_add(1, std::sync::atomic::Ordering::SeqCst) < attempts
}

#[cfg(not(feature = "test-support"))]
pub(super) fn keep_moved(_attempts: usize) -> bool {
	false
}

/// The lost connection's error when `point` is armed and this is the first use
/// of any once-only point in the process. The once-only points are
/// `OpenLost`, `OpenUnconfirmed`, `IntroduceUnsent`, `PostUnconfirmed`,
/// `PostLost`, and `PostLostUnkept`:
/// they share one use because the request they break is retried or looked
/// at again, and that must succeed. The
/// flag is process-wide because the view has no handle a test could reset.
#[cfg(feature = "test-support")]
pub(super) fn once(point: ViewFault) -> Option<ClientError> {
	static SPENT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
	(armed() == Some(point) && !SPENT.swap(true, std::sync::atomic::Ordering::SeqCst)).then(|| point.lost())
}

#[cfg(not(feature = "test-support"))]
pub(super) fn once(_point: ViewFault) -> Option<ClientError> {
	None
}

/// Whether the session answers `operation` as a moved workspace at the armed
/// `point`: the first operation that reaches any conflict point, and that same
/// operation every time after, as a real session answers an operation that
/// can never commit. A retry under the same operation therefore fails again,
/// so a test proves the retry took a new one. The first operation is
/// process-wide because the view has no handle a test could reset.
#[cfg(feature = "test-support")]
pub(super) fn conflicts(point: ViewFault, operation: &str) -> bool {
	static CONFLICTED: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
	if armed() != Some(point) {
		return false;
	}
	let mut first = CONFLICTED.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
	first.get_or_insert_with(|| operation.to_owned()) == operation
}

#[cfg(not(feature = "test-support"))]
pub(super) fn conflicts(_point: ViewFault, _operation: &str) -> bool {
	false
}

/// The armed point, read from the variable once.
#[cfg(feature = "test-support")]
fn armed() -> Option<ViewFault> {
	static ARMED: std::sync::OnceLock<Option<ViewFault>> = std::sync::OnceLock::new();
	*ARMED.get_or_init(|| {
		let named = std::env::var_os("GLOWCAP_ROOMS_VIEW_FAULT")?;
		let point = ViewFault::ALL.iter().find(|point| named == point.name());
		match point {
			Some(point) => Some(*point),
			None => panic!("GLOWCAP_ROOMS_VIEW_FAULT names no view fault point: {named:?}"),
		}
	})
}

/// The operations whose result reached the view's forfeit, so a test proves
/// which path a command took. Global because forfeiting is reached through
/// the view with no handle to the test.
#[cfg(feature = "test-support")]
static FORFEITS: std::sync::Mutex<std::collections::BTreeSet<String>> =
	std::sync::Mutex::new(std::collections::BTreeSet::new());

/// Note that the view reached its forfeit of the result under `operation`.
#[cfg(feature = "test-support")]
pub(super) fn reach_forfeit(operation: &str) {
	FORFEITS
		.lock()
		.unwrap_or_else(std::sync::PoisonError::into_inner)
		.insert(operation.into());
}

#[cfg(not(feature = "test-support"))]
pub(super) fn reach_forfeit(_operation: &str) {}

/// Test-only: whether the view reached its forfeit of the result under
/// `operation`, in this process.
#[cfg(feature = "test-support")]
pub fn forfeit_reached(operation: &str) -> bool {
	FORFEITS
		.lock()
		.unwrap_or_else(std::sync::PoisonError::into_inner)
		.contains(operation)
}

/// The meetings a test arranged, by operation. Global because the keeper that
/// waits is reached through the view with no handle to the test.
#[cfg(feature = "test-support")]
static MEETINGS: std::sync::Mutex<std::collections::BTreeMap<String, std::sync::Arc<tokio::sync::Barrier>>> =
	std::sync::Mutex::new(std::collections::BTreeMap::new());

/// Test-only: the next `callers` keepers of an introduced route under `operation` wait for each
/// other after reading their command's result and before keeping it, so a
/// process test holds two callers of one operation both past their first look
/// at whether it was adopted, then lets one of them adopt before the other
/// goes on. A build without the feature never waits.
#[cfg(feature = "test-support")]
pub fn meet_before_keeping_direct(operation: &str, callers: usize) -> impl FnOnce() + '_ {
	MEETINGS
		.lock()
		.unwrap_or_else(std::sync::PoisonError::into_inner)
		.insert(
			operation.into(),
			std::sync::Arc::new(tokio::sync::Barrier::new(callers)),
		);
	move || {
		assert!(
			!MEETINGS
				.lock()
				.unwrap_or_else(std::sync::PoisonError::into_inner)
				.contains_key(operation),
			"the keepers never met for {operation}"
		)
	}
}

/// The follower of a test's meeting goes on only once the other caller of
/// its operation has adopted it, and fails if that does not happen in ten
/// seconds, so a broken meeting fails the test instead of falling through.
/// Without a meeting or the feature it does nothing.
#[cfg(feature = "test-support")]
pub(super) async fn meet<F, Fut>(operation: &str, adopted: F) -> Result<(), Error>
where
	F: Fn() -> Fut,
	Fut: std::future::Future<Output = Result<bool, ClientError>>,
{
	let meeting = MEETINGS
		.lock()
		.unwrap_or_else(std::sync::PoisonError::into_inner)
		.get(operation)
		.cloned();
	if let Some(meeting) = meeting {
		if meeting.wait().await.is_leader() {
			MEETINGS
				.lock()
				.unwrap_or_else(std::sync::PoisonError::into_inner)
				.remove(operation);
			return Ok(());
		}
		for _ in 0..500 {
			if adopted().await.map_err(Error::Peer)? {
				return Ok(());
			}
			tokio::time::sleep(std::time::Duration::from_millis(20)).await;
		}
		return Err(Error::Input("the meeting's other caller never adopted the open".into()));
	}
	Ok(())
}

#[cfg(not(feature = "test-support"))]
pub(super) async fn meet<F, Fut>(_operation: &str, _adopted: F) -> Result<(), Error>
where
	F: Fn() -> Fut,
	Fut: std::future::Future<Output = Result<bool, ClientError>>,
{
	Ok(())
}
