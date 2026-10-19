// Gate: the browser binding's wasm32 module imports exactly its two hosted-
// object callbacks.
//
// The freestanding wasm32 Host (`zig build wasm-driver`, ADR-0034) declares a
// two synchronous imports: behavior dispatch and hosted-actor retirement. The
// module is otherwise self-contained: it draws no entropy, owns no I/O, and
// carries no other host callback. Another import creeping in, an accidental
// libc dependency, a new unfulfilled seam, or a rename of either one, changes the
// contract the adapter's import object must satisfy, so it must fail the build
// rather than surface as an instantiation error in a browser.
//
// This reads the import section statically (`WebAssembly.Module.imports`), so it
// needs no import object and never instantiates, the import being unsatisfied
// is exactly the state under test.

const wasmPath = new URL("../../zig-out/wasm/glowcap_host.wasm", import.meta.url);

const EXPECTED = [
	{ module: "env", name: "glowcap_behavior_trampoline", kind: "function" },
	{ module: "env", name: "glowcap_hosted_free_trampoline", kind: "function" },
];

function fail(msg: string): never {
	console.error("wasm-import-check: " + msg);
	Deno.exit(1);
}

const bytes = await Deno.readFile(wasmPath);
const mod = new WebAssembly.Module(bytes);
const imports = WebAssembly.Module.imports(mod);

if (imports.length !== EXPECTED.length) {
	const list = imports.map((i) => `${i.module}.${i.name} (${i.kind})`).join(", ");
	fail(`expected exactly ${EXPECTED.length} imports, found ${imports.length}: [${list}]`);
}

const label = (item: { module: string; name: string; kind: string }) => `${item.module}.${item.name} (${item.kind})`;
const expectedLabels = EXPECTED.map(label).sort();
const actualLabels = imports.map(label).sort();
if (actualLabels.join("\n") !== expectedLabels.join("\n")) {
	fail(`import mismatch: expected [${expectedLabels.join(", ")}], found [${actualLabels.join(", ")}]`);
}

console.log(
	`wasm-import-check: exact hosted callback imports (${
		EXPECTED.map((item) => item.name).join(", ")
	}) — contract holds.`,
);
