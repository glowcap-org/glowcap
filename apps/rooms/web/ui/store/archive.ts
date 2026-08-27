// Presentation rows for read-only archive facets another member handed over.
// Live references and their sessions remain in net/archive_shares.ts.

import type { ArchiveShareView } from "../archive_model.ts";
import { get, set } from "./core.ts";

export function addArchiveShare(share: ArchiveShareView): void {
	set({ archiveShares: [...get().archiveShares, share] });
}

export function patchArchiveShare(id: string, patch: Partial<Omit<ArchiveShareView, "id">>): void {
	const shares = get().archiveShares;
	if (!shares.some((share) => share.id === id)) return;
	set({ archiveShares: shares.map((share) => share.id === id ? { ...share, ...patch } : share) });
}

export function dropArchiveShare(id: string): void {
	const shares = get().archiveShares;
	if (!shares.some((share) => share.id === id)) return;
	set({ archiveShares: shares.filter((share) => share.id !== id) });
}
