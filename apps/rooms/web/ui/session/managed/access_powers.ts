// What an access grants and what a control may do, as the session describes
// them, and the rules that derive one from the other.
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";

export interface PolicyView {
	permissions: RoomsPermission[];
	bounds: { key: string; operator: string; value: string }[];
}
export interface GrantView {
	slot: number;
	generation: string;
	revision: string;
	label: string;
	status: "active" | "paused" | "revoked";
	effectiveStatus: "active" | "paused" | "revoked";
	configured: PolicyView;
	ceiling: PolicyView;
	delegationDepth: number;
}
export interface ManagementView {
	available: boolean;
	status?: "active" | "paused" | "revoked";
	revision?: string;
	inspect?: boolean;
	pause?: boolean;
	resume?: boolean;
	revoke?: boolean;
	delegateControl?: boolean;
	editCeiling?: PolicyView | null;
	issueCeiling?: PolicyView | null;
}
export interface ManagementPowers {
	inspect: boolean;
	pause: boolean;
	resume: boolean;
	revoke: boolean;
	delegateControl: boolean;
	editCeiling: RoomsPermission[] | null;
	issueCeiling: RoomsPermission[] | null;
}
export const NO_MANAGEMENT: ManagementPowers = {
	inspect: false,
	pause: false,
	resume: false,
	revoke: false,
	delegateControl: false,
	editCeiling: null,
	issueCeiling: null,
};
/** The issuer keeps the control that issuance returns, so it holds every power
 * the source can pass on: powers are fixed at issuance, and a narrower one is
 * shared later by attenuation. A source that cannot delegate passes none. */
export function keptPowers(
	source: ManagementView,
	ceilings: { editCeiling: RoomsPermission[] | null; issueCeiling: RoomsPermission[] | null },
): ManagementPowers {
	if (source.delegateControl !== true) return { ...NO_MANAGEMENT };
	return {
		inspect: source.inspect === true,
		pause: source.pause === true,
		resume: source.resume === true,
		revoke: source.revoke === true,
		delegateControl: true,
		editCeiling: ceilings.editCeiling,
		issueCeiling: ceilings.issueCeiling,
	};
}
/** What a new access's own permissions can later be changed up to: both the
 * source's edit limit and its issuance limit bound the new grant's ceiling. */
export function editableUnder(source: ManagementView): RoomsPermission[] | undefined {
	const edit = source.editCeiling?.permissions;
	const issue = source.issueCeiling?.permissions;
	return edit == null || issue == null ? undefined : edit.filter((permission) => issue.includes(permission));
}
export function grantIdentity(row: GrantView): string {
	return `${row.slot}:${row.generation}`;
}
