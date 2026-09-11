// The one rooms control whose meaning is carried by an interface icon.
//
// Callers choose three independent facts: size is touch/layout geometry,
// variant is how much surface the control draws, and tone is its semantic or
// contextual colour. The component owns everything easy to drift — reset,
// icon size, shape, tooltip, accessible name, focus, hover, pressed, and
// disabled treatment. Buttons that carry their meaning in words are the
// separate family next door in `Button.tsx`, and content-as-controls — a room
// row, a message act — are neither.

import type { ComponentPropsWithRef } from "react";
import { Icon, type IconName } from "./icons.tsx";

export type IconButtonSize = "small" | "normal" | "large";
export type IconButtonVariant = "ghost" | "outline" | "solid";
export type IconButtonTone = "neutral" | "accent" | "teal" | "danger" | "inverse" | "on-accent";
export type IconButtonShape = "rounded" | "circle";

export type IconButtonProps =
	& Omit<ComponentPropsWithRef<"button">, "aria-label" | "children">
	& {
		icon: IconName;
		label: string;
		size?: IconButtonSize;
		/** Glyph size inside the control. Leave this off to take the size
		 * step; pass it only when a glyph has to disagree with that step. */
		iconSize?: number;
		variant?: IconButtonVariant;
		tone?: IconButtonTone;
		shape?: IconButtonShape;
		/** A short count attached to the icon, never arbitrary button content. */
		badge?: string | number;
		/** The action is in flight. The glyph gives way to the shared progress
		 * ring and the control cannot be pressed a second time. */
		busy?: boolean;
	};

const iconSizes: Record<IconButtonSize, number> = {
	small: 15,
	normal: 18,
	large: 20,
};

export function IconButton({
	icon,
	label,
	size = "normal",
	iconSize,
	variant = "outline",
	tone = "neutral",
	shape = "rounded",
	badge,
	busy = false,
	className,
	title,
	type = "button",
	disabled,
	...button
}: IconButtonProps) {
	const classes = ["icon-button", className].filter(Boolean).join(" ");
	return (
		<button
			{...button}
			type={type}
			className={classes}
			data-size={size}
			data-variant={variant}
			data-tone={tone}
			data-shape={shape}
			data-busy={busy || undefined}
			disabled={disabled || busy}
			aria-label={label}
			title={title ?? label}
		>
			<Icon name={icon} size={iconSize ?? iconSizes[size]} />
			{badge !== undefined && <span className="icon-button-badge" aria-hidden="true">{badge}</span>}
		</button>
	);
}
