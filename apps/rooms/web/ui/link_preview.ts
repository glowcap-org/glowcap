// Browser effect state over the shared Rust Open Graph vocabulary.
import { openGraphMetadata, openGraphSelection, openGraphTargets } from "./application.ts";
import { ROOMS_FAILURES } from "../../lib/failure_data.ts";
import { linkPreviewShared } from "../../lib/text/link_preview.ts";

export interface OpenGraphImage {
	readonly url: string;
	readonly mediaType?: string;
	readonly width?: number;
	readonly height?: number;
	readonly alt?: string;
}

export interface OpenGraphMetadata {
	readonly requestedUrl: string;
	readonly url: string;
	readonly title?: string;
	readonly description?: string;
	readonly siteName?: string;
	readonly objectType?: string;
	readonly images: readonly OpenGraphImage[];
}

export interface PreviewFailure {
	readonly code: string;
	readonly summary: string;
	readonly action?: string;
	readonly retry: "never" | "after-request-change" | "after-state-change" | "after-request-or-state-change" | "soon";
}

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

export function previewTargets(text: string): readonly Target[] {
	try {
		const value = JSON.parse(openGraphTargets(text));
		return Array.isArray(value) &&
				value.every((target) => target != null && typeof target === "object" && typeof target.url === "string")
			? value as Target[]
			: [];
	} catch {
		return [];
	}
}

/** Admit a selected subset through the shared Rust authority before it can
 * cause reader-side network effects. This is the final boundary for archives
 * and peers whose outer tuple parser can prove shape but not Markdown meaning. */
export function previewSelection(text: string, urls: readonly string[]): readonly string[] {
	try {
		const encoded = openGraphSelection(text, JSON.stringify(urls));
		if (encoded == null) return [];
		const value = JSON.parse(encoded);
		return Array.isArray(value) && value.every((url) => typeof url === "string") ? value : [];
	} catch {
		return [];
	}
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

export async function fetchPreview(url: string, signal: AbortSignal, refresh = false): Promise<OpenGraphMetadata> {
	const query = new URLSearchParams({ url });
	if (refresh) query.set("refresh", "1");
	const response = await fetch(`/link-preview?${query}`, {
		signal,
		credentials: "same-origin",
		cache: "no-store",
		headers: { accept: "application/json" },
	});
	const result = await response.json() as
		| { readonly ok: true; readonly metadata: OpenGraphMetadata }
		| { readonly ok: false; readonly failure: PreviewFailure };
	if (result.ok) {
		const metadata = validMetadata(result.metadata);
		if (metadata != null && metadata.requestedUrl === url) return metadata;
		throw new Error("the link preview service returned malformed metadata");
	}
	throw result.failure;
}

function validMetadata(value: unknown): OpenGraphMetadata | null {
	try {
		const encoded = openGraphMetadata(JSON.stringify(value));
		return encoded == null ? null : JSON.parse(encoded) as OpenGraphMetadata;
	} catch {
		return null;
	}
}

export function previewHost(url: string): string {
	try {
		return new URL(url).hostname;
	} catch {
		return linkPreviewShared;
	}
}

export function previewFailure(error: unknown): PreviewFailure {
	if (
		error != null && typeof error === "object" &&
		typeof (error as Partial<PreviewFailure>).code === "string" &&
		typeof (error as Partial<PreviewFailure>).summary === "string"
	) {
		const failure = error as Partial<PreviewFailure>;
		return {
			code: failure.code!,
			summary: failure.summary!,
			...(typeof failure.action === "string" ? { action: failure.action } : {}),
			retry: failure.retry === "never" || failure.retry === "after-request-change" ||
					failure.retry === "after-state-change" || failure.retry === "after-request-or-state-change" ||
					failure.retry === "soon"
				? failure.retry
				: "soon",
		};
	}
	const fallback = ROOMS_FAILURES["link-preview-failed"];
	return {
		code: "link-preview-failed",
		summary: fallback.summary,
		...(fallback.action == null ? {} : { action: fallback.action }),
		retry: fallback.retry,
	};
}

export function previewImageUrl(url: string): string {
	return `/link-preview/image?url=${encodeURIComponent(url)}`;
}
