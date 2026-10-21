// Presentation rows for read-only archive facets another member handed over.
// Live references and their sessions remain in session/managed/archive_shares.ts.

import type { ArchiveShareView } from "../archive_model.ts";
import type { PageProjection } from "./core.ts";

export function patchArchiveShare(
	projection: PageProjection,
	id: string,
	patch: Partial<Omit<ArchiveShareView, "id">>,
): void {
	const shares = projection.get().archiveShares;
	if (!shares.some((share) => share.id === id)) return;
	projection.set({ archiveShares: shares.map((share) => share.id === id ? { ...share, ...patch } : share) });
}

export function dropArchiveShare(projection: PageProjection, id: string): void {
	const shares = projection.get().archiveShares;
	if (!shares.some((share) => share.id === id)) return;
	projection.set({ archiveShares: shares.filter((share) => share.id !== id) });
}
