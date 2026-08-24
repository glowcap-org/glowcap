// Shared Deno.test wrapper for Engine-constructing cases.
//
// d3-force (used by KeyframeLayoutSystem at engine construction)
// schedules a d3-timer via setTimeout under Deno (no
// requestAnimationFrame in the test env). `simulation.stop()`
// cancels the timer logically but the platform handle lingers past
// the synchronous test, which Deno's resource sanitizer flags as a
// leak. Harmless in the browser (where rAF is used); disable
// sanitizers for these Engine-constructing tests.

export function engineTest(name: string, fn: () => void | Promise<void>): void {
	Deno.test({
		name,
		sanitizeOps: false,
		sanitizeResources: false,
		fn,
	});
}
