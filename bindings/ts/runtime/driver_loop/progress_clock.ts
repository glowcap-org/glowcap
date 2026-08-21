/** Allocation-neutral JavaScript projection of the native driver's complete
 * pending-work deadline. Native code owns policy; the loop owns the timer slot
 * and these mechanics turn its nearest duration into one scheduler wake. */

import { loopS } from "../internal/ffi/driver.ts";
import type { Ptr } from "../internal/ffi/runtime.ts";
import { ab } from "../internal/seam.ts";
import { checkDriver } from "../internal/driver_failure.ts";

export type DriverProgressTimer = ReturnType<typeof setTimeout> | null;

/** Milliseconds to the nearest close/session/dial/listener deadline, clamped
 * at zero, or -1 while readiness alone can advance terminal progress. */
export function driverStepWaitMs(handle: Ptr): number {
	const out = new Uint8Array(4);
	checkDriver(loopS.pancake_driver_step_wait_ms(handle, ab(out)));
	return new DataView(out.buffer).getInt32(0, true);
}

export function clearProgressClock(timer: DriverProgressTimer): null {
	if (timer != null) clearTimeout(timer);
	return null;
}

export function armProgressClock(
	waitMs: number,
	wake: () => void,
): DriverProgressTimer {
	return waitMs < 0 ? null : setTimeout(wake, waitMs);
}

/** Park until loop activity or the nearest native deadline. The expiry
 * becomes authoritative only when the caller performs its next step. */
export async function waitForProgressClock(
	activity: Promise<void>,
	waitMs: number,
): Promise<void> {
	if (waitMs < 0) {
		await activity;
		return;
	}
	let timer: ReturnType<typeof setTimeout> | undefined;
	const deadline = new Promise<void>((resolve) => {
		timer = setTimeout(resolve, waitMs);
	});
	try {
		await Promise.race([activity, deadline]);
	} finally {
		clearTimeout(timer);
	}
}
