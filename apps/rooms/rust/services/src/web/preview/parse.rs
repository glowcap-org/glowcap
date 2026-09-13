use encoding_rs::{Encoding, UTF_8};
use html5ever::{
	tendril::StrTendril,
	tokenizer::{
		BufferQueue, CharacterTokens, EndTag, StartTag, Tag, TagToken, Token, TokenSink, TokenSinkResult, Tokenizer,
		states::RawKind,
	},
};
use rooms_application::open_graph::{MAX_PROPERTIES, MAX_TITLE_BYTES, MAX_URL_BYTES, Metadata, Observation, Property};
use serde_json::Value;
use std::cell::RefCell;

const MAX_JSON_LD_BLOCKS: usize = 8;
const MAX_JSON_LD_BYTES: usize = 32 * 1024;

pub(super) fn metadata(requested_url: &str, final_url: &str, content_type: &str, body: &[u8]) -> Option<Metadata> {
	let encoding = charset(content_type)
		.and_then(|label| Encoding::for_label(label.as_bytes()))
		.unwrap_or(UTF_8);
	let (decoded, _, _) = encoding.decode(body);
	let extracted = extract(&decoded);
	let mut properties = extracted.properties;
	properties.extend(schema_properties(&extracted.schemas, properties.len()));
	Metadata::from_observation(&Observation {
		requested_url,
		final_url,
		canonical_url: extracted.canonical.as_deref(),
		html_title: extracted.title.as_deref(),
		properties: &properties,
	})
}

/// Tokenize once into only the metadata Rooms can admit. A DOM and selector
/// engine retain the whole page even though previews need a bounded handful of
/// attributes and text nodes; this sink drops every unrelated token as it arrives.
fn extract(source: &str) -> Extraction {
	let input = BufferQueue::default();
	input.push_back(StrTendril::from_slice(source));
	let tokenizer = Tokenizer::new(Sink::default(), Default::default());
	let result = tokenizer.feed(&input);
	debug_assert!(matches!(result, html5ever::interface::TokenizerResult::Done));
	tokenizer.end();
	tokenizer.sink.take()
}

#[derive(Clone, Copy, Default, Eq, PartialEq)]
enum Capture {
	#[default]
	None,
	Title,
	JsonLd,
	IgnoredRawText,
}

#[derive(Default)]
struct Sink(RefCell<Extraction>);

impl Sink {
	fn take(&self) -> Extraction {
		core::mem::take(&mut *self.0.borrow_mut()).finish()
	}
}

#[derive(Default)]
struct Extraction {
	properties: Vec<Property>,
	canonical: Option<String>,
	title: Option<BoundedText>,
	schemas: Vec<String>,
	current_schema: Option<String>,
	matching_scripts: usize,
	capture: Capture,
}

impl Extraction {
	fn start(&mut self, tag: &Tag) -> TokenSinkResult<()> {
		match tag.name.as_ref() {
			"meta" if self.properties.len() < MAX_PROPERTIES => {
				let key = attribute(tag, "property").or_else(|| attribute(tag, "name"));
				if let Some(property) = key
					.zip(attribute(tag, "content"))
					.and_then(|(key, content)| Property::new(key, content))
				{
					self.properties.push(property);
				}
			}
			"link" if self.canonical.is_none() => {
				let canonical = attribute(tag, "rel").is_some_and(|value| {
					value
						.split_ascii_whitespace()
						.any(|relation| relation.eq_ignore_ascii_case("canonical"))
				});
				if canonical && let Some(href) = attribute(tag, "href").filter(|href| href.len() <= MAX_URL_BYTES) {
					self.canonical = Some(href.to_owned());
				}
			}
			"title" => {
				if self.title.is_none() {
					self.title = Some(BoundedText::default());
					self.capture = Capture::Title;
				} else {
					self.capture = Capture::IgnoredRawText;
				}
				return TokenSinkResult::RawData(RawKind::Rcdata);
			}
			"textarea" => {
				self.capture = Capture::IgnoredRawText;
				return TokenSinkResult::RawData(RawKind::Rcdata);
			}
			"style" | "xmp" | "iframe" | "noembed" | "noframes" | "noscript" => {
				self.capture = Capture::IgnoredRawText;
				return TokenSinkResult::RawData(RawKind::Rawtext);
			}
			"plaintext" => {
				self.capture = Capture::IgnoredRawText;
				return TokenSinkResult::Plaintext;
			}
			"script" => {
				let json_ld = attribute(tag, "type")
					.is_some_and(|value| value.trim().eq_ignore_ascii_case("application/ld+json"));
				if json_ld && self.matching_scripts < MAX_JSON_LD_BLOCKS {
					self.matching_scripts += 1;
					self.current_schema = Some(String::new());
					self.capture = Capture::JsonLd;
				} else {
					self.capture = Capture::IgnoredRawText;
				}
				return TokenSinkResult::RawData(RawKind::ScriptData);
			}
			_ => {}
		}
		TokenSinkResult::Continue
	}

