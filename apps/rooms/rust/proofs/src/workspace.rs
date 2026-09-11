use rooms_application::{session::checkpoint::Routes, workspace::Workspace};

struct CapturedRoutes;
impl Routes for CapturedRoutes {
	fn locator_authority(&self, locator: &str) -> Option<String> {
		match locator {
			"ocapn://directory.id" | "ocapn://other.id" => Some(locator.into()),
			_ => None,
		}
	}
	fn sturdyref_authority(&self, link: &str) -> Option<String> {
		let (peer, swiss) = link.split_once("/s/")?;
		if swiss.is_empty() {
			return None;
		}
		match peer {
			"ocapn://directory.id" => Some(peer.into()),
			"ocapn://session.iroh" => Some("ocapn://session.id".into()),
			"ocapn://archive.iroh" => Some("ocapn://archive.id".into()),
			_ => None,
		}
	}
}

pub fn run() {
	let rows: serde_json::Value = serde_json::from_str(include_str!("../fixtures/workspaces.json")).unwrap();
	for row in rows.as_array().unwrap() {
		let parsed = Workspace::decode(row["raw"].as_str().unwrap(), &CapturedRoutes);
		assert_eq!(
			parsed.is_ok(),
			!row["normalized"].is_null(),
			"{}: {:?}",
			row["name"],
			parsed.as_ref().err()
		);
		if let Ok(parsed) = parsed {
			// Compare canonical JSON strings: serde_json::Value cannot preserve
			// the isolated UTF-16 surrogates present in saved user text.
			assert_eq!(
				parsed.encode().unwrap(),
				row["normalized"].as_str().unwrap(),
				"{}",
				row["name"]
			);
		}
	}
}

#[test]
fn workspace_contract() {
	run();
}
