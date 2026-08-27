// Product-level diagnosis for opening a durable Rooms session capability.

import { IO } from "@pancake/abi";
import { PancakeError } from "@pancake/runtime";

export function attachedSessionFailureText(error: unknown): string {
	const reason = error instanceof Error ? error.message : String(error);
	if (
		error instanceof PancakeError && error.code === IO &&
		(error.detail?.includes("NetworkUnreachable") === true || reason.includes("NetworkUnreachable"))
	) {
		return "The shared session peer could not be reached. Make sure it is running and retry the " +
			"capability it currently announces. An iroh session needs either a reachable advertised address " +
			"or working iroh discovery and relay access.";
	}
	if (reason.includes("did not finish the OCapN handshake")) {
		return "The session peer was reached, but it did not finish the OCapN handshake. " +
			"Check that the Rooms session peer is running compatible code, then retry.";
	}
	return reason;
}
