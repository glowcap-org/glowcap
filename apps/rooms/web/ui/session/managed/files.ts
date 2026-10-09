// The existing presentation owner retains one opaque source per displayed file.
// Rust reserves receiver capacity and streams directly to a browser Blob.
import type { RoomsManagedFile } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { AttachedSessionFiles, type FileDescription, type FileSources } from "../attached_files.ts";
import type { PageProjection } from "../../store/core.ts";
import type { ArchiveSource } from "./history.ts";
import type { ArchiveLine } from "../../../../lib/archive/protocol.ts";

export interface PresentedFile extends FileDescription {
	open(progress: (got: number) => void, signal: AbortSignal): ReturnType<RoomsManagedFile["open"]>;
	release(): void;
}
export function presentFile(file: RoomsManagedFile): PresentedFile {
	try {
		return {
			...file.description(),
			open: (progress, signal) => file.open(progress, signal),
			release: () => {
				try {
					file.release();
				} finally {
					file.free();
				}
			},
		};
	} catch (error) {
		file.free();
		throw error;
	}
}
export function presentationFiles(projection: PageProjection, archive: () => ArchiveSource | null) {
	const source: FileSources<PresentedFile> = {
		fetchAttachment: (file, progress, signal) => file.open(progress, signal),
		releaseAttachment: (file) => file.release(),
		archiveSource: (record: ArchiveLine, index) => archive()?.file(record, index) ?? null,
	};
	return new AttachedSessionFiles(source, projection);
}
