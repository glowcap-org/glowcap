//! HTTP reads from the selected Rooms server. The browser sends credentials
//! on that server's own page. An independently hosted page reads anonymously.
use js_sys::{JsString, Promise, futures::JsFuture};
use serde::Serialize;
use wasm_bindgen::{JsCast, prelude::*};
use web_sys::{
	AbortSignal, RequestCache, RequestCredentials, RequestInit, RequestMode, RequestRedirect, Response, Url,
};

const LOCATOR_TIMEOUT_MS: u32 = 5_000;

#[wasm_bindgen]
extern "C" {
	#[wasm_bindgen(catch, js_name = fetch)]
	fn fetch(input: &str, options: &RequestInit) -> Result<Promise, JsValue>;
}

pub(crate) async fn get(address: &str, signal: &AbortSignal) -> Result<Response, JsValue> {
	let options = RequestInit::new();
	options.set_signal(Some(signal));
	options.set_mode(RequestMode::Cors);
	options.set_credentials(RequestCredentials::SameOrigin);
	options.set_redirect(RequestRedirect::Error);
	options.set_cache(RequestCache::NoStore);
	JsFuture::from(fetch(address, &options)?).await?.dyn_into::<Response>()
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum LocatorReply {
	Answers { directory: String },
	Elsewhere,
	Unavailable,
	TimedOut,
}

/// One request for the locator, shared by Settings and startup. Fetch hides
/// the cause of some failures, including CORS and redirects to sign-in.
#[wasm_bindgen(js_name = locateRoomsServer)]
pub async fn locate(base: &str) -> Result<String, JsValue> {
	let address = Url::new_with_base("locator", base)?;
	let signal = AbortSignal::timeout_with_u32(LOCATOR_TIMEOUT_MS);
	let reply = match locator_reply(&address.href(), &signal).await {
		Ok(reply) => reply,
		Err(_failure) if signal.aborted() => LocatorReply::TimedOut,
		Err(_failure) => LocatorReply::Unavailable,
	};
	serde_json::to_string(&reply).map_err(|error| js_sys::Error::new(&error.to_string()).into())
}

async fn locator_reply(address: &str, signal: &AbortSignal) -> Result<LocatorReply, JsValue> {
	let response = get(address, signal).await?;
	if !response.ok() {
		if let Some(body) = response.body() {
			JsFuture::from(body.cancel()).await?;
		}
		return Ok(match response.status() {
			401 | 403 => LocatorReply::Unavailable,
			_ => LocatorReply::Elsewhere,
		});
	}
	let body = JsFuture::from(response.text()?).await?.dyn_into::<JsString>()?;
	let Some(text) = crate::js_text::address_text(body) else {
		return Ok(LocatorReply::Elsewhere);
	};
	let directory = text.trim();
	if rooms_glowcap::routes::Address::directory(directory).is_ok_and(|address| address.is_some()) {
		Ok(LocatorReply::Answers {
			directory: directory.to_owned(),
		})
	} else {
		Ok(LocatorReply::Elsewhere)
	}
}

#[wasm_bindgen(js_name = readRoomsLinkPreview)]
pub async fn read_link_preview(
	base: &str,
	target: &str,
	refresh: bool,
	signal: AbortSignal,
) -> Result<Response, JsValue> {
	let address = Url::new_with_base("link-preview", base)?;
	let query = address.search_params();
	query.set("url", target);
	if refresh {
		query.set("refresh", "1");
	}
	get(&address.href(), &signal).await
}