	fn text(&mut self, text: &str) {
		match self.capture {
			Capture::Title => {
				if let Some(title) = self.title.as_mut() {
					title.push(text);
				}
			}
			Capture::JsonLd => {
				let Some(schema) = self.current_schema.as_mut() else {
					return;
				};
				if text.len() <= MAX_JSON_LD_BYTES.saturating_sub(schema.len()) {
					schema.push_str(text);
				} else {
					self.current_schema = None;
				}
			}
			Capture::None | Capture::IgnoredRawText => {}
		}
	}

	fn end_tag(&mut self, tag: &Tag) {
		match tag.name.as_ref() {
			"script" if self.capture == Capture::JsonLd => {
				if let Some(schema) = self.current_schema.take() {
					self.schemas.push(schema);
				}
				self.capture = Capture::None;
			}
			_ if matches!(self.capture, Capture::Title | Capture::IgnoredRawText) => self.capture = Capture::None,
			_ => {}
		}
	}

	fn finish(mut self) -> Extraction {
		if self.capture == Capture::JsonLd
			&& let Some(schema) = self.current_schema.take()
		{
			self.schemas.push(schema);
		}
		self.capture = Capture::None;
		self.title = self.title.filter(|title| !title.value.is_empty());
		self
	}
}

impl TokenSink for Sink {
	type Handle = ();

	fn process_token(&self, token: Token, _line_number: u64) -> TokenSinkResult<()> {
		let mut output = self.0.borrow_mut();
		match token {
			TagToken(tag) if tag.kind == StartTag => output.start(&tag),
			TagToken(tag) if tag.kind == EndTag => {
				output.end_tag(&tag);
				TokenSinkResult::Continue
			}
			CharacterTokens(text) => {
				output.text(&text);
				TokenSinkResult::Continue
			}
			_ => TokenSinkResult::Continue,
		}
	}
}

fn attribute<'a>(tag: &'a Tag, wanted: &str) -> Option<&'a str> {
	tag.attrs
		.iter()
		.find(|attribute| {
			let name: &str = attribute.name.local.as_ref();
			name == wanted
		})
		.map(|attribute| attribute.value.as_ref())
}

#[derive(Default)]
struct BoundedText {
	value: String,
	in_word: bool,
	word_start: usize,
	full: bool,
}

impl BoundedText {
	fn push(&mut self, source: &str) {
		if self.full {
			return;
		}
		for character in source.chars() {
			if character.is_whitespace() {
				self.in_word = false;
				continue;
			}
			if !self.in_word {
				self.word_start = self.value.len();
				if !self.value.is_empty() {
					self.value.push(' ');
				}
				self.in_word = true;
			}
			if character.len_utf8() > MAX_TITLE_BYTES.saturating_sub(self.value.len()) {
				self.value.truncate(self.word_start);
				self.full = true;
				return;
			}
			self.value.push(character);
		}
	}
}

impl core::ops::Deref for BoundedText {
	type Target = str;

	fn deref(&self) -> &Self::Target {
		&self.value
	}
}

fn schema_properties(schemas: &[String], already: usize) -> Vec<Property> {
	let remaining = MAX_PROPERTIES.saturating_sub(already);
	let mut properties = Vec::new();
	if remaining == 0 {
		return properties;
	}
	for source in schemas {
		let Ok(value) = serde_json::from_str::<Value>(source) else {
			continue;
		};
		for object in schema_objects(&value).take(16) {
			for (key, value) in [
				("schema:title", object.get("headline").or_else(|| object.get("name"))),
				("schema:description", object.get("description")),
				("schema:image", object.get("image")),
			] {
				push_schema(&mut properties, key, value);
				if properties.len() == remaining {
					return properties;
				}
			}
		}
	}
	properties
}

