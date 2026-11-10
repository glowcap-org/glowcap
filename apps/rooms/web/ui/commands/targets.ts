// Who a command is talking to, and the sentences for a missing handle.

import { applicationModule } from "../application.ts";

/** Whether `who` is a room-wide word rather than a person. */
export function addressesEveryone(who: string): boolean {
	return applicationModule().addressesEveryone(who);
}

/** The sentences themselves live in the catalog. These are the names the
 * command modules read them by. */
export {
	directNotSelf as DIRECT_NOT_SELF,
	inviteWithoutTheRoom,
	kickWithoutModerator as KICK_WITHOUT_MODERATOR,
	linkRoomNotJoined,
	moderatorLinkLine,
	moderatorLinkTaken,
	noDirectoryToGiveBack as NO_DIRECTORY_TO_GIVE_BACK,
	noLineToChange as NO_LINE_TO_CHANGE,
	noLineToTakeBack as NO_LINE_TO_TAKE_BACK,
	noRoomToHandOver as NO_ROOM_TO_HAND_OVER,
	noRoomToLink as NO_ROOM_TO_LINK,
	noRoomToModerate as NO_ROOM_TO_MODERATE,
	noRoomToSayThatIn as NO_ROOM_TO_SAY_THAT_IN,
	noSubjectOffered as NO_SUBJECT_OFFERED,
	notARoomEntryLink as NOT_A_ROOM_ENTRY_LINK,
	notOnADirectory as NOT_ON_A_DIRECTORY,
	notRegisteredForDirect,
	roomLinkLine,
	thatLinkDidNotOpen,
} from "../../../lib/text/commands.ts";

/** Why this nick cannot be offered the room, or null when they can. */
export function inviteWhy(who: string, you: string): string | null {
	return applicationModule().roomInviteRefusal(who, you) ?? null;
}
