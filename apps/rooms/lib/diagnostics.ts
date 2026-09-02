// The operator's view of a directory, taken as a capability.
//
// Inspect is not a directory method: it is a second object the server publishes
// under an unguessable name, so holding that name is the whole of the
// authority. Taking it is the shared operations flow in `operations.ts`; what
// it answers — the `snapshot` rows below — is what this module owns.

import type { Ref, Session } from "@glowcap/runtime";
import * as z from "zod/mini";
import { SNAPSHOT } from "./protocol.ts";
import { ask } from "./ask.ts";
import { takeOperationsCap } from "./operations.ts";
import { MAX_OPERATIONS_ROWS } from "./limits.ts";
import { boundedText, nonemptyText } from "./schema.ts";

/** One named object the inspect capability can currently see. */
const diagnosticKind = nonemptyText(64 * 1024);
const diagnosticName = nonemptyText(64 * 1024);
const diagnosticNote = boundedText(64 * 1024);

export const DiagnosticRowSchema = z.strictObject({
	kind: diagnosticKind,
	name: diagnosticName,
	note: diagnosticNote,
});

export type DiagnosticRow = z.infer<typeof DiagnosticRowSchema>;

const DiagnosticWireRowsSchema = z.array(
	z.tuple([diagnosticKind, diagnosticName, diagnosticNote]),
).check(z.maxLength(MAX_OPERATIONS_ROWS));

/** Fetch the inspect object and ask it what this directory currently holds. */
export async function takeDiagnostics(session: Session, pasted: string): Promise<{
	cap: Ref;
	rows: DiagnosticRow[];
}> {
	const { cap, taken } = await takeOperationsCap(session, pasted, (fetched) => snapshotDiagnostics(session, fetched));
	return { cap, rows: taken };
}

/** Ask an inspect capability already in hand for a fresh snapshot. */
export async function snapshotDiagnostics(session: Session, cap: Ref): Promise<DiagnosticRow[]> {
	const raw = await ask(
		session,
		cap,
		SNAPSHOT,
		[],
		"the diagnostic capability did not answer",
	);
	return parseDiagnosticRows(raw);
}

export function parseDiagnosticRows(raw: unknown): DiagnosticRow[] {
	const parsed = z.safeParse(DiagnosticWireRowsSchema, raw);
	if (!parsed.success) throw new Error("the diagnostics capability answered a snapshot with an invalid row");
	return parsed.data.map(([kind, name, note]) => ({ kind, name, note }));
}
