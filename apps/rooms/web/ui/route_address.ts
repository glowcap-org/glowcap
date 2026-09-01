// Canonical browser addresses for Rooms presentation state.

/** Keep only the page-startup choices that every navigable Rooms address
 * carries. Modal and pane state never belongs in a shared URL. */
export function pageSearch(): URLSearchParams {
	const here = new URLSearchParams(location.search);
	const kept = new URLSearchParams();
	for (const name of ["dm", "viz"]) {
		const value = here.get(name);
		if (value !== null) kept.set(name, value);
	}
	return kept;
}

export function withPageSearch(path: string, search: URLSearchParams = pageSearch()): string {
	const text = search.toString();
	return text === "" ? path : `${path}?${text}`;
}

export function roomAddress(
	name: string,
	options: { directory?: string; private?: boolean } = {},
): string {
	const search = pageSearch();
	if (options.directory != null) search.set("dir", options.directory);
	if (options.private === true) search.set("private", "1");
	return withPageSearch(`/room/${encodeURIComponent(name)}`, search);
}

/** This page's directory is `/directory`; any other is `/directory?dir=`. */
export function directoryAddress(options: { directory?: string } = {}): string {
	const search = pageSearch();
	if (options.directory != null) search.set("dir", options.directory);
	return withPageSearch("/directory", search);
}
