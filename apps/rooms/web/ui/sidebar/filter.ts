// How much of the rail a reader is looking at, as a list of questions about a
// row.
//
// The rail is a flat list of the rooms and direct lines this tab holds, in the
// order the reader made. A filter hides rows from that list and does nothing
// else. It never groups and it never reorders, because the order is the
// reader's and a grouping is a view somebody else chose for them.
//
// The questions are peers. A room is the first-class thing here, and each
// question asks about one property it has: what it is called, which directory
// it is on, who can get in, whether anything on it is waiting to be read. None
// of them is the axis the others hang off, so which directory a row is on is
// one question among them rather than the shape of the whole control.
//
// Adding another question means adding a line to `railCriteria`, and a field to
// `RailRow` when the question asks about something the row does not carry yet.
// The control draws whatever this list holds, the answers are held one field
// per kind of answer rather than one per question, and `criterionShows` is the
// only place a single question is decided.

import type { DirId, DirView, DmConv, Invitation, RoomConv, Unread } from "../types.ts";
import { directoryName } from "../text.ts";

/** A row of the rail, reduced to the facts the questions ask about.
 *
 * Every kind of row the rail draws becomes one of these, so a question is
 * asked once and answered the same way whether it lands on a room, a direct
 * line, an invitation, or a directory with nothing open on it. */
export interface RailRow {
	/** The directory this row belongs to. */
	dir: DirId;
	/** What the row is called, which is what a reader would type looking for
	 * it. */
	name: string;
	/** Whether the thing on this row can be reached by name or only by a
	 * reference somebody hands over. Null on a row the question does not apply
	 * to, such as a direct line, which is between two people rather than open
	 * or closed to a directory. */
	access: string | null;
	/** Whether anything on this row is waiting to be read. Null on a row with no
	 * conversation behind it, such as an invitation nobody has answered or a
	 * directory with nothing open on it. */
	unread: string | null;
}

/** How a conversation answers the question about being read.
 *
 * A rule still standing answers caught up. The rule is a marker left where the
 * reader last came in, so a row carrying one has been read and has nothing
 * waiting on it. Somebody asking the rail for unread rows is asking where
 * something is waiting for them, and a row they have already read would only
 * make that list one they have to check again. */
function unreadAnswer(unread: Unread): string {
	return unread.kind === "unread" ? "unread" : "caught-up";
}

/** One answer a question offers, as a value and as the word for it. */
export interface Choice {
	value: string;
	/** How this answer is said, both on the control and in what it announces. */
	said: string;
}

/** One question the reader can put to every row.
 *
 * Two kinds, because two kinds of question are being asked. A question with a
 * known set of answers is a list you turn entries off in. A question whose
 * answers are whatever a reader types is a field. Everything else about them
 * is the same, and the control below draws both from this one type. */
export type Criterion =
	| {
		kind: "choices";
		id: string;
		label: string;
		choices: readonly Choice[];
		answer: (row: RailRow) => string | null;
	}
	| {
		kind: "text";
		id: string;
		label: string;
		placeholder: string;
		answer: (row: RailRow) => string | null;
	};

/** What the reader has said, one field per kind of answer rather than one per
 * question.
 *
 * That is what keeps a new question from touching this type. A question with a
 * set of answers turns entries off, a question with a typed answer holds what
 * was typed, and any number of either fits in these two. */
export interface FilterAnswers {
	/** The choices turned off, by `offKey`. Turned off rather than turned on,
	 * because a directory this tab reaches for the first time has to arrive in
	 * view rather than already hidden by an answer nobody gave. */
	off: ReadonlySet<string>;
	/** What has been typed into each field question, by question. */
	typed: ReadonlyMap<string, string>;
}

/** Nothing asked, which is the rail a reader who has not touched this gets. */
export const askedNothing: FilterAnswers = { off: new Set(), typed: new Map() };

/** One turned-off choice, named by the question it belongs to as well as by
 * its own value.
 *
 * Both halves, because two questions may offer the same word and mean
 * different things. The newline is the join: a question's id is one plain
 * word, so it cannot hold one, and the pair is unambiguous. */
export function offKey(criterion: string, value: string): string {
	return criterion + "\n" + value;
}

/** Whether one question is hiding anything. */
function isAsked(criterion: Criterion, answers: FilterAnswers): boolean {
	if (criterion.kind === "text") return (answers.typed.get(criterion.id) ?? "").trim() !== "";
	return criterion.choices.some((choice) => answers.off.has(offKey(criterion.id, choice.value)));
}

/** Whether anything at all is hiding anything. */
export function anyAsked(criteria: readonly Criterion[], answers: FilterAnswers): boolean {
	return criteria.some((criterion) => isAsked(criterion, answers));
}

