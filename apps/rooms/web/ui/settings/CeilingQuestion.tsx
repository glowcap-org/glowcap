// How far a control's management may reach, asked as one question: not at
// all, within what this access itself is given, as far as the issuing control
// reaches, or a custom limit picked in the row that offers it.
import { useId } from "react";
import { allowedPermissions, managedAccessText as text } from "../../../lib/text/managed_access.ts";
import type { RoomsPermission } from "../../../lib/session_content_data.ts";
import { PermissionFields, permissionSummary } from "./PermissionFields.tsx";

export type CeilingMode = "none" | "within" | "all" | "custom";
export interface CeilingAnswer {
	mode: CeilingMode;
	custom: RoomsPermission[];
}
export const NO_CEILING: CeilingAnswer = { mode: "none", custom: [] };

/** The limit an answer grants, or null when it grants none. `within` follows
 * the access's own permissions, bounded by what the issuing control allows. */
export function ceilingOf(
	answer: CeilingAnswer,
	permissions: readonly RoomsPermission[],
	available: readonly RoomsPermission[] | undefined,
): RoomsPermission[] | null {
	if (available == null || answer.mode === "none") return null;
	if (answer.mode === "all") return [...available];
	const chosen = answer.mode === "within" ? permissions : answer.custom;
	return chosen.filter((permission) => available.includes(permission));
}

export function CeilingQuestion({ label, noneSaid, answer, permissions, available, disabled, onChange }: {
	label: string;
	/** What "not allowed" withholds, in this question's terms. */
	noneSaid: string;
	answer: CeilingAnswer;
	/** The access's own permissions, which `within` follows. */
	permissions: readonly RoomsPermission[];
	/** The issuing control's limit for this power, or undefined when it has none to pass on. */
	available: readonly RoomsPermission[] | undefined;
	disabled: boolean;
	onChange(answer: CeilingAnswer): void;
}) {
	const id = useId();
	const labelId = `${id}-label`;
	const closed = disabled || available == null;
	const allows = (mode: CeilingMode) =>
		allowedPermissions(permissionSummary(ceilingOf({ ...answer, mode }, permissions, available) ?? []));
	const answers: { mode: CeilingMode; name: string; said: string }[] = [
		{ mode: "none", name: text.ceilingNone, said: noneSaid },
		{ mode: "within", name: text.ceilingWithin, said: text.ceilingWithinSaid },
		{ mode: "all", name: text.ceilingAll, said: text.ceilingAllSaid },
		{ mode: "custom", name: text.custom, said: text.ceilingCustomSaid },
	];
	return (
		<div className="question">
			<p className="group-label" id={labelId}>{label}</p>
			<div className="choices" role="radiogroup" aria-labelledby={labelId}>
				{answers.map((row) => (
					<div className="choice-row" key={row.mode}>
						<label className="choice">
							<input
								type="radio"
								name={labelId}
								checked={answer.mode === row.mode}
								disabled={row.mode === "none" ? disabled : closed}
								onChange={() => onChange({ ...answer, mode: row.mode })}
							/>
							<span>
								<strong>{row.name}</strong>
								{row.said}
								{(row.mode === "within" || row.mode === "all") && available != null && (
									<em className="choice-aside">{allows(row.mode)}</em>
								)}
							</span>
						</label>
						{row.mode === "custom" && answer.mode === "custom" && (
							<div className="ceiling-picker">
								<PermissionFields
									value={answer.custom}
									ceiling={available ?? []}
									disabled={closed}
									onChange={(custom) => onChange({ ...answer, custom })}
								/>
							</div>
						)}
					</div>
				))}
			</div>
		</div>
	);
}
