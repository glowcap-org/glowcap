// Commands whose subject is a room authority: its topic, durable reach,
// handover, stewardship, and the moderation act that stewardship grants.

import { MAX_TOPIC } from "../../../lib/limits.ts";
import type { Command } from "./types.ts";
import { inviteWhy } from "./targets.ts";

export const ROOM_COMMANDS: readonly Command[] = [
	{
		name: "topic",
		kind: "granted",
		summary: "set what this room is about",
		usage: "/topic what we are talking about, /topic to read it, or /topic - to take it down",
		grant: "topic",
		place: "room",
		run(rest, powers, conv) {
			if (conv?.type !== "room") return { kind: "refused", why: "Only a room has a topic." };
			const said = rest.trim();
			if (said === "") {
				powers.say(conv.topic ? `The topic is: ${conv.topic}` : "This room has no topic.");
				return { kind: "done" };
			}
			const wanted = said === "-" ? "" : said;
			if (wanted.length > MAX_TOPIC) {
				return { kind: "refused", why: `A topic may be at most ${MAX_TOPIC} characters.` };
			}
			return powers.setTopic(wanted) ? { kind: "done" } : {
				kind: "refused",
				why: "This room did not offer a topic to set.",
			};
		},
	},
	{
		name: "link",
		// Holding the room is the authority to ask for durable reach. The mint is
		// the cost: the server records the room for good, while `/invite` below
		// hands over the live reference and creates no durable state.
		kind: "tab",
		summary: "a link to this room, or to a listed room you name",
		usage: "/link, or /link lobby for a listed room",
		place: "room",
		argument: "room",
		run(rest, powers, conv) {
			if (conv?.type !== "room") return { kind: "refused", why: "Only a room has a link." };
			const name = rest.trim().replace(/^#/, "");
			return powers.roomLink(name === "" ? undefined : name) ? { kind: "done" } : {
				kind: "refused",
				why: name === ""
					? "There is no room here to link to."
					: "There is no directory here to link a room on.",
			};
		},
	},
	{
		name: "invite",
		kind: "tab",
		summary: "offer this room to somebody, so they can hold it too",
		usage: "/invite alice",
		needsArgument: true,
		place: "room",
		targets: "reachable",
		run(rest, powers, conv) {
			if (conv?.type !== "room") return { kind: "refused", why: "Only a room can be offered." };
			const who = rest.trim().replace(/^@/, "").split(/\s+/)[0] ?? "";
			if (who === "") return { kind: "refused", why: "Use /invite followed by who to hand it to." };
			const why = inviteWhy(who, powers.you());
			if (why !== null) return { kind: "refused", why };
			return powers.invite(who) ? { kind: "done" } : {
				kind: "refused",
				why: "There is no room here to hand over.",
			};
		},
	},
	{
		name: "moderator",
		// Claiming mints durable server state and is therefore explicit. A handed
		// sturdyref is validated against this exact room before it is retained.
		kind: "tab",
		summary: "claim, show, or take this room's moderation capability",
		usage: "/moderator, or /moderator ocapn://…/s/<moderator>",
		place: "room",
		run(rest, powers, conv) {
			if (conv?.type !== "room") {
				return { kind: "refused", why: "Only a room has a moderator capability." };
			}
			const link = rest.trim();
			return powers.steward(link === "" ? undefined : link) ? { kind: "done" } : {
				kind: "refused",
				why: "There is no connected room here to moderate.",
			};
		},
	},
	{
		name: "kick",
		kind: "granted",
		summary: "ask a member to leave this room",
		usage: "/kick alice",
		grant: "steward",
		needsArgument: true,
		place: "room",
		run(rest, powers, conv) {
			if (conv?.type !== "room") return { kind: "refused", why: "Only a room can ask somebody to leave." };
			const who = rest.trim().replace(/^@/, "").split(/\s+/)[0] ?? "";
			if (who === "") return { kind: "refused", why: "Use /kick followed by who to ask out." };
			return powers.kick(who) ? { kind: "done" } : {
				kind: "refused",
				why: "This room did not hand this tab its moderator capability.",
			};
		},
	},
];
