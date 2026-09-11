//! One schema decoder for in-memory values and bounded network responses.
use super::*;
use core::{cell::Cell, fmt};
use serde::de::{DeserializeSeed, Deserializer, Error, MapAccess, SeqAccess, Visitor};

#[derive(Clone, Copy)]
struct Context<'a> {
	limits: Limits,
	reason: &'a Cell<Option<&'static str>>,
}
impl Context<'_> {
	fn fail<E: Error>(self, reason: &'static str) -> E {
		self.reason.set(Some(reason));
		E::custom(reason)
	}
}
pub(super) fn read<'de>(input: impl Deserializer<'de>, limits: Limits) -> Result<Servers, &'static str> {
	let reason = Cell::new(None);
	let context = Context {
		limits,
		reason: &reason,
	};
	List {
		item: context,
		limit: limits.servers,
	}
	.deserialize(input)
	.map(Servers)
	.map_err(|_| reason.get().unwrap_or("invalid ICE configuration structure"))
}

/// Refuse an excess element before asking the format to decode its contents.
struct Excess;
impl<'de> DeserializeSeed<'de> for Excess {
	type Value = ();
	fn deserialize<D: Deserializer<'de>>(self, _: D) -> Result<(), D::Error> {
		Err(D::Error::custom("ICE collection exceeds its count limit"))
	}
}
struct List<S> {
	item: S,
	limit: usize,
}
impl<'de, S: DeserializeSeed<'de> + Copy> DeserializeSeed<'de> for List<S> {
	type Value = Vec<S::Value>;
	fn deserialize<D: Deserializer<'de>>(self, input: D) -> Result<Self::Value, D::Error> {
		input.deserialize_seq(self)
	}
}
impl<'de, S: DeserializeSeed<'de> + Copy> Visitor<'de> for List<S> {
	type Value = Vec<S::Value>;
	fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str("a bounded ICE collection")
	}
	fn visit_seq<A: SeqAccess<'de>>(self, mut input: A) -> Result<Self::Value, A::Error> {
		let mut values = Vec::new();
		while values.len() < self.limit {
			let Some(value) = input.next_element_seed(self.item)? else {
				return Ok(values);
			};
			values.push(value);
		}
		input.next_element_seed(Excess)?;
		Ok(values)
	}
}

#[derive(serde::Deserialize)]
#[serde(field_identifier, rename_all = "lowercase")]
enum Field {
	Urls,
	Username,
	Credential,
}
impl<'de> DeserializeSeed<'de> for Context<'_> {
	type Value = Server;
	fn deserialize<D: Deserializer<'de>>(self, input: D) -> Result<Server, D::Error> {
		input.deserialize_map(self)
	}
}
impl<'de> Visitor<'de> for Context<'_> {
	type Value = Server;
	fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str("an ICE server record")
	}
	fn visit_map<A: MapAccess<'de>>(self, mut input: A) -> Result<Server, A::Error> {
		let (mut urls, mut username, mut credential) = (None, None, None);
		while let Some(field) = input.next_key::<Field>()? {
			match field {
				Field::Urls => {
					if urls.is_some() {
						return Err(self.fail("duplicate ICE URLs"));
					}
					urls = Some(input.next_value_seed(UrlSet(self))?);
				}
				Field::Username | Field::Credential => {
					let slot = if matches!(field, Field::Username) {
						&mut username
					} else {
						&mut credential
					};
					if slot.is_some() {
						return Err(self.fail("duplicate ICE credential field"));
					}
					*slot = Some(input.next_value_seed(Text {
						context: self,
						url: false,
					})?);
				}
			}
		}
		let server = Server {
			urls: urls.ok_or_else(|| self.fail("ICE server has no URLs"))?,
			username,
			credential,
		};
		let has_turn = server.urls().iter().any(|url| is_turn(url));
		if has_turn && (server.username.is_none() || server.credential.is_none()) {
			return Err(self.fail("TURN server requires username and credential"));
		}
		if !has_turn && (server.username.is_some() || server.credential.is_some()) {
			return Err(self.fail("STUN servers do not take TURN credentials"));
		}
		Ok(server)
	}
}

struct UrlSet<'a>(Context<'a>);
impl<'de> DeserializeSeed<'de> for UrlSet<'_> {
	type Value = Urls;
	fn deserialize<D: Deserializer<'de>>(self, input: D) -> Result<Urls, D::Error> {
		input.deserialize_any(self)
	}
}
impl<'de> Visitor<'de> for UrlSet<'_> {
	type Value = Urls;
	fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str("an ICE URL or URL array")
	}
	fn visit_str<E: Error>(self, text: &str) -> Result<Urls, E> {
		if self.0.limits.urls == 0 {
			return Err(self.0.fail("ICE server URL count is invalid"));
		}
		Text {
			context: self.0,
			url: true,
		}
		.visit_str(text)
		.map(Urls::One)
	}
	fn visit_seq<A: SeqAccess<'de>>(self, input: A) -> Result<Urls, A::Error> {
		let urls = List {
			item: Text {
				context: self.0,
				url: true,
			},
			limit: self.0.limits.urls,
		}
		.visit_seq(input)?;
		if urls.is_empty() {
			return Err(self.0.fail("ICE server URL count is invalid"));
		}
		Ok(Urls::Many(urls))
	}
}

#[derive(Clone, Copy)]
struct Text<'a> {
	context: Context<'a>,
	url: bool,
}
impl<'de> DeserializeSeed<'de> for Text<'_> {
	type Value = String;
	fn deserialize<D: Deserializer<'de>>(self, input: D) -> Result<String, D::Error> {
		input.deserialize_str(self)
	}
}
impl<'de> Visitor<'de> for Text<'_> {
	type Value = String;
	fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str("bounded ICE text")
	}
	fn visit_str<E: Error>(self, text: &str) -> Result<String, E> {
		let limit = if self.url {
			self.context.limits.url_bytes
		} else {
			self.context.limits.credential_bytes
		};
		let text = if self.url { text.trim() } else { text };
		if text.is_empty() || text.len() > limit {
			return Err(self.context.fail("ICE text is empty or too long"));
		}
		if self.url {
			let scheme = scheme(text);
			if !is_turn(text) && !scheme.eq_ignore_ascii_case("stun") && !scheme.eq_ignore_ascii_case("stuns") {
				return Err(self.context.fail("ICE URL must use stun, stuns, turn, or turns"));
			}
		}
		Ok(text.to_string())
	}
}
fn scheme(url: &str) -> &str {
	url.split_once(':').map(|(scheme, _)| scheme).unwrap_or("")
}
pub(super) fn is_turn(url: &str) -> bool {
	let scheme = scheme(url);
	scheme.eq_ignore_ascii_case("turn") || scheme.eq_ignore_ascii_case("turns")
}
