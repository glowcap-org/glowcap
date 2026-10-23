//! The executable's readiness announcement. An unread stdout is reported on
//! stderr and never ends the process.

pub fn announce(text: &str) {
	if let Err(error) = rooms_services::announce::announce(text) {
		eprintln!("rooms: nobody read the readiness announcement on stdout: {error}");
	}
}
