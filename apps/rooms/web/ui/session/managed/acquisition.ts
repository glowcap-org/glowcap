// Only an explicit acquisition conflict proves absence of custody acquisition.
import { managedSessionText } from "../../../../lib/text/managed_session.ts";

// A proved conflict installed no custody, so re-preparation at a newer
// revision is safe. The bound settles an unstable workspace as a refusal
// instead of an unbounded gesture.
export const MAX_CONFLICT_REPREPARATIONS = 4;

export class AcquisitionConflict extends Error {
	constructor() {
		super(managedSessionText.acquisitionConflict);
	}
}

export async function submitAcquisition(request: { submit(): Promise<unknown> }): Promise<"committed" | "conflict"> {
	const outcome = await request.submit();
	if (outcome !== "committed" && outcome !== "conflict") {
		throw new Error("The access acquisition outcome is unknown. Recover the original request.");
	}
	return outcome;
}
