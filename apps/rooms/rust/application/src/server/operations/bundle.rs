//! Editable and pasted boot-capability bundles. The boot inventory owns labels;
//! parsing never turns a capability for another host into a local swiss number.
use super::{BOOT_CAPABILITIES, boot_capability};
use crate::text::js_whitespace;
use alloc::{format, string::String, vec::Vec};

pub const MAX_BUNDLE_BYTES: usize = 64 * 1024;
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Draft(Vec<(&'static str, String)>);
impl Draft {
	pub fn parse(raw: &str, pasted: bool) -> Result<Self, String> {
		if raw.len() > MAX_BUNDLE_BYTES {
			return Err("The capability set exceeds its text limit.".into());
		}
		let mut draft = Self::default();
		for line in raw.split('\n').map(|line| line.trim_matches(js_whitespace)) {
			if line.is_empty() || (pasted && !line.starts_with("ROOMS-")) {
				continue;
			}
			let mut parts = line.split(js_whitespace).filter(|part| !part.is_empty());
			let label = parts.next().expect("nonempty line");
			if pasted && label == "ROOMS-TRACE-LISTENING" {
				continue;
			}
			let definition = BOOT_CAPABILITIES
				.iter()
				.find(|cap| cap.token == label)
				.ok_or_else(|| format!("The capability set contains an unknown label: {label}."))?;
			let swiss = parts.next();
			if parts.next().is_some() || (pasted && swiss.is_none()) {
				return Err(format!(
					"{label} must be followed by {} one swiss number.",
					if pasted { "exactly" } else { "at most" }
				));
			}
			let swiss = swiss.unwrap_or("");
			if swiss.contains("://") {
				return Err(
					"paste the bare swiss number this directory printed, not a sturdyref for another host".into(),
				);
			}
			draft.insert(definition.id, swiss)?;
		}
		if pasted && draft.0.is_empty() {
			return Err("Paste the ROOMS-* capability lines printed by the server.".into());
		}
		Ok(draft)
	}
	pub fn insert(&mut self, capability: &str, swiss: &str) -> Result<(), String> {
		let definition = boot_capability(capability).ok_or("Unknown operations capability.")?;
		if self.0.iter().any(|(id, _)| *id == capability) {
			return Err(format!("The capability set repeats {}.", definition.token));
		}
		if swiss.len() > 16384 {
			return Err("A swiss number exceeds its text limit.".into());
		}
		if self.0.iter().map(|(_, value)| value.len()).sum::<usize>() + swiss.len() > MAX_BUNDLE_BYTES {
			return Err("The capability set exceeds its text limit.".into());
		}
		self.0.push((definition.id, swiss.into()));
		Ok(())
	}
	pub fn entries(&self) -> impl Iterator<Item = (&'static str, &str)> {
		self.0.iter().map(|(id, swiss)| (*id, swiss.as_str()))
	}
	pub fn ready(&self) -> bool {
		!self.0.is_empty()
			&& self
				.0
				.iter()
				.all(|(_, swiss)| !swiss.is_empty() && !swiss.contains("://") && !swiss.chars().any(js_whitespace))
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
