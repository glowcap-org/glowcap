//! Decode tagged socket requests without Serde's intermediate content buffer.
//! Rooms document text retains raw JSON, including isolated UTF-16 surrogates.
macro_rules! request {
	($visibility:vis enum $name:ident, $tag:ident = $tag_name:literal {
		$( $variant:ident => $wire:literal { $( $(#[$attribute:meta])* $field:ident: $ty:ty ),* $(,)? } ),* $(,)?
	}) => {
		#[derive(serde::Serialize)]
		#[serde(tag = $tag_name, rename_all = "kebab-case")]
		$visibility enum $name {
			$( $variant { $( $(#[$attribute])* $field: $ty ),* } ),*
		}
		impl<'de> serde::Deserialize<'de> for $name {
			fn deserialize<D: serde::Deserializer<'de>>(input: D) -> Result<Self, D::Error> {
				use serde::de::Error;
				let raw = <&serde_json::value::RawValue as serde::Deserialize>::deserialize(input)?;
				#[derive(serde::Deserialize)]
				struct Tag { $tag: String }
				let tag: Tag = serde_json::from_str(raw.get()).map_err(D::Error::custom)?;
				match tag.$tag.as_str() {
					$( $wire => {
						#[derive(serde::Deserialize)]
						#[serde(deny_unknown_fields)]
						struct Fields { #[serde(rename = $tag_name)] _tag: String, $( $(#[$attribute])* $field: $ty ),* }
						let fields: Fields = serde_json::from_str(raw.get()).map_err(D::Error::custom)?;
						let Fields { _tag: _, $( $field ),* } = fields;
						Ok(Self::$variant { $( $field ),* })
					} ),*,
					_ => Err(D::Error::custom("unknown socket request")),
				}
			}
		}
	};
}
pub(super) use request;
