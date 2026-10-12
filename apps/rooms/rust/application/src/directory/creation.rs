//! Room-creation verbs and caller-held retry keys.
use super::Error;
use crate::fields::lower_hex;
use crate::room::{attachment::AttachmentArgument, authority::Reply};
use alloc::string::String;

/// Exact temporary capabilities returned by managed creation. The bootstrap
/// issues the durable room and manager publications through its own authority.
pub struct Bootstrap<C> {
	pub room: C,
	pub bootstrap: C,
}
pub fn read_bootstrap<A: AttachmentArgument>(args: &[A]) -> Result<Bootstrap<A::Capability>, Error> {
	let [room, bootstrap] = args else {
		return Err(Error::Bootstrap);
	};
	Ok(Bootstrap {
		room: room.capability().ok_or(Error::Bootstrap)?.clone(),
		bootstrap: bootstrap.capability().ok_or(Error::Bootstrap)?.clone(),
	})
}

/// Borrow the exact publications supplied by the held bootstrap. Callers
/// validate and acquire these URIs through their existing CapTP owner.
pub fn authorities(reply: &impl Reply) -> Result<[&str; 2], Error> {
	if reply.list_len() != Some(2) {
		return Err(Error::Authorities);
	}
	let field = |index| {
		reply
			.list_text(index)
			.filter(|text| !text.is_empty())
			.ok_or(Error::Authorities)
	};
	Ok([field(0)?, field(1)?])
}

pub use crate::protocol_data::{
	ADVERTISED_LOCATION as LOCATION, ENTER, ENTER_PUBLICATION, LINK, LINK_PUBLICATION, OPEN, OPEN_MANAGED,
	OPEN_PRIVATE_LINK as PRIVATE_LINK, ROOM_AUTHORITIES as AUTHORITIES, SUBSCRIBE_PUBLICATION,
};

/// A caller-held recovery key must survive an uncertain creation result.
/// Reusing it retries that creation. Generating a new one requests a new room.
pub struct RecoveryKey(String);
impl RecoveryKey {
	pub fn accepts(value: &str) -> bool {
		value.len() == 33
			&& value.starts_with('~')
			&& value.as_bytes()[1..]
				.iter()
				.all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f'))
	}
	pub fn parse(value: String) -> Result<Self, Error> {
		if Self::accepts(&value) {
			Ok(Self(value))
		} else {
			Err(Error::RecoveryKey)
		}
	}
	/// A fresh key from caller-supplied entropy, in the one form `accepts`.
	pub fn from_entropy(entropy: [u8; 16]) -> Self {
		let mut key = alloc::string::String::with_capacity(33);
		key.push('~');
		key.push_str(&lower_hex(&entropy));
		Self(key)
	}
	pub fn as_str(&self) -> &str {
		&self.0
	}
}
