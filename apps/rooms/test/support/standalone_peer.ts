import { readAnnounced } from "./announce.ts";

export function announcedSturdyref(
	process: Deno.ChildProcess,
	token: string,
	label: string,
): Promise<string> {
	return readAnnounced(process, { token, who: label });
}
