#[tokio::main(flavor = "current_thread")]
async fn main() {
	let arguments: Vec<_> = std::env::args().skip(1).collect();
	if arguments.as_slice() == ["--help"] || arguments.as_slice() == ["-h"] {
		print!("{}", rooms_native::chat::HELP);
		return;
	}
	let [locator, room, nick] = arguments.as_slice() else {
		eprint!("{}", rooms_native::chat::HELP);
		std::process::exit(2);
	};
	let result = tokio::task::LocalSet::new()
		.run_until(rooms_native::chat::run(locator, room, nick))
		.await;
	if let Err(error) = result {
		eprintln!("rooms chat: {error}");
		std::process::exit(1);
	}
}
