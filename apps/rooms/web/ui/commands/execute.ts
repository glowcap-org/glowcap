// Apply a Rust-interpreted command through session and browser gesture ports.
// Text formatting reads projections. It cannot manufacture live authority.
import * as z from "zod/mini";
import { applicationModule } from "../application.ts";
import type { Conv } from "../types.ts";
import type { CommandOutcome, CommandPowers, CommandResult, HeldDirectory } from "./types.ts";
import { CommandRefused } from "./types.ts";
import { held, hereOf } from "./catalog.ts";
import { helpCommandFormatting } from "../../../lib/text/writing.ts";
import { directoryReportLine, helpYouCanUse, roomListLine, whoisLine } from "../../../lib/text/log.ts";
import {
	advertisingNoRooms,
	directoryNamesMoreThanOne,
	ignoringNobody,
	ignoringNow,
	ignoringThese,
	ignoringYourOwnName,
	nobodyCalled,
	noDirectoryCalled,
	noDirectoryHeld,
	noLongerIgnoring,
	noSubject,
	subjectIs,
	thisDirectory,
	wereNotIgnoring,
	whoisAway,
	whoisHereNow,
	whoisNotHere,
} from "../../../lib/text/commands.ts";

/** The wire shape of one Rust command gesture. The composer's command plan
 * embeds the same arm. The schema is the one definition: the type derives
 * from it. */
export const EffectSchema = z.object({
	kind: z.literal("effect"),
	op: z.string(),
	text: z.string(),
	extra: z.optional(z.string()),
	refusal: z.optional(z.string()),
});
export type Effect = z.infer<typeof EffectSchema>;

/** The plan grammar is Rust's. An answer outside it is a defect in the shared
 * build, never an applicable command. Each variant mirrors one
 * `CommandOutcome` arm, and the call into `applyCommandPlan` holds the
 * schema's output to that type at compile time. */
const CommandPlanSchema = z.discriminatedUnion("kind", [
	z.object({ kind: z.literal("say"), text: z.string() }),
	z.object({ kind: z.literal("action"), text: z.string() }),
	z.object({ kind: z.literal("refused"), why: z.string() }),
	EffectSchema,
]);

export function runCommand(name: string, rest: string, powers: CommandPowers, conv: Conv | null): CommandOutcome {
	const raw: unknown = JSON.parse(
		applicationModule().interpretSlashCommand(
			name,
			rest,
			conv?.type === "dm" ? "direct" : conv?.type ?? "none",
			name === "msg" || name === "invite" ? powers.you() : "",
			name === "away" && powers.standingHere() !== "",
		),
	);
	const parsed = z.safeParse(CommandPlanSchema, raw);
	if (!parsed.success) {
		throw new Error(`the Rooms application answered an invalid command plan:\n${z.prettifyError(parsed.error)}`);
	}
	return applyCommandPlan(parsed.data, powers, conv);
}

