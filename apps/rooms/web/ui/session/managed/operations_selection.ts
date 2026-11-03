// Custody intent owns possession. Loaded inventory is only a pane's last answer.
import type { OpsHeld } from "../../ops/capabilities.ts";
import type { OperationsCapability } from "../../application_data.ts";
import type { Coordinate, WorkspaceIntent } from "./model.ts";

export const operationKind = (cap: OperationsCapability): string => cap === "irc" ? "ircGateway" : cap;

/** The command a capability's actions run through, and the coordinate
 * encoding that command expects: `operator` takes the bare coordinate key,
 * while the shared `operations` command takes the full coordinate. */
export function operationCommand(
	cap: OperationsCapability,
	row: { coordinate: Coordinate },
): { name: "operator" | "operations"; coordinate: string } {
	return cap === "operator"
		? { name: "operator", coordinate: JSON.stringify(row.coordinate.key) }
		: { name: "operations", coordinate: JSON.stringify(row.coordinate) };
}

export function operationSelection(intent: WorkspaceIntent | undefined, cap: OperationsCapability): string | null {
	const held = operationHolding(intent, cap);
	return held == null ? null : JSON.stringify([held.coordinate.role, held.coordinate.key, held.kind]);
}

export function operationHolding(
	intent: WorkspaceIntent | undefined,
	cap: OperationsCapability,
): { coordinate: Coordinate; kind?: string } | null {
	if (cap === "operator") {
		const key = intent?.operators[0];
		return key == null ? null : { coordinate: { role: "operator", key } };
	}
	const row = intent?.operations?.find((row) => row.kind === operationKind(cap));
	return row == null ? null : { coordinate: row.handle, kind: row.kind };
}

export function operationsHeld(intent?: WorkspaceIntent): OpsHeld {
	return {
		listeners: operationHolding(intent, "listeners") != null,
		diagnostics: operationHolding(intent, "diagnostics") != null,
		irc: operationHolding(intent, "irc") != null,
		operator: operationHolding(intent, "operator") != null,
		peering: operationHolding(intent, "peering") != null,
		trace: operationHolding(intent, "trace") != null,
	};
}
