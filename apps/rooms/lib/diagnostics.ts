// The operator's view of a directory, taken as a capability.
//
// Inspect is not a directory method: it is a second object the server publishes
// under an unguessable name, so holding that name is the whole of the
// authority. Taking it is the shared operations flow in `operations.ts`; what
// it answers — the `snapshot` rows below — is what this module owns.

import type { Ref, Session } from "@pancake/runtime";
import { SNAPSHOT } from "./protocol.ts";
import { ask } from "./ask.ts";
import { takeOperationsCap } from "./operations.ts";

/** One named object the inspect capability can currently see. */
export interface DiagnosticRow {
	kind: string;
	name: string;
	note: string;
}

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
	if (!Array.isArray(raw)) throw new Error("diagnostics snapshot was not a list");
	const rows: DiagnosticRow[] = [];
	for (const row of raw) {
		if (!Array.isArray(row) || row.length < 2) continue;
		const kind = typeof row[0] === "string" ? row[0] : "";
		const name = typeof row[1] === "string" ? row[1] : "";
		const note = typeof row[2] === "string" ? row[2] : "";
		if (kind !== "" && name !== "") rows.push({ kind, name, note });
	}
	return rows;
}
