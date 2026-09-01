// One durable session's live direct conversation and its posted-line authority.

import { currentSession, type Session } from "@pancake/runtime";
import type { Argument, Behavior } from "@pancake/runtime";
import type { Message, PostedLine } from "../lib/room/client.ts";
import { DirectMessage } from "../lib/direct_message.ts";
import type { Attachment, AttachmentSource } from "../lib/attachment.ts";
import { lineCost, MAX_LINE, MAX_SCROLLBACK } from "../lib/limits.ts";
import { EDIT, REFILE, WITHDRAW } from "../lib/protocol.ts";
import { DirectFileCustody } from "./direct_files.ts";
import type { RuntimeAttachment } from "./room_files.ts";
import { attachmentCapabilities, readRefileChange } from "../lib/attachment.ts";
import { settleCapabilityCleanup } from "../lib/capability_cleanup.ts";
import {
	hasCapabilityArguments,
	releaseUnexpectedCapabilityArguments,
	throwAfterReleasingCapabilities,
} from "../lib/argument_custody.ts";

export class DurableDirectLine {
	readonly topology: string;
	readonly line: DirectMessage;
	readonly generation: string;
	readonly files: DirectFileCustody;
	readonly #posted = new Map<number, PostedLine>();
	#nextLineId = 1;

	constructor(topology: string, line: DirectMessage, generation: string = crypto.randomUUID()) {
		this.topology = topology;
		this.line = line;
		this.generation = generation;
		this.files = new DirectFileCustody();
	}

	nextLineId(): number {
		return this.#nextLineId++;
	}

	async say(from: string, text: string): Promise<{ message: Message; editable: boolean }> {
		const authority = await this.line.say(text);
		const lineId = this.nextLineId();
		if (authority != null) this.#remember(lineId, authority);
		return {
			message: { from, text, system: false, lineId, change: "said", attachments: [] },
			editable: authority != null,
		};
	}

	async edit(from: string, lineId: number, text: string): Promise<Message> {
		const line = this.#line(lineId);
		await line.edit(text);
		return { from, text, system: false, lineId, change: "edited", attachments: [] };
	}

	async withdraw(from: string, lineId: number): Promise<Message> {
		const line = this.#line(lineId);
		await line.withdraw();
		this.#posted.delete(lineId);
		settleCapabilityCleanup("withdrawn direct-line release failed", () => line.release());
		this.files.releaseOutgoing(lineId);
		return { from, text: "", system: false, lineId, change: "withdrawn", attachments: [] };
	}

	async sendFiles(
		from: string,
		text: string,
		sources: AttachmentSource[],
	): Promise<{ message: Message; editable: boolean; files: RuntimeAttachment[] }> {
		const authority = await this.line.sendFiles(sources, text);
		const lineId = this.nextLineId();
		if (authority != null) this.#remember(lineId, authority);
		const files = this.files.retainOutgoing(lineId, sources);
		return {
			message: { from, text, system: false, lineId, change: "said", attachments: [] },
			editable: authority != null,
			files,
		};
	}

	async refile(
		from: string,
		lineId: number,
		caption: string,
		keep: readonly number[],
		sources: AttachmentSource[],
	): Promise<{ message: Message; files: RuntimeAttachment[] }> {
		const line = this.#line(lineId);
		this.files.validateOutgoingRefiling(lineId, keep, sources);
		await line.refile(caption, [...keep], sources);
		const files = this.files.refileOutgoing(lineId, keep, sources);
		return { message: { from, text: caption, system: false, lineId, change: "refiled", attachments: [] }, files };
	}

	async close(): Promise<void> {
		for (const posted of this.#posted.values()) {
			settleCapabilityCleanup("direct posted-line release failed", () => posted.release());
		}
		this.#posted.clear();
		this.files.close();
		await this.line.close();
	}

	#line(lineId: number): PostedLine {
		const line = this.#posted.get(lineId);
		if (line == null) throw new Error("this Rooms session does not hold authority over that direct line");
		return line;
	}

	#remember(lineId: number, authority: PostedLine): void {
		this.#posted.set(lineId, authority);
		while (this.#posted.size > MAX_SCROLLBACK) {
			const oldest = this.#posted.entries().next().value as [number, PostedLine] | undefined;
			if (oldest == null) break;
			this.#posted.delete(oldest[0]);
			settleCapabilityCleanup("evicted direct-line release failed", () => oldest[1].release());
			this.files.releaseOutgoing(oldest[0]);
		}
	}
}

export function directReceivedLineBehavior(
	from: string,
	lineId: number,
	initialFiles: Attachment[],
	changed: (message: Message) => void | Promise<void>,
	sessionFor: () => Session | null = currentSession,
): Behavior {
	let withdrawn = false;
	let files = [...initialFiles];
	const caller = (): Session => {
		const session = sessionFor();
		if (session == null) throw new Error("a direct posted line is reachable only during a session turn");
		return session;
	};
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		if (verb !== REFILE && hasCapabilityArguments(args)) {
			throwAfterReleasingCapabilities(
				caller(),
				args,
				new Error(`direct posted line ${verb} does not take capability arguments`),
			);
		}
		if (withdrawn) throw new Error("that direct line was withdrawn");
		if (verb === EDIT) {
			if (args.length !== 1 || typeof args[0] !== "string" || lineCost(args[0]) > MAX_LINE) {
				throw new Error("edit needs one bounded text value");
			}
			return Promise.resolve(
				changed({ from, text: args[0], system: false, lineId, change: "edited", attachments: files }),
			).then(() => null);
		}
		if (verb === WITHDRAW) {
			if (args.length !== 0) throw new Error("withdraw takes no arguments");
			withdrawn = true;
			return Promise.resolve(
				changed({ from, text: "", system: false, lineId, change: "withdrawn", attachments: [] }),
			).then(() => null);
		}
		if (verb === REFILE) {
			let change: ReturnType<typeof readRefileChange>;
			try {
				change = readRefileChange(args, files.length);
			} catch (error) {
				if (hasCapabilityArguments(args)) throwAfterReleasingCapabilities(caller(), args, error);
				throw error;
			}
			if (hasCapabilityArguments(args)) {
				releaseUnexpectedCapabilityArguments(
					caller(),
					args,
					attachmentCapabilities(change.records),
					"a direct refile could not return an unexpected capability",
				);
			}
			files = [...change.keep.map((index) => files[index]), ...change.records];
			const applied = changed({
				from,
				text: change.caption,
				system: false,
				lineId,
				change: "refiled",
				attachments: files,
			});
			if (files.length === 0 && change.caption === "") withdrawn = true;
			return Promise.resolve(applied).then(() => null);
		}
		throw new Error(`direct posted line has no method ${verb}`);
	};
}
