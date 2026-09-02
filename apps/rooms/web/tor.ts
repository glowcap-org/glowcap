// DENO-SPECIFIC: the Tor an onion room server listens through.
//
// glowcap itself starts no Tor: the onion netlayer only receives configured
// SOCKS and control endpoints, the same contract the demo harness
// (`apps/rooms/demos/run-onion.sh`) holds. This module is the web supervisor's
// side of that contract. When the environment already names endpoints
// (`GLOWCAP_ONION_SOCKS` and `GLOWCAP_ONION_CONTROL`), it uses them and owns
// nothing; otherwise it starts a private Tor on Unix sockets under a temporary
// directory, waits for those sockets to appear, and stops the daemon and
// removes the directory on `stop`.

/** Where the room server's onion netlayer finds Tor, plus who cleans it up. */
export interface TorEndpoints {
	readonly socks: string;
	readonly control: string;
	/** Stop the private Tor this module started and remove its state; a no-op
	 * when the endpoints came configured from the environment. */
	stop(): Promise<void>;
}

const SOCKS_ENV = "GLOWCAP_ONION_SOCKS";
const CONTROL_ENV = "GLOWCAP_ONION_CONTROL";

function configured(name: string): string | undefined {
	const allowed = Deno.permissions.querySync({ name: "env", variable: name }).state === "granted";
	if (!allowed) return undefined;
	return Deno.env.get(name)?.trim() || undefined;
}

async function pathExists(path: string): Promise<boolean> {
	try {
		await Deno.lstat(path);
		return true;
	} catch {
		return false;
	}
}

/** The last lines of the private Tor's own log, for an error a person can act
 * on when the daemon dies or never publishes its endpoints. */
async function torLogTail(state: string): Promise<string> {
	try {
		const log = await Deno.readTextFile(`${state}/tor.log`);
		return log.trimEnd().split("\n").slice(-5).join("\n");
	} catch {
		return "(no tor log was written)";
	}
}

/** Endpoints for the onion room server: the environment's when both are named,
 * otherwise a private Tor started here. Throws with a sentence an operator can
 * act on when Tor is missing, dies at startup, or never publishes. */
export async function ensureTor(): Promise<TorEndpoints> {
	const socks = configured(SOCKS_ENV);
	const control = configured(CONTROL_ENV);
	if (socks !== undefined && control !== undefined) {
		return { socks, control, stop: () => Promise.resolve() };
	}
	if (socks !== undefined || control !== undefined) {
		throw new Error(
			`${SOCKS_ENV} and ${CONTROL_ENV} name one Tor together; set both, or neither to start a private one`,
		);
	}

	const state = await Deno.makeTempDir({ prefix: "glowcap-rooms-tor-" });
	const socksPath = `${state}/socks.sock`;
	const controlPath = `${state}/control.sock`;
	const removeState = () => Deno.remove(state, { recursive: true }).catch(() => {});
	let child: Deno.ChildProcess;
	try {
		await Deno.mkdir(`${state}/data`);
		// The onion listener needs an unauthenticated control socket, which a
		// distribution's Tor does not offer, so a private daemon with its own
		// data directory is the reliable shape (the demo harness uses the same
		// torrc). Unix sockets, so no port can collide with another run.
		await Deno.writeTextFile(
			`${state}/torrc`,
			[
				`DataDirectory ${state}/data`,
				`SocksPort unix:${socksPath}`,
				`ControlPort unix:${controlPath}`,
				"CookieAuthentication 0",
				`Log notice file ${state}/tor.log`,
				"",
			].join("\n"),
		);
		child = new Deno.Command("tor", {
			args: ["-f", `${state}/torrc`],
			stdout: "null",
			stderr: "null",
		}).spawn();
	} catch (err) {
		await removeState();
		if (err instanceof Deno.errors.NotFound) {
			throw new Error(
				`the onion transport needs \`tor\` on PATH, or ${SOCKS_ENV} and ${CONTROL_ENV} naming a running Tor's endpoints`,
			);
		}
		throw err;
	}

	// A daemon that dies while we wait has said why in its own log; surface
	// that instead of a bare timeout. Publishing the sockets is fast — this is
	// Tor accepting its config, not building circuits.
	let died = false;
	const exited = child.status.then((status) => {
		died = true;
		return status;
	});
	const stop = async (): Promise<void> => {
		try {
			child.kill("SIGTERM");
		} catch {
			// Already exited; `exited` below is the authority.
		}
		await exited;
		await Deno.remove(state, { recursive: true });
	};
	const deadline = Date.now() + 60_000;
	while (!(await pathExists(socksPath)) || !(await pathExists(controlPath))) {
		if (died) {
			const tail = await torLogTail(state);
			await removeState();
			throw new Error(`the private Tor exited before publishing its endpoints:\n${tail}`);
		}
		if (Date.now() >= deadline) {
			const tail = await torLogTail(state);
			await stop().catch(() => {});
			throw new Error(`the private Tor did not publish its endpoints in time:\n${tail}`);
		}
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
	return { socks: socksPath, control: controlPath, stop };
}
