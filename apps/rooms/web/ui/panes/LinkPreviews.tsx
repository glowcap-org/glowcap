import { useEffect, useState } from "react";
import {
	linkPreviewLoading,
	linkPreviewRemove,
	linkPreviewRetry,
	linkPreviewsLabel,
} from "../../../lib/text/link_preview.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { Button } from "../Button.tsx";
import { IconButton } from "../IconButton.tsx";
import {
	type DraftPreview,
	fetchPreview,
	type OpenGraphMetadata,
	previewFailure,
	previewHost,
	previewImageUrl,
	previewSelection,
} from "../link_preview.ts";

const FETCH_SETTLE_MS = 300;

function PreviewImage({ image }: { image: OpenGraphMetadata["images"][number] }) {
	const [visible, setVisible] = useState(true);
	if (!visible) return null;
	return (
		<img
			src={previewImageUrl(image.url)}
			alt={image.alt ?? ""}
			width={image.width}
			height={image.height}
			loading="lazy"
			decoding="async"
			onError={() => setVisible(false)}
		/>
	);
}

/** One fetch attempt lives outside the card presentation. Keeping this child
 * mounted across offered -> fetching avoids cancelling the effect because of
 * its own state transition; removing or settling the card unmounts it and
 * cancels only the exact attempt it started. */
function PreviewEffect({ conversation, preview }: { conversation: string; preview: DraftPreview }) {
	const browser = useRoomsBrowser();
	useEffect(() => {
		if (preview.state !== "offered") return;
		let started: DraftPreview | null = null;
		let abort: AbortController | null = null;
		const timer = setTimeout(() => {
			started = browser.startPreview(conversation, preview.id);
			if (started?.state !== "fetching") return;
			const attempt = started;
			abort = new AbortController();
			void fetchPreview(attempt.url, abort.signal, attempt.attempt > 0).then(
				(metadata) =>
					browser.settlePreview(conversation, attempt.id, attempt.attempt, { state: "ready", metadata }),
				(error) => {
					if (abort?.signal.aborted) return;
					browser.settlePreview(conversation, attempt.id, attempt.attempt, {
						state: "failed",
						failure: previewFailure(error),
					});
				},
			);
		}, FETCH_SETTLE_MS);
		return () => {
			clearTimeout(timer);
			abort?.abort();
			if (started?.state === "fetching") {
				browser.cancelPreview(conversation, started.id, started.attempt);
			}
		};
		// The effect owns this id/attempt until it settles or unmounts. Fetching
		// and ready are outcomes of that same attempt, not reasons to cancel it.
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [browser, conversation, preview.id, preview.url, preview.attempt]);
	return null;
}

function PreviewCard({ conversation, preview }: { conversation: string; preview: DraftPreview }) {
	const browser = useRoomsBrowser();

	if (preview.state === "removed") return null;
	const effect = (preview.state === "offered" || preview.state === "fetching") && (
		<PreviewEffect conversation={conversation} preview={preview} />
	);
	const remove = (
		<IconButton
			className="link-preview-remove"
			icon="close"
			label={linkPreviewRemove}
			size="small"
			variant="solid"
			shape="circle"
			onClick={() => browser.removePreview(conversation, preview.id)}
		/>
	);
	if (preview.state === "ready") {
		const image = preview.metadata.images[0];
		return (
			<article className="link-preview-card ready">
				{effect}
				{remove}
				<a href={preview.url} target="_blank" rel="noopener noreferrer">
					<span className="link-preview-copy">
						{preview.metadata.siteName && <small>{preview.metadata.siteName}</small>}
						<strong>{preview.metadata.title ?? previewHost(preview.metadata.url)}</strong>
						{preview.metadata.description && <span>{preview.metadata.description}</span>}
					</span>
					{image !== undefined && <PreviewImage image={image} />}
				</a>
			</article>
		);
	}
	if (preview.state === "failed") {
		return (
			<article className="link-preview-card failed">
				{effect}
				{remove}
				<div className="link-preview-failure">
					<strong>{preview.failure.summary}</strong>
					{preview.failure.action && <span>{preview.failure.action}</span>}
				</div>
				{preview.failure.retry !== "never" && (
					<Button
						variant="quiet"
						className="link-preview-retry"
						onClick={() => browser.retryPreview(conversation, preview.id)}
					>
						{linkPreviewRetry}
					</Button>
				)}
			</article>
		);
	}
	return (
		<article className="link-preview-card loading" aria-live="polite">
			{effect}
			{remove}
			<span>{linkPreviewLoading}</span>
		</article>
	);
}

type ReadState =
	| { state: "loading"; attempt: number }
	| { state: "ready"; attempt: number; metadata: OpenGraphMetadata }
	| { state: "failed"; attempt: number; failure: import("../link_preview.ts").PreviewFailure };

function MessagePreview({ url }: { url: string }) {
	const [read, setRead] = useState<ReadState>({ state: "loading", attempt: 0 });
	useEffect(() => {
		if (read.state !== "loading") return;
		const attempt = read.attempt;
		const abort = new AbortController();
		void fetchPreview(url, abort.signal).then(
			(metadata) =>
				setRead((current) =>
					current.state === "loading" && current.attempt === attempt
						? { state: "ready", attempt, metadata }
						: current
				),
			(error) => {
				if (abort.signal.aborted) return;
				setRead((current) =>
					current.state === "loading" && current.attempt === attempt
						? { state: "failed", attempt, failure: previewFailure(error) }
						: current
				);
			},
		);
		return () => abort.abort();
	}, [read, url]);
	if (read.state === "loading") {
		return (
			<article className="link-preview-card loading">
				<span>{linkPreviewLoading}</span>
			</article>
		);
	}
	if (read.state === "failed") {
		// The authored link remains the useful fallback. A reader-side preview
		// refusal should not turn a delivered message into an error panel.
		return null;
	}
	const image = read.metadata.images[0];
	return (
		<article className="link-preview-card ready">
			<a href={url} target="_blank" rel="noopener noreferrer">
				<span className="link-preview-copy">
					{read.metadata.siteName && <small>{read.metadata.siteName}</small>}
					<strong>{read.metadata.title ?? previewHost(read.metadata.url)}</strong>
					{read.metadata.description && <span>{read.metadata.description}</span>}
				</span>
				{image !== undefined && <PreviewImage image={image} />}
			</a>
		</article>
	);
}

export function MessageLinkPreviews({ text, urls }: { text: string; urls: readonly string[] }) {
	const selected = previewSelection(text, urls);
	if (selected.length === 0) return null;
	return (
		<div className="link-preview-list message-link-previews" aria-label={linkPreviewsLabel}>
			{selected.map((url) => <MessagePreview key={url} url={url} />)}
		</div>
	);
}

export function DraftLinkPreviews(
	{ conversation, previews }: { conversation: string; previews: readonly DraftPreview[] },
) {
	if (previews.every((preview) => preview.state === "removed")) return null;
	return (
		<div className="link-preview-list draft-link-previews" aria-label={linkPreviewsLabel}>
			{previews.map((preview) => <PreviewCard key={preview.id} conversation={conversation} preview={preview} />)}
		</div>
	);
}