/** Whether one question lets this row through.
 *
 * The one place a single question is decided, which is why a new question of
 * either kind needs no change here.
 *
 * A row whose answer is not one of the offered ones stays in view. That is
 * what lets a direct line sit under a question about who can get into a room,
 * and it is also what keeps a row from vanishing while the answers a question
 * offers are still catching up with what this tab holds. */
function criterionShows(criterion: Criterion, answers: FilterAnswers, row: RailRow): boolean {
	const answer = criterion.answer(row);
	if (criterion.kind === "text") {
		const needle = (answers.typed.get(criterion.id) ?? "").trim().toLowerCase();
		if (needle === "") return true;
		return answer !== null && answer.toLowerCase().includes(needle);
	}
	if (answer === null) return true;
	if (!criterion.choices.some((choice) => choice.value === answer)) return true;
	return !answers.off.has(offKey(criterion.id, answer));
}

/** Whether the rail shows this row. Every question has to let it through, and
 * the questions are asked in no particular order because none of them ranks
 * above another. */
export function rowShows(
	criteria: readonly Criterion[],
	answers: FilterAnswers,
	row: RailRow,
): boolean {
	return criteria.every((criterion) => criterionShows(criterion, answers, row));
}

/** Turn one choice off, or back on. */
export function toggleChoice(answers: FilterAnswers, key: string): FilterAnswers {
	const off = new Set(answers.off);
	if (!off.delete(key)) off.add(key);
	return { off, typed: answers.typed };
}

/** Put what has been typed into one field question. */
export function setTyped(answers: FilterAnswers, id: string, value: string): FilterAnswers {
	const typed = new Map(answers.typed);
	if (value === "") typed.delete(id);
	else typed.set(id, value);
	return { off: answers.off, typed };
}

/** The questions the rail puts to its rows.
 *
 * The single place a question joins. They are listed in the order the control
 * draws them, and that order carries no rank: a list has to be in some order,
 * and this one is only the order a reader reads them in.
 *
 * Every question is offered whatever this tab happens to hold. A tab on one
 * directory is still asked which directory, for the same reason a tab in one
 * room is still asked for a name: a question with one answer today is a
 * question all the same, and taking it away means the control changes shape
 * under a reader as they join things. */
export function railCriteria(
	dirs: ReadonlyMap<DirId, DirView>,
	home: DirId | null,
): readonly Criterion[] {
	return [
		{
			kind: "text",
			id: "name",
			label: "Name",
			placeholder: "part of a name",
			answer: (row) => row.name,
		},
		{
			kind: "choices",
			id: "directory",
			label: "Directory",
			choices: [...dirs.values()].map((dir) => ({
				value: dir.id as string,
				said: directoryName(dir.id, home),
			})),
			answer: (row) => row.dir as string,
		},
		{
			kind: "choices",
			id: "access",
			label: "Access",
			choices: [
				{ value: "public", said: "Public" },
				{ value: "private", said: "Private" },
			],
			answer: (row) => row.access,
		},
		{
			kind: "choices",
			id: "unread",
			label: "Unread",
			choices: [
				{ value: "unread", said: "Unread" },
				{ value: "caught-up", said: "Caught up" },
			],
			answer: (row) => row.unread,
		},
	];
}

/** How many lines are waiting on this row, for the badge. Zero when caught up
 * or when the rule is still standing. */
export function unreadCount(unread: Unread): number {
	return unread.kind === "unread" ? unread.count : 0;
}

/** A room this tab is in. A private room has no name anybody can enter, so it
 * answers the access question the other way. */
export function roomRow(conv: RoomConv, unread: Unread): RailRow {
	return {
		dir: conv.dir,
		name: conv.id,
		access: conv.held ? "private" : "public",
		unread: unreadAnswer(unread),
	};
}

/** A direct line. It answers the access question with nothing, because a line
 * between two people is neither open nor closed to a directory. */
export function dmRow(conv: DmConv, unread: Unread): RailRow {
	return { dir: conv.dir, name: conv.id, access: null, unread: unreadAnswer(unread) };
}

/** A room somebody handed this tab and it has not answered yet. Private, since
 * a reference is the only way into it. */
export function inviteRow(invite: Invitation): RailRow {
	return { dir: invite.dir, name: invite.label, access: "private", unread: null };
}

/** A directory this tab is on with nothing open on it. It is named by the same
 * words its row draws, so looking for it by name finds it. */
export function dirRow(dir: DirView, home: DirId | null): RailRow {
	return { dir: dir.id, name: directoryName(dir.id, home), access: null, unread: null };
}
