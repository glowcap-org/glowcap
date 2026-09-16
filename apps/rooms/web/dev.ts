#!/usr/bin/env -S deno run -A
/** The process owner behind `zig build rooms-dev`.
 *
 * The build step supplies the native `rooms-web` executable, public port, and
 * server arguments. This program starts that backend on an ephemeral loopback
 * port, points Vite at it, and retires both processes on exit. */
import { fileURLToPath } from "node:url";

const webRoot = fileURLToPath(new URL("./", import.meta.url));
const denoConfig = fileURLToPath(new URL("./deno.json", import.meta.url));
const viteConfig = fileURLToPath(new URL("./vite.config.ts", import.meta.url));
const handledSignals = ["SIGINT", "SIGTERM", "SIGHUP"] as const;

export interface DevelopmentLaunch {
	web: string;
	port: number;
	args: string[];
}

export function parseDevelopmentLaunch(args: string[]): DevelopmentLaunch {
	if (args.length < 2 || args[0]?.trim() === "") {
		throw new Error("rooms-dev needs the rooms-web executable and public port");
	}
	const port = Number(args[1]);
	if (!Number.isInteger(port) || port < 1 || port > 65_535) {
		throw new Error("rooms-dev public port must be an integer from 1 through 65535");
	}
	return { web: args[0], port, args: args.slice(2) };
}

export function backendFromOutput(output: string): string | null {
	const match = output.match(/(?:^|\n)\s*web ui\s+http:\/\/localhost:(\d+)(?:\r?\n|$)/);
	if (match?.[1] == null) return null;
	const port = Number(match[1]);
	return Number.isInteger(port) && port > 0 && port <= 65_535 ? `http://127.0.0.1:${port}` : null;
}

const VITE_SHUTDOWN_GRACE_MS = 5_000;
// rooms-web gives an owned peer up to 30 seconds to retire before it escalates.
// The outer owner must not kill it first and strand the peer it is reaping.
const BACKEND_SHUTDOWN_GRACE_MS = 35_000;

async function signal(
	child: Deno.ChildProcess,
	status: Promise<Deno.CommandStatus>,
	value: Deno.Signal,
): Promise<void> {
	try {
		child.kill(value);
	} catch (error) {
		if (error instanceof Deno.errors.NotFound) return;
		let timer: ReturnType<typeof setTimeout> | undefined;
		const ended = await Promise.race([
			status.then(() => true),
			new Promise<false>((resolve) => {
				timer = setTimeout(() => resolve(false), 0);
			}),
		]);
		if (timer != null) clearTimeout(timer);
		if (!ended) throw error;
	}
}

async function retire(
	child: Deno.ChildProcess,
	status: Promise<Deno.CommandStatus>,
	name: string,
	graceMs: number,
): Promise<void> {
	await signal(child, status, "SIGTERM");
	let timer: ReturnType<typeof setTimeout> | undefined;
	const ended = await Promise.race([
		status.then(() => true),
		new Promise<false>((resolve) => {
			timer = setTimeout(() => resolve(false), graceMs);
		}),
	]);
	if (timer != null) clearTimeout(timer);
	if (ended) return;
	await signal(child, status, "SIGKILL");
	const forced = await status;
	throw new Error(`${name} ignored SIGTERM and was killed (${forced.code})`);
}

async function mirrorAndFindBackend(
	stream: ReadableStream<Uint8Array>,
	found: PromiseWithResolvers<string>,
): Promise<void> {
	const reader = stream.getReader();
	const decoder = new TextDecoder();
	const encoder = new TextEncoder();
	let pending = "";
	const write = async (line: string) => {
		const backend = backendFromOutput(line);
		if (backend != null) {
			found.resolve(backend);
			line = `  native backend   ${backend} (internal)\n`;
		}
		await Deno.stdout.write(encoder.encode(line));
	};
	try {
		while (true) {
			const { value, done } = await reader.read();
			if (done) break;
			pending += decoder.decode(value, { stream: true });
			let newline = pending.indexOf("\n");
			while (newline >= 0) {
				await write(pending.slice(0, newline + 1));
				pending = pending.slice(newline + 1);
				newline = pending.indexOf("\n");
			}
		}
		pending += decoder.decode();
		if (pending !== "") await write(pending);
	} finally {
		reader.releaseLock();
	}
}

async function run(launch: DevelopmentLaunch): Promise<void> {
	const backendChild = new Deno.Command(launch.web, {
		args: [
			"--http-bind=127.0.0.1",
			"--http-port=0",
			"--no-browser-assets",
			...launch.args,
		],
		stdin: "null",
		stdout: "piped",
		stderr: "inherit",
	}).spawn();
	const backend = Promise.withResolvers<string>();
	const output = mirrorAndFindBackend(backendChild.stdout, backend);
	const backendStatus = backendChild.status;
	let viteChild: Deno.ChildProcess | null = null;
	let viteStatus: Promise<Deno.CommandStatus> | null = null;
	const signals = Promise.withResolvers<void>();
	const stop = () => signals.resolve();
	for (const signal of handledSignals) Deno.addSignalListener(signal, stop);
	let failure: unknown = null;
	try {
		const target = await Promise.race<string | null>([
			backend.promise,
			backendStatus.then((result) => {
				throw new Error(`rooms-web exited before its HTTP backend was ready (${result.code})`);
			}),
			signals.promise.then(() => null),
		]);
		if (target != null) {
			viteChild = new Deno.Command(Deno.execPath(), {
				args: ["run", "-A", "--config", denoConfig, "vite", "--config", viteConfig],
				cwd: webRoot,
				env: {
					GLOWCAP_ROOMS_DEV_BACKEND: target,
					GLOWCAP_ROOMS_DEV_PORT: String(launch.port),
				},
				stdin: "null",
				stdout: "inherit",
				stderr: "inherit",
			}).spawn();
			viteStatus = viteChild.status;
			await Promise.race([
				signals.promise,
				backendStatus.then((result) => {
					throw new Error(`rooms-web exited while Vite was serving (${result.code})`);
				}),
				viteStatus.then((result) => {
					throw new Error(`Vite exited while rooms-web was serving (${result.code})`);
				}),
			]);
		}
	} catch (error) {
		failure = error;
	}
	// Keep handling repeated interrupts until both children have been reaped.
	// Restoring the default signal action here would abandon backend cleanup.
	const cleanup: unknown[] = [];
	if (viteChild != null && viteStatus != null) {
		try {
			await retire(viteChild, viteStatus, "Vite", VITE_SHUTDOWN_GRACE_MS);
		} catch (error) {
			cleanup.push(error);
		}
	}
	try {
		await retire(backendChild, backendStatus, "rooms-web", BACKEND_SHUTDOWN_GRACE_MS);
	} catch (error) {
		cleanup.push(error);
	}
	try {
		await output;
	} catch (error) {
		cleanup.push(error);
	}
	for (const signal of handledSignals) Deno.removeSignalListener(signal, stop);
	if (failure != null && cleanup.length > 0) {
		throw new AggregateError([failure, ...cleanup], "rooms-dev failed and cleanup was incomplete");
	}
	if (failure != null) throw failure;
	if (cleanup.length > 0) throw new AggregateError(cleanup, "rooms-dev cleanup was incomplete");
}

if (import.meta.main) {
	try {
		await run(parseDevelopmentLaunch(Deno.args));
	} catch (error) {
		console.error(`rooms-dev: ${error instanceof Error ? error.message : String(error)}`);
		Deno.exit(1);
	}
}
