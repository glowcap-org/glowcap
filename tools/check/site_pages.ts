// The pages a rendered site holds, for the checks that open each one in a
// browser: every directory holding an index.html, except an application
// exported beside the pages, such as the Rooms page at rooms/app/. The site
// config lists each of those as a static directory, and the application's own
// checks prove it.
const siteConfig = new URL("../../site/zine.ziggy", import.meta.url);

/** The directories the site config serves as they are, each without the
 * trailing slash its entry carries. */
export async function exportedApplications(): Promise<string[]> {
	const listed = /\.static_assets\s*=\s*\[(?<entries>[^\]]*)\]/.exec(await Deno.readTextFile(siteConfig))
		?.groups?.entries;
	if (listed == null) throw new Error("site/zine.ziggy no longer lists static_assets");
	return [...listed.matchAll(/"(?<directory>[^"]+)\/"/g)].flatMap((entry) => {
		const directory = entry.groups?.directory;
		return directory == null ? [] : [`/${directory}`];
	});
}

export async function sitePages(root: string): Promise<string[]> {
	const applications = await exportedApplications();
	const pages: string[] = [];
	async function walk(dir: string, rel: string): Promise<void> {
		if (applications.includes(rel)) return;
		for await (const entry of Deno.readDir(dir)) {
			if (!entry.isDirectory && entry.name === "index.html") pages.push(`${rel}/`);
			if (entry.isDirectory) await walk(`${dir}/${entry.name}`, `${rel}/${entry.name}`);
		}
	}
	await walk(root, "");
	return pages.sort();
}
