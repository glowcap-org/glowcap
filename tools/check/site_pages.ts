// The pages a rendered site holds, for the checks that open each one in a
// browser: every directory holding an index.html, except an application
// exported beside the pages, such as the Rooms page at rooms/app/. Its
// index.html carries the Rooms mark of a page with no server behind it, and
// the Rooms checks prove it.
export async function sitePages(root: string): Promise<string[]> {
	const pages: string[] = [];
	async function walk(dir: string, rel: string): Promise<void> {
		for await (const entry of Deno.readDir(dir)) {
			if (!entry.isDirectory && entry.name === "index.html") {
				const page = await Deno.readTextFile(`${dir}/${entry.name}`);
				if (!page.includes('<meta name="rooms-host"')) pages.push(`${rel}/`);
			}
			if (entry.isDirectory) await walk(`${dir}/${entry.name}`, `${rel}/${entry.name}`);
		}
	}
	await walk(root, "");
	return pages.sort();
}
