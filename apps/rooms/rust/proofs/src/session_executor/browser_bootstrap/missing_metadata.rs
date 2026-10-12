//! The browser harness supplies physical rows with absent metadata.
use super::*;

#[wasm_bindgen::prelude::wasm_bindgen]
pub async fn rooms_session_missing_metadata_contract(populated: bool) {
	tokio::task::LocalSet::new()
		.run_until(async {
			let name = "rooms-session-executor-missing-metadata";
			for bootstrap in [false, true] {
				let result = if bootstrap {
					loam::Store::open_bootstrap(name, [42; 16], &managed::schemas(), Default::default()).await
				} else {
					loam::Store::open(name, [42; 16], true, &managed::schemas(), Default::default()).await
				};
				if populated {
					let error = result.err().expect("surviving rows cannot authorize new metadata");
					assert!(error.to_string().contains("metadata"), "unexpected refusal: {error}");
				} else {
					let mut store = result.expect("an explicitly emptied database may initialize");
					store.close().await.unwrap();
					// Create and bootstrap have different existing-store contracts.
					break;
				}
			}
		})
		.await;
}
