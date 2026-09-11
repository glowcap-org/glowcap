// Editable form values projected from the shared Rust bundle grammar.
import { applicationModule } from "../application.ts";
import { ALL_BOOT_CAPS } from "../application_data.ts";
import type { OpsCap } from "../types.ts";

export const OPS_BUNDLE_CAPABILITIES = ALL_BOOT_CAPS.map((definition) => ({
	capability: definition.id as OpsCap,
	token: definition.token,
}));
export type OpsBundleDraft = ReadonlyMap<OpsCap, string>;
type Projection = { entries: [OpsCap, string][]; ready: boolean; formatted: string };
function parse(raw: string, pasted: boolean): Projection {
	return JSON.parse(applicationModule().operationsBundleDraft(raw, pasted)) as Projection;
}
function project(draft: OpsBundleDraft): Projection {
	return JSON.parse(applicationModule().operationsBundleEntries(JSON.stringify([...draft]))) as Projection;
}
export function parseOpsBundleDraft(raw: string): OpsBundleDraft {
	return new Map(parse(raw, false).entries);
}
export function formatOpsBundle(draft: OpsBundleDraft): string {
	return project(draft).formatted;
}
export function opsBundleReady(draft: OpsBundleDraft): boolean {
	try {
		return project(draft).ready;
	} catch {
		return false;
	}
}
export function parseOpsBundle(raw: string): Map<OpsCap, string> {
	return new Map(parse(raw, true).entries);
}
