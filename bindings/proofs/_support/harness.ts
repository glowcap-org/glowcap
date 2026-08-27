// Read a child process's stdout line by line until a marker prefix appears,
// echoing everything so a red run carries the child's own diagnostics, and
// resolve the line's tail. Every proof harness that supervises a peer process
// waits on its announce line this way, and fails the same way when it never
// comes.

export function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

export async function awaitMarker(
	child: Deno.ChildProcess,
	prefix: string,
	who: string,
): Promise<string> {
	const reader = child.stdout.pipeThrough(new TextDecoderStream()).getReader();
	let buffered = "";
	while (true) {
		const { value, done } = await reader.read();
		if (done) fail(`${who} exited before printing ${prefix}`);
		buffered += value;
		let newline: number;
		while ((newline = buffered.indexOf("\n")) !== -1) {
			const line = buffered.slice(0, newline).trim();
			buffered = buffered.slice(newline + 1);
			if (line.length !== 0) console.log(`  [${who}] ${line}`);
			if (line.startsWith(prefix)) {
				// Keep draining in the background so the child never blocks on a
				// full stdout pipe.
				void (async () => {
					try {
						while (!(await reader.read()).done) { /* drain */ }
					} catch { /* child ended */ }
				})();
				return line.slice(prefix.length).trim();
			}
		}
	}
}
