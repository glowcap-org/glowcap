// The durable session is ready only while its current process has published
// and reconciled the administrator capability. session/main.ts creates this
// bounded mirror after that boundary and removes it before every restart.

import { sessionAdminPath, sessionAdminSturdyref } from "../../session/readiness.ts";
import { readBoundedText } from "../../lib/durable_file.ts";

const MAX_STURDYREF_BYTES = 2_048;
const DEFAULT_PATH = sessionAdminPath("/run/rooms-session");

export function sessionHealthcheckOptions(args: readonly string[]): { path: string; print: boolean } {
	let path: string | undefined;
	let print = false;
	for (const argument of args) {
		if (argument === "--print") {
			print = true;
		} else if (argument.startsWith("--")) {
			throw new Error(`unknown option ${argument}`);
		} else if (path === undefined) {
			path = argument;
		} else {
			throw new Error("name at most one administrator readiness file");
		}
	}
	return { path: path ?? DEFAULT_PATH, print };
}

if (import.meta.main) {
	try {
		const options = sessionHealthcheckOptions(Deno.args);
		const sturdyref = sessionAdminSturdyref(
			await readBoundedText(options.path, MAX_STURDYREF_BYTES, "Rooms session administrator readiness file"),
		);
		if (options.print) console.log(sturdyref);
	} catch (error) {
		console.error(`rooms session: not ready: ${error instanceof Error ? error.message : error}`);
		Deno.exit(1);
	}
}
