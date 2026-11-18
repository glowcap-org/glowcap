// Host effect for Wasm.imports. Reflection reads declarations without running the module.
io_eff(CID(Wasm.imports), (path) => {
	let imports;
	try {
		const bytes = require("node:fs").readFileSync(path);
		imports = WebAssembly.Module.imports(new WebAssembly.Module(bytes));
	} catch (error) {
		return { $: CID(Fail), error: error.message };
	}

	let tail = { $: CID(Nil) };
	for (let i = imports.length - 1; i >= 0; i--) {
		const { module, name, kind } = imports[i];
		tail = { $: CID(Con), head: { $: CID(Import), module, name, kind }, tail };
	}
	return io_done(tail);
});
