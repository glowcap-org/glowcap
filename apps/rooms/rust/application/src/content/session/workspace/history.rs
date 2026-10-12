//! Archive identity survives a direct route reopening, but never a replacement
//! peer registration. It describes history. It restores no capability custody.
use super::{Conversation, Id, InboxSelection};
use sha2::{Digest, Sha256};

/// Hash bounded, length-framed scalar identities into one fixed archive key.
/// The directory scopes the peer's registration namespace. Neither nickname,
/// command identity nor connection identity participates in retained history.
pub fn direct(directory: &str, registration: &str) -> Result<Id, &'static str> {
	if !Id::accepts_utf16(directory.encode_utf16()) || !crate::directory::registration_id_text(registration) {
		return Err("Invalid direct history identity");
	}
	let mut hash = Sha256::new();
	hash.update(b"rooms-direct-history-v1");
	for value in [directory, registration] {
		hash.update((value.len() as u64).to_be_bytes());
		hash.update(value.as_bytes());
	}
	let id = crate::fields::lower_hex(&hash.finalize());
	Id::new(id.into()).ok_or("Invalid direct history identity")
}
fn selected(id: &Id, directory: &Id, introduction: Option<&super::Introduction>) -> Id {
	match introduction {
		Some(introduction) =>
		{
			#[expect(
				clippy::expect_used,
				reason = "an introduction's directory and registration ids are admitted as lowercase hex, so they are scalar text and `direct` accepts them"
			)]
			direct(
				directory.text().as_str().expect("scalar directory identity"),
				introduction
					.registration
					.text()
					.as_str()
					.expect("scalar registration identity"),
			)
			.expect("validated introduction")
		}
		// A directly handed occurrence has no directory registration witness.
		// Its own canonical identity is the only history namespace it owns.
		None => id.clone(),
	}
}
impl Conversation {
	pub fn history_id(&self) -> Id {
		match self {
			Self::Room(row) => row.id.clone(),
			Self::Direct(row) => row.history_id(),
		}
	}
}
impl super::Direct {
	pub fn history_id(&self) -> Id {
		selected(&self.id, &self.directory, self.introduction.as_ref())
	}
}
impl InboxSelection {
	pub fn history_id(&self) -> Option<Id> {
		match self {
			Self::Room { id, .. } => Some(id.clone()),
			Self::Direct {
				id,
				directory,
				introduction,
				..
			} => Some(selected(id, directory, introduction.as_ref())),
			Self::Directory { .. } => None,
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn direct_history_is_scoped_to_the_exact_peer_registration() {
		let registration = "01234567-89ab-4cde-8fab-0123456789ab";
		let original = direct("directory", registration).unwrap();
		assert_eq!(original, direct("directory", registration).unwrap());
		assert_ne!(original, direct("other-directory", registration).unwrap());
		assert_ne!(
			original,
			direct("directory", "abcdef01-2345-4789-abcd-ef0123456789").unwrap()
		);
		assert!(direct("directory", "nickname").is_err());
		assert_eq!(original.text().as_str().unwrap().len(), 64);
	}
}
