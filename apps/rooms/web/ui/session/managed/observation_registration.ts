// How a page starts observing a workspace: the first start and every new link
// register an observation the same way.
import type {
	RoomsManagedObservation,
	RoomsManagedObservationRequest,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";

/** Register a new observation of `workspace`, and release its request. With
 * `keep`, the request stays held while its submission is unanswered, so its
 * owner can submit it again. Without, a failed submission releases it. */
export async function registerObservation(
	workspace: RoomsManagedWorkspace,
	keep?: (request: RoomsManagedObservationRequest | null) => void,
): Promise<RoomsManagedObservation> {
	const registering: RoomsManagedObservationRequest = await workspace.prepareObservation();
	keep?.(registering);
	try {
		const observation = await registering.submit();
		registering.free();
		keep?.(null);
		return observation;
	} catch (error) {
		if (keep == null) registering.free();
		throw error;
	}
}
