//! Experimental compiler-request adapter, called by interface authoring checks.
//! stdin: one unpacked CodeGeneratorRequest. stdout: canonical Syrup description.
mod schema;
mod syrup;
use std::io::{Read, Write};

const MAX_DESCRIPTION_BYTES: usize = 1024 * 1024;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn translate() -> Result<Vec<u8>> {
	const MAX_INPUT: usize = 1024 * 1024;
	let mut input = Vec::new();
	std::io::stdin().take((MAX_INPUT + 1) as u64).read_to_end(&mut input)?;
	if input.len() > MAX_INPUT {
		return Err("compiler request exceeds 1 MiB".into());
	}
	let mut options = capnp::message::ReaderOptions::new();
	options.traversal_limit_in_words = Some(8 * 1024 * 1024);
	options.nesting_limit = 64;
	let mut reader = std::io::Cursor::new(&input);
	let message = capnp::serialize::read_message(&mut reader, options)?;
	if reader.position() != input.len() as u64 {
		return Err("trailing compiler-request data".into());
	}
	let request = message.get_root::<capnp::schema_capnp::code_generator_request::Reader>()?;
	let output = schema::translate(request)?.encode();
	if output.len() > MAX_DESCRIPTION_BYTES {
		return Err("description exceeds 1 MiB".into());
	}
	Ok(output)
}
fn main() {
	match translate() {
		Ok(output) => {
			if let Err(error) = std::io::stdout().write_all(&output) {
				eprintln!("capnp authoring: {error}");
				std::process::exit(1);
			}
		}
		Err(error) => {
			eprintln!("capnp authoring: {error}");
			std::process::exit(1);
		}
	}
}
