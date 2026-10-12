//! Open Graph metadata admission normalizes bounded preview fields.
use super::{MAX_URL_BYTES, normalize_url};
use alloc::{string::String, vec, vec::Vec};
use serde::{Deserialize, Serialize};
use url::Url;

pub const MAX_PROPERTIES: usize = 128;
pub const MAX_PROPERTY_KEY_BYTES: usize = 64;
pub const MAX_PROPERTY_CONTENT_BYTES: usize = 2_048;
pub const MAX_TITLE_BYTES: usize = 512;
pub const MAX_DESCRIPTION_BYTES: usize = 2_048;
pub const MAX_SITE_BYTES: usize = 256;
pub const MAX_TYPE_BYTES: usize = 128;
pub const MAX_IMAGES: usize = 4;
pub const MAX_IMAGE_ALT_BYTES: usize = 512;
pub const MAX_METADATA_JSON_BYTES: usize = 32 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Property {
	key: String,
	content: String,
}

impl Property {
	/// Bound parser output before it enters the shared precedence model. Page
	/// bytes are already capped by the adapter, but one hostile attribute must
	/// not consume that whole budget again in retained observations.
	#[must_use]
	pub fn new(key: &str, content: &str) -> Option<Self> {
		let key = key.trim();
		let content = content.trim();
		(!key.is_empty()
			&& key.len() <= MAX_PROPERTY_KEY_BYTES
			&& !content.is_empty()
			&& content.len() <= MAX_PROPERTY_CONTENT_BYTES)
			.then(|| Self {
				key: key.into(),
				content: content.into(),
			})
	}
}

/// Parser-neutral input from an HTTP adapter. Document parsing may use any
/// suitable standards-compliant HTML parser. Accepted vocabulary and bounds
/// stay here.
pub struct Observation<'a> {
	pub requested_url: &'a str,
	pub final_url: &'a str,
	pub canonical_url: Option<&'a str>,
	pub html_title: Option<&'a str>,
	pub properties: &'a [Property],
}

/// Parser-neutral oEmbed fields. Provider discovery and HTTP stay in an
/// adapter. The shared application owns how the standard's vocabulary enters
/// the one metadata shape every Rooms presentation consumes.
pub struct OEmbedObservation<'a> {
	pub requested_url: &'a str,
	pub title: Option<&'a str>,
	pub provider_name: Option<&'a str>,
	pub object_type: Option<&'a str>,
	pub thumbnail_url: Option<&'a str>,
	pub thumbnail_width: Option<u32>,
	pub thumbnail_height: Option<u32>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Image {
	pub url: String,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub media_type: Option<String>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub width: Option<u32>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub height: Option<u32>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub alt: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Metadata {
	pub requested_url: String,
	pub url: String,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub title: Option<String>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub description: Option<String>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub site_name: Option<String>,
	#[serde(skip_serializing_if = "Option::is_none")]
	pub object_type: Option<String>,
	pub images: Vec<Image>,
}

impl Metadata {
	/// Admit metadata crossing an adapter boundary through the same bounds and
	/// URL identity rules that construct it. Presentations never become a
	/// second, looser authority merely because the value is already JSON.
	#[must_use]
	pub fn decode(encoded: &str) -> Option<Self> {
		if encoded.len() > MAX_METADATA_JSON_BYTES {
			return None;
		}
		let metadata: Self = serde_json::from_str(encoded).ok()?;
		metadata.valid().then_some(metadata)
	}

	fn valid(&self) -> bool {
		(self.title.is_some()
			|| self.description.is_some()
			|| self.site_name.is_some()
			|| self.object_type.is_some()
			|| !self.images.is_empty())
			&& canonical_url(&self.requested_url)
			&& canonical_url(&self.url)
			&& valid_text(&self.title, MAX_TITLE_BYTES)
			&& valid_text(&self.description, MAX_DESCRIPTION_BYTES)
			&& valid_text(&self.site_name, MAX_SITE_BYTES)
			&& valid_text(&self.object_type, MAX_TYPE_BYTES)
			&& self.images.len() <= MAX_IMAGES
			&& self.images.iter().all(|image| {
				canonical_url(&image.url)
					&& valid_text(&image.media_type, MAX_TYPE_BYTES)
					&& image.width.is_none_or(|value| value > 0 && value <= 100_000)
					&& image.height.is_none_or(|value| value > 0 && value <= 100_000)
					&& valid_text(&image.alt, MAX_IMAGE_ALT_BYTES)
			})
	}

	/// Apply OGP precedence with common Twitter and HTML fallbacks. An empty
	/// result is valid: the presentation can omit a card without hiding its link.
	#[must_use]
	pub fn from_observation(input: &Observation<'_>) -> Option<Self> {
		let requested_url = normalize_url(input.requested_url)?;
		let final_url = normalize_url(input.final_url)?;
		let properties = &input.properties[..input.properties.len().min(MAX_PROPERTIES)];
		let canonical = first(properties, &["og:url"])
			.and_then(|value| resolve_url(&final_url, value))
			.or_else(|| input.canonical_url.and_then(|value| resolve_url(&final_url, value)))
			.unwrap_or_else(|| final_url.clone());
		let title = first(properties, &["og:title", "twitter:title", "schema:title"])
			.or(input.html_title)
			.and_then(|value| bounded_text(value, MAX_TITLE_BYTES));
		let description = first(
			properties,
			&[
				"og:description",
				"twitter:description",
				"description",
				"schema:description",
			],
		)
		.and_then(|value| bounded_text(value, MAX_DESCRIPTION_BYTES));
		let site_name = first(properties, &["og:site_name"]).and_then(|value| bounded_text(value, MAX_SITE_BYTES));
		let object_type = first(properties, &["og:type"]).and_then(|value| bounded_text(value, MAX_TYPE_BYTES));
		let images = images(properties, &final_url);
		if title.is_none() && description.is_none() && site_name.is_none() && object_type.is_none() && images.is_empty()
		{
			return None;
		}
		Some(Self {
			requested_url,
			url: canonical,
			title,
			description,
			site_name,
			object_type,
			images,
		})
	}

	/// Admit the display-safe subset of oEmbed. Executable embed HTML never
	/// crosses this boundary. Rooms keeps the authored link as navigation and
	/// proxies only a bounded thumbnail through its existing image service.
	#[must_use]
	pub fn from_oembed(input: &OEmbedObservation<'_>) -> Option<Self> {
		let requested_url = normalize_url(input.requested_url)?;
		let title = input.title.and_then(|value| bounded_text(value, MAX_TITLE_BYTES));
		let site_name = input
			.provider_name
			.and_then(|value| bounded_text(value, MAX_SITE_BYTES));
		let object_type = match input.object_type {
			Some(value) if matches!(value, "link" | "photo" | "rich" | "video") => bounded_text(value, MAX_TYPE_BYTES),
			Some(_) => return None,
			None => None,
		};
		let images = input
			.thumbnail_url
			.and_then(|value| resolve_url(&requested_url, value))
			.map(|url| {
				vec![Image {
					url,
					media_type: None,
					width: valid_dimension(input.thumbnail_width),
					height: valid_dimension(input.thumbnail_height),
					alt: None,
				}]
			})
			.unwrap_or_default();
		if title.is_none() && site_name.is_none() && object_type.is_none() && images.is_empty() {
			return None;
		}
		Some(Self {
			url: requested_url.clone(),
			requested_url,
			title,
			description: None,
			site_name,
			object_type,
			images,
		})
	}
}

fn valid_dimension(value: Option<u32>) -> Option<u32> {
	value.filter(|value| *value > 0 && *value <= 100_000)
}

fn canonical_url(value: &str) -> bool {
	normalize_url(value).as_deref() == Some(value)
}

fn valid_text(value: &Option<String>, max: usize) -> bool {
	value
		.as_ref()
		.is_none_or(|value| bounded_text(value, max).as_ref() == Some(value))
}

fn first<'a>(properties: &'a [Property], keys: &[&str]) -> Option<&'a str> {
	keys.iter().find_map(|wanted| {
		properties
			.iter()
			.find(|property| property.key.eq_ignore_ascii_case(wanted))
			.map(|property| property.content.as_str())
	})
}

