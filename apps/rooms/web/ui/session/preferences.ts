// Preference writes are semantic session commands, resolved against its revision.
import type { RoomsSessionSnapshot } from "../../../lib/session/client.ts";

type Command = (name: string, args: string[]) => Promise<RoomsSessionSnapshot>;
export function sessionPreferences(command: Command) {
	return {
		setStanding(standing: string): Promise<RoomsSessionSnapshot> {
			return command("setStanding", [standing]);
		},

		setDirectoryNick(directoryId: string, nick: string): Promise<RoomsSessionSnapshot> {
			return command("setDirectoryNick", [directoryId, nick]);
		},

		setDirectoryStanding(directoryId: string, standing: string | null): Promise<RoomsSessionSnapshot> {
			return command("setDirectoryStanding", standing == null ? [directoryId] : [directoryId, standing]);
		},

		setRoomStanding(conversationId: string, standing: string | null): Promise<RoomsSessionSnapshot> {
			return command("setRoomStanding", standing == null ? [conversationId] : [conversationId, standing]);
		},

		setIgnoredNames(names: readonly string[]): Promise<RoomsSessionSnapshot> {
			return command("setIgnoredNames", [JSON.stringify(names)]);
		},

		setIgnoredName(name: string, ignored: boolean): Promise<RoomsSessionSnapshot> {
			return command("setIgnoredName", [name, String(ignored)]);
		},
		setEffectiveStanding(conversationId: string, standing: string): Promise<RoomsSessionSnapshot> {
			return command("setEffectiveStanding", [conversationId, standing]);
		},
	};
}
