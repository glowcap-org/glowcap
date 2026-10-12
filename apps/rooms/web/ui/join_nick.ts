// The join card's nickname answer: typed intent reconciled with directory and
// room evidence, including the authoritative refusal from an earlier attempt.

import type { Conv, DirId, Standing } from "./types.ts";
import { nicknameAvailability, roomAuthorityToken } from "./application.ts";

export interface JoinNickTarget {
	readonly directory: DirId;
	/** A link is exact room identity. Without one, the public room's folded name
	 * is identity inside its directory. */
	readonly link: string | null;
	readonly room: string;
}

export type JoinNickAvailability =
	| { readonly kind: "unknown" }
	| { readonly kind: "available" }
	| { readonly kind: "taken"; readonly source: "directory" | "room"; readonly suggestion: string };

export interface JoinNickAnswer {
	/** The available name drawn in an empty field. */
	readonly placeholder: string;
	/** The exact name pressing Join will request. */
	readonly request: string;
	/** What the live evidence can prove about that exact request. */
	readonly availability: JoinNickAvailability;
}

export interface JoinNickRefusal {
	/** A newer replacement for the implicit offer this answer is reconciling. */
	readonly suggestion: string;
}

/** Reconcile the field's intent with the live naming evidence.
 *
 * An empty field accepts the offered name. If that name is already known to
 * be occupied, its next available spelling becomes both the placeholder and
 * the request. An explicit name remains the reader's choice and is never
 * silently replaced. Presentation, validation, and submission consume this
 * one answer so an empty field cannot display one identity and submit another. */
export function answerJoinNick(
	nick: string,
	offeredNick: string,
	target: JoinNickTarget | null,
	ownNick: string | null,
	registeredNames: Iterable<string> | null,
	conversations: ReadonlyMap<string, Conv>,
	members: ReadonlyMap<string, ReadonlyMap<string, Standing>>,
	refusal: JoinNickRefusal | null = null,
): JoinNickAnswer {
	const names = registeredNames === null ? null : [...registeredNames];
	const offeredAvailability = joinNickAvailability(
		offeredNick,
		target,
		ownNick,
		names,
		conversations,
		members,
	);
	let placeholder = offeredAvailability.kind === "taken" ? offeredAvailability.suggestion : offeredNick;
	// A refusal is newer authority than an offer made without enough live
	// evidence. Empty means the reader accepted the offer, so advance that offer
	// without pretending they explicitly typed the replacement. An explicit
	// field remains untouched and requires an explicit choice.
	if (nick === "" && refusal !== null) placeholder = refusal.suggestion;
	const request = nick === "" ? placeholder : nick;
	return {
		placeholder,
		request,
		availability: request === offeredNick
			? offeredAvailability
			: joinNickAvailability(request, target, ownNick, names, conversations, members),
	};
}

/** What this tab can prove about a requested room nickname now.
 *
 * A live directory registration reserves its name across that directory, so
 * it proves a collision before this tab has the room. A room listing only
 * carries a count. Room-local knowledge comes from holding the exact room and
 * receiving its roster. The room still judges at submit time because either
 * reading can race another arrival. */
export function joinNickAvailability(
	nick: string,
	target: JoinNickTarget | null,
	ownNick: string | null,
	registeredNames: Iterable<string> | null,
	conversations: ReadonlyMap<string, Conv>,
	members: ReadonlyMap<string, ReadonlyMap<string, Standing>>,
): JoinNickAvailability {
	if (nick === "" || target === null) return { kind: "unknown" };
	const directoryNames = registeredNames === null ? null : [...registeredNames];
	const room = [...conversations.values()].find((candidate) =>
		candidate.type === "room" && candidate.membership === "joined" &&
		(target.link !== null
			? candidate.linkToken === roomAuthorityToken(target.link)
			: !candidate.held && candidate.dir === target.directory &&
				candidate.id.toLowerCase() === target.room.toLowerCase())
	);
	const roster = room === undefined ? undefined : members.get(room.key);
	// A joined room announces a roster containing this reader. Its absence is a
	// projection gap, not evidence that every name is free.
	const rosterNames = roster !== undefined && roster.size > 0 ? [...roster.keys()] : null;
	// The directory's actual grant proves this reader is the holder. Rust owns
	// collision folding and suffix policy; this adapter only selects which live
	// directory and room evidence describes the aimed destination.
	return nicknameAvailability(nick, ownNick, directoryNames, rosterNames);
}
