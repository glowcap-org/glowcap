//! Validated grant lineage owns collaborator accounting. Names come only from
//! the admitted Loam call. Command strings cannot choose a bucket. The root and
//! hosted session pools allow several collaborators' ordinary bursts while
//! every delegated subtree retains its own allowance.
use glowcap::{
	Result,
	loam::{self, Call},
};
use rooms_application::{
	admission::{Charge, Class, CleanupReserve, Policy, Profile, Rate, Registry, Settings},
	room::ArgumentView,
	session::{
		checkpoint::commands::{Command, results},
		command::{Effect, Request, Route},
	},
};

const MAX_PATH: usize = 65;
const MAX_CHARGES: usize = (MAX_PATH + 1) * 3;

/// These selectors can forward only through their private admitted
/// continuation. Rechecking authority cannot spend the gesture's quota twice.
pub(super) fn admitted_effect(selector: &str) -> bool {
	matches!(selector, "command" | "sendFiles" | "refileLine" | "submit-bridge")
}

/// Public entry points spend their own allowance once. Private continuations
/// are authorized separately and finish work that was already admitted.
pub(super) fn invocation_class(verb: &str) -> Option<Class> {
	match verb {
		"command" | "sendFiles" | "refileLine" | "submit-bridge" => None,
		"release" | "release-effect" | "forget-bridge" => Some(Class::Cleanup),
		"initialize"
		| "restore-custody"
		| "settle-effect"
		| "settle-history-erasure"
		| "retention-intent"
		| "retire-host-registrations"
		| "retire-room-authority"
		| "record-inbox"
		| "observe-direct-connection"
		| "observe-archive-connection" => None,
		"continue-workspace" => None,
		_ => Some(Class::Read),
	}
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Key {
	Session,
	Grant { name: [u8; 33], root: bool },
}
struct Rates {
	individual: Profile,
	aggregate: Profile,
}
impl Policy<Key> for Rates {
	fn rate(&self, key: Key, class: Class) -> Rate {
		match key {
			Key::Session | Key::Grant { root: true, .. } => self.aggregate.rate(class),
			Key::Grant { root: false, .. } => self.individual.rate(class),
		}
	}
}
pub(super) struct Admission {
	registry: Registry<Key, Rates>,
	cleanup: CleanupReserve,
	used: bool,
}
impl Default for Admission {
	fn default() -> Self {
		Self::new(Settings::defaults(
			rooms_application::admission::SESSION_ROWS,
			rooms_application::admission::POOLED_AGGREGATE_SCALE,
		))
	}
}
impl Admission {
	pub fn new(settings: Settings) -> Self {
		Self {
			cleanup: CleanupReserve::new(settings.aggregate().rate(Class::Cleanup)),
			used: false,
			registry: Registry::new(
				Rates {
					individual: settings.profile(),
					aggregate: settings.aggregate(),
				},
				settings.rows(),
			),
		}
	}
	pub fn is_unused(&self) -> bool {
		!self.used
	}
	pub fn work(&mut self, call: &Call<'_>, class: Class, bytes: Option<usize>, now: u64) -> Result<()> {
		let mut path = [[0; 33]; MAX_PATH];
		let count = call.accounting_path(&mut path)?;
		let bytes = bytes
			.map(u32::try_from)
			.transpose()
			.map_err(|_| loam::refusal("request-too-large: message bytes overflow"))?;
		let work = [(class, 1), (Class::MessageBytes, bytes.unwrap_or(0))];
		self.path_work(&path[..count], &work, now)
	}
	pub fn upload(&mut self, call: &Call<'_>, files: usize, caption: &str, now: u64) -> Result<()> {
		let mut path = [[0; 33]; MAX_PATH];
		let count = call.accounting_path(&mut path)?;
		let bytes =
			u32::try_from(caption.len()).map_err(|_| loam::refusal("request-too-large: caption bytes overflow"))?;
		let files = u32::try_from(files).map_err(|_| loam::refusal("request-too-large: file count overflow"))?;
		self.path_work(
			&path[..count],
			&[
				(Class::Message, 1),
				(Class::MessageBytes, bytes),
				(Class::Upload, files),
			],
			now,
		)
	}
	fn path_work(&mut self, path: &[[u8; 33]], work: &[(Class, u32)], now: u64) -> Result<()> {
		self.used = true;
		let mut charges = [Charge {
			key: Key::Session,
			class: Class::Read,
			amount: 0,
		}; MAX_CHARGES];
		let mut used = 0;
		let mut charge = |key| {
			for &(class, amount) in work {
				if amount == 0 {
					continue;
				}
				charges[used] = Charge { key, class, amount };
				used += 1;
			}
		};
		charge(Key::Session);
		for (index, &name) in path.iter().enumerate() {
			charge(Key::Grant {
				name,
				root: index + 1 == path.len(),
			});
		}
		let result = if work
			.iter()
			.all(|&(class, amount)| amount == 0 || class == Class::Cleanup)
		{
			self.registry.admit_cleanup(&charges[..used], now, &mut self.cleanup)
		} else {
			self.registry.admit(&charges[..used], now)
		};
		result.map_err(|refusal| loam::refusal(refusal.reason_at(rooms_application::admission::Owner::Session)))
	}
	pub fn command<A: ArgumentView>(&mut self, call: &Call<'_>, request: &Request<'_, A>, now: u64) -> Result<()> {
		let class = command_class(request.route()).unwrap_or(Class::Cleanup);
		let bytes = (class == Class::Message).then(|| request.material_bytes());
		self.work(call, class, bytes, now)
	}
}

/// Cleanup and already admitted settlement retain reserved execution. Local
/// draft work spends the query allowance, independently of posts and uploads.
fn command_class(route: Route) -> Option<Class> {
	match route {
		Route::Effect(effect) => match effect {
			Effect::Say | Effect::EditLine | Effect::SetRoomSubject => Some(Class::Message),
			Effect::SetRoomAway => Some(Class::Transient),
			Effect::EnterRoom => Some(Class::Join),
			Effect::DirectReady | Effect::OfferDirectInbox => Some(Class::Signal),
			Effect::OfferRoom
			| Effect::ShareArchiveHistory
			| Effect::OfferDurableArchive
			| Effect::IssueRoomModerator => Some(Class::Create),
			Effect::RetireRoomMembership
			| Effect::WithdrawLine
			| Effect::RevokeIssuedArchiveShare
			| Effect::KickRoomMember
			| Effect::Operator
			| Effect::RevokeManagedRoomAuthority
			| Effect::UnregisterManagedRoom
			| Effect::SetManagedRoomPolicy
			| Effect::Operations => None,
		},
		Route::Result(command) => match command {
			results::Command::OpenManagedRoom | results::Command::EnsureRoomLink | results::Command::LinkRoom => {
				Some(Class::Create)
			}
			results::Command::TakeRoomLink
			| results::Command::TakeRoomModerator
			| results::Command::TakeRoomManager
			| results::Command::RecoverRoomManager => Some(Class::Read),
		},
		Route::Checkpoint(command) => match command {
			Command::JoinRoom | Command::JoinDirectory => Some(Class::Join),
			Command::StartDirect | Command::OpenDirect => Some(Class::Introduction),
			Command::AcceptInvitation | Command::ReceiveRoomLinkInvitation | Command::PublishPeeredRoom => {
				Some(Class::Create)
			}
			Command::SetStanding
			| Command::SetDirectoryStanding
			| Command::SetRoomStanding
			| Command::SetEffectiveStanding => Some(Class::Transient),
			Command::ClearWorkspace
			| Command::LeaveDirectory
			| Command::LeaveConversation
			| Command::CloseDirect
			| Command::RevokePeeredRoom
			| Command::DropRoomModerator
			| Command::DropRoomManager => None,
			Command::SetDraft
			| Command::Select
			| Command::DismissInvitation
			| Command::SetDirectoryNick
			| Command::ChooseDirectoryNickname
			| Command::ReplaceOperationsCapabilities
			| Command::ReplaceOperationsBundle
			| Command::SubmitRoomBridgeForm
			| Command::SetIgnoredNames
			| Command::SetIgnoredName
			| Command::ChooseHistoryRetention
			| Command::ChooseConnection
			| Command::SelectArchive => Some(Class::Read),
		},
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn direct_readiness_does_not_spend_the_opening_pool() {
		let mut admission = Admission::default();
		let path = [[1; 33], [9; 33]];
		for _ in 0..Class::Introduction.default_rate().burst() {
			for route in [
				Route::Checkpoint(Command::StartDirect),
				Route::Effect(Effect::OfferDirectInbox),
				Route::Effect(Effect::DirectReady),
			] {
				admission
					.path_work(&path, &[(command_class(route).unwrap(), 1)], 0)
					.unwrap();
			}
		}
		assert!(admission.path_work(&path, &[(Class::Introduction, 1)], 0).is_err());
	}
	#[test]
	fn delegated_siblings_share_parent_debt_without_spending_other_roots() {
		let mut admission = Admission::default();
		let first = [[1; 33], [2; 33], [9; 33]];
		let sibling = [[3; 33], [2; 33], [9; 33]];
		let independent = [[4; 33], [9; 33]];
		admission
			.path_work(&first, &[(Class::Message, Class::Message.default_rate().burst())], 0)
			.unwrap();
		assert!(admission.path_work(&sibling, &[(Class::Message, 1)], 0).is_err());
		// Failed ancestor preflight did not debit this child's fresh allowance.
		admission
			.path_work(
				&[[3; 33], [9; 33]],
				&[(Class::Message, Class::Message.default_rate().burst())],
				0,
			)
			.unwrap();
		admission
			.path_work(
				&independent,
				&[(Class::Message, Class::Message.default_rate().burst())],
				0,
			)
			.unwrap();
		admission.path_work(&sibling, &[(Class::Message, 1)], 1000).unwrap();
	}
	#[test]
	fn table_pressure_does_not_reset_existing_allowance_or_allow_policy_replacement() {
		let mut admission = Admission::new(Settings::defaults(3, 8));
		admission
			.path_work(
				&[[1; 33], [9; 33]],
				&[(Class::Message, Class::Message.default_rate().burst())],
				0,
			)
			.unwrap();
		assert!(
			admission
				.path_work(&[[2; 33], [9; 33]], &[(Class::Message, 1)], 0)
				.is_err()
		);
		assert!(
			admission
				.path_work(&[[1; 33], [9; 33]], &[(Class::Message, 1)], 0)
				.is_err()
		);
		assert!(!admission.is_unused());
		admission
			.path_work(&[[1; 33], [9; 33]], &[(Class::Read, 1)], 0)
			.unwrap();
	}

	#[test]
	fn cleanup_for_an_absent_grant_survives_full_accounting() {
		let mut admission = Admission::new(Settings::defaults(3, 8));
		admission
			.path_work(
				&[[1; 33], [9; 33]],
				&[(Class::Message, Class::Message.default_rate().burst())],
				0,
			)
			.unwrap();
		assert!(
			admission
				.path_work(&[[2; 33], [9; 33]], &[(Class::Message, 1)], 0)
				.is_err()
		);
		admission
			.path_work(&[[2; 33], [9; 33]], &[(Class::Cleanup, 1)], 0)
			.unwrap();
	}

	#[test]
	fn session_pool_bounds_many_independent_collaborators_and_keeps_cleanup_available() {
		let mut admission = Admission::default();
		for subject in 1..=8 {
			admission
				.path_work(
					&[[subject; 33], [9; 33]],
					&[(Class::Message, Class::Message.default_rate().burst())],
					0,
				)
				.unwrap();
		}
		assert!(
			admission
				.path_work(&[[10; 33], [9; 33]], &[(Class::Message, 1)], 0)
				.is_err()
		);
		admission
			.path_work(&[[10; 33], [9; 33]], &[(Class::Cleanup, 1)], 0)
			.unwrap();
		admission
			.path_work(&[[10; 33], [9; 33]], &[(Class::Message, 1)], 1000)
			.unwrap();
	}
}
