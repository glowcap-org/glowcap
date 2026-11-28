import type { CommandPowers } from "../../web/ui/commands/types.ts";
import {
	NO_DIRECTORY_TO_GIVE_BACK,
	NO_LINE_TO_CHANGE,
	NO_LINE_TO_TAKE_BACK,
	NOT_ON_A_DIRECTORY,
} from "../../web/ui/commands/targets.ts";

/** Powers that answer without acting, for running every command to see what it
 * says. Each returns the empty answer held by a fresh window. */
export const quietCommandPowers: CommandPowers = {
	say: () => {},
	joinRoom: () => NOT_ON_A_DIRECTORY,
	joinLink: () => null,
	leaveHere: () => {},
	directMessage: () => NOT_ON_A_DIRECTORY,
	you: () => "",
	setRoomAudience: (_key, names) => Promise.resolve(names),
	setTheme: () => {},
	clearHere: () => {},
	ignore: () => {},
	unignore: () => false,
	ignored: () => [],
	editLast: () => NO_LINE_TO_CHANGE,
	withdrawLast: () => NO_LINE_TO_TAKE_BACK,
	setSubject: () => null,
	setAway: () => null,
	invite: () => null,
	kick: () => null,
	steward: () => null,
	roomLink: () => null,
	standingHere: () => "",
	directories: () => [],
	granted: () => new Set(),
	showRoster: () => {},
	liveRooms: () => new Map(),
	roster: () => [],
	quitDirectory: () => NO_DIRECTORY_TO_GIVE_BACK,
	aboutConversation: () => {},
};
