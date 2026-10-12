// Editable form values projected from the shared Rust bundle grammar.
import * as z from "zod/mini";
import { applicationModule } from "../application.ts";
import { ALL_BOOT_CAPS } from "../application_data.ts";
import type { OpsCap } from "../types.ts";

export const OPS_BUNDLE_CAPABILITIES = ALL_BOOT_CAPS.map((definition) => ({
	capability: definition.id as OpsCap,
	token: definition.token,
}));
const BUNDLE_CAPABILITY_IDS: ReadonlySet<string> = new Set(ALL_BOOT_CAPS.map((definition) => definition.id));
export type OpsBundleDraft = ReadonlyMap<OpsCap, string>;
type Projection = { entries: [OpsCap, string][]; ready: boolean; formatted: string };

/** The bundle grammar is Rust's. An answer outside it is a defect in the
 * shared build, never a draft. */
const ProjectionSchema: z.ZodMiniType<Projection> = z.object({
	entries: z.array(z.tuple([
		z.custom<OpsCap>((value) => typeof value === "string" && BUNDLE_CAPABILITY_IDS.has(value)),
		z.string(),
	])),
	ready: z.boolean(),
	formatted: z.string(),
});

function prove(encoded: string): Projection {
	const parsed = z.safeParse(ProjectionSchema, JSON.parse(encoded));
	if (!parsed.success) {
		throw new Error(
			`the Rooms application answered an invalid operations bundle:\n${z.prettifyError(parsed.error)}`,
		);
	}
	return parsed.data;
}
function parse(raw: string, pasted: boolean): Projection {
	return prove(applicationModule().operationsBundleDraft(raw, pasted));
}
function project(draft: OpsBundleDraft): Projection {
	return prove(applicationModule().operationsBundleEntries(JSON.stringify([...draft])));
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
