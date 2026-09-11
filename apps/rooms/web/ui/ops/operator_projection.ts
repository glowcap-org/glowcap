// Render shared operator facts without loading a protocol client or Host.
import type {
	operatorPage,
	OperatorReferenceKind,
	snapshotOperator,
	StewardshipRow,
} from "../../../lib/room/client.ts";
import type { RoomsOperatorState } from "../types.ts";

function viewOf(row: StewardshipRow) {
	return {
		name: row.name,
		label: row.label,
		visibility: row.visibility,
		generation: row.generation,
		issued: row.issued,
		stewardLink: row.steward,
	};
}

export function operatorStateOf(
	snapshot: Awaited<ReturnType<typeof snapshotOperator>>,
	search = "",
	referenceKind: OperatorReferenceKind | null = null,
): RoomsOperatorState {
	return {
		revision: snapshot.revision,
		totals: snapshot.totals,
		search,
		referenceKind,
		stewardships: snapshot.stewardships.map(viewOf),
		links: snapshot.links,
		registrations: snapshot.registrations,
		sessions: snapshot.sessions,
		rooms: snapshot.rooms,
		references: snapshot.references,
		trouble: snapshot.trouble,
		next: snapshot.next,
	};
}

export function appendOperatorPage(current: RoomsOperatorState, page: Awaited<ReturnType<typeof operatorPage>>) {
	const next = {
		...current,
		next: { ...current.next, [page.category]: page.next },
		totals: { ...current.totals, [page.category]: page.total },
	};
	if (page.category === "stewardships") {
		next.stewardships = [...current.stewardships, ...page.rows.map(viewOf)];
	} else if (page.category === "links") {
		next.links = [...current.links, ...page.rows];
	} else if (page.category === "registrations") {
		next.registrations = [...current.registrations, ...page.rows];
	} else if (page.category === "sessions") {
		next.sessions = [...current.sessions, ...page.rows];
	} else if (page.category === "rooms") {
		next.rooms = [...current.rooms, ...page.rows];
	} else if (page.category === "references") {
		next.references = [...current.references, ...page.rows];
	} else next.trouble = [...current.trouble, ...page.rows];
	return next;
}
