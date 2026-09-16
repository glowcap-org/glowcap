// An isolated replacement compiler: use the real application sources and
// artifacts, but give the publisher no Vite configuration or dependency imports.
import { ROOT } from "./paths.ts";

export async function denoBrowserSource(directory: string): Promise<string> {
	const web = `${directory}/repo/apps/rooms/web`;
	await Deno.mkdir(web, { recursive: true });
	for (const relative of ["apps/rooms/web/ui", "apps/rooms/lib", "bindings/ts", "zig-out/wasm/rooms", "ui/fonts"]) {
		const target = `${directory}/repo/${relative}`;
		await Deno.mkdir(target.slice(0, target.lastIndexOf("/")), { recursive: true });
		await Deno.symlink(`${ROOT}${relative}`, target, { type: "dir" });
	}
	const config = JSON.parse(await Deno.readTextFile(`${ROOT}apps/rooms/web/deno.json`));
	for (const name of ["vite", "@vitejs/plugin-react", "@deno/vite-plugin"]) delete config.imports[name];
	delete config.tasks;
	await Deno.writeTextFile(`${web}/deno.json`, JSON.stringify(config));
	await Deno.copyFile(`${ROOT}apps/rooms/web/deno.lock`, `${web}/deno.lock`);
	// Prune the copied lock after removing the build dependencies, then restore
	// the ordinary frozen build. The configured compiler has warmed this cache.
	const installed = await new Deno.Command(Deno.execPath(), {
		args: ["install", "--config", `${web}/deno.json`, "--frozen=false", "--cached-only"],
		cwd: web,
		stdout: "piped",
		stderr: "piped",
	}).output();
	if (!installed.success) throw new Error(new TextDecoder().decode(installed.stderr));
	await Deno.writeTextFile(
		`${web}/compiler.json`,
		JSON.stringify({
			args: [
				"bundle",
				"--config",
				"deno.json",
				"--platform",
				"browser",
				"--minify",
				"--code-splitting",
				"--outdir",
				"{outdir}",
				"ui/page.js",
			],
			inputs: [],
		}),
	);
	return web;
}
