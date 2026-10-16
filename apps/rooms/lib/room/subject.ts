// What a room is about: a description every client can show, and optionally a
// link to an object hosted elsewhere. The Rust owner is
// `rooms_application::room::subject`, and this mirror keeps its rules.

import * as z from "zod/mini";
import { MAX_SUBJECT_DESCRIPTION, MAX_SUBJECT_LINK, SUBJECT_LINK_SCHEME } from "../limits.ts";

/** A room's subject. A description alone is a whole subject. A link is the
 * sturdyref of an object the room is about, hosted by whoever set it, and it
 * always travels with a description so every client has something to show.
 * The empty subject (no description, no link) is a subject taken down. */
export interface Subject {
	readonly description: string;
	readonly link?: string;
}

/** Whether `link` has a sturdyref's outward shape: the OCapN scheme, bounded,
 * and printable ASCII as every URI is, so no space, control, or invisible
 * character can hide in what a reader is offered to copy. Redeeming it is the
 * only full check, and the room's host parses it before accepting it. */
function subjectLinkShaped(link: string): boolean {
	return link.length > SUBJECT_LINK_SCHEME.length && link.length <= MAX_SUBJECT_LINK &&
		link.startsWith(SUBJECT_LINK_SCHEME) && /^[\x21-\x7e]+$/.test(link);
}

/** Why the room would refuse this subject, in the words the Rust owner uses,
 * or null when it is valid. */
export function subjectRefusal(description: string, link?: string): string | null {
	if (description.length > MAX_SUBJECT_DESCRIPTION) {
		return `a subject's description may be at most ${MAX_SUBJECT_DESCRIPTION} characters`;
	}
	// Rust text is always well-formed, so a lone surrogate could only reach the
	// room replaced, and a subject is taken exactly or refused.
	if (!description.isWellFormed()) return "a subject's description must be well-formed text";
	// One line of text: no line break and no NUL, the set Rust refuses.
	if (/[\0\n\v\f\r\u0085\u2028\u2029]/.test(description)) {
		return "a subject's description must be one line of text";
	}
	if (description.startsWith(SUBJECT_LINK_SCHEME)) {
		return `a subject's description cannot start with ${SUBJECT_LINK_SCHEME}, so put the link first`;
	}
	if (link === undefined) return null;
	if (description === "") return "a subject with a link needs a description";
	if (!subjectLinkShaped(link)) {
		return `a subject's link must be an ${SUBJECT_LINK_SCHEME} sturdyref of at most ${MAX_SUBJECT_LINK} printable ASCII characters`;
	}
	return null;
}

/** Take a subject exactly, or answer undefined. Nothing is trimmed. */
export function subject(description: string, link?: string): Subject | undefined {
	if (subjectRefusal(description, link) !== null) return undefined;
	return link === undefined ? { description } : { description, link };
}

/** The subject as a room fact or a saved projection carries it. */
export const SubjectSchema = z.strictObject({ description: z.string(), link: z.optional(z.string()) }).check(
	z.refine((value) => subject(value.description, value.link) !== undefined),
);

export function isSubjectEmpty(value: Subject): boolean {
	return value.description === "" && value.link === undefined;
}
