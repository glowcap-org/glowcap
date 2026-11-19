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
pub async fn rooms_browser_ice_contract(elsewhere: String) -> js_sys::Array {
	super::install_panic_hook();
	tokio::task::LocalSet::new()
		.run_until(async {
			// A page served elsewhere reads its Rooms server's ICE across origins.
			let across = Source::new(&elsewhere);
			assert_eq!(credential(&across.configuration().await.unwrap()), "elsewhere");
			across.close().await.unwrap();
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
			// A page with no Rooms server holds the default STUN policy and fetches nothing.
			let fixed = Source::stun_default().unwrap();
			let urls: js_sys::Array =
				js_sys::Reflect::get(&records(&fixed.configuration().await.unwrap()).get(0), &"urls".into())
					.unwrap()
					.unchecked_into();
			assert!(urls.get(0).as_string().unwrap().starts_with("stun:"));
			// Fixed ICE is synchronous. This poll reaches the pending browser
			// certificate generation before the source closes.
			let pending = fixed.configuration();
			tokio::pin!(pending);
			tokio::select! { biased;
				_ = &mut pending => panic!("certificate generation completed synchronously"),
				() = std::future::ready(()) => {},
			}
			let close = fixed.close();
			tokio::pin!(close);
			tokio::select! { biased;
				_ = &mut close => panic!("close returned before the native certificate promise settled"),
				() = std::future::ready(()) => {},
			}
			assert_eq!(pending.await.unwrap_err(), Error::Closed);
			close.await.unwrap();
			assert_eq!(fixed.configuration().await.unwrap_err(), Error::Closed);
			for url in ["/ice/invalid", "/ice/oversize", "/ice/oversize-stream"] {
				let source = Source::new(url);
				assert!(matches!(source.configuration().await, Err(Error::Invalid(_))));
				source.close().await.unwrap();
			}
			js_sys::Array::of2(&first, &concurrent)
		})
		.await
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

/// The JS fixture holds certificate promises without starting native work.
#[wasm_bindgen]
pub async fn rooms_browser_certificate_capacity(settle: js_sys::Function) {
	super::install_panic_hook();
	let source = Source::stun_default().unwrap();
	for _ in 1..rooms_application::signaling::MAX_EXCHANGES {
		tokio::select! { biased;
			_ = source.configuration() => panic!("held certificate generation completed"),
			() = std::future::ready(()) => {},
		}
	}
	let observed = source.configuration();
	tokio::pin!(observed);
	tokio::select! { biased;
		_ = &mut observed => panic!("held certificate generation completed"),
		() = std::future::ready(()) => {},
	}
	tokio::select! { biased;
		result = source.configuration() => assert_eq!(result.unwrap_err(), Error::Busy),
		() = std::future::ready(()) => panic!("cancelled observers released unsettled certificate capacity"),
	}
	settle.call0(&JsValue::UNDEFINED).unwrap();
	assert!(matches!(observed.await, Err(Error::Certificate(reason)) if reason.contains("fixture certificate refusal")));
	source.configuration().await.unwrap();
	source.close().await.unwrap();
}
