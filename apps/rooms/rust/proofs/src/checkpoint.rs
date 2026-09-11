use rooms_application::{
	grants::Access,
	session::checkpoint::{Checkpoint, Routes, MAX_CHECKPOINT_UNITS},
};

struct CapturedRoutes<'a>(&'a serde_json::Value);
impl Routes for CapturedRoutes<'_> {
	fn locator_authority(&self, locator: &str) -> Option<String> {
		self.0["locatorAuthorities"][locator].as_str().map(str::to_owned)
	}
	fn sturdyref_authority(&self, link: &str) -> Option<String> {
		self.0["sturdyrefAuthorities"][link].as_str().map(str::to_owned)
	}
}
fn fixtures() -> serde_json::Value {
	serde_json::from_str(include_str!("../fixtures/checkpoints.json")).unwrap()
}
fn check(rows: &serde_json::Value, routes: &impl Routes) {
	let empty = Checkpoint::empty().encode_for(Access::Admin).unwrap();
	for row in rows.as_array().unwrap() {
		let result = Checkpoint::decode(row["raw"].as_str().unwrap(), routes);
		assert_eq!(
			result.is_ok(),
			row["accepted"].as_bool().unwrap(),
			"{}: {:?}",
			row["name"],
			result.as_ref().err()
		);
		if let Ok(checkpoint) = result {
			assert_eq!(
				checkpoint.adoption_material().unwrap().as_str().unwrap(),
				format!("[\"adoptWorkspace\",{}]", row["admin"].as_str().unwrap())
			);
			assert!(checkpoint.retained_bytes() >= core::mem::size_of::<Checkpoint>());
			assert_eq!(
				checkpoint.encode_for(Access::Admin).unwrap(),
				row["admin"].as_str().unwrap(),
				"{} admin",
				row["name"]
			);
			for access in [Access::Observe, Access::Interact] {
				assert_eq!(
					checkpoint.encode_for(access).unwrap(),
					row["observe"].as_str().unwrap(),
					"{} observing",
					row["name"]
				);
			}
			assert_eq!(checkpoint.encode_for(Access::None).unwrap(), empty);
			assert_eq!(
				checkpoint.encode_for(Access::Admin).unwrap(),
				row["admin"].as_str().unwrap(),
				"projection mutated its owner"
			);
		}
	}
}
pub fn run() {
	let fixture = fixtures();
	check(&fixture["rows"], &CapturedRoutes(&fixture));
	assert!(Checkpoint::decode(&" ".repeat(MAX_CHECKPOINT_UNITS + 1), &CapturedRoutes(&fixture)).is_err());
	let routes = CapturedRoutes(&fixture);
	let empty = Checkpoint::empty().encode_for(Access::Admin).unwrap();
	let mut state: serde_json::Value = serde_json::from_str(&empty).unwrap();
	state["ignored"] = serde_json::json!(vec!["peer"; 512]);
	assert!(Checkpoint::decode(&state.to_string(), &routes).is_ok());
	state["ignored"].as_array_mut().unwrap().push("peer".into());
	assert!(Checkpoint::decode(&state.to_string(), &routes).is_err());
	state["ignored"] = serde_json::json!([]);
	// A surrogate must not force every ordinary character in these fields to
	// expand to six-byte escapes and make the owner's own export unreadable.
	let prefix = "a".repeat(65535);
	state["standing"] = prefix.clone().into();
	state["join"]["room"] = prefix.clone().into();
	let raw = state
		.to_string()
		.replace(&format!("\"{prefix}\""), &format!("\"{prefix}\\ud800\""));
	let checkpoint = Checkpoint::decode(&raw, &routes).unwrap();
	let encoded = checkpoint.encode_for(Access::Admin).unwrap();
	assert!(encoded.encode_utf16().count() <= MAX_CHECKPOINT_UNITS);
	assert_eq!(
		Checkpoint::decode(&encoded, &routes)
			.unwrap()
			.encode_for(Access::Admin)
			.unwrap(),
		encoded
	);
}

#[cfg(all(test, not(target_arch = "wasm32")))]
#[test]
fn native_checkpoint_uses_the_existing_locator_grammar() {
	let fixture = fixtures();
	let routes = rooms_glowcap::routes::CheckpointRoutes;
	for (input, expected) in fixture["locatorAuthorities"].as_object().unwrap() {
		assert_eq!(
			routes.locator_authority(input).as_deref(),
			expected.as_str(),
			"locator {input}"
		);
	}
	for (input, expected) in fixture["sturdyrefAuthorities"].as_object().unwrap() {
		assert_eq!(
			routes.sturdyref_authority(input).as_deref(),
			expected.as_str(),
			"sturdyref {input}"
		);
	}
	check(&fixture["rows"], &routes);
}
