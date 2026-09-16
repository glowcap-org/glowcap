//! Bound retained selection entries before deserializing the next URL. JSON's
//! escaped-string scratch is separately bounded at the wire decode boundary.
use super::{MAX_PREVIEWS, MAX_URL_BYTES, Selection};
use alloc::{string::String, vec::Vec};
use core::fmt;
use serde::de::{self, Deserialize, DeserializeSeed, Deserializer, SeqAccess, Visitor};

pub(super) const MAX_ENCODED_BYTES: usize = 2 + MAX_PREVIEWS * (6 * MAX_URL_BYTES + 3);

struct Url;
impl Visitor<'_> for Url {
	type Value = String;
	fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		formatter.write_str("a bounded preview URL")
	}
	fn visit_str<E: de::Error>(self, value: &str) -> Result<String, E> {
		if value.len() > MAX_URL_BYTES {
			return Err(E::custom("preview URL exceeds its byte limit"));
		}
		Ok(value.into())
	}
	fn visit_string<E: de::Error>(self, value: String) -> Result<String, E> {
		if value.len() > MAX_URL_BYTES {
			return Err(E::custom("preview URL exceeds its byte limit"));
		}
		Ok(value)
	}
}
struct NextUrl(bool);
impl<'de> DeserializeSeed<'de> for NextUrl {
	type Value = String;
	fn deserialize<D: Deserializer<'de>>(self, deserializer: D) -> Result<String, D::Error> {
		if !self.0 {
			return Err(de::Error::custom("preview selection exceeds its count limit"));
		}
		deserializer.deserialize_str(Url)
	}
}
impl<'de> Deserialize<'de> for Selection {
	fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
		struct Selected;
		impl<'de> Visitor<'de> for Selected {
			type Value = Selection;
			fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
				formatter.write_str("a bounded preview selection")
			}
			fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Selection, A::Error> {
				let mut urls = Vec::new();
				while let Some(url) = seq.next_element_seed(NextUrl(urls.len() < MAX_PREVIEWS))? {
					urls.push(url);
				}
				Ok(Selection(urls))
			}
		}
		deserializer.deserialize_seq(Selected)
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn deserialization_enforces_count_and_url_bounds() {
		let url = "https://example.org/";
		let encoded = serde_json::to_string(&alloc::vec![url; MAX_PREVIEWS]).unwrap();
		assert_eq!(
			serde_json::from_str::<Selection>(&encoded).unwrap().urls().len(),
			MAX_PREVIEWS
		);
		let encoded = serde_json::to_string(&alloc::vec![url; MAX_PREVIEWS + 1]).unwrap();
		assert!(serde_json::from_str::<Selection>(&encoded).is_err());
		let encoded = serde_json::to_string(&alloc::vec!["x".repeat(MAX_URL_BYTES + 1)]).unwrap();
		assert!(serde_json::from_str::<Selection>(&encoded).is_err());
		let encoded = alloc::format!("[{}]", serde_json::to_string(&url).unwrap());
		assert_eq!(Selection::decode(url, &encoded).unwrap().urls(), &[url]);
		assert!(Selection::decode(url, &" ".repeat(MAX_ENCODED_BYTES + 1)).is_err());
	}
	#[test]
	fn owned_json_urls_transfer_and_unbounded_iterators_stop_at_the_limit() {
		let url = String::from("https://example.org/");
		let pointer = url.as_ptr();
		let selected: Selection =
			serde_json::from_value(serde_json::Value::Array(alloc::vec![serde_json::Value::String(url),])).unwrap();
		assert_eq!(
			selected.urls()[0].as_ptr(),
			pointer,
			"owned JSON must not add a URL copy"
		);
		let mut seen = 0;
		let selected = core::iter::repeat("https://example.org/").inspect(|_| {
			seen += 1;
			assert!(
				seen <= MAX_PREVIEWS + 1,
				"bounded admission must stop consuming rejected input"
			);
		});
		assert_eq!(Selection::new("", selected), Err(super::super::SelectionError::Shape));
	}
}
