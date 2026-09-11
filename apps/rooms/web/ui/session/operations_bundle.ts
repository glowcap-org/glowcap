// Display a bundle from the shared checkpoint policy.
import type { RoomsSessionState } from "../../../lib/rooms_state.ts";
import { applicationModule } from "../application.ts";

export function attachedOperationsView(checkpoint: RoomsSessionState): { bundle: string; context: string } {
	return JSON.parse(applicationModule().operationsBundleView(JSON.stringify(checkpoint))) as {
		bundle: string;
		context: string;
	};
}
export function attachedOperationsBundle(checkpoint: RoomsSessionState): string {
	return attachedOperationsView(checkpoint).bundle;
}