fn bounded_text(value: &str, max: usize) -> Option<String> {
	let mut normalized = String::new();
	for word in value.split_whitespace() {
		let separator = usize::from(!normalized.is_empty());
		if separator + word.len() > max.saturating_sub(normalized.len()) {
			break;
		}
		if separator == 1 {
			normalized.push(' ');
		}
		normalized.push_str(word);
	}
	(!normalized.is_empty()).then_some(normalized)
}

fn resolve_url(base: &str, value: &str) -> Option<String> {
	if value.len() > MAX_URL_BYTES {
		return None;
	}
	let joined = Url::parse(base).ok()?.join(value.trim()).ok()?;
	normalize_url(joined.as_str())
}

#[derive(Default)]
struct ImageBuilder {
	url: Option<String>,
	secure_url: Option<String>,
	media_type: Option<String>,
	width: Option<u32>,
	height: Option<u32>,
	alt: Option<String>,
}

impl ImageBuilder {
	fn finish(self) -> Option<Image> {
		Some(Image {
			url: self.secure_url.or(self.url)?,
			media_type: self.media_type,
			width: self.width,
			height: self.height,
			alt: self.alt,
		})
	}
}

fn images(properties: &[Property], base: &str) -> Vec<Image> {
	let mut complete = Vec::new();
	let mut current: Option<ImageBuilder> = None;
	for property in properties {
		let key = property.key.to_ascii_lowercase();
		if matches!(key.as_str(), "og:image" | "og:image:url") {
			if let Some(image) = current.take().and_then(ImageBuilder::finish) {
				complete.push(image);
			}
			current = Some(ImageBuilder {
				url: resolve_url(base, &property.content),
				..Default::default()
			});
			continue;
		}
		let Some(image) = current.as_mut() else {
			continue;
		};
		match key.as_str() {
			"og:image:secure_url" => {
				image.secure_url = resolve_url(base, &property.content).filter(|url| url.starts_with("https://"));
			}
			"og:image:type" => image.media_type = bounded_text(&property.content, MAX_TYPE_BYTES),
			"og:image:width" => image.width = dimension(&property.content),
			"og:image:height" => image.height = dimension(&property.content),
			"og:image:alt" => image.alt = bounded_text(&property.content, MAX_IMAGE_ALT_BYTES),
			_ => {}
		}
	}
	if let Some(image) = current.and_then(ImageBuilder::finish) {
		complete.push(image);
	}
	complete.truncate(MAX_IMAGES);
	if complete.is_empty()
		&& let Some(url) = first(properties, &["twitter:image", "twitter:image:src", "schema:image"])
			.and_then(|value| resolve_url(base, value))
	{
		complete.push(Image {
			url,
			media_type: None,
			width: None,
			height: None,
			alt: first(properties, &["twitter:image:alt"]).and_then(|value| bounded_text(value, MAX_IMAGE_ALT_BYTES)),
		});
	}
	complete
}

fn dimension(value: &str) -> Option<u32> {
	value
		.trim()
		.parse()
		.ok()
		.filter(|value| *value > 0 && *value <= 100_000)
}
