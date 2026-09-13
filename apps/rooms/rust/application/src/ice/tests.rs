use super::*;
use serde_json::json;

const LIMITS: Limits = Limits {
	servers: 2,
	urls: 2,
	url_bytes: 64,
	credential_bytes: 8,
};

#[test]
fn defaults_and_explicit_absence_preserve_operator_choice() {
	assert_eq!(
		serde_json::to_value(Servers::stun(None, LIMITS).unwrap()).unwrap(),
		json!([{"urls":"stun:stun.cloudflare.com:3478"}])
	);
	assert_eq!(
		serde_json::to_value(Servers::stun(Some(""), LIMITS).unwrap()).unwrap(),
		json!([])
	);
	assert_eq!(
		serde_json::to_value(Servers::stun(Some(" stun:first, stuns:second "), LIMITS).unwrap()).unwrap(),
		json!([{"urls":"stun:first"},{"urls":"stuns:second"}])
	);
}

#[test]
fn turn_credentials_are_bounded_bytes_and_unrecognized_data_is_refused() {
	let exact = json!([{"urls":["turn:relay","turns:relay"],"username":"user","credential":"éééé"}]);
	assert_eq!(
		serde_json::to_value(Servers::parse(&exact, LIMITS).unwrap()).unwrap(),
		exact
	);
	for malformed in [
		json!({"urls":"stun:relay"}),
		json!([{"urls":"https://relay"}]),
		json!([{"urls":[]}]),
		json!([{"urls":["stun:a","stun:b","stun:c"]}]),
		json!([{"urls":"stun:a"},{"urls":"stun:b"},{"urls":"stun:c"}]),
		json!([{"urls":"stun:a","credential":"secret"}]),
		json!([{"urls":"turn:a","username":"user"}]),
		json!([{"urls":"turn:a","credential":"secret"}]),
		json!([{"urls":"turn:a","username":"user","credential":"ééééé"}]),
		json!([{"urls":"stun:a","extra":true}]),
		json!([{"urls":alloc::format!("stun:{}", "é".repeat(30))}]),
	] {
		assert!(Servers::parse(&malformed, LIMITS).is_err(), "accepted {malformed}");
		assert!(Servers::from_json(&serde_json::to_vec(&malformed).unwrap(), LIMITS).is_err());
	}
}

#[test]
fn network_decoder_preserves_shape_and_refuses_ambiguous_records() {
	let input = br#"[{"urls":" stun:chosen "},{"urls":["turn:relay"],"username":"u","credential":"p"}]"#;
	assert_eq!(
		serde_json::to_value(Servers::from_json(input, LIMITS).unwrap()).unwrap(),
		json!([{"urls":"stun:chosen"},{"urls":["turn:relay"],"username":"u","credential":"p"}])
	);
	for input in [
		br#"[{"urls":"stun:a","urls":"stun:b"}]"#.as_slice(),
		br#"[{"urls":"turn:a","username":"u","credential":"p","credential":"q"}]"#,
		br#"[{"urls":"stun:a","credential":null}]"#,
		br#"[] []"#,
		br#"[{"urls":"stun:a"},{"urls":"stun:b"},{}]"#,
	] {
		assert!(Servers::from_json(input, LIMITS).is_err());
	}
}

#[test]
fn issued_rows_cannot_replace_stun_or_overflow_the_combined_budget() {
	let stun = Servers::stun(Some("stun:chosen"), LIMITS).unwrap();
	let issue = |value| Servers::parse(&value, LIMITS).unwrap();
	assert!(stun.with_turn(issue(json!([{"urls":"stun:issuer"}])), LIMITS).is_err());
	assert!(
		stun.with_turn(
			issue(json!([
				{"urls":"turn:a","username":"u","credential":"p"},
				{"urls":"turn:b","username":"u","credential":"p"}
			])),
			LIMITS
		)
		.is_err()
	);
	let merged = stun
		.with_turn(
			issue(json!([
				{"urls":["stun:issuer","turn:issuer"],"username":"u","credential":"p"}
			])),
			LIMITS,
		)
		.unwrap();
	assert_eq!(
		serde_json::to_value(merged).unwrap(),
		json!([
			{"urls":"stun:chosen"},
			{"urls":["turn:issuer"],"username":"u","credential":"p"}
		])
	);
}
