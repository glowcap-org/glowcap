// The composer's inline completion: the token under the caret and the rows
// that could finish it. The rules live in `complete.ts` as pure functions.
// This hook reads what they complete against (the members here and the
// listed rooms this tab is in) so the composer only says where the caret is.

import {
	type Candidate,
	commandArgTrigger,
	composerCandidates,
	roomSource,
	type Trigger,
	triggerAt,
} from "../complete.ts";
import type { Conv } from "../conversation.ts";
import type { LiveRooms } from "../directory.ts";
import { useConversationMembers, useListedRoomsOn } from "../hooks.ts";
import type { ComposerState } from "../panes/composer_state.ts";

export function useComposerCompletion(
	{ conv, draft, state, enabled, reachable, nick, liveRooms }: {
		conv: Conv | null;
		draft: string;
		/** Where the caret is, whether the field holds it, and which token Escape
		 * put the list down for. */
		state: Pick<ComposerState, "focused" | "caret" | "dismissedAt">;
		/** Whether the field can be typed in at all. */
		enabled: boolean;
		reachable: ReadonlySet<string>;
		nick: string;
		liveRooms: LiveRooms;
	},
): { trigger: Trigger | null; candidates: readonly Candidate[] } {
	const members = useConversationMembers(conv?.type === "room" ? conv.key : null);
	const linkable = useListedRoomsOn(conv);
	const { focused, caret, dismissedAt } = state;
	const trigger = focused && enabled ? commandArgTrigger(draft, caret) ?? triggerAt(draft, caret) : null;
	const rooms = roomSource(trigger, draft, liveRooms, linkable);
	return {
		trigger,
		candidates: composerCandidates(trigger, dismissedAt, conv, draft, reachable, nick, members, rooms),
	};
}
