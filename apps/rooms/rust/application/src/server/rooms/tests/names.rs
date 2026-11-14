//! What a room may be named. One function answers every verb that takes a
//! new name, so its refusals are the ones a person reads.
use super::*;

#[test]
fn a_room_name_is_refused_empty_too_long_or_with_hidden_characters() {
	let reason = |name: &str| room_name_refusal(name).map(|refusal| refusal.reason());
	assert_eq!(reason("Salon"), None);
	assert_eq!(reason(""), Some("a room name may not be empty".into()));
	assert_eq!(reason(&"a".repeat(MAX_ROOM)), None);
	assert_eq!(
		reason(&"a".repeat(MAX_ROOM + 1)),
		Some(format!(
			"room-too-long: a room name may be at most {MAX_ROOM} characters"
		))
	);
	// Length counts UTF-16 units, as the page's own count does.
	assert_eq!(reason(&"\u{1f331}".repeat(MAX_ROOM / 2)), None);
	assert!(reason(&"\u{1f331}".repeat(MAX_ROOM / 2 + 1)).is_some());
	for hidden in ["bell\u{7}room", "flipped\u{202e}name", "arabic\u{61c}mark"] {
		assert_eq!(
			reason(hidden),
			Some("a room name may not contain control or text-direction characters".into()),
			"{hidden:?}"
		);
	}
}
