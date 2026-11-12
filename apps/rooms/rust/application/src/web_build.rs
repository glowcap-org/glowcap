//! The name of one browser bundle build. `rooms-web` stamps it on the page and
//! answers it at `/ui-version`, and a static export writes it to `ui-version`,
//! so a running page can tell its own build from the one being served.
//!
//! A name is a 12-digit lowercase hex digest, either after `source-` (a build
//! named by its sources) or alone with an optional `-dirty` suffix.

/// What a build named by its sources starts with.
pub const SOURCE_PREFIX: &str = "source-";
/// What a digest from a modified tree ends with.
pub const DIRTY_SUFFIX: &str = "-dirty";
/// How many lowercase hex digits a digest has.
pub const DIGEST_LEN: usize = 12;

/// Whether `value` is a build name, exactly.
pub fn is_name(value: &str) -> bool {
	let digest = match value.strip_prefix(SOURCE_PREFIX) {
		Some(digest) => digest,
		None => value.strip_suffix(DIRTY_SUFFIX).unwrap_or(value),
	};
	digest.len() == DIGEST_LEN && digest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
mod tests {
	use super::is_name;

	#[test]
	fn names_are_exact() {
		for name in ["source-0123456789ab", "0123456789ab", "0123456789ab-dirty"] {
			assert!(is_name(name), "{name}");
		}
		for other in [
			"",
			"source-",
			"source-0123456789ab-dirty",
			"source-0123456789AB",
			"0123456789abc",
			"0123456789a",
			" source-0123456789ab",
			"<!doctype html>",
		] {
			assert!(!is_name(other), "{other}");
		}
	}
}
