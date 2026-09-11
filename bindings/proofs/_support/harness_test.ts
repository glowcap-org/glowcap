// Process-owner regression: a diagnostic deadline must unwind through cleanup,
// and cleanup must reap even a child that ignores SIGTERM. This was validated
// against the pre-owner harness: its timer called `Deno.exit`, leaving both the
// fixture peer and a hung client alive under pid 1.

import { awaitMarker, ProofTimeout, runProof } from "./harness.ts";

function expect(condition: boolean, message: string): void {
	if (!condition) throw new Error(message);
}

Deno.test("a proof deadline reaps a SIGTERM-resistant child before it reports", async () => {
	let victimPid = 0;
	let victimPort = 0;
	let failure: unknown = null;
	try {
		await runProof({
			deadlineMs: 1_500,
			killGraceMs: 100,
			timeoutMessage: () => `injected deadline after child ${victimPid} started`,
		}, async (processes) => {
			const victim = processes.spawn(Deno.execPath(), {
				args: [
					"eval",
					'const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 }); Deno.addSignalListener("SIGTERM", () => {}); console.log(`READY ${Deno.pid} ${(listener.addr as Deno.NetAddr).port}`); setInterval(() => {}, 1_000);',
				],
				stdout: "piped",
				stderr: "inherit",
			});
			const marker = await awaitMarker(victim, "READY", "resistant child");
			const [pidText, portText] = marker.split(/\s+/);
			victimPid = Number(pidText);
			victimPort = Number(portText);
			await new Promise<never>(() => {});
		});
	} catch (raised) {
		failure = raised;
	}

	expect(victimPid > 0, "the injected child never reached its ready marker");
	expect(victimPort > 0, "the injected child did not report its held port");
	expect(failure instanceof ProofTimeout, `deadline reported as ${failure}`);
	expect(
		String(failure).includes(`child ${victimPid} started`),
		`deadline lost its live diagnostic: ${failure}`,
	);

	let survived = false;
	let probe: Deno.TcpListener | undefined;
	try {
		// Prove cleanup through release of an operating-system resource rather
		// than signalling a PID that the kernel may already have reused.
		probe = Deno.listen({ hostname: "127.0.0.1", port: victimPort });
	} catch (raised) {
		if (raised instanceof Deno.errors.AddrInUse) survived = true;
		else throw raised;
	} finally {
		probe?.close();
	}
	if (survived) {
		// Keep a red regression run from becoming the process leak it detects.
		try {
			Deno.kill(victimPid, "SIGKILL");
		} catch (raised) {
			if (!(raised instanceof Deno.errors.NotFound)) throw raised;
		}
	}
	expect(
		!survived,
		`child ${victimPid} survived the proof owner's cleanup on port ${victimPort}`,
	);
});
