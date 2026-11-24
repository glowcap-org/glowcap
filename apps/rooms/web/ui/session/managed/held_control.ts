// The rows `ManagedAccess` holds: each held control and what this viewer knows
// of the access it holds. The edit under way through one is `edit_state.ts`'s,
// and a share under way is `share_state.ts`'s.
import type {
	RoomsManagedAcquisition,
	RoomsManagedControl,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";
import { type FailureView, failureView, LocalRefusal, reworded, tryNowCanHelp } from "../../../../lib/text/failure.ts";
import { unreachedAccess } from "../../../../lib/text/managed_access.ts";
import type { GrantView, ManagementView } from "./access_powers.ts";
import type { EditState } from "./edit_state.ts";

/** Where a held control stands over the current link. A reached control holds
 * its handle, replaced when that link is replaced. One the link could not reach
 * says why, and still knows what it was last described as. One never reached,
 * as a saved control whose session did not answer when the page opened, knows
 * nothing of its access. */
export type ControlState =
	| {
		readonly kind: "reached";
		readonly handle: RoomsManagedControl;
		readonly grant: GrantView | null;
		readonly powers: ManagementView;
	}
	| {
		readonly kind: "unreached";
		readonly failure: unknown;
		readonly grant: GrantView | null;
		readonly powers: ManagementView;
	}
	| { readonly kind: "undescribed"; readonly failure: unknown };
/** What a control's last description said of its access. `grant` is null for
 * a control that cannot inspect it. */
export type Description = Pick<Extract<ControlState, { kind: "reached" }>, "grant" | "powers">;

export interface HeldControl {
	/** The control's saved row, or what this viewer calls one not saved. */
	readonly id: string;
	state: ControlState;
	/** The last edit through this control: one under way, or how it ended. */
	edit?: EditState;
	saving?: RoomsManagedAcquisition;
	/** How a new link to the session reaches this control again. A saved one is
	 * restored from its row. One not yet saved is attached again from the
	 * management link it was attached from, and one with none, as an access a
	 * share made, moves with that share. `address` is the link a control this
	 * page attached came from, kept once it is saved. */
	storage:
		| { readonly kind: "saved"; readonly address?: string | null }
		| { readonly kind: "unsaved"; readonly address: string | null };
	/** What this viewer last committed, for a control that cannot inspect. */
	committed?: { label?: string; permissions?: RoomsPermission[] };
	/** Why the last read of a reached control failed, for a failure other than
	 * a lost connection, until a read or a new handle replaces it. */
	readFailure?: unknown;
}
/** What a person reads of the failure that left an access unreached. */
export function unreachedView(failure: unknown): FailureView {
	return reworded(failureView(failure), unreachedAccess);
}
/** Whether asking again can clear `failure`, the one reach failure this page
 * offers Try now for. */
export function tryNowReaches(failure: unknown): boolean {
	return tryNowCanHelp(unreachedView(failure));
}
/** Why `control` cannot be worked through now: the failure that left it
 * unreached, or the one its last read met. Null when nothing stands in the way. */
export function standingFailure(control: HeldControl): unknown {
	return control.state.kind === "reached" ? control.readFailure ?? null : control.state.failure;
}
/** Whether `control`'s Try now can help: it is unreached, or its last read
 * failed, for a failure asking again can clear. */
export function canTryNow(control: HeldControl): boolean {
	const failure = standingFailure(control);
	return failure != null && tryNowReaches(failure);
}
/** A control that has been described, whose access this viewer can manage. */
export type DescribedControl = HeldControl & { state: Exclude<ControlState, { kind: "undescribed" }> };
export function described(control: HeldControl): control is DescribedControl {
	return control.state.kind !== "undescribed";
}
/** The handle `control` holds over the current link, if it reached it. */
export function handleOf(control: HeldControl): RoomsManagedControl | null {
	return control.state.kind === "reached" ? control.state.handle : null;
}
/** Why the current link could not reach `control`, as the refusal of a
 * request that sends nothing, or null once it is reached. */
export function unreached(control: HeldControl): LocalRefusal | null {
	const state = control.state;
	return state.kind === "reached" ? null : new LocalRefusal("not-sent", { cause: state.failure });
}
/** The control's handle over the current link. A control the link could not
 * reach sends nothing, and says why. */
export function reached(control: HeldControl): RoomsManagedControl {
	const state = control.state;
	if (state.kind === "reached") return state.handle;
	throw new LocalRefusal("not-sent", { cause: state.failure });
}
/** The local workspace's own control: the root every other access descends from. */
export const OWN_CONTROL = "current";
/** Whether links this control publishes lead to this browser, which people
 * reach through its Rooms server. Only the browser's own control manages a
 * session this browser runs. Every other control publishes at the session it
 * manages, reached as it already is. */
export const publishesHere = (control: HeldControl): boolean => control.id === OWN_CONTROL;
/** Whether this page keeps a row for `control` in its own storage. */
export const saved = (control: HeldControl): boolean => control.storage.kind === "saved";
/** The label this viewer knows the control's access to have. */
export function knownLabel(control: HeldControl): string {
	return (described(control) ? control.state.grant?.label : null) ?? control.committed?.label ?? "";
}
/** What a held control is called: its access's label, or what it is. */
export function controlName(
	control: HeldControl,
	names: { readonly held: string; readonly ownControl: string; readonly revokedName: string },
): string {
	const known = knownLabel(control);
	if (known !== "") return known;
	if (control.id === OWN_CONTROL) return names.ownControl;
	return !described(control) || control.state.powers.available ? names.held : names.revokedName;
}
/** The status this viewer knows the access to have, if any. A control that
 * describes nothing has had its access, or an access above it, revoked. */
export function knownStatus(control: HeldControl): GrantView["status"] | undefined {
	if (!described(control)) return undefined;
	const { grant, powers } = control.state;
	if (!powers.available) return "revoked";
	return grant?.effectiveStatus ?? powers.status;
}
/** The permissions this viewer knows the control's access to have. */
export function knownPermissions(control: HeldControl): readonly RoomsPermission[] {
	return (described(control) ? control.state.grant?.configured.permissions : null) ??
		control.committed?.permissions ??
		[];
}
