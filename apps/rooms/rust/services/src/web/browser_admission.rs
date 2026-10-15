//! Browser-local startup policy is deployment configuration, not saved intent.
//! Page generation carries the validated overrides to the Wasm constructor.
use rooms_application::admission::{Settings, Source};
use std::collections::BTreeMap;

pub(super) struct Config {
	pub settings: Settings,
	pub encoded: String,
}
impl Config {
	pub fn read(options: &BTreeMap<String, String>, env: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
		let mut values = BTreeMap::new();
		for &key in Settings::OPTIONS {
			let argument = format!("browser-{key}");
			let environment = format!("GLOWCAP_ROOMS_BROWSER_{}", key.replace('-', "_").to_uppercase());
			let selected = options
				.get(&argument)
				.cloned()
				.map(|v| (v, Source::Argument))
				.or_else(|| env(&environment).map(|v| (v, Source::Environment)));
			if let Some((value, source)) = selected {
				let value = value.trim();
				if !value.is_empty() {
					values.insert(key, (value.to_owned(), source));
				}
			}
		}
		let settings = Settings::parse_from(
			|key| values.get(key).cloned(),
			rooms_application::admission::SESSION_ROWS,
			rooms_application::admission::POOLED_AGGREGATE_SCALE,
		)?;
		let overrides: BTreeMap<_, _> = values.into_iter().map(|(key, (value, _))| (key, value)).collect();
		let encoded = serde_json::to_string(&overrides).map_err(|e| e.to_string())?;
		Ok(Self { settings, encoded })
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn deployment_and_embedding_receive_the_same_validated_overrides() {
		let config = Config::read(
			&BTreeMap::from([("browser-admission-rates".into(), "create=64/120".into())]),
			|key| (key == "GLOWCAP_ROOMS_BROWSER_ADMISSION_ROWS").then(|| "123".into()),
		)
		.unwrap();
		let decoded: BTreeMap<String, String> = serde_json::from_str(&config.encoded).unwrap();
		let embedded = Settings::parse(|key| decoded.get(key).cloned(), 4096, 8).unwrap();
		assert_eq!(embedded.rows(), 123);
		assert_eq!(
			embedded
				.profile()
				.rate(rooms_application::admission::Class::Create)
				.burst(),
			64
		);
		assert!(config.settings.summary().contains("admission-rates=argument"));
		assert!(
			Config::read(&BTreeMap::from([("browser-admission-rows".into(), "0".into())]), |_| {
				None
			})
			.is_err()
		);
	}
}