export function applyCommandPlan(
	plan: Exclude<CommandOutcome, { kind: "done" }> | Effect,
	powers: CommandPowers,
	conv: Conv | null,
): CommandOutcome {
	if (plan.kind !== "effect") return plan;
	const text = plan.text;
	const say = (message: string) => powers.say(message, conv?.key);
	const granted = (accepted: CommandResult<boolean>): CommandOutcome => {
		if (accepted instanceof Promise) return pending(accepted.then(granted));
		if (accepted) return { kind: "done" };
		if (plan.refusal === undefined) throw new Error(`Missing Rust refusal for ${plan.op}`);
		return { kind: "refused", why: plan.refusal };
	};
	switch (plan.op) {
		case "help":
			say(
				`${helpYouCanUse}\n${
					held(powers.granted(), hereOf(conv)).map((command) => `/${command.name}: ${command.summary}`).join(
						"\n",
					)
				}\n\n${helpCommandFormatting}`,
			);
			break;
		case "joinRoom":
			return committed(powers.joinRoom(text));
		case "joinLink":
			return committed(powers.joinLink(text, plan.extra ?? ""));
		case "leave":
			return { kind: "done", retires: "conversation", completion: Promise.resolve(powers.leaveHere()) };
		case "directMessage":
			return committed(powers.directMessage(text));
		case "members":
			powers.showRoster(true);
			break;
		case "theme":
			powers.setTheme(text as "light" | "dark");
			break;
		case "clear":
			powers.clearHere();
			break;
		case "ignored": {
			const already = powers.ignored();
			say(
				already.length === 0 ? ignoringNobody : ignoringThese(already.join(", ")),
			);
			break;
		}
		case "ignore": {
			const result = powers.ignore(text);
			const yours = powers.directories().some((directory) => directory.nick.toLowerCase() === text.toLowerCase());
			const report = () => {
				say(
					ignoringNow(text) + (yours ? ignoringYourOwnName : ""),
				);
			};
			if (result instanceof Promise) return { kind: "done", completion: result.then(report) };
			report();
			break;
		}
		case "unignore": {
			const result = powers.unignore(text);
			const report = (changed: boolean) => {
				say(changed ? noLongerIgnoring(text) : wereNotIgnoring(text));
			};
			if (result instanceof Promise) return { kind: "done", completion: result.then(report) };
			report(result);
			break;
		}
		case "list": {
			if (text === "") return sayRooms(powers, thisDirectory, powers.liveRooms());
			const found = pickDirectory(powers, text);
			return typeof found === "string"
				? { kind: "refused", why: found }
				: sayRooms(powers, found.name, found.rooms);
		}
		case "directories": {
			const directories = powers.directories();
			if (directories.length === 0) return { kind: "refused", why: noDirectoryHeld };
			say(
				directories.map((dir) =>
					directoryReportLine(
						dir.name,
						dir.connected,
						dir.nick,
						dir.standing,
						dir.rooms.size,
						dir.joined,
						dir.locator,
					)
				).join("\n"),
			);
			break;
		}
		case "whois": {
			const found = powers.roster().find((member) => member.name.toLowerCase() === text.toLowerCase());
			if (found === undefined) return { kind: "refused", why: nobodyCalled(text) };
			const here = found.away !== "" ? whoisAway(found.away) : found.online ? whoisHereNow : whoisNotHere;
			say(whoisLine(found.name, here, found.reachable));
			break;
		}
		case "details":
			powers.aboutConversation();
			break;
		case "quit":
			return committed(powers.quitDirectory(), "directory");
		case "away":
			return granted(powers.setAway(text));
		case "edit":
			return granted(powers.editLast(text));
		case "delete":
			return granted(powers.withdrawLast());
		case "showSubject":
			say(
				conv?.type === "room" && conv.subject
					? subjectIs(conv.subject.description, conv.subject.link)
					: noSubject,
			);
			break;
		case "setSubject":
			return granted(powers.setSubject(text, plan.extra));
		case "roomLink":
			return granted(powers.roomLink(text === "" ? undefined : text));
		case "moderator":
			return granted(powers.steward(text === "" ? undefined : text));
		case "invite":
			return granted(powers.invite(text));
		case "kick":
			return granted(powers.kick(text));
		default:
			throw new Error(`Unknown Rust command gesture: ${plan.op}`);
	}
	return { kind: "done" };
}

function pending(result: Promise<CommandOutcome>): Extract<CommandOutcome, { kind: "done" }> {
	return {
		kind: "done",
		completion: result.then((outcome) => {
			if (outcome.kind === "refused") throw new CommandRefused(outcome.why);
			if (outcome.kind !== "done") throw new Error("A command effect unexpectedly produced a message");
			return outcome.completion;
		}),
	};
}
function committed(why: CommandResult<string | null>, retires?: "conversation" | "directory"): CommandOutcome {
	if (why instanceof Promise) return { ...pending(why.then((value) => committed(value))), retires };
	if (why != null) return { kind: "refused", why };
	return retires == null ? { kind: "done" } : { kind: "done", retires };
}
function sayRooms(powers: CommandPowers, whose: string, rooms: ReadonlyMap<string, number | null>): CommandOutcome {
	if (rooms.size === 0) return { kind: "refused", why: advertisingNoRooms(whose) };
	powers.say(
		[...rooms].sort(([a], [b]) => a.localeCompare(b)).map(([name, count]) => roomListLine(name, count)).join("\n"),
	);
	return { kind: "done" };
}
function pickDirectory(powers: CommandPowers, asked: string): HeldDirectory | string {
	const wanted = asked.toLowerCase();
	const held = powers.directories();
	const hit = held.filter((directory) =>
		directory.name.toLowerCase().includes(wanted) || directory.locator.toLowerCase().includes(wanted)
	);
	if (hit.length === 1) return hit[0];
	if (hit.length === 0) {
		return held.length === 0
			? noDirectoryHeld
			: noDirectoryCalled(asked, held.map((directory) => directory.name).join(", "));
	}
	return directoryNamesMoreThanOne(asked, hit.map((directory) => directory.name).join(", "));
}
