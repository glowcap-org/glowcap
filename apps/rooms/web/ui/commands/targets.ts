// Who a command is talking to, and the sentences for a missing handle.

import { applicationModule } from "../application.ts";

/** Whether `who` is a room-wide word rather than a person. */
export function addressesEveryone(who: string): boolean {
	return applicationModule().addressesEveryone(who);
}

/** The sentences themselves live in the catalog; these are the names the
 * command modules read them by. */
export {
	directNotSelf as DIRECT_NOT_SELF,
	noDirectoryToGiveBack as NO_DIRECTORY_TO_GIVE_BACK,
	notARoomEntryLink as NOT_A_ROOM_ENTRY_LINK,
	notOnADirectory as NOT_ON_A_DIRECTORY,
	notRegisteredForDirect,
	thatLinkDidNotOpen,
} from "../../../lib/text/commands.ts";

/** Why this nick cannot be offered the room, or null when they can. */
export function inviteWhy(who: string, you: string): string | null {
	return applicationModule().roomInviteRefusal(who, you) ?? null;
}
