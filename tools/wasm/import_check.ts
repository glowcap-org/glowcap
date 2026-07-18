// Gate: the browser binding's wasm32 module imports exactly one thing.
//
// The freestanding wasm32 Host (`zig build wasm-driver`, ADR-0070) declares a
// single synchronous import — `env.pancake_behavior_trampoline` — the one
// behavior-dispatch seam the browser adapter implements (every wasm-hosted
// object registers this shared trampoline and is told apart by its `ctx`). The
// module is otherwise self-contained: it draws no entropy, owns no I/O, and
// carries no other host callback. A second import creeping in — an accidental
// libc dependency, a new unfulfilled seam, or a rename of this one — changes the
// contract the adapter's import object must satisfy, so it must fail the build
// rather than surface as an instantiation error in a browser.
//
// This reads the import section statically (`WebAssembly.Module.imports`), so it
// needs no import object and never instantiates — the import being unsatisfied
// is exactly the state under test.

const wasmPath = new URL("../../zig-out/wasm/pancake_driver.wasm", import.meta.url);

const EXPECTED = { module: "env", name: "pancake_behavior_trampoline", kind: "function" };

function fail(msg: string): never {
	console.error("wasm-import-check: " + msg);
	Deno.exit(1);
}

const bytes = await Deno.readFile(wasmPath);
const mod = new WebAssembly.Module(bytes);
const imports = WebAssembly.Module.imports(mod);

if (imports.length !== 1) {
	const list = imports.map((i) => `${i.module}.${i.name} (${i.kind})`).join(", ");
	fail(`expected exactly 1 import, found ${imports.length}: [${list}]`);
}

const only = imports[0];
if (only.module !== EXPECTED.module || only.name !== EXPECTED.name || only.kind !== EXPECTED.kind) {
	fail(
		`import mismatch: expected ${EXPECTED.module}.${EXPECTED.name} (${EXPECTED.kind}), ` +
			`found ${only.module}.${only.name} (${only.kind})`,
	);
}

console.log(
	`wasm-import-check: sole import is ${only.module}.${only.name} (${only.kind}) — contract holds.`,
);
