use super::*;
use js_sys::{Promise, Reflect, Uint8Array, futures::JsFuture};
use wasm_bindgen::{JsCast, prelude::wasm_bindgen};
use web_sys::{
	AbortController, ReadableStreamDefaultReader, RequestCache, RequestCredentials, RequestInit, RequestMode,
	RequestRedirect, Response,
};

// Enough for every admitted field in fully JSON-escaped form plus record
// punctuation. Whitespace does not grant an unbounded response envelope.
const MAX_BYTES: usize =
	LIMITS.servers * (LIMITS.urls * (6 * LIMITS.url_bytes + 3) + 12 * LIMITS.credential_bytes + 128) + 2;

#[wasm_bindgen]
extern "C" {
	#[wasm_bindgen(catch, js_name = fetch)]
	fn fetch(input: &str, options: &RequestInit) -> Result<Promise, wasm_bindgen::JsValue>;
}
struct Reader(ReadableStreamDefaultReader);
impl Drop for Reader {
	fn drop(&mut self) {
		self.0.release_lock();
	}
}
pub(super) async fn read(url: &str, abort: &AbortController) -> Result<Servers, Error> {
	let options = RequestInit::new();
	options.set_signal(Some(&abort.signal()));
	options.set_mode(RequestMode::SameOrigin);
	options.set_credentials(RequestCredentials::SameOrigin);
	options.set_redirect(RequestRedirect::Error);
	options.set_cache(RequestCache::NoStore);
	let response = JsFuture::from(fetch(url, &options).map_err(|_| Error::Platform("starting ICE fetch failed"))?)
		.await
		.map_err(|_| Error::Platform("ICE fetch failed"))?
		.dyn_into::<Response>()
		.map_err(|_| Error::Platform("ICE fetch returned no response"))?;
	if !response.ok() {
		return Err(Error::Http(response.status()));
	}
	let length = response
		.headers()
		.get("content-length")
		.map_err(|_| Error::Invalid("invalid ICE response headers"))?
		.map(|value| {
			value
				.parse::<usize>()
				.map_err(|_| Error::Invalid("invalid ICE content length"))
		})
		.transpose()?;
	if length.is_some_and(|length| length > MAX_BYTES) {
		return Err(Error::Invalid("ICE response exceeds its byte limit"));
	}
	let body = response.body().ok_or(Error::Invalid("ICE response has no body"))?;
	let reader = Reader(
		body.get_reader()
			.dyn_into::<ReadableStreamDefaultReader>()
			.map_err(|_| Error::Platform("ICE body reader is unavailable"))?,
	);
	let mut bytes = Vec::with_capacity(length.unwrap_or(0));
	loop {
		let result = JsFuture::from(reader.0.read())
			.await
			.map_err(|_| Error::Platform("reading ICE response failed"))?;
		let done = Reflect::get(&result, &"done".into())
			.ok()
			.and_then(|value| value.as_bool())
			.ok_or(Error::Platform("invalid ICE body read result"))?;
		if done {
			break;
		}
		let chunk = Reflect::get(&result, &"value".into())
			.map_err(|_| Error::Platform("ICE body has no bytes"))?
			.dyn_into::<Uint8Array>()
			.map_err(|_| Error::Platform("ICE body is not bytes"))?;
		let length = chunk.length() as usize;
		if length > MAX_BYTES - bytes.len() {
			return Err(Error::Invalid("ICE response exceeds its byte limit"));
		}
		let offset = bytes.len();
		bytes.resize(offset + length, 0);
		chunk.copy_to(&mut bytes[offset..]);
	}
	Servers::from_json(&bytes, LIMITS).map_err(Error::Invalid)
}
