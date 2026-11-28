import { roomAudienceText as words } from "../../../lib/text/conversation.ts";
import { useAsyncAction } from "../async_action.ts";
import type { RoomConv } from "../conversation.ts";
import { useRoomsSession } from "../controller/session.ts";
import { ComposerContext } from "./ComposerContext.tsx";

export function SavedMentions({ room, focusDraft }: { room: RoomConv; focusDraft: () => void }) {
	const session = useRoomsSession();
	const stop = useAsyncAction(() => session.setRoomAudience(room.key, []));
	const names = room.audience;
	if (!names?.length) return null;
	const mentions = names.map((name) => "@" + name).join(", ");
	return (
		<>
			<ComposerContext
				id="savedMentions"
				dismissLabel={words.stop}
				dismiss={() => {
					focusDraft();
					void stop.run();
				}}
				busy={stop.busy}
			>
				{words.keeping} <bdi title={mentions}>{mentions}</bdi>
			</ComposerContext>
			{stop.why && <span role="alert">{stop.why}</span>}
		</>
	);
}
