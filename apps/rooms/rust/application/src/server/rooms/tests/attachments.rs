//! What a room answers a member whose file it will not take.
use super::*;
use crate::files::{MAX_FILE_BYTES, NAME_CHARACTERS};

#[test]
fn a_refused_file_is_told_which_rule_refused_it() {
	let asked = |name: &str, size: u64| {
		let args = [
			Value::Text(name.into()),
			Value::Text("image/jpeg".into()),
			Value::Integer(size),
		];
		wire::attachment(args.len(), |at| args.get(at).cloned()).map_err(|refusal| refusal.reason())
	};
	assert_eq!(asked("photo.jpg", 12).unwrap().name(), "photo.jpg");
	let code = FailureCode::AttachmentRefused.wire();
	// A direction override draws this name as `photoexe.jpg`.
	assert_eq!(
		asked("photo\u{202e}gpj.exe", 12),
		Err(format!("{code}: {NAME_CHARACTERS}"))
	);
	assert_eq!(
		asked("photo.jpg", MAX_FILE_BYTES as u64 + 1),
		Err(format!("{code}: file exceeds the room attachment limit"))
	);
	assert_eq!(
		asked("", 12),
		Err(format!("{code}: room attachment description is invalid"))
	);
}
