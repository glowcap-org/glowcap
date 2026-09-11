// Read-only command affordances from the shared Rust catalog.
import { applicationModule } from "../application.ts";
import type { Conv } from "../types.ts";
import type { Command, CommandHere } from "./types.ts";
import { runCommand } from "./execute.ts";

let catalog: readonly Command[] | null = null;
export function known(): readonly Command[] {
	return catalog ??= (JSON.parse(applicationModule().slashCatalog()) as Omit<Command, "run">[]).map((entry) => ({
		...entry,
		run: (rest, powers, conv) => runCommand(entry.name, rest, powers, conv),
	}));
}

export function hereOf(conv: Conv | null): CommandHere {
	return conv?.type === "room" ? "room" : conv?.type === "directory" ? "directory" : "direct";
}

/** Filter displayed affordances; possession is validated by the Rust executor. */
export function held(grants: ReadonlySet<string>, here: CommandHere): readonly Command[] {
	return known().filter((command) =>
		(command.grant === undefined || grants.has(command.grant)) &&
		(command.place !== "room" || here === "room") &&
		(here !== "directory" || command.kind === "tab")
	);
}
