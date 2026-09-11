// Page-address presentation. Rust owns directory connections and their lifetime.
import { directoryId } from "./application.ts";
import { directoryLocator as advertisedDirectory } from "./prefs.ts";
import type { RoomsPageContext } from "./page.ts";
import type { DirId } from "./types.ts";
import type { Given } from "./intent.ts";
export { directoryId } from "./application.ts";

export class PageBootstrap {
	homeDirectoryLocator: string | null = null;
	pageDirectoryId: DirId | null = null;
	selectionReservedByAddress = false;
}
export async function homeLocator(page: RoomsPageContext): Promise<string> {
	if (page.bootstrap.homeDirectoryLocator != null) return page.bootstrap.homeDirectoryLocator;
	const locator = await advertisedDirectory();
	if (locator == null) throw new Error("Rooms directory address is unavailable");
	page.bootstrap.homeDirectoryLocator = locator;
	return locator;
}
export function dirAddress(page: RoomsPageContext, id: DirId): string {
	return page.projection.get().dirs.get(id)?.locator ?? id;
}
export function actLocator(page: RoomsPageContext, given: Given<string>): Given<string> {
	if (given.value.trim() === "") return given;
	const known = directoryId(given.value);
	if (known == null) return given;
	if (known === page.projection.get().homeDir) return { ...given, value: "" };
	return { ...given, value: page.projection.get().dirs.get(known)?.locator ?? given.value };
}
export function reserveSelectionForAddress(page: RoomsPageContext): void {
	page.bootstrap.selectionReservedByAddress = true;
}
