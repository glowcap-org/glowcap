// Editable form values projected from the shared Rust bundle grammar.
import { invariant } from "../../../lib/invariant.ts";
import { LocalRefusal } from "../../../lib/text/failure.ts";
import * as z from "zod/mini";
import { applicationModule } from "../application.ts";
import { ALL_BOOT_CAPS } from "../application_data.ts";
import type { OperationsCapability } from "../application_data.ts";

export const OPS_BUNDLE_CAPABILITIES = ALL_BOOT_CAPS.map((definition) => ({
	capability: definition.id as OperationsCapability,
	token: definition.token,
}));
const BUNDLE_CAPABILITY_IDS: ReadonlySet<string> = new Set(ALL_BOOT_CAPS.map((definition) => definition.id));
export type OpsBundleDraft = ReadonlyMap<OperationsCapability, string>;
type Projection = { entries: [OperationsCapability, string][]; ready: boolean; formatted: string };

/** The bundle grammar is Rust's. An answer outside it is a defect in the
 * shared build, never a draft. */
const ProjectionSchema: z.ZodMiniType<Projection> = z.object({
	entries: z.array(z.tuple([
		z.custom<OperationsCapability>((value) => typeof value === "string" && BUNDLE_CAPABILITY_IDS.has(value)),
		z.string(),
	])),
	ready: z.boolean(),
	formatted: z.string(),
});

function prove(encoded: string): Projection {
	const parsed = z.safeParse(ProjectionSchema, JSON.parse(encoded));
	if (!parsed.success) {
		invariant(
			false,
			`the Rooms application answered an invalid operations bundle:\n${z.prettifyError(parsed.error)}`,
		);
	}
	return parsed.data;
}
function parse(raw: string, pasted: boolean): Projection {
	const application = applicationModule();
	let encoded: string;
	try {
		encoded = application.operationsBundleDraft(raw, pasted);
	} catch (cause) {
		if (cause instanceof WebAssembly.RuntimeError) throw cause;
		throw new LocalRefusal("capability-set-unreadable", { cause });
	}
	return prove(encoded);
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
/** Whether `draft` is a complete bundle. An entry the grammar refuses makes
 * the draft not ready. A missing module, a trap, or an answer outside the
 * grammar is a fault and throws. */
export function opsBundleReady(draft: OpsBundleDraft): boolean {
	const application = applicationModule();
	let encoded: string;
	try {
		encoded = application.operationsBundleEntries(JSON.stringify([...draft]));
	} catch (error) {
		if (error instanceof WebAssembly.RuntimeError) throw error;
		return false;
	}
	return prove(encoded).ready;
}
export function parseOpsBundle(raw: string): Map<OperationsCapability, string> {
	return new Map(parse(raw, true).entries);
}
