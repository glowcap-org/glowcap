// Shared process ownership for binding proof harnesses.
//
// A proof process is a tree, not one pid: Cargo, a shell client, or another
// harness may spawn the executable that holds sockets and identity
// state. Every child therefore runs behind `tools/run-with-timeout.py`, whose
// process-group contract is black-boxed by `zig build timeout-runner-test`.
// `runProof` owns those wrappers, races the whole scenario against its local
// diagnostic deadline, and always joins every wrapper before reporting a
// failure. A timer never calls `Deno.exit` while children are live.

const TIMEOUT_WRAPPER = new URL("../../../tools/run-with-timeout.py", import.meta.url).pathname;

const CHILD_FALLBACK_DEADLINE = "5m";
const DEFAULT_KILL_GRACE_MS = 1_000;

export interface ChildOptions {
	args?: string[];
	cwd?: string | URL;
	env?: Record<string, string>;
	clearEnv?: boolean;
	stdin?: "piped" | "inherit" | "null";
	stdout?: "piped" | "inherit" | "null";
	stderr?: "piped" | "inherit" | "null";
}

export interface ProofRunOptions {
	deadlineMs: number;
	timeoutMessage: () => string;
	killGraceMs?: number;
}

export class ProofFailure extends Error {
	constructor(message: string) {
		super(message);
		this.name = "ProofFailure";
	}
}

export class ProofTimeout extends ProofFailure {
	constructor(message: string) {
		super(message);
		this.name = "ProofTimeout";
	}
}

export function fail(message: string): never {
	console.error(`FAIL: ${message}`);
	Deno.exit(1);
}

function failureMessage(raised: unknown): string {
	return raised instanceof Error ? raised.message : String(raised);
}

/** The sole owner of every process tree a proof starts. */
export class ProofProcesses {
	readonly #killGrace: string;
	readonly #active = new Set<Deno.ChildProcess>();
	readonly #statuses = new WeakMap<Deno.ChildProcess, Promise<Deno.CommandStatus>>();
	#closed = false;

	constructor(killGraceMs = DEFAULT_KILL_GRACE_MS) {
		if (!Number.isFinite(killGraceMs) || killGraceMs < 0) {
			throw new TypeError("proof child kill grace must be a finite nonnegative duration");
		}
		this.#killGrace = `${killGraceMs / 1_000}s`;
	}

	/** Start one command in a process group owned by the timeout wrapper. */
	spawn(command: string, options: ChildOptions = {}): Deno.ChildProcess {
		if (this.#closed) throw new ProofFailure("proof tried to spawn a child during teardown");
		const { args = [], ...stdio } = options;
		const child = new Deno.Command("python3", {
			...stdio,
			args: [
				TIMEOUT_WRAPPER,
				"--kill-after",
				this.#killGrace,
				CHILD_FALLBACK_DEADLINE,
				command,
				...args,
			],
		}).spawn();
		const status = child.status;
		this.#active.add(child);
		this.#statuses.set(child, status);
		status.then(
			() => this.#active.delete(child),
			() => this.#active.delete(child),
		);
		return child;
	}

	/** The cached status promise whose settlement also retires ownership. */
	status(child: Deno.ChildProcess): Promise<Deno.CommandStatus> {
		const status = this.#statuses.get(child);
		if (status === undefined) throw new ProofFailure("proof does not own this child");
		return status;
	}

	/** Stop and join one child tree before the rest of the proof continues. */
	async stop(child: Deno.ChildProcess): Promise<Deno.CommandStatus> {
		const status = this.status(child);
		if (this.#active.has(child)) {
			try {
				child.kill("SIGTERM");
			} catch { /* already gone */ }
		}
		return await status;
	}

	/** Stop and join every live child tree. Safe to call more than once. */
	async close(): Promise<void> {
		if (this.#closed) return;
		this.#closed = true;
		const active = [...this.#active];
		for (const child of active) {
			try {
				child.kill("SIGTERM");
			} catch { /* already gone */ }
		}
		await Promise.all(active.map((child) => this.status(child)));
	}
}

/**
 * Run one complete proof under a diagnostic deadline and one process owner.
 * Reporting happens only after the owner's `finally` has joined every child.
 */
export async function runProof<T>(
	options: ProofRunOptions,
	body: (processes: ProofProcesses) => Promise<T>,
): Promise<T> {
	const processes = new ProofProcesses(options.killGraceMs);
	let deadline: ReturnType<typeof setTimeout> | undefined;
	const timedOut = new Promise<never>((_resolve, reject) => {
		deadline = setTimeout(
			() => reject(new ProofTimeout(options.timeoutMessage())),
			options.deadlineMs,
		);
	});
	try {
		return await Promise.race([body(processes), timedOut]);
	} finally {
		if (deadline !== undefined) clearTimeout(deadline);
		await processes.close();
	}
}

/** Run a supervised proof and report its failure after cleanup. */
export async function runProofOrFail<T>(
	options: ProofRunOptions,
	body: (processes: ProofProcesses) => Promise<T>,
): Promise<T> {
	try {
		return await runProof(options, body);
	} catch (raised) {
		fail(failureMessage(raised));
	}
}

// Read a child process's stdout line by line until a marker prefix appears,
// echoing everything so a red run carries the child's own diagnostics, and
// resolve the line's tail. Failure throws into `runProof`; it never exits past
// the process owner's cleanup.
export async function awaitMarker(
	child: Deno.ChildProcess,
	prefix: string,
	who: string,
): Promise<string> {
	const reader = child.stdout.pipeThrough(new TextDecoderStream()).getReader();
	let buffered = "";
	while (true) {
		const { value, done } = await reader.read();
		if (done) throw new ProofFailure(`${who} exited before printing ${prefix}`);
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
