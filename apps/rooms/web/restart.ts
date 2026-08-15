// How long the web front waits before starting its room server again.
//
// The front supervises one room server: when it exits, the front brings it
// back. Two very different things arrive at that decision. A server that had
// been serving for a while and then died is an accident, and a reader waiting
// on the page wants it back at once. A server that cannot bind its port or
// reach its state directory says so and exits immediately, and starting it
// again as fast as it can fail is a spawn loop: it floods the console, keeps a
// core busy, and buries the one message that says what is wrong under thousands
// of copies of itself.
//
// So the wait is a function of how long the last one ran, and it lives here
// rather than inside the loop because it is the part with an answer worth
// checking. `serve.ts` starts servers when it is imported, which leaves nothing
// in it reachable from a test.

/** How long a room server has to have run for its exit to count as an accident
 * rather than a refusal to start. */
export const RESTART_STEADY_MS = 5_000;
/** The first wait after a server that never got going, and the ceiling the
 * doubling stops at. The ceiling is what keeps a server that is down for the
 * afternoon from waiting hours for the attempt that would find it back. */
export const RESTART_FIRST_WAIT_MS = 500;
export const RESTART_MAX_WAIT_MS = 30_000;

/** The wait before the next start, given the wait before this one and how long
 * the server it started ran for. Zero means start again now. */
export function nextRestartWait(previous: number, ranForMs: number): number {
	if (ranForMs >= RESTART_STEADY_MS) return 0;
	if (previous <= 0) return RESTART_FIRST_WAIT_MS;
	return Math.min(previous * 2, RESTART_MAX_WAIT_MS);
}
