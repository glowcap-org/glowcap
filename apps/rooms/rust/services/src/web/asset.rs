//! One served file and the reply it gives: its body, a gzip form when that
//! saves enough to hold, and the entity tag a browser revalidates each form
//! against.
use super::http::Reply;
use bytes::Bytes;
use flate2::{Compression, write::GzEncoder};
use hyper::{
	StatusCode,
	header::{HeaderMap, HeaderValue},
};
use sha2::{Digest, Sha256};
use std::io::Write;

#[derive(Clone)]
pub(super) struct Asset {
	pub body: Bytes,
	pub content_type: &'static str,
	pub etag: HeaderValue,
	pub headers: HeaderMap,
	form: Form,
}
/// What compressing an asset's body decided.
#[derive(Clone)]
enum Form {
	/// Not compressed yet, or its form did not fit the generation's budget.
	Undecided,
	/// The body is served as it is: gzip saves less than a tenth of it.
	Plain,
	Gzip(Gzip),
}
/// An asset's body in gzip. Its entity tag is its own, so a cache never
/// answers one form with the other.
#[derive(Clone)]
struct Gzip {
	body: Bytes,
	etag: HeaderValue,
}
impl Asset {
	pub(super) fn new(body: Bytes, content_type: &'static str) -> Result<Self, String> {
		Ok(Self {
			etag: entity_tag(&body)?,
			body,
			content_type,
			headers: HeaderMap::new(),
			form: Form::Undecided,
		})
	}
	pub fn response<B>(self, request: &hyper::Request<B>) -> Reply {
		let negotiated = matches!(self.form, Form::Gzip(_));
		let (body, etag, gzip) = match self.form {
			Form::Gzip(gzip) if accepts_gzip(request.headers()) => (gzip.body, gzip.etag, true),
			_ => (self.body, self.etag, false),
		};
		let matches = request
			.headers()
			.get("if-none-match")
			.and_then(|h| h.to_str().ok())
			.is_some_and(|header| {
				header
					.split(',')
					.map(str::trim)
					.any(|tag| tag == "*" || etag.to_str().is_ok_and(|etag| tag.trim_prefix("W/") == etag))
			});
		let mut response = super::http::response(
			if matches {
				StatusCode::NOT_MODIFIED
			} else {
				StatusCode::OK
			},
			self.content_type,
			if matches { Bytes::new() } else { body },
		);
		response.headers_mut().extend(self.headers);
		response.headers_mut().insert("etag", etag);
		if negotiated {
			response
				.headers_mut()
				.insert("vary", HeaderValue::from_static("accept-encoding"));
		}
		if gzip && !matches {
			response
				.headers_mut()
				.insert("content-encoding", HeaderValue::from_static("gzip"));
		}
		if request.uri().path() != "/ui-version" {
			response
				.headers_mut()
				.insert("cache-control", HeaderValue::from_static("no-cache"));
		}
		response
	}
	/// Add a gzip form when it saves a tenth of the body and fits in `room`
	/// bytes, and return the bytes it holds. A font or an image is compressed
	/// already: a form a few bytes smaller would cost a second copy here and
	/// an inflate in the browser, so the body is served as it is. When
	/// `earlier` has this body's tag and decided, its decision is shared
	/// rather than compressed again.
	pub(super) fn compress(&mut self, room: usize, earlier: Option<&Asset>) -> Result<usize, String> {
		let decided = earlier
			.filter(|earlier| earlier.etag == self.etag)
			.map(|earlier| &earlier.form);
		let gzip = match decided {
			Some(Form::Plain) => {
				self.form = Form::Plain;
				return Ok(0);
			}
			Some(Form::Gzip(gzip)) => gzip.clone(),
			Some(Form::Undecided) | None => {
				let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
				encoder.write_all(&self.body).map_err(|e| e.to_string())?;
				let body = encoder.finish().map_err(|e| e.to_string())?;
				if body.len() > self.body.len() - self.body.len() / 10 {
					self.form = Form::Plain;
					return Ok(0);
				}
				Gzip {
					etag: entity_tag(&body)?,
					body: body.into(),
				}
			}
		};
		if gzip.body.len() > room {
			return Ok(0);
		}
		let held = gzip.body.len();
		self.form = Form::Gzip(gzip);
		Ok(held)
	}
}
fn entity_tag(body: &[u8]) -> Result<HeaderValue, String> {
	HeaderValue::from_str(&format!(
		"\"{}\"",
		rooms_application::fields::lower_hex(&Sha256::digest(body))
	))
	.map_err(|e| e.to_string())
}
/// Whether a request lists gzip among the codings it accepts. A member with a
/// zero weight refuses the coding it names. A parameter's name is read
/// without regard to case.
fn accepts_gzip(headers: &HeaderMap) -> bool {
	headers
		.get_all("accept-encoding")
		.iter()
		.filter_map(|value| value.to_str().ok())
		.flat_map(|value| value.split(','))
		.any(|member| {
			let mut parts = member.split(';').map(str::trim);
			parts.next().is_some_and(|coding| coding.eq_ignore_ascii_case("gzip"))
				&& !parts.any(|parameter| {
					parameter
						.split_once('=')
						.filter(|(name, _)| name.trim().eq_ignore_ascii_case("q"))
						.and_then(|(_, q)| q.trim().parse::<f32>().ok())
						.is_some_and(|q| q <= 0.0)
				})
		})
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::io::Read;

	fn request(headers: &[(&'static str, &str)]) -> hyper::Request<()> {
		let mut request = hyper::Request::new(());
		for (name, value) in headers {
			request
				.headers_mut()
				.insert(*name, HeaderValue::from_str(value).unwrap());
		}
		request
	}

	fn served(body: &[u8], content_type: &'static str) -> (usize, Asset) {
		let mut asset = Asset::new(Bytes::copy_from_slice(body), content_type).unwrap();
		(asset.compress(usize::MAX, None).unwrap(), asset)
	}

	fn gzip(asset: &Asset) -> Option<Gzip> {
		match &asset.form {
			Form::Gzip(gzip) => Some(gzip.clone()),
			Form::Undecided | Form::Plain => None,
		}
	}

	fn header<'a>(reply: &'a Reply, name: &str) -> Option<&'a str> {
		reply.headers().get(name).map(|value| value.to_str().unwrap())
	}

	#[test]
	fn a_browser_that_accepts_gzip_gets_the_smaller_form_under_its_own_tag() {
		let body = "export const rooms = 1;\n".repeat(64);
		let (held, asset) = served(body.as_bytes(), "text/javascript; charset=utf-8");
		let gzip = gzip(&asset).expect("a repetitive script shrinks");
		assert_eq!(held, gzip.body.len(), "the generation budgets the second form");
		assert_ne!(gzip.etag, asset.etag);

		let reply = asset
			.clone()
			.response(&request(&[("accept-encoding", "br;q=1.0, GZIP;q=0.8")]));
		assert_eq!(reply.status(), StatusCode::OK);
		assert_eq!(header(&reply, "content-encoding"), Some("gzip"));
		assert_eq!(header(&reply, "vary"), Some("accept-encoding"));
		assert_eq!(header(&reply, "etag"), gzip.etag.to_str().ok());
		let mut inflated = String::new();
		flate2::read::GzDecoder::new(gzip.body.as_ref())
			.read_to_string(&mut inflated)
			.unwrap();
		assert_eq!(inflated, body);

		for refusing in [
			&[][..],
			&[("accept-encoding", "identity")],
			&[("accept-encoding", "gzip;q=0, br")],
			&[("accept-encoding", "gzip; Q = 0.0")],
		] {
			let reply = asset.clone().response(&request(refusing));
			assert_eq!(header(&reply, "content-encoding"), None);
			assert_eq!(
				header(&reply, "vary"),
				Some("accept-encoding"),
				"a cache keeps the forms apart"
			);
			assert_eq!(header(&reply, "etag"), asset.etag.to_str().ok());
		}
	}

	#[test]
	fn a_cached_form_revalidates_only_against_its_own_tag() {
		let (_, asset) = served("a{color:red}\n".repeat(64).as_bytes(), "text/css; charset=utf-8");
		let gzip = gzip(&asset).unwrap();
		let held = gzip.etag.to_str().unwrap();
		let reply = asset
			.clone()
			.response(&request(&[("accept-encoding", "gzip"), ("if-none-match", held)]));
		assert_eq!(reply.status(), StatusCode::NOT_MODIFIED);
		assert_eq!(header(&reply, "content-encoding"), None, "no body, so no coding");
		assert_eq!(header(&reply, "etag"), Some(held));

		let other = asset.etag.to_str().unwrap();
		let reply = asset
			.clone()
			.response(&request(&[("accept-encoding", "gzip"), ("if-none-match", other)]));
		assert_eq!(reply.status(), StatusCode::OK, "the plain form's tag is another entity");
	}

	#[test]
	fn an_asset_that_barely_shrinks_keeps_one_form() {
		// A long run of bytes with no repeats, then a short run of one byte: gzip
		// saves a little, and less than a tenth.
		let mut state = 0x9e37_79b9_u32;
		let mut body: Vec<u8> = (0..4096)
			.map(|_| {
				state ^= state << 13;
				state ^= state >> 17;
				state ^= state << 5;
				state.to_be_bytes()[0]
			})
			.collect();
		body.extend([0u8; 128]);
		let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
		encoder.write_all(&body).unwrap();
		assert!(encoder.finish().unwrap().len() < body.len(), "the form is smaller");
		let (held, asset) = served(&body, "font/woff2");
		assert!(matches!(asset.form, Form::Plain));
		assert_eq!(held, 0);
		let reply = asset.response(&request(&[("accept-encoding", "gzip")]));
		assert_eq!(header(&reply, "content-encoding"), None);
		assert_eq!(header(&reply, "vary"), None);
	}

	#[test]
	fn a_form_with_no_room_left_is_not_held() {
		let body = "export const rooms = 1;\n".repeat(64);
		let (form, _) = served(body.as_bytes(), "text/javascript; charset=utf-8");
		assert!(form > 0);
		let mut asset = Asset::new(Bytes::from(body), "text/javascript; charset=utf-8").unwrap();
		assert_eq!(asset.compress(form - 1, None).unwrap(), 0);
		assert!(matches!(asset.form, Form::Undecided), "tried again next time");
		assert_eq!(asset.compress(form, None).unwrap(), form);
	}

	#[test]
	fn an_unchanged_body_shares_its_earlier_form() {
		let body = "export const rooms = 1;\n".repeat(64);
		let kind = "text/javascript; charset=utf-8";
		let mut earlier = Asset::new(Bytes::from(body.clone()), kind).unwrap();
		let held = Bytes::from_static(b"the earlier form");
		let tag = entity_tag(&held).unwrap();
		earlier.form = Form::Gzip(Gzip {
			etag: tag.clone(),
			body: held.clone(),
		});

		let mut same = Asset::new(Bytes::from(body.clone()), kind).unwrap();
		assert_eq!(same.compress(usize::MAX, Some(&earlier)).unwrap(), held.len());
		let shared = gzip(&same).unwrap();
		assert_eq!(shared.body, held, "shared, not compressed again");
		assert_eq!(shared.etag, tag);

		let mut cramped = Asset::new(Bytes::from(body.clone()), kind).unwrap();
		assert_eq!(cramped.compress(held.len() - 1, Some(&earlier)).unwrap(), 0);
		assert!(matches!(cramped.form, Form::Undecided));

		// A compressible body proves the earlier refusal was taken as given.
		earlier.form = Form::Plain;
		let mut refused = Asset::new(Bytes::from(body.clone()), kind).unwrap();
		assert_eq!(refused.compress(usize::MAX, Some(&earlier)).unwrap(), 0);
		assert!(matches!(refused.form, Form::Plain));

		earlier.form = Form::Undecided;
		let mut retried = Asset::new(Bytes::from(body.clone()), kind).unwrap();
		retried.compress(usize::MAX, Some(&earlier)).unwrap();
		assert!(gzip(&retried).is_some(), "an undecided body is compressed");

		let mut edited = Asset::new(Bytes::from(body + "// edited\n"), kind).unwrap();
		edited.compress(usize::MAX, Some(&earlier)).unwrap();
		assert!(gzip(&edited).is_some(), "a changed body is compressed");
	}
}
