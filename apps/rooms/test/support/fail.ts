// The one way a rooms test or proof fails: say why, then throw.
//
// It throws rather than exiting because `Deno.exit` skips every `finally` on
// the way out, and a proof's `finally` is what stops the servers it started. A
// failing check has to fail, not hang on a child holding the inherited stdout
// pipe. `zig build source-check` refuses any exit under the test tree other than
// `Deno.exit(0)` after cleanup, and any second `fail`.

export function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	throw new Error(message);
}
