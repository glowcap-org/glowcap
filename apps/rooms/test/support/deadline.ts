// A scenario's whole-run deadline, which says where the run stood when it
// fired.
//
// A scenario's own waits each carry a bound and a message, and their bounds
// add up to more than the run is allowed. So a run can stall across several
// waits and meet this deadline before any of them reports. The scenario names
// each part as it starts, and the deadline's failure carries the last name.

import { fail } from "./fail.ts";

interface Deadline {
	/** Names the part of the scenario that starts here. */
	at(part: string): void;
	clear(): void;
}

export function scenarioDeadline(name: string, seconds: number): Deadline {
	let part = "starting";
	const timer = setTimeout(
		() => fail(`${name} scenario timed out after ${seconds}s while ${part}`),
		seconds * 1000,
	);
	return {
		at: (next) => {
			part = next;
		},
		clear: () => clearTimeout(timer),
	};
}
