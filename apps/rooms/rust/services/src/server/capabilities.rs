//! Read the operator capabilities kept on disk without taking server custody.
//! The boot catalog and the state's swiss validator own the printed contract.
use super::{Error, operations::Minted};
use rooms_application::server::operations::{BOOT_CAPABILITIES, is_swiss};
use std::path::PathBuf;

pub struct CapabilityQuery {
	directory: PathBuf,
	locator: glowcap::Locator,
	trace_locator: Option<glowcap::Locator>,
}
impl CapabilityQuery {
	pub fn parse(args: &[String], env: impl Fn(&str) -> Option<String>) -> Result<Option<Self>, Error> {
		let Some(first) = args.first() else { return Ok(None) };
		let directory = if first == "--capabilities" {
			env("GLOWCAP_ROOMS_STATE")
		} else if let Some(path) = first.strip_prefix("--capabilities=") {
			Some(path.to_owned())
		} else {
			return Ok(None);
		};
		if args.len() != 1 {
			return Err(Error::refused(
				"--capabilities takes a state directory, without server options",
			));
		}
		let directory = directory
			.filter(|s| !s.trim().is_empty())
			.ok_or_else(|| Error::refused("use --capabilities=<state-directory> or set GLOWCAP_ROOMS_STATE"))?;
		let trace_locator = env("GLOWCAP_ROOMS_TRACE_LOCATOR")
			.map(|locator| glowcap::parse_locator(&locator))
			.transpose()?;
		if let Some(locator) = &trace_locator {
			let Some(glowcap::HintValue::String(endpoint)) = locator.hints.get("trace-publish") else {
				return Err(Error::refused(
					"the trace locator must advertise its exact trace-publish endpoint",
				));
			};
			rooms_application::server::trace::producer_endpoint(endpoint).map_err(Error::refused)?;
		}
		Ok(Some(Self {
			directory: directory.into(),
			locator: glowcap::parse_locator(&env("GLOWCAP_ROOMS_LOCATOR").ok_or_else(|| {
				Error::refused(
					"set GLOWCAP_ROOMS_LOCATOR to the server's advertised locator when reading durable capability recipes",
				)
			})?)?,
			trace_locator,
		}))
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
			let line = match rooms_platform::storage::read(&self.directory.join(capability.file), 256)? {
				None => format!(
					"{} (not minted here; start with {} to mint it)",
					capability.token, capability.flag
				),
				Some(bytes) => {
					let swiss = std::str::from_utf8(&bytes)
						.ok()
						.map(str::trim)
						.filter(|s| is_swiss(s))
						.ok_or_else(|| {
							Error::refused(format!("{} state is not a complete swiss number", capability.file))
						})?;
					// The timeline's locator is chosen when the server starts
					// (its port and any proxy endpoints), so this offline read
					// can name it only when the operator supplies it. Without
					// it the line says so, like an unminted one, and every
					// other recipe still prints.
					let locator = if capability.id == "trace" {
						self.trace_locator.as_ref()
					} else {
						Some(&self.locator)
					};
					match locator {
						Some(locator) => Minted {
							capability,
							swiss: swiss.into(),
						}
						.line(locator)?,
						None => format!(
							"{} (minted; set GLOWCAP_ROOMS_TRACE_LOCATOR to the timeline's advertised locator to print it)",
							capability.token
						),
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
	fn an_unknown_timeline_locator_names_its_remedy_and_keeps_every_other_recipe() {
		let directory = std::env::temp_dir().join(format!("rooms-capability-read-{}", std::process::id()));
		std::fs::create_dir_all(&directory).unwrap();
		for capability in &BOOT_CAPABILITIES {
			std::fs::write(directory.join(capability.file), "a".repeat(64)).unwrap();
		}
		let args = [format!("--capabilities={}", directory.display())];
		let query = CapabilityQuery::parse(&args, |name| {
			(name == "GLOWCAP_ROOMS_LOCATOR").then(|| "ocapn://directory.id".to_owned())
		})
		.unwrap()
		.unwrap();
		let printed = query.read().unwrap();
		std::fs::remove_dir_all(&directory).unwrap();
		for capability in &BOOT_CAPABILITIES {
			let line = printed.lines().find(|line| line.starts_with(capability.token)).unwrap();
			if capability.id == "trace" {
				assert!(line.contains("set GLOWCAP_ROOMS_TRACE_LOCATOR"), "{line}");
			} else {
				assert!(line.contains("ocapn://directory.id"), "{line}");
			}
		}
	}
}
