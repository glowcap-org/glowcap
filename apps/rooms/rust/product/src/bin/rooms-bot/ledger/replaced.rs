//! A replaced line: a reply line this access finished by its echo, because
//! another access holds the session's receipt of it (`serve/access.rs`). The
//! ledger records the line beside the turns until the session says who holds
//! it, and each start asks about every record. The access that holds it keeps
//! or releases the receipt, as it does for a line of its own, and the record
//! is dropped. When nobody holds it any more the record is dropped, and when
//! another still does it stays.
//!
//! Three words keep apart three things. To replace is to swap the session
//! link (`serve/replace.rs`). The old access is the one the swap ends
//! (`engine/settle_old.rs`). A replaced line or open is one another access
//! sent and still holds, so the serving access leaves its receipt alone
//! until a start finds this access holds it again
//! (`engine/deliver/replaced.rs`, `../opens.rs`).
use crate::bot::{
	error::Error,
	rooms::{Base, ConversationId},
	store::Store,
};
use serde::{Deserialize, Serialize};

/// Why the old access of the last replacement could not list the agent's
/// actions it held. Its actions are then neither settled nor recorded, and
/// each can hold one of the session's places until that access is revoked.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Unlisted {
	/// The operator paused it, and the bot leaves a pause as it is.
	Paused,
	/// The session answers that it no longer holds the access, which says
	/// nothing about the receipts it gave back.
	Denied,
}
use std::collections::BTreeSet;

/// The most records the ledger holds. Every record is a receipt another
/// access holds, and the session holds at most [`MAX_EFFECTS`] receipts, so a
/// start that has dropped the records nobody holds never leaves more.
///
/// [`MAX_EFFECTS`]: rooms_application::content::session::custody::MAX_EFFECTS
pub const MAX_REPLACED: usize = rooms_application::content::session::custody::MAX_EFFECTS;

/// What keeping or releasing the receipt of one line takes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Replaced {
	pub operation: String,
	/// The base the line was sent at.
	pub base: Base,
	pub conversation: ConversationId,
	pub text: String,
}

/// The records the ledger keeps of receipts that hold one of the session's
/// places and that no turn of this access will settle.
impl super::Ledger {
	/// The lines this access finished by their echo while another access held
	/// their receipts, oldest first.
	pub fn replaced(&self) -> &[Replaced] {
		&self.replaced
	}

	/// Drop the records of `operations`, which the session says nobody holds
	/// or this access has kept or released. No record there changes nothing.
	pub fn drop_replaced(&mut self, store: &Store, operations: &BTreeSet<String>) -> Result<(), Error> {
		if !self.replaced.iter().any(|line| operations.contains(&line.operation)) {
			return Ok(());
		}
		self.commit(store, |next| {
			next.replaced.retain(|line| !operations.contains(&line.operation));
			Ok(())
		})
	}

	/// How many receipts of lines the session would not take back held one of
	/// its places when the serving access last listed its receipts.
	pub fn left(&self) -> usize {
		self.left.len()
	}

	/// The operations of those lines, oldest first.
	pub fn left_lines(&self) -> &[String] {
		&self.left
	}

	/// Record that the session would not take back the receipt of
	/// `operation`, which still holds one of its places, once. The session
	/// holds at most [`MAX_REPLACED`] receipts, so a record past that names a
	/// receipt it no longer holds and the oldest goes.
	pub fn leave(&mut self, store: &Store, operation: &str) -> Result<(), Error> {
		if self.left.iter().any(|held| held == operation) {
			return Ok(());
		}
		self.commit(store, |next| {
			next.left.push(operation.to_owned());
			if next.left.len() > MAX_REPLACED {
				next.left.remove(0);
			}
			Ok(())
		})
	}

	/// Drop the records of `operations`, receipts the session no longer lists
	/// for the serving access. No record there changes nothing.
	pub fn forget_left(&mut self, store: &Store, operations: &BTreeSet<String>) -> Result<(), Error> {
		if !self.left.iter().any(|operation| operations.contains(operation)) {
			return Ok(());
		}
		self.commit(store, |next| {
			next.left.retain(|operation| !operations.contains(operation));
			Ok(())
		})
	}

	/// The operations of the agent's actions an access this one replaced sent
	/// and could not settle before the replacement, oldest first. Each can
	/// hold one of the session's places until that access is revoked.
	pub fn replaced_actions(&self) -> &[String] {
		&self.replaced_actions
	}

	/// Why the old access of the last replacement could not list its
	/// agent's actions, or none when it listed them or held none.
	pub fn unlisted(&self) -> Option<Unlisted> {
		self.unlisted
	}

	/// Record `operations`, the agent's actions the old access's last list
	/// could not settle, beside any recorded before. A record past
	/// [`MAX_REPLACED`] names a receipt the session no longer holds, so the
	/// oldest goes.
	pub fn replace_actions(&mut self, store: &Store, operations: &[String]) -> Result<(), Error> {
		if operations
			.iter()
			.all(|operation| self.replaced_actions.contains(operation))
		{
			return Ok(());
		}
		self.commit(store, |next| {
			for operation in operations {
				if !next.replaced_actions.contains(operation) {
					next.replaced_actions.push(operation.clone());
				}
			}
			let over = next.replaced_actions.len().saturating_sub(MAX_REPLACED);
			next.replaced_actions.drain(..over);
			Ok(())
		})
	}

	/// Record `unlisted`, why the old access of the replacement whose link was
	/// just stored could not list its agent's actions, in place of the last
	/// replacement's.
	pub fn record_unlisted(&mut self, store: &Store, unlisted: Option<Unlisted>) -> Result<(), Error> {
		if self.unlisted == unlisted {
			return Ok(());
		}
		self.commit(store, |next| {
			next.unlisted = unlisted;
			Ok(())
		})
	}

	/// Drop the records of the replaced actions in `operations`, which the
	/// session says this access holds again or nobody holds.
	pub fn drop_replaced_actions(&mut self, store: &Store, operations: &BTreeSet<String>) -> Result<(), Error> {
		if !self
			.replaced_actions
			.iter()
			.any(|operation| operations.contains(operation))
		{
			return Ok(());
		}
		self.commit(store, |next| {
			next.replaced_actions
				.retain(|operation| !operations.contains(operation));
			Ok(())
		})
	}
}
