//! Read the operator capabilities kept on disk without taking server custody.
//! The boot catalog and the state's swiss validator own the printed contract.
use super::{Error, operations::Minted};
use rooms_application::server::operations::{BOOT_CAPABILITIES, Kind, is_swiss};
use std::path::PathBuf;

/// Where the timeline's locator comes from. It is chosen when the server
/// starts (its port and any proxy endpoints), so an offline read knows it only
/// when the operator supplies it, and the trace line says which case it is in
/// when there is none.
pub enum TraceLocator {
	Advertised(glowcap::Locator),
	/// The running front answered that no timeline is up.
	NotRunning,
	/// Nothing running was asked, and the environment named none.
	Unknown,
}

pub struct CapabilityQuery {
	directory: PathBuf,
	locator: glowcap::Locator,
	trace: TraceLocator,
}
impl CapabilityQuery {
	/// The locators `GLOWCAP_ROOMS_LOCATOR` and `GLOWCAP_ROOMS_TRACE_LOCATOR`
	/// supply. With the first set, the environment is the whole answer, and a
	/// trace locator it leaves out stays unknown. `None` when it is unset, so
	/// a caller may read both from a running front instead.
	pub(crate) fn environment_locators(
		env: impl Fn(&str) -> Option<String>,
	) -> Result<Option<(glowcap::Locator, TraceLocator)>, Error> {
		let Some(locator) = env("GLOWCAP_ROOMS_LOCATOR") else {
			return Ok(None);
		};
		let trace = match env("GLOWCAP_ROOMS_TRACE_LOCATOR") {
			Some(trace) => TraceLocator::Advertised(glowcap::parse_locator(&trace)?),
			None => TraceLocator::Unknown,
		};
		Ok(Some((glowcap::parse_locator(&locator)?, trace)))
	}
	/// A read of `directory` that prints each link against the directory's
	/// `locator`, and the timeline's against `trace` when it is advertised.
	pub(crate) fn new(directory: PathBuf, locator: glowcap::Locator, trace: TraceLocator) -> Result<Self, Error> {
		if let TraceLocator::Advertised(locator) = &trace {
			let Some(glowcap::HintValue::String(endpoint)) = locator.hints.get("trace-publish") else {
				return Err(Error::refused(
					"the trace locator must advertise its exact trace-publish endpoint",
				));
			};
			rooms_application::server::trace::producer_endpoint(endpoint).map_err(Error::refused)?;
		}
		Ok(Self {
			directory,
			locator,
			trace,
		})
	}
	pub async fn run(self) -> Result<String, Error> {
		tokio::task::spawn_blocking(move || self.read())
			.await
			.map_err(|e| Error::Worker(e.to_string()))?
	}
	fn read(self) -> Result<String, Error> {
		if !std::fs::metadata(&self.directory)?.is_dir() {
			return Err(Error::refused("capability state must be a directory"));
		}
		let mut lines = Vec::new();
		for capability in &BOOT_CAPABILITIES {
			let line = match rooms_platform::storage::read(&self.directory.join(capability.name), 256)? {
				None => format!(
					"{} (not minted here; start with --capabilities={} to mint it)",
					capability.token, capability.name
				),
				Some(bytes) => {
					let swiss = std::str::from_utf8(&bytes)
						.ok()
						.map(str::trim)
						.filter(|s| is_swiss(s))
						.ok_or_else(|| {
							Error::refused(format!("{} state is not a complete swiss number", capability.name))
						})?;
					let minted = Minted {
						capability,
						swiss: swiss.into(),
					};
					// Without the timeline's locator its line says why, like
					// an unminted one, and every other link still prints.
					if capability.kind != Kind::Trace {
						minted.line(&self.locator)?
					} else {
						match &self.trace {
							TraceLocator::Advertised(locator) => minted.line(locator)?,
							TraceLocator::NotRunning => format!(
								"{} (kept here, not running; start with --capabilities=trace to serve it)",
								capability.token
							),
							TraceLocator::Unknown => format!(
								"{} (minted; set GLOWCAP_ROOMS_TRACE_LOCATOR to the timeline's advertised locator to print it)",
								capability.token
							),
						}
					}
				}
			};
			lines.push(line);
		}
		Ok(lines.join("\n"))
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn an_unknown_timeline_locator_names_its_remedy_and_keeps_every_other_link() {
		let directory = rooms_testing::scratch::Scratch::create("capability-read");
		for capability in &BOOT_CAPABILITIES {
			std::fs::write(directory.join(capability.name), "a".repeat(64)).unwrap();
		}
		let (locator, trace) = CapabilityQuery::environment_locators(|name| {
			(name == "GLOWCAP_ROOMS_LOCATOR").then(|| "ocapn://directory.id".to_owned())
		})
		.unwrap()
		.unwrap();
		let printed = CapabilityQuery::new(directory.to_path_buf(), locator, trace)
			.unwrap()
			.read()
			.unwrap();
		for capability in &BOOT_CAPABILITIES {
			let line = printed.lines().find(|line| line.starts_with(capability.token)).unwrap();
			if capability.kind == Kind::Trace {
				assert!(line.contains("set GLOWCAP_ROOMS_TRACE_LOCATOR"), "{line}");
			} else {
				assert!(line.contains("ocapn://directory.id"), "{line}");
			}
		}
		// A front that answered with no timeline names the start option, not
		// a variable, because the server already said the timeline is off.
		let locator = glowcap::parse_locator("ocapn://directory.id").unwrap();
		let printed = CapabilityQuery::new(directory.to_path_buf(), locator, TraceLocator::NotRunning)
			.unwrap()
			.read()
			.unwrap();
		let line = printed.lines().find(|line| line.starts_with("ROOMS-TRACE")).unwrap();
		assert!(line.contains("--capabilities=trace"), "{line}");
	}
}
