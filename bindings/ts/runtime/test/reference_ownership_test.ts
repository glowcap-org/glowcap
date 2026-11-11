// Failed reference adoption returns its native retain to the Host release queue.
import { HostGc } from "../gc.ts";
import { secondaryFailures } from "../errors.ts";
import type { Ref } from "../value.ts";
import { assert, assertEquals } from "../../test/assert.ts";

Deno.test("reference adoption parks its retain when finalizer registration fails", () => {
	for (const refusesSchedule of [false, true]) {
		const failure = new Error("registration refused");
		const cleanup = new Error("scheduler refused");
		class RefusingGc extends HostGc {
			override trackRef(ref: Ref): Ref {
				super.trackRef(ref);
				throw failure;
			}
		}
		const gc = new RefusingGc();
		gc.bind({
			released: false,
			hostRaw: 0n,
			kick() {},
			recordFailure(error) {
				throw error;
			},
			abandonVow() {},
			scheduleDrain() {
				if (refusesSchedule) throw cleanup;
			},
		});
		let observed: unknown;
		try {
			gc.adoptRef(19n);
		} catch (error) {
			observed = error;
		}
		assert(observed === failure, "adoption replaced its original failure");
		assertEquals(gc.pending.length, 1);
		assertEquals(gc.pending[0], 19n);
		if (refusesSchedule) assert(secondaryFailures(failure).includes(cleanup), "cleanup failure was lost");
	}
});
