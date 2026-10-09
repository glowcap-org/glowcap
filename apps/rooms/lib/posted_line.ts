// The authority returned for a line its author may still change or withdraw.

import { Ref, type Session } from "@glowcap/runtime";
import type { Argument } from "@glowcap/runtime";
import type { AttachmentSource } from "./attachment.ts";
import { sendWithAttachments } from "./attachment.ts";
import { ask } from "./ask.ts";
import { EDIT, REFILE, WITHDRAW } from "./protocol.ts";
import { releaseUnclaimedCapabilityArguments } from "./argument_custody.ts";

/** Room replies pair the notification ID with the exact line authority. */
function postedLineReference(reply: unknown): Ref | null {
	if (reply == null) return null;
	if (Array.isArray(reply) && reply.length === 2) {
		const [id, authority] = reply;
		const number = typeof id === "bigint" ? Number(id) : id;
		if (Number.isSafeInteger(number) && number > 0 && (authority == null || authority instanceof Ref)) {
			return authority;
		}
	}
	throw new Error("The peer returned an invalid posted line result");
}

/** Adopt the reply's capability occurrence without retaining it again. */
export function postedLineResult(session: Session, reply: unknown): PostedLine | null {
	try {
		const authority = postedLineReference(reply);
		return authority == null ? null : new PostedLine(session, authority);
	} catch (error) {
		releaseUnclaimedCapabilityArguments(
			session,
			[reply as Argument],
			"invalid posted line custody could not be released",
		);
		throw error;
	}
}

/** A line this member posted, and the authority to change or withdraw it.
 *
 * Holding this is the whole of that authority — the room asks nobody who is
 * calling, because only the member whose `post` made the line was ever handed
 * it. Which means it can be given away: hand it to somebody and they can take
 * the line down, without the room learning what a moderator is. */
export class PostedLine {
	#session: Session;
	#ref: Ref;

	constructor(session: Session, ref: Ref) {
		this.#session = session;
		this.#ref = ref;
	}

	/** Let this line's reference go when nothing is left to change or take back. */
	release(): void {
		this.#session.release(this.#ref);
	}

	async edit(text: string): Promise<void> {
		await ask(this.#session, this.#ref, EDIT, [text], "the room did not answer changing that line");
	}

	/** Replace this line's files. `keep` names retained file positions. */
	async refile(caption: string, keep: number[], sources: AttachmentSource[] = []): Promise<void> {
		const leading: Argument[] = [caption, ...keep.map((at) => BigInt(at))];
		if (sources.length === 0) {
			await ask(this.#session, this.#ref, REFILE, leading, "the line's host did not answer changing its files");
		} else {
			await sendWithAttachments(this.#session, this.#ref, REFILE, leading, sources);
		}
	}

	/** Take this line back. Saying so twice is not an error. */
	async withdraw(): Promise<void> {
		await ask(this.#session, this.#ref, WITHDRAW, [], "the room did not answer taking that line back");
	}
}