fn schema_objects(value: &Value) -> impl Iterator<Item = &serde_json::Map<String, Value>> {
	let values: &[Value] = match value {
		Value::Array(values) => values,
		Value::Object(object) => object
			.get("@graph")
			.and_then(Value::as_array)
			.map_or(core::slice::from_ref(value), Vec::as_slice),
		_ => &[],
	};
	values.iter().filter_map(Value::as_object)
}

fn push_schema(properties: &mut Vec<Property>, key: &str, value: Option<&Value>) {
	let text = value.and_then(|value| match value {
		Value::String(value) => Some(value.as_str()),
		Value::Array(values) => values.iter().find_map(Value::as_str),
		Value::Object(object) => object
			.get("contentUrl")
			.or_else(|| object.get("url"))
			.and_then(Value::as_str),
		_ => None,
	});
	if let Some(property) = text.and_then(|text| Property::new(key, text)) {
		properties.push(property);
	}
}

fn charset(content_type: &str) -> Option<&str> {
	content_type.split(';').skip(1).find_map(|parameter| {
		let (name, value) = parameter.trim().split_once('=')?;
		name.trim()
			.eq_ignore_ascii_case("charset")
			.then(|| value.trim().trim_matches(['"', '\'']))
	})
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn reads_property_and_name_metadata_with_canonical_url() {
		let body = br#"<html><head><title>HTML fallback</title>
			<link rel="CANONICAL alternate" href="/article">
			<meta name="description" content="The description">
			<meta property="og:title" content="Open Graph title">
			<meta property="og:image" content="/cover.jpg"></head></html>"#;
		let found = metadata(
			"https://example.com/start",
			"https://example.com/final",
			"text/html; charset=utf-8",
			body,
		)
		.unwrap();
		assert_eq!(found.url, "https://example.com/article");
		assert_eq!(found.title.as_deref(), Some("Open Graph title"));
		assert_eq!(found.description.as_deref(), Some("The description"));
		assert_eq!(found.images[0].url, "https://example.com/cover.jpg");
	}

	#[test]
	fn uses_bounded_json_ld_only_as_a_fallback() {
		let body = br#"<meta property="og:title" content="Open Graph wins">
			<script type="APPLICATION/LD+JSON">{
				"@type":"Article", "headline":"Schema title",
				"description":"Schema description", "image":{"contentUrl":"/schema.jpg"}
			}</script>"#;
		let found = metadata(
			"https://example.com/start",
			"https://example.com/final",
			"text/html",
			body,
		)
		.unwrap();
		assert_eq!(found.title.as_deref(), Some("Open Graph wins"));
		assert_eq!(found.description.as_deref(), Some("Schema description"));
		assert_eq!(found.images[0].url, "https://example.com/schema.jpg");
	}

	#[test]
	fn malformed_html_keeps_raw_text_from_forging_metadata() {
		let body = br#"<title>Fallback &amp; title</title><style>
			<meta property='og:title' content='forged by style'></style><textarea>
			<meta property='og:title' content='forged by textarea'></textarea><noscript>
			<meta property='og:title' content='forged by noscript'></noscript><script>
			"<meta property='og:title' content='forged by script'>"</script>
			<meta property=og:description content='Real description'>"#;
		let found = metadata("https://example.com/", "https://example.com/", "text/html", body).unwrap();
		assert_eq!(found.title.as_deref(), Some("Fallback & title"));
		assert_eq!(found.description.as_deref(), Some("Real description"));
	}

	#[test]
	fn retained_parser_output_is_bounded_during_extraction() {
		let huge_word = "a".repeat(MAX_TITLE_BYTES + 1);
		let huge_schema = "x".repeat(MAX_JSON_LD_BYTES + 1);
		let source = format!(
			"<title>useful {huge_word} ignored</title><script type='application/ld+json'>{huge_schema}</script>"
		);
		let extracted = extract(&source);
		assert_eq!(extracted.title.as_deref(), Some("useful"));
		assert!(extracted.schemas.is_empty());
	}

	#[test]
	fn charset_decode_and_property_budget_apply_before_admission() {
		let found = metadata(
			"https://example.com/",
			"https://example.com/",
			"text/html; charset=windows-1252",
			b"<title>caf\xe9</title>",
		)
		.unwrap();
		assert_eq!(found.title.as_deref(), Some("caf\u{e9}"));

		let schemas = vec![r#"{"name":"title","description":"description","image":"/image"}"#.to_owned()];
		assert_eq!(schema_properties(&schemas, MAX_PROPERTIES - 1).len(), 1);
		assert!(schema_properties(&schemas, MAX_PROPERTIES).is_empty());
	}
}
