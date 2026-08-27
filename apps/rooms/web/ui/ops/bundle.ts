// The labelled capability block printed by a Rooms server.

import { operationsSwiss } from "../../../lib/operations.ts";
import { ALL_BOOT_CAPS } from "../../../lib/boot_caps.ts";
import type { OpsCap } from "../types.ts";

export const OPS_BUNDLE_CAPABILITIES = ALL_BOOT_CAPS.map((definition) => ({
	capability: definition.id as OpsCap,
	token: definition.token,
}));

const LABELS = new Map(OPS_BUNDLE_CAPABILITIES.map(({ token, capability }) => [token, capability]));

export type OpsBundleDraft = ReadonlyMap<OpsCap, string>;

/** Parse the editable form. Whitespace separates grammar and is canonicalized;
 * unrelated text is never dropped. A label without a value is a real enabled
 * row whose field still needs completing. */
export function parseOpsBundleDraft(raw: string): OpsBundleDraft {
	const found = new Map<OpsCap, string>();
	for (const untrimmed of raw.split(/\r?\n/)) {
		const line = untrimmed.trim();
		if (line === "") continue;
		const parts = line.split(/\s+/);
		const capability = LABELS.get(parts[0]);
		if (capability == null) throw new Error(`The capability set contains an unknown label: ${parts[0]}.`);
		if (parts.length > 2) throw new Error(`${parts[0]} must be followed by at most one swiss number.`);
		if (found.has(capability)) throw new Error(`The capability set repeats ${parts[0]}.`);
		found.set(capability, parts.length === 1 ? "" : operationsSwiss(parts[1]));
	}
	return found;
}

export function formatOpsBundle(draft: OpsBundleDraft): string {
	return OPS_BUNDLE_CAPABILITIES.flatMap(({ capability, token }) => {
		if (!draft.has(capability)) return [];
		const swiss = draft.get(capability) ?? "";
		return [swiss === "" ? token : `${token} ${swiss}`];
	}).join("\n");
}

export function opsBundleReady(draft: OpsBundleDraft): boolean {
	if (draft.size === 0) return false;
	try {
		return [...draft.values()].every((swiss) =>
			swiss !== "" && swiss === swiss.trim() && !/\s/.test(swiss) && operationsSwiss(swiss) === swiss
		);
	} catch {
		return false;
	}
}

export function parseOpsBundle(raw: string): Map<OpsCap, string> {
	const found = new Map<OpsCap, string>();
	for (const untrimmed of raw.split(/\r?\n/)) {
		const line = untrimmed.trim();
		if (line === "" || !line.startsWith("ROOMS-")) continue;
		const parts = line.split(/\s+/);
		if (parts[0] === "ROOMS-VIZ-LISTENING") continue;
		const capability = LABELS.get(parts[0]);
		if (capability == null) throw new Error(`The capability set contains an unknown label: ${parts[0]}.`);
		if (parts.length !== 2) throw new Error(`${parts[0]} must be followed by exactly one swiss number.`);
		if (found.has(capability)) throw new Error(`The capability set repeats ${parts[0]}.`);
		found.set(capability, operationsSwiss(parts[1]));
	}
	if (found.size === 0) throw new Error("Paste the ROOMS-* capability lines printed by the server.");
	return found;
}
