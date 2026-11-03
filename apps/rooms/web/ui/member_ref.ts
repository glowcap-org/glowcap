// Which person a member card is about.

/** Which person a member card is about.
 *
 * `conv` is the room whose roster the reading came from. It is null when the
 * reader opened their own card from the rail's foot, which is about them on the
 * page rather than in any one room, and the card says so rather than naming a
 * room that was never asked about. */
export interface MemberRef {
	readonly conv: string | null;
	readonly name: string;
}
