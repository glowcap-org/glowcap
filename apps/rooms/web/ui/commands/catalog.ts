// Read-only command affordances from the shared Rust catalog.
import * as z from "zod/mini";
import { applicationModule } from "../application.ts";
import type { Conv } from "../types.ts";
import type { Command, CommandHere } from "./types.ts";
import { runCommand } from "./execute.ts";

type CatalogEntry = Omit<Command, "run">;

/** The catalog grammar is Rust's. An answer outside it is a defect in the
 * shared build, never an offered command. */
const CatalogEntrySchema: z.ZodMiniType<CatalogEntry> = z.object({
	name: z.string(),
	kind: z.enum(["tab", "line", "granted"]),
	summary: z.string(),
	usage: z.string(),
	needsArgument: z.optional(z.literal(true)),
	grant: z.optional(z.string()),
	place: z.optional(z.literal("room")),
	targets: z.optional(z.literal("reachable")),
	argument: z.optional(z.literal("room")),
	aliases: z.optional(z.array(z.string())),
});

let catalog: readonly Command[] | null = null;
export function known(): readonly Command[] {
	if (catalog != null) return catalog;
	const parsed = z.safeParse(z.array(CatalogEntrySchema), JSON.parse(applicationModule().slashCatalog()));
	if (!parsed.success) {
		throw new Error(`the Rooms application answered an invalid command catalog:\n${z.prettifyError(parsed.error)}`);
	}
	return catalog = parsed.data.map((entry) => ({
		...entry,
		run: (rest, powers, conv) => runCommand(entry.name, rest, powers, conv),
	}));
}

export function hereOf(conv: Conv | null): CommandHere {
	return conv?.type === "room" ? "room" : conv?.type === "directory" ? "directory" : "direct";
}

/** Filter displayed affordances. Possession is validated by the Rust executor. */
export function held(grants: ReadonlySet<string>, here: CommandHere): readonly Command[] {
	return known().filter((command) =>
		(command.grant === undefined || grants.has(command.grant)) &&
		(command.place !== "room" || here === "room") &&
		(here !== "directory" || command.kind === "tab")
	);
}
