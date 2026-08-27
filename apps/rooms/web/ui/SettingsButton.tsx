// The gear that opens Settings. Two homes, one control: the rail title while
// the list is up, and the conversation bar (left of standing) when it is away.
// Size, label, and pressed state are stated once so the two cannot drift.

import { IconButton } from "./IconButton.tsx";
import { useRoomsBrowser } from "./controller/browser.ts";

export function SettingsButton(
	{ id, mobile, settingsOpen }: { id: string; mobile: boolean; settingsOpen: boolean },
) {
	const browser = useRoomsBrowser();
	return (
		<IconButton
			id={id}
			icon="gear"
			label="Settings"
			size={mobile ? "large" : "normal"}
			aria-pressed={settingsOpen}
			onClick={() => settingsOpen ? browser.closeSettings() : browser.openSettings()}
		/>
	);
}
