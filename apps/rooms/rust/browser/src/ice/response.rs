//! Bounded decoding of an ICE endpoint's HTTP response. Request policy,
//! cancellation, and attempt lifetime belong to the caller.
use super::{Error, LIMITS};
use js_sys::{Reflect, Uint8Array, futures::JsFuture};
use rooms_application::ice::Servers;
use wasm_bindgen::JsCast;
use web_sys::{ReadableStreamDefaultReader, Response};

// Enough for every admitted field in fully JSON-escaped form plus record
// punctuation. Whitespace does not grant an unbounded response envelope.
const MAX_BODY_BYTES: usize =
	LIMITS.servers * (LIMITS.urls * (6 * LIMITS.url_bytes + 3) + 12 * LIMITS.credential_bytes + 128) + 2;

struct BodyReader(ReadableStreamDefaultReader);
impl Drop for BodyReader {
	fn drop(&mut self) {
		self.0.release_lock();
	}
}
pub(super) async fn read(response: Response) -> Result<Servers, Error> {
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
	if length.is_some_and(|length| length > MAX_BODY_BYTES) {
		return Err(Error::Invalid("ICE response exceeds its byte limit"));
	}
	let body = response.body().ok_or(Error::Invalid("ICE response has no body"))?;
	let reader = BodyReader(
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
		if length > MAX_BODY_BYTES - bytes.len() {
			return Err(Error::Invalid("ICE response exceeds its byte limit"));
		}
		let offset = bytes.len();
		bytes.resize(offset + length, 0);
		chunk.copy_to(&mut bytes[offset..]);
	}
	Servers::from_json(&bytes, LIMITS).map_err(Error::Invalid)
}
