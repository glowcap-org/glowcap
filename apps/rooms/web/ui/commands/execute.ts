// Apply a Rust-interpreted command through session and browser gesture ports.
// Text formatting reads projections; it cannot manufacture live authority.
import { applicationModule } from "../application.ts";
import type { Conv } from "../types.ts";
import type { CommandOutcome, CommandPowers, CommandResult, HeldDirectory } from "./types.ts";
import { held, hereOf } from "./catalog.ts";

export type Effect = { kind: "effect"; op: string; text: string; extra?: string; refusal?: string };
export function runCommand(name: string, rest: string, powers: CommandPowers, conv: Conv | null): CommandOutcome {
	const plan = JSON.parse(
		applicationModule().interpretSlashCommand(
			name,
			rest,
			conv?.type === "dm" ? "direct" : conv?.type ?? "none",
			name === "msg" || name === "invite" ? powers.you() : "",
			name === "away" && powers.standingHere() !== "",
		),
	) as Exclude<CommandOutcome, { kind: "done" }> | Effect;
	return applyCommandPlan(plan, powers, conv);
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
				`You can use:\n${
					held(powers.granted(), hereOf(conv)).map((command) => `/${command.name}: ${command.summary}`).join(
						"\n",
					)
				}`,
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
				already.length === 0 ? "You are not ignoring anybody." : `You are ignoring ${already.join(", ")}.`,
			);
			break;
		}
		case "ignore": {
			const result = powers.ignore(text);
			const yours = powers.directories().some((directory) => directory.nick.toLowerCase() === text.toLowerCase());
			const report = () => {
				say(
					`Ignoring ${text} in this window. Their lines still reach the room.` +
						(yours ? " That is also your own name here, so your own messages stay shown." : ""),
				);
			};
			if (result instanceof Promise) return { kind: "done", completion: result.then(report) };
			report();
			break;
		}
		case "unignore": {
			const result = powers.unignore(text);
			const report = (changed: boolean) => {
				say(changed ? `No longer ignoring ${text}.` : `You were not ignoring ${text}.`);
			};
			if (result instanceof Promise) return { kind: "done", completion: result.then(report) };
			report(result);
			break;
		}
		case "list": {
			if (text === "") return sayRooms(powers, "This directory", powers.liveRooms());
			const found = pickDirectory(powers, text);
			return typeof found === "string"
				? { kind: "refused", why: found }
				: sayRooms(powers, found.name, found.rooms);
		}
		case "directories": {
			const directories = powers.directories();
			if (directories.length === 0) return { kind: "refused", why: "This tab holds no directory." };
			say(
				directories.map((dir) => {
					const count = dir.rooms.size;
					const you = dir.nick === "" ? "no name yet" : `you: ${dir.nick}`;
					const where = dir.standing === "" ? "here" : `away: ${dir.standing}`;
					const joined = dir.joined.length === 0 ? "in none of them" : "in " + dir.joined.join(" ");
					return `${dir.name}${dir.connected ? "" : " (not connected)"}: ${you}, ${where}, ${count} ${
						count === 1 ? "room" : "rooms"
					} advertised, ${joined}\n  ${dir.locator}`;
				}).join("\n"),
			);
			break;
		}
		case "whois": {
			const found = powers.roster().find((member) => member.name.toLowerCase() === text.toLowerCase());
			if (found === undefined) return { kind: "refused", why: `Nobody here is called ${text}.` };
			const here = found.away !== "" ? `away: ${found.away}` : found.online ? "here now" : "not here just now";
			say(
				`${found.name}: ${here}, ${
					found.reachable ? "reachable for a direct message" : "not reachable directly"
				}`,
			);
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
		case "showTopic":
			say(conv?.type === "room" && conv.topic ? `The topic is: ${conv.topic}` : "This room has no topic.");
			break;
		case "setTopic":
			return granted(powers.setTopic(text));
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
			if (outcome.kind === "refused") throw new Error(outcome.why);
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
	if (rooms.size === 0) return { kind: "refused", why: `${whose} is advertising no rooms.` };
	powers.say(
		[...rooms].sort(([a], [b]) => a.localeCompare(b)).map(([name, count]) =>
			count === null ? `#${name}: occupancy unknown` : `#${name}: ${count} ${count === 1 ? "person" : "people"}`
		).join("\n"),
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
			? "This tab holds no directory."
			: `No directory here is called "${asked}". This tab holds ${
				held.map((directory) => directory.name).join(", ")
			}.`;
	}
	return `"${asked}" names more than one: ${hit.map((directory) => directory.name).join(", ")}.`;
}
