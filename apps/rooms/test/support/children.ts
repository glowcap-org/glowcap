// The child processes a rooms proof owns, and the one place they are reaped.
//
// These proofs spawn servers that bind real loopback ports, and one of them,
// `serve.ts`, supervises a room server of its own. A child left behind holds
// its port for as long as the container lives, and the run that eventually
// cannot bind fails a long way from the run that leaked. Fifteen of them
// stacked up over five gate runs before anyone counted, so how a spawned server
// dies is not something each proof gets to answer for itself.
//
// Owned means the whole tree. Signalling only the process we spawned leaves
// `serve.ts`'s room server behind whenever `serve.ts` goes without running its
// own shutdown, and it races the respawn loop even when it does. So every child
// starts under `setsid` and leads a process group of its own, and the reap
// signals that group by negative pid.
//
// That negative pid can only ever mean one of two things, which is what makes
// it safe to send even to a child that has already exited. A process group is
// named by its leader's pid, the leader here is the child we spawned, and the
// kernel keeps that number reserved for as long as any member of the group is
// still alive. So the signal reaches this proof's own group, or it reaches
// nothing at all and reports no such process. It cannot reach a stranger's.
//
// Ending is not only returning or throwing. Deno runs no `unload` handler after
// an uncaught error, and a signal with a listener on it stops terminating the
// process, so the reap hangs off five doors: the `finally` a proof writes, the
// `error` and `unhandledrejection` events, `unload`, and SIGINT, SIGTERM and
// SIGHUP. Only the first of those can wait, so it is the only polite one. It
// asks the group to stop, gives it a bounded moment, and escalates. The other
// four have no turn of the event loop left to wait in, so they go straight to
// SIGKILL, which is the right trade when the harness is already dying.
//
// A harness killed with SIGKILL still leaks, because nothing a parent process
// writes can outlive that signal.

/** How long a group gets to stop politely before it is killed. */
const GRACE_MS = 3_000;

/** The signals the harness answers by reaping. */
const REAPING_SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"] as const;

/** What a signal-terminated shell reports, so an interrupted proof exits the
 * way an uninterrupted one that failed would. */
const INTERRUPTED_EXIT_CODE = 130;

const owned = new Set<Deno.ChildProcess>();
let doorsOpen = false;

/** Start a child this proof owns, in a process group of its own.
 *
 * Takes what `new Deno.Command(command, options).spawn()` takes and answers the
 * same child, so a caller reads its stdout, awaits its `status`, and reports its
 * pid unchanged. The one difference is that it is now reaped with its own
 * children whichever way this proof ends.
 *
 * Wants `setsid` on the path. Without it the spawn fails outright, which is the
 * report we want: a proof that quietly lost its group would leak again. */
export function spawnOwned(command: string, options: Deno.CommandOptions = {}): Deno.ChildProcess {
	openDoors();
	const { args = [], ...rest } = options;
	const proc = new Deno.Command("setsid", { ...rest, args: [command, ...args] }).spawn();
	owned.add(proc);
	return proc;
}

/** Stop one owned child and everything it started, then wait for it.
 *
 * Polite first, because a room server given the chance removes the temporary
 * state directory it made and `serve.ts` takes its own child down with it. A
 * group still standing after the grace period is killed instead: a child that
 * will not answer a signal is a defect, and hanging here would hide it behind a
 * run that never ends. */
export async function stopOwned(proc: Deno.ChildProcess, graceMs = GRACE_MS): Promise<void> {
	owned.delete(proc);
	signalTree(proc, "SIGTERM");
	let timer: ReturnType<typeof setTimeout> | undefined;
	const grace = new Promise<false>((settle) => {
		timer = setTimeout(() => settle(false), graceMs);
	});
	try {
		const stopped = await Promise.race([proc.status.then(() => true as const), grace]);
		// Still up, so the group still has members and its id still names it.
		// The hard signal therefore reaches every straggler under this child.
		if (!stopped) signalTree(proc, "SIGKILL");
	} finally {
		clearTimeout(timer);
	}
	await proc.status;
	closeDoors();
}

/** Stop everything this proof owns. The line a `finally` runs. */
export async function reapOwned(graceMs = GRACE_MS): Promise<void> {
	await Promise.all([...owned].map((proc) => stopOwned(proc, graceMs)));
}

/** Signal a child and the group it leads. Both, because the group signal is
 * the one that reaches a supervised grandchild while the direct signal is the
 * one that still works if this child never became a group leader. */
function signalTree(proc: Deno.ChildProcess, signal: Deno.Signal): void {
	try {
		Deno.kill(-proc.pid, signal);
	} catch {
		// No such group: everything under this child has already gone.
	}
	try {
		proc.kill(signal);
	} catch {
		// Already exited, and not yet awaited.
	}
}

/** Reap without waiting, for the doors that have no time left to wait in. */
function reapNow(): void {
	for (const proc of owned) signalTree(proc, "SIGKILL");
	owned.clear();
}

/** Open the doors on the first child, so a proof that spawns nothing installs
 * nothing. The signal listeners in particular hold the event loop open, which
 * is why `closeDoors` takes them away again once nothing is owned. */
function openDoors(): void {
	if (doorsOpen) return;
	doorsOpen = true;
	globalThis.addEventListener("error", reapNow);
	globalThis.addEventListener("unhandledrejection", reapNow);
	globalThis.addEventListener("unload", reapNow);
	for (const signal of REAPING_SIGNALS) Deno.addSignalListener(signal, onSignal);
}

function closeDoors(): void {
	if (!doorsOpen || owned.size > 0) return;
	doorsOpen = false;
	globalThis.removeEventListener("error", reapNow);
	globalThis.removeEventListener("unhandledrejection", reapNow);
	globalThis.removeEventListener("unload", reapNow);
	for (const signal of REAPING_SIGNALS) Deno.removeSignalListener(signal, onSignal);
}

function onSignal(): void {
	reapNow();
	Deno.exit(INTERRUPTED_EXIT_CODE);
}
