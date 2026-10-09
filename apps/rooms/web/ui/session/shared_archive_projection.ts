// Present an attributed archive account without acquiring archive authority.
import * as store from "../store.ts";
import type { RoomsPageContext } from "../page.ts";
import type { Item } from "../types.ts";
import type { ArchiveLine, ArchiveRecord } from "../../../lib/archive/protocol.ts";
import { archivedAttachmentsMatch, archivedAttachmentViews } from "../archive_attachments.ts";
import { sharedArchiveDivider, sharedArchiveStanding } from "../../../lib/text/attached.ts";
import type { AttachedSessionFiles, FileDescription, HeldFile } from "./attached_files.ts";

const samePreviews = (current: readonly string[] | undefined, next: readonly string[]) =>
	(current?.length ?? 0) === next.length && next.every((url, index) => current?.[index] === url);
function shortId(value: string): string {
	return value.slice(0, 8);
}

export function reconcileSharedArchive(
	page: RoomsPageContext,
	key: string,
	records: readonly ArchiveRecord[],
	from: string,
	files?: Pick<AttachedSessionFiles<FileDescription>, "holdArchived" | "adoptArchived" | "release">,
	source?: (record: ArchiveLine, index: number) => HeldFile | null,
): void {
	const groups = new Map<string, {
		source: string;
		generation: string;
		lines: ArchiveLine[];
		standings: string[];
	}>();
	for (const record of records) {
		const groupKey = `${record.source}\u0000${record.generation}`;
		let group = groups.get(groupKey);
		if (group === undefined) {
			group = { source: record.source, generation: record.generation, lines: [], standings: [] };
			groups.set(groupKey, group);
		}
		if (record.kind === "standing") {
			group.standings.push(`${record.nick} in ${record.room}`);
		} else {
			group.lines.push(record);
		}
	}
	const ordered = [...groups.values()];
	for (const group of ordered) group.lines.sort((a, b) => a.at - b.at || a.order - b.order);
	ordered.sort((a, b) => (a.lines[0]?.at ?? 0) - (b.lines[0]?.at ?? 0));
	const shown = new Map(
		store.historyOf(page.projection, key)
			.filter((item): item is Extract<Item, { kind: "chat" }> => item.kind === "chat" && item.history != null)
			.map((item) => [store.historyCoordinateKey(item.history!), item]),
	);
	for (const group of ordered) {
		const standing = group.standings.length === 0 ? "" : sharedArchiveStanding(group.standings.join("; "));
		const divider = sharedArchiveDivider(from, shortId(group.source), shortId(group.generation), standing);
		const fresh: ArchiveLine[] = [];
		for (const record of group.lines) {
			const current = shown.get(store.historyCoordinateKey(record));
			if (record.state === "withdrawn") {
				// The account's takedown reaches a line it showed earlier; a line it
				// never showed stays unshown.
				if (current != null && current.withdrawn !== true) {
					files?.release(current.attachments ?? []);
					store.reviseItem(page.projection, key, current.id, {
						at: record.at,
						text: "",
						withdrawn: true,
						previewUrls: undefined,
						attachments: undefined,
					});
				}
				continue;
			}
			if (current == null) {
				fresh.push(record);
				continue;
			}
			const attachmentsChanged = !archivedAttachmentsMatch(current, record);
			if (
				current.text !== record.text || current.from !== record.from || current.at !== record.at ||
				current.order !== record.order || (current.edited === true) !== (record.state === "edited") ||
				!samePreviews(current.previewUrls, record.previewUrls) || attachmentsChanged ||
				current.withdrawn === true
			) {
				if (attachmentsChanged) files?.release(current.attachments ?? []);
				const attachments = attachmentsChanged
					? record.attachments.map((attachment, index) =>
						files == null
							? store.attachmentView(page.projection, archivedAttachmentViews([attachment])[0])
							: files.holdArchived(record, index, source)
					)
					: null;
				store.reviseItem(page.projection, key, current.id, {
					from: record.from,
					at: record.at,
					order: record.order,
					text: record.text,
					edited: record.state === "edited",
					withdrawn: false,
					previewUrls: record.previewUrls.length === 0 ? undefined : record.previewUrls,
					...(attachments == null ? {} : { attachments: attachments.length === 0 ? undefined : attachments }),
				});
			}
			if (!attachmentsChanged && files != null) {
				for (let index = 0; index < (current.attachments?.length ?? 0); index++) {
					files.adoptArchived(key, current.attachments![index].id, record, index, source);
				}
			}
		}
		if (
			fresh.length > 0 || standing !== "" ||
			group.lines.some((record) => shown.has(store.historyCoordinateKey(record)))
		) {
			store.insertArchiveLines(
				page.projection,
				key,
				fresh.map((record) => ({
					from: record.from,
					text: record.text,
					mine: false,
					at: record.at,
					order: record.order,
					history: { source: record.source, generation: record.generation, id: record.id },
					edited: record.state === "edited",
					previewUrls: record.previewUrls,
					attachments: files == null
						? archivedAttachmentViews(record.attachments)
						: record.attachments.map((_attachment, index) => files.holdArchived(record, index, source)),
				})),
				divider,
				group,
			);
		}
	}
}
