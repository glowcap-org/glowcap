import type { RefObject } from "react";
import { MAX_ROOM_AUDIENCE } from "../../../lib/application_data.ts";
import { SESSION_COMMAND_REQUIREMENTS } from "../../../lib/session_content_data.ts";
import { memberAbout, roomAudienceText } from "../../../lib/text/conversation.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import type { ChatItem } from "../conversation.ts";
import { useConversationMembers, useRoomsState, useSessionPermission } from "../hooks.ts";
import { type MarkdownNode, readRichText } from "../markdown.ts";
import { MenuRow } from "../Menu.tsx";
import { useOpenModal } from "../modal.ts";

/** Read only the mention nodes that Rooms rendered. Code, quoted URLs and literal @ text are not people. */
function namedMentions(text: string): string[] {
	const names = new Set<string>();
	const pending: MarkdownNode[] = readRichText(text).flatMap((part) => part.document.blocks).reverse();
	while (pending.length) {
		const node = pending.pop()!;
		if (node.kind === "mention") {
			if (node.room) return [];
			names.add(node.name.toLowerCase());
			if (names.size > MAX_ROOM_AUDIENCE) return [];
		} else if ("children" in node) {
			for (let i = node.children.length - 1; i >= 0; i--) pending.push(node.children[i]);
		}
	}
	return [...names];
}

/** Only a visible line menu reads the current roster or looks for names to keep. */
export function RoomLineActions({ convKey, item, trigger, close }: {
	convKey: string;
	item: ChatItem;
	trigger: RefObject<HTMLButtonElement | null>;
	close: () => void;
}) {
	const room = useRoomsState((state) => state.convs.get(convKey));
	const members = useConversationMembers(convKey);
	const maySet = useSessionPermission(SESSION_COMMAND_REQUIREMENTS.setRoomAudience.workspace[0]);
	const session = useRoomsSession();
	const browser = useRoomsBrowser();
	const openModalFrom = useOpenModal();
	if (room?.type !== "room") return null;
	if (!item.mine) {
		if (!members.has(item.from)) return null;
		return (
			<MenuRow
				className="line-menu-row"
				icon="group"
				onPick={() => {
					close();
					if (trigger.current) {
						openModalFrom(trigger.current, () => browser.aboutMember({ conv: convKey, name: item.from }));
					}
				}}
			>
				{memberAbout(item.from)}
			</MenuRow>
		);
	}
	if (
		!maySet || room.membership !== "joined" || room.membershipKind !== "participant" || item.state !== undefined ||
		item.pendingEdit || item.withdrawn || item.withdrawal || !item.text.includes("@")
	) return null;
	const keys = namedMentions(item.text);
	if (!keys.length || keys.includes(item.from.toLowerCase())) return null;
	const online = new Map<string, string>();
	for (const [name, standing] of members) {
		if (standing.online) online.set(name.toLowerCase(), name);
	}
	const names = keys.flatMap((key) => online.get(key) ?? []);
	if (
		names.length !== keys.length || (room.audience?.length === names.length &&
			room.audience.every((name, i) => name.toLowerCase() === keys[i]))
	) return null;
	return (
		<MenuRow
			className="line-menu-row"
			icon="mention"
			onPick={() => {
				close();
				trigger.current?.focus();
				void session.setRoomAudience(convKey, names).catch((cause) =>
					browser.toast("failure", refusalText(cause))
				);
			}}
		>
			{roomAudienceText.keep(names)}
		</MenuRow>
	);
}
