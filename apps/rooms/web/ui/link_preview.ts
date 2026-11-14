// Browser effect state over the shared Rust Open Graph vocabulary.
import { LocalRefusal } from "../../lib/text/failure.ts";
import { invariant } from "../../lib/invariant.ts";
import { openGraphMetadata, openGraphSelection, openGraphTargets } from "./application.ts";
import { ROOMS_FAILURES, type RoomsErrorCode, type RoomsFailureRetry } from "../../lib/failure_data.ts";

export interface OpenGraphImage {
	readonly url: string;
	readonly mediaType?: string;
	readonly width?: number;
	readonly height?: number;
	readonly alt?: string;
}

export interface OpenGraphMetadata {
	readonly requestedUrl: string;
	readonly title?: string;
	readonly description?: string;
	readonly images: readonly OpenGraphImage[];
}

export interface PreviewFailure {
	readonly code: string;
	readonly summary: string;
	readonly action?: string;
	readonly retry: RoomsFailureRetry;
}

const RETRIES: ReadonlySet<unknown> = new Set(Object.values(ROOMS_FAILURES).map((definition) => definition.retry));
const isRetry = (value: unknown): value is RoomsFailureRetry => RETRIES.has(value);
const isRoomsCode = (code: string): code is RoomsErrorCode => Object.hasOwn(ROOMS_FAILURES, code);

export type DraftPreview =
	| { readonly id: number; readonly url: string; readonly state: "offered"; readonly attempt: number }
	| { readonly id: number; readonly url: string; readonly state: "fetching"; readonly attempt: number }
	| {
		readonly id: number;
		readonly url: string;
		readonly state: "ready";
		readonly attempt: number;
		readonly metadata: OpenGraphMetadata;
	}
	| {
		readonly id: number;
		readonly url: string;
		readonly state: "failed";
		readonly attempt: number;
		readonly failure: PreviewFailure;
	}
	| { readonly id: number; readonly url: string; readonly state: "removed"; readonly attempt: number };

interface Target {
	readonly url: string;
}

/** The links in `text` worth a preview. Rust's Markdown reader answers; an
 * answer of any other shape is a defect in the shared build, not an empty draft. */
export function previewTargets(text: string): readonly Target[] {
	const value = JSON.parse(openGraphTargets(text));
	if (
		Array.isArray(value) &&
		value.every((target) => target != null && typeof target === "object" && typeof target.url === "string")
	) {
		return value as Target[];
	}
	invariant(false, "the Rooms application answered malformed preview targets");
}

/** Admit a selected subset through the shared Rust authority before it can
 * cause reader-side network effects. This is the final boundary for archives
 * and peers whose outer tuple parser can prove shape but not Markdown meaning. */
export function previewSelection(text: string, urls: readonly string[]): readonly string[] {
	// No answer is Rust refusing the subset, which admits nothing.
	const encoded = openGraphSelection(text, JSON.stringify(urls));
	if (encoded == null) return [];
	const value = JSON.parse(encoded);
	if (Array.isArray(value) && value.every((url) => typeof url === "string")) return value;
	invariant(false, "the Rooms application answered a malformed preview selection");
}

/** Preserve intent and completed effects only while the same normalized target
 * remains in the draft. Removing and later re-adding a URL creates a new
 * offered intent. Unrelated edits cannot resurrect a removed preview. */
export function reconcileDraftPreviews(
	current: readonly DraftPreview[],
	text: string,
	allocate: () => number,
): readonly DraftPreview[] {
	const byUrl = new Map(current.map((preview) => [preview.url, preview]));
	return previewTargets(text).map(({ url }) =>
		byUrl.get(url) ?? { id: allocate(), url, state: "offered", attempt: 0 }
	);
}

/** Ask the Rooms server at `service` for what a link shows. */
export async function fetchPreview(
	service: string,
	url: string,
	signal: AbortSignal,
	refresh = false,
): Promise<OpenGraphMetadata> {
	const query = new URLSearchParams({ url });
	if (refresh) query.set("refresh", "1");
	const response = await fetch(new URL(`link-preview?${query}`, service), {
		signal,
		credentials: "omit",
		cache: "no-store",
		headers: { accept: "application/json" },
	});
	const httpFailure = response.ok ? null : { code: "link-preview-failed", ...ROOMS_FAILURES["link-preview-failed"] };
	let result: unknown;
	try {
		result = await response.json();
	} catch (cause) {
		if (!(cause instanceof SyntaxError)) throw cause;
		if (httpFailure != null) throw httpFailure;
		throw new LocalRefusal("preview-unreadable", { cause });
	}
	if (result != null && typeof result === "object" && !Array.isArray(result) && "ok" in result) {
		if (response.ok && result.ok === true && "metadata" in result) {
			const metadata = validMetadata(result.metadata);
			if (metadata != null && metadata.requestedUrl === url) return metadata;
		} else if (result.ok === false && "failure" in result) {
			const failure = result.failure;
			if (
				failure != null && typeof failure === "object" && !Array.isArray(failure) &&
				"code" in failure && typeof failure.code === "string" &&
				"summary" in failure && typeof failure.summary === "string"
			) throw failure;
		}
	}
	if (httpFailure != null) throw httpFailure;
	throw new LocalRefusal("preview-unreadable");
}

/** The service's metadata as Rust admits it, or null when Rust refuses it. */
function validMetadata(value: unknown): OpenGraphMetadata | null {
	const encoded = openGraphMetadata(JSON.stringify(value));
	return encoded == null ? null : JSON.parse(encoded) as OpenGraphMetadata;
}

/** Where a preview card goes, as the browser that opens it reads the address:
 * the host, with its port when that is not the scheme's own. Every address a
 * card holds is one Rust admitted, so it parses. */
export function previewHost(url: string): string {
	return new URL(url).host;
}

/** The failure a preview fetch settled with, in the shared failure vocabulary.
 * A retry outside that vocabulary is not advice: the code's own definition
 * answers when the code is a Rooms code, and an unknown code offers no retry. */
export function previewFailure(error: unknown): PreviewFailure {
	if (error instanceof LocalRefusal) return { code: error.code, summary: error.message, retry: error.retry };
	if (error != null && typeof error === "object" && !Array.isArray(error)) {
		const code = "code" in error ? error.code : null;
		const summary = "summary" in error ? error.summary : null;
		const action = "action" in error ? error.action : null;
		const retry = "retry" in error ? error.retry : null;
		if (typeof code === "string" && typeof summary === "string") {
			return {
				code,
				summary,
				...(typeof action === "string" ? { action } : {}),
				retry: isRetry(retry) ? retry : isRoomsCode(code) ? ROOMS_FAILURES[code].retry : "never",
			};
		}
	}
	const fallback = ROOMS_FAILURES["link-preview-failed"];
	return {
		code: "link-preview-failed",
		summary: fallback.summary,
		...(fallback.action == null ? {} : { action: fallback.action }),
		retry: fallback.retry,
	};
}

export function previewImageUrl(service: string, url: string): string {
	return new URL(`link-preview/image?url=${encodeURIComponent(url)}`, service).href;
}
