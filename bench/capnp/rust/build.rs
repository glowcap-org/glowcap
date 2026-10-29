fn main() {
	capnpc::CompilerCommand::new()
		.src_prefix("..")
		.file("../echo.capnp")
		.run()
		.expect("compiling echo.capnp");
}
