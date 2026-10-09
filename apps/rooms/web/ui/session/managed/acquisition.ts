// Only an explicit acquisition conflict proves absence of custody acquisition.
import { managedSessionText } from "../../../../lib/text/managed_session.ts";
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
