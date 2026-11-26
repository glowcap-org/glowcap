//! Why a workspace is refused, each with its own words.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InvalidIntent {
	/// More than one directory is marked as the home directory.
	Home,
	/// Two rows share one identifier.
	Duplicate,
	/// A conversation or registration names a directory the workspace has no
	/// row for.
	Directory,
	/// The active conversation is not one of the workspace's conversations.
	Active,
	/// The change reaches the session's own custody, which no workspace
	/// change may do.
	Custody,
	/// A replacement opens a direct row for a registration another open row
	/// already reaches.
	DirectOpen,
}
impl core::fmt::Display for InvalidIntent {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Home => "the workspace names more than one home directory",
			Self::Duplicate => "the workspace holds the same identifier twice",
			Self::Directory => "the workspace names a directory it does not hold",
			Self::Active => "the workspace names an active conversation it does not hold",
			Self::Custody => {
				"the change alters what the session holds for itself, such as how long it keeps history, its routes, its operations, or its peerings, which a workspace change may not do"
			}
			Self::DirectOpen => "an open direct conversation already reaches this member",
		})
	}
}

#[cfg(test)]
mod tests {
	use super::InvalidIntent::*;
	use alloc::{collections::BTreeSet, string::ToString};

	#[test]
	fn every_refusal_says_its_own_thing() {
		let all = [Home, Duplicate, Directory, Active, Custody, DirectOpen];
		let texts: BTreeSet<_> = all.iter().map(ToString::to_string).collect();
		assert_eq!(texts.len(), all.len());
	}
}
