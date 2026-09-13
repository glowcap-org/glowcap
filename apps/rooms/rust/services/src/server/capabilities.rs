//! Read the operator capabilities kept on disk without taking server custody.
//! The boot catalog and the state's swiss validator own the printed contract.
use super::{Error, operations::Minted};
use rooms_application::server::operations::{BOOT_CAPABILITIES, is_swiss};
use std::path::PathBuf;

pub struct CapabilityQuery {
	directory: PathBuf,
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
		Ok(Some(Self {
			directory: directory.into(),
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
					Minted {
						capability,
						swiss: swiss.into(),
					}
					.line()
				}
			};
			lines.push(line);
		}
		Ok(lines.join("\n"))
	}
}
