// Page-address presentation. Rust owns directory connections and their lifetime.
import { directoryId } from "./application.ts";
import type { RoomsPageContext } from "./page.ts";
import type { DirId, DirView } from "./directory.ts";
import type { Given } from "./intent.ts";
export { directoryId } from "./application.ts";

export class PageBootstrap {
	pageDirectoryId: DirId | null = null;
	selectionReservedByAddress = false;
}

/** The address a directory is reached at, as a link that leaves the page says
 * it: its locator, or its id while no locator is known. */
export function dirAddress(dirs: ReadonlyMap<DirId, DirView>, id: DirId): string {
	return dirs.get(id)?.locator || id;
}

export function actLocator(page: RoomsPageContext, given: Given<string>): Given<string> {
	if (given.value.trim() === "") return given;
	const known = directoryId(given.value);
	if (known == null) return given;
	if (known === page.projection.get().homeDirectory) return { ...given, value: "" };
	return { ...given, value: page.projection.get().dirs.get(known)?.locator ?? given.value };
}

export function reserveSelectionForAddress(page: RoomsPageContext): void {
	page.bootstrap.selectionReservedByAddress = true;
}
