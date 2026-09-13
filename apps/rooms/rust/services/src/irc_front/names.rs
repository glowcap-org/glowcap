//! One IRC nickname reservation per connection, acquired before an asynchronous
//! Rooms registration and released only when that connection's owner retires.
use rooms_application::server::irc::{front, protocol::fold};
use std::{cell::RefCell, collections::BTreeSet, rc::Rc};
#[derive(Clone, Default)]
pub(super) struct Names(Rc<RefCell<BTreeSet<String>>>);
pub(super) struct Lease {
	names: Names,
	key: String,
}
impl Names {
	pub fn claim(&self, nick: &str) -> Result<Lease, String> {
		let key = fold(nick);
		let mut names = self.0.borrow_mut();
		if names.len() >= front::CLIENTS {
			return Err("IRC nickname reservation limit is full".into());
		}
		if !names.insert(key.clone()) {
			return Err("That IRC nickname is already in use".into());
		}
		Ok(Lease {
			names: self.clone(),
			key,
		})
	}
}
impl Drop for Lease {
	fn drop(&mut self) {
		self.names.0.borrow_mut().remove(&self.key);
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn nickname_leases_bound_active_users_and_retire_churn() {
		let names = Names::default();
		for index in 0..front::CLIENTS * 3 {
			drop(names.claim(&format!("nick-{index}")).unwrap());
		}
		let mut live = Vec::new();
		for index in 0..front::CLIENTS {
			live.push(names.claim(&format!("nick-{index}")).unwrap());
		}
		assert!(names.claim("overflow").is_err());
		live.pop();
		let brackets = names.claim("[bob]").unwrap();
		assert!(names.claim("{BOB}").is_err());
		drop(brackets);
		assert!(names.claim("{BOB}").is_ok());
	}
}
