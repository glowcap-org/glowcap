// The one way a rooms test or proof fails: say why, then throw.
//
// It throws rather than exiting because `Deno.exit` skips every `finally` on
// the way out, and a proof's `finally` is what stops the servers it started. A
// failing check has to fail, not hang on a child holding the inherited stdout
// pipe. `zig build source-check` refuses any other exit under the test tree.

export function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	throw new Error(message);
}
