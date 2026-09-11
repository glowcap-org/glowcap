// Equality of archive row identities in a presentation projection.
import type { ArchiveCoordinates } from "./protocol.ts";

export function sameArchiveCoordinates(
	left: ArchiveCoordinates | null | undefined,
	right: ArchiveCoordinates | null | undefined,
): boolean {
	return left != null && right != null && left.source === right.source && left.generation === right.generation &&
		left.id === right.id;
}
