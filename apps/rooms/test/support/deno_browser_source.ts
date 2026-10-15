// An isolated replacement compiler: use the real application sources and
// artifacts, but give the publisher no Vite configuration or dependency imports.
import { parse as parseJsonc } from "@std/jsonc";
import { ROOT } from "./paths.ts";

export async function denoBrowserSource(directory: string): Promise<string> {
	const web = `${directory}/repo/apps/rooms/web`;
	await Deno.mkdir(web, { recursive: true });
	for (const relative of ["apps/rooms/web/ui", "apps/rooms/lib", "bindings/ts", "zig-out/wasm/rooms", "ui/fonts"]) {
		const target = `${directory}/repo/${relative}`;
		await Deno.mkdir(target.slice(0, target.lastIndexOf("/")), { recursive: true });
		await Deno.symlink(`${ROOT}${relative}`, target, { type: "dir" });
	}
	// The manifest carries a comment per dependency, so it is JSONC.
	const config = parseJsonc(await Deno.readTextFile(`${ROOT}apps/rooms/web/deno.json`)) as {
		imports: Record<string, string>;
		tasks?: Record<string, string>;
	};
	// Only the browser graph stays: the publisher gets no build or test import.
	for (const name of ["vite", "@vitejs/plugin-react", "@deno/vite-plugin", "@std/assert"]) {
		delete config.imports[name];
	}
	delete config.tasks;
	await Deno.writeTextFile(`${web}/deno.json`, JSON.stringify(config));
	await Deno.copyFile(`${ROOT}apps/rooms/web/deno.lock`, `${web}/deno.lock`);
	// Prune the copied lock after removing the build and test imports, then
	// restore the ordinary frozen build. Pruning re-resolves each npm specifier
	// against registry metadata, which a shared cache warmed from the lock can
	// hold older than the lock, so this may fetch it as the bundle below does.
	const installed = await new Deno.Command(Deno.execPath(), {
		args: ["install", "--config", `${web}/deno.json`, "--frozen=false"],
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
				"ui/ground.js",
			],
			inputs: [],
		}),
	);
	return web;
}
