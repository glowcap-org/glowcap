//! Real browser Fetch, including a read cancelled while its body is pending.
use rooms_browser::ice::{Error, Source};
use wasm_bindgen::prelude::*;

fn records(config: &web_sys::RtcConfiguration) -> js_sys::Array {
	js_sys::Reflect::get(config, &"iceServers".into())
		.unwrap()
		.unchecked_into()
}
fn credential(config: &web_sys::RtcConfiguration) -> String {
	js_sys::Reflect::get(&records(config).get(0), &"credential".into())
		.unwrap()
		.as_string()
		.unwrap()
}

#[wasm_bindgen]
pub async fn rooms_browser_ice_contract() {
	super::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async {
			let source = Source::new("/ice/rotating");
			let (first, concurrent) = tokio::join!(source.configuration(), source.configuration());
			let (first, concurrent) = (first.unwrap(), concurrent.unwrap());
			assert_eq!(credential(&first), "credential-1");
			assert_eq!(credential(&concurrent), "credential-1");
			// Observers receive independent browser objects, even for one response.
			js_sys::Reflect::set(&records(&first).get(0), &"credential".into(), &"modified".into()).unwrap();
			assert_eq!(credential(&concurrent), "credential-1");
			assert_eq!(credential(&source.configuration().await.unwrap()), "credential-2");
			source.close().await.unwrap();
			assert_eq!(source.configuration().await.unwrap_err(), Error::Closed);
			let retry = Source::new("/ice/retry");
			assert_eq!(retry.configuration().await.unwrap_err(), Error::Http(503));
			assert_eq!(records(&retry.configuration().await.unwrap()).length(), 0);
			retry.close().await.unwrap();
			for url in ["/ice/invalid", "/ice/oversize", "/ice/oversize-stream"] {
				let source = Source::new(url);
				assert!(matches!(source.configuration().await, Err(Error::Invalid(_))));
				source.close().await.unwrap();
			}
		})
		.await;
}

#[wasm_bindgen]
pub async fn rooms_browser_ice_cancel_contract(read_pending: js_sys::Promise) {
	super::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async {
			let source = Source::new("/ice/pending");
			let request = source.configuration();
			let cancel = async {
				js_sys::futures::JsFuture::from(read_pending).await.unwrap();
				source.close().await.unwrap();
			};
			let (result, ()) = tokio::join!(request, cancel);
			assert_eq!(result.unwrap_err(), Error::Closed);
		})
		.await;
}
