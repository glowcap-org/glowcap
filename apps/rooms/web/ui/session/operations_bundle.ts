// Projection between one attached session's credential vault and bundle UI.

import type { RoomsSessionState } from "../../../lib/rooms_state.ts";
import { formatOpsBundle, type OpsBundleDraft } from "../ops/bundle.ts";
import type { OpsCap } from "../types.ts";

export function attachedOperationsBundle(checkpoint: RoomsSessionState): string {
	const home = checkpoint.directories.find((directory) => directory.home)?.id;
	const found = new Map<OpsCap, string>();
	for (const credential of checkpoint.capabilities.operations) {
		if (credential.capability === "viz" || credential.scope === home) {
			found.set(credential.capability, credential.swiss);
		}
	}
	return formatOpsBundle(found);
}

export async function attachedOperationsCredentials(
	checkpoint: RoomsSessionState,
	draft: OpsBundleDraft,
	advertisedViz: () => Promise<string | null>,
): Promise<RoomsSessionState["capabilities"]["operations"]> {
	const home = checkpoint.directories.find((directory) => directory.home)?.id;
	if (home == null) {
		throw new Error("Join a room on this directory before saving its operation capabilities.");
	}
	let vizScope = checkpoint.capabilities.operations.find((credential) => credential.capability === "viz")?.scope ??
		checkpoint.vizOverride;
	if (draft.has("viz") && vizScope === "") {
		vizScope = await advertisedViz() ?? "";
		if (vizScope === "") {
			throw new Error("This page has no live timeline endpoint to scope the visualizer capability to.");
		}
	}
	const preserved = checkpoint.capabilities.operations.filter((credential) =>
		credential.capability !== "viz" && credential.scope !== home
	);
	const replacement = [...draft].map(([capability, swiss]) => ({
		capability,
		scope: capability === "viz" ? vizScope : home,
		swiss,
	}));
	return [...preserved, ...replacement];
}
