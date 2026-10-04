// Generated glue imports snippet modules; both proof origins serve the same build.
import { readFile } from "node:fs/promises";

export function snippet(root, path) {
	if (!path.startsWith("/snippets/") || !path.endsWith(".js")) throw new Error("not a generated snippet");
	const target = new URL(`.${path}`, root);
	if (!target.href.startsWith(new URL("snippets/", root).href)) throw new Error("snippet escaped the proof build");
	return readFile(target);
}
