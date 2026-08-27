// The tools showcase's thesis, held hermetically: attenuation refuses the
// unsafe verb, and revocation severs a handle so every later call breaks.
//
// The cross-language demo proves all three properties — delegation included —
// over a live session, but it is not on the ordinary gate. Delegation is a wire
// property (handing a spawned reference across a session), so it stays with the
// demo; attenuation and revocation are pure `Tool -> Tool` transforms, and those
// are what this pins on `check`. Validated against a defect: letting `readOnly`
// forward WRITE, or `revocable` ignore its lever, fails the matching case here.

import { makeFiles, readOnly, revocable, toolFor } from "./capabilities.ts";
import { READ, WRITE } from "./protocol.ts";

function assert(condition: boolean, message: string): void {
	if (!condition) throw new Error(message);
}

function throws(action: () => unknown, needle: string, message: string): void {
	try {
		action();
	} catch (error) {
		const text = error instanceof Error ? error.message : String(error);
		assert(text.includes(needle), `${message}: threw "${text}", expected to mention "${needle}"`);
		return;
	}
	assert(false, `${message}: did not throw`);
}

Deno.test("attenuation forwards the safe verb and refuses the rest", () => {
	const view = readOnly(makeFiles());
	assert(view(READ, ["report.txt"]) === "all systems nominal", "read passes through the read-only view");
	throws(() => view(WRITE, ["report.txt", "tampered"]), "attenuated", "write through a read-only view");
	// The attenuation is real: the underlying file is unchanged, because the
	// write never reached it.
	const full = makeFiles();
	full(WRITE, ["report.txt", "changed"]);
	assert(full(READ, ["report.txt"]) === "changed", "the un-attenuated tool still writes");
});

Deno.test("revocation works before the lever and breaks after it", () => {
	const { behavior, revoke } = revocable(makeFiles());
	assert(behavior(READ, ["report.txt"]) === "all systems nominal", "the handle works before revoke");
	revoke();
	throws(() => behavior(READ, ["report.txt"]), "revoked", "any call after revoke");
});

Deno.test("toolFor hands out the read-only files view under its own name", () => {
	throws(() => toolFor("files-readonly")(WRITE, ["x", "y"]), "attenuated", "the named read-only tool refuses write");
	assert(toolFor("files")(WRITE, ["x", "y"]) === "ok", "the full files tool writes");
});
