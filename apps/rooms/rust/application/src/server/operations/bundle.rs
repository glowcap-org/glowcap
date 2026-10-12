//! Editable and pasted boot-capability bundles. The boot inventory owns labels.
//! Parsing never turns a capability for another host into a local swiss number.
use super::{BOOT_CAPABILITIES, boot_capability};
use crate::text::js_whitespace;
use alloc::{
	format,
	string::{String, ToString},
	vec::Vec,
};

pub const MAX_BUNDLE_BYTES: usize = 64 * 1024;
/// Why a capability bundle is refused. `Display` is the exact line the
/// operator reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invalid {
	/// The bundle text, or its URIs together, are over the byte limit.
	BundleLimit,
	/// A line holds no label.
	NoLabel,
	/// A line names a label the boot inventory does not know.
	UnknownLabel { label: String },
	/// A label is followed by other than one capability URI.
	UriCount { label: String, exactly: bool },
	/// A paste held no `ROOMS-` line.
	NothingPasted,
	/// The capability id is not an operations capability.
	UnknownCapability,
	/// The bundle names one capability twice.
	Repeated { token: &'static str },
	/// One capability URI is over its byte limit.
	UriLimit,
	/// The capability URI is not a complete one.
	UriShape,
}

impl core::fmt::Display for Invalid {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::BundleLimit => f.write_str("The capability set exceeds its text limit."),
			Self::NoLabel => f.write_str("The capability set contains a line with no label."),
			Self::UnknownLabel { label } => write!(f, "The capability set contains an unknown label: {label}."),
			Self::UriCount { label, exactly } => write!(
				f,
				"{label} must be followed by {} one complete capability URI.",
				if *exactly { "exactly" } else { "at most" }
			),
			Self::NothingPasted => f.write_str("Paste the ROOMS-* capability lines printed by the server."),
			Self::UnknownCapability => f.write_str("Unknown operations capability."),
			Self::Repeated { token } => write!(f, "The capability set repeats {token}."),
			Self::UriLimit => f.write_str("A capability URI exceeds its text limit."),
			Self::UriShape => f.write_str("Enter the complete capability URI printed by the server."),
		}
	}
}

impl core::error::Error for Invalid {}

impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		invalid.to_string()
	}
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Draft(Vec<(&'static str, String)>);
impl Draft {
	pub fn parse(raw: &str, pasted: bool) -> Result<Self, Invalid> {
		if raw.len() > MAX_BUNDLE_BYTES {
			return Err(Invalid::BundleLimit);
		}
		let mut draft = Self::default();
		for line in raw.split('\n').map(|line| line.trim_matches(js_whitespace)) {
			if line.is_empty() || (pasted && !line.starts_with("ROOMS-")) {
				continue;
			}
			let mut parts = line.split(js_whitespace).filter(|part| !part.is_empty());
			let label = parts.next().ok_or(Invalid::NoLabel)?;
			if pasted && label == "ROOMS-TRACE-LISTENING" {
				continue;
			}
			let definition = BOOT_CAPABILITIES
				.iter()
				.find(|cap| cap.token == label)
				.ok_or_else(|| Invalid::UnknownLabel { label: label.into() })?;
			let uri = parts.next();
			if parts.next().is_some() || (pasted && uri.is_none()) {
				return Err(Invalid::UriCount {
					label: label.into(),
					exactly: pasted,
				});
			}
			draft.insert(definition.id, uri.unwrap_or(""))?;
		}
		if pasted && draft.0.is_empty() {
			return Err(Invalid::NothingPasted);
		}
		Ok(draft)
	}
	pub fn insert(&mut self, capability: &str, swiss: &str) -> Result<(), Invalid> {
		let definition = boot_capability(capability).ok_or(Invalid::UnknownCapability)?;
		if self.0.iter().any(|(id, _)| *id == capability) {
			return Err(Invalid::Repeated {
				token: definition.token,
			});
		}
		if swiss.len() > 16384 {
			return Err(Invalid::UriLimit);
		}
		if !swiss.is_empty() && !recipe(swiss) {
			return Err(Invalid::UriShape);
		}
		if self.0.iter().map(|(_, value)| value.len()).sum::<usize>() + swiss.len() > MAX_BUNDLE_BYTES {
			return Err(Invalid::BundleLimit);
		}
		self.0.push((definition.id, swiss.into()));
		Ok(())
	}
	pub fn entries(&self) -> impl Iterator<Item = (&'static str, &str)> {
		self.0.iter().map(|(id, swiss)| (*id, swiss.as_str()))
	}
	pub fn ready(&self) -> bool {
		!self.0.is_empty() && self.0.iter().all(|(_, uri)| recipe(uri))
	}
	pub fn is_empty(&self) -> bool {
		self.0.is_empty()
	}
	pub fn format(&self) -> String {
		BOOT_CAPABILITIES
			.iter()
			.filter_map(|cap| {
				self.0.iter().find(|(id, _)| *id == cap.id).map(|(_, swiss)| {
					if swiss.is_empty() {
						cap.token.into()
					} else {
						format!("{} {swiss}", cap.token)
					}
				})
			})
			.collect::<Vec<String>>()
			.join("\n")
	}
}
// Form readiness checks URI shape. The runtime acquisition owner validates the
// actual sturdy reference and exporter before performing any lookup.
fn recipe(uri: &str) -> bool {
	uri.starts_with("ocapn://") && uri.contains("/s/") && !uri.chars().any(js_whitespace)
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn every_invalid_line_is_the_line_it_replaced() {
		let lines = [
			(Invalid::BundleLimit, "The capability set exceeds its text limit."),
			(Invalid::NoLabel, "The capability set contains a line with no label."),
			(
				Invalid::UnknownLabel { label: "X".into() },
				"The capability set contains an unknown label: X.",
			),
			(
				Invalid::UriCount {
					label: "X".into(),
					exactly: true,
				},
				"X must be followed by exactly one complete capability URI.",
			),
			(
				Invalid::UriCount {
					label: "X".into(),
					exactly: false,
				},
				"X must be followed by at most one complete capability URI.",
			),
			(
				Invalid::NothingPasted,
				"Paste the ROOMS-* capability lines printed by the server.",
			),
			(Invalid::UnknownCapability, "Unknown operations capability."),
			(Invalid::Repeated { token: "X" }, "The capability set repeats X."),
			(Invalid::UriLimit, "A capability URI exceeds its text limit."),
			(
				Invalid::UriShape,
				"Enter the complete capability URI printed by the server.",
			),
		];
		for (invalid, line) in lines {
			assert_eq!(invalid.to_string(), line);
		}
	}
}
