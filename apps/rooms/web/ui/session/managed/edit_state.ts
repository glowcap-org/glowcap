// What an edit through a held control is, and where it stands. `AccessEdits`
// moves it between these phases, and the control's card reads them.
import type { RoomsManagedEdit } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";
import type { HeldControl } from "./held_control.ts";

export type EditIntent =
	| { kind: "policy"; permissions: RoomsPermission[] }
	| { kind: "label"; label: string }
	| { kind: "pause" | "resume" | "revoke" };
/** Where an edit through a held control stands, and why in the words its card
 * shows, empty where the phase says enough. Each phase holds exactly the
 * handles it needs.
 * - `prepared`: made and never sent. It holds its request.
 * - `uncertain`: sent, with no answer yet. It holds its request, which asks
 *   the session again as `acquisition.ts` says.
 * - `conflict`: the access changed since the edit's base, and nothing was
 *   applied. It holds no request: saving it again prepares a new one.
 * - `ended`: committed, refused, lost with its request (`unknown`), or never
 *   sent because preparing it failed (`unsent`), as `outcome` says. It holds
 *   nothing, and stays only to say how it ended. */
export type EditState =
	| {
		readonly phase: "prepared" | "uncertain";
		readonly intent: EditIntent;
		readonly base: string;
		readonly request: RoomsManagedEdit;
		readonly reason: string;
	}
	| { readonly phase: "conflict"; readonly intent: EditIntent; readonly reason: string }
	| {
		readonly phase: "ended";
		readonly intent: EditIntent;
		readonly outcome: "committed" | "refused" | "unknown" | "unsent";
		readonly reason: string;
	};
/** An edit that holds its request: prepared, or sent and unanswered. */
export type LiveEdit = Extract<EditState, { phase: "prepared" | "uncertain" }>;
/** `control`'s edit while it holds its request, or null. */
export function liveEdit(control: HeldControl): LiveEdit | null {
	const edit = control.edit;
	return edit?.phase === "prepared" || edit?.phase === "uncertain" ? edit : null;
}
/** Whether `control`'s edit waits on a person: one under way, or a conflict
 * they have not settled. */
export function editOpen(control: HeldControl): boolean {
	const edit = control.edit;
	return edit != null && edit.phase !== "ended";
}
/** Whether `control` holds a change that was sent and never answered. */
export function sentUnconfirmed(control: HeldControl): boolean {
	return control.edit?.phase === "uncertain";
}
