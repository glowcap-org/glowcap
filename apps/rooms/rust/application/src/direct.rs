//! Direct inbox vocabulary. Text stays borrowed until its receiver admits an
//! effect; only accepted attachment and handed capability occurrences retain.
use crate::{
	archive::ShareKind,
	room::{
		ArgumentView,
		attachment::{self, Attachment, AttachmentArgument},
		line::{MAX_LINE_BYTES, MAX_MESSAGE_FILES},
	},
};
use alloc::vec::Vec;
pub mod event;
pub mod line;
pub mod operation;
pub mod publication;
pub use crate::protocol_data::{DIRECT_READY as READY, DM, TYPING};
pub const RECIPROCAL_ROUTE_TIMEOUT_MS: u64 = 15_000;
pub const HAND_ROOM: &str = "handRoom";
pub const OFFER_ROOM: &str = "offerRoom";
pub const HAND_ARCHIVE: &str = "handArchive";
pub const OFFER_ARCHIVE: &str = "offerArchive";
pub const MAX_ARGUMENTS: usize = 2 + MAX_MESSAGE_FILES * attachment::RECORD_SPAN + crate::open_graph::WIRE_FIELDS;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	Method,
	Fields,
	Line,
	Ended,
	NoReply,
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		f.write_str(match self {
			Self::Method => "unknown direct inbox method",
			Self::Fields => "invalid direct inbox arguments",
			Self::Line => "a direct message needs text of at most 8192 bytes",
			Self::Ended => "the direct line is closed",
			Self::NoReply => "the direct line has no reciprocal inbox",
		})
	}
}
impl core::error::Error for Error {}
#[derive(Debug)]
pub enum Notice<'a, C> {
	Message {
		text: &'a str,
		reply: Option<C>,
		previews: crate::open_graph::Selection,
		attachments: Vec<Attachment<C>>,
	},
	Ready(C),
	Typing(bool),
	HandRoom {
		label: &'a str,
		room: C,
	},
	OfferRoom {
		label: &'a str,
		link: &'a str,
	},
	HandArchive {
		directory: &'a str,
		kind: ShareKind,
		conversation: Option<&'a str>,
		archive: C,
	},
	OfferArchive {
		directory: &'a str,
		kind: ShareKind,
		conversation: Option<&'a str>,
		link: &'a str,
	},
}
pub fn read<'a, A: AttachmentArgument>(verb: &str, args: &'a [A]) -> Result<Notice<'a, A::Capability>, Error> {
	let text = |at| args.get(at).and_then(ArgumentView::text).ok_or(Error::Fields);
	let cap = |at| {
		args.get(at)
			.and_then(AttachmentArgument::capability)
			.ok_or(Error::Fields)
	};
	match verb {
		READY if args.len() == 1 => Ok(Notice::Ready(cap(0)?.clone())),
		TYPING if args.len() == 1 => Ok(Notice::Typing(args[0].boolean().ok_or(Error::Fields)?)),
		HAND_ROOM if args.len() == 2 => Ok(Notice::HandRoom {
			label: text(0)?,
			room: cap(1)?.clone(),
		}),
		OFFER_ROOM if args.len() == 2 => Ok(Notice::OfferRoom {
			label: text(0)?,
			link: text(1)?,
		}),
		HAND_ARCHIVE | OFFER_ARCHIVE if args.len() == 4 => {
			let directory = text(0)?;
			let kind = ShareKind::parse(text(1)?).ok_or(Error::Fields)?;
			let conversation = if args[2].is_null() { None } else { Some(text(2)?) };
			if verb == HAND_ARCHIVE {
				Ok(Notice::HandArchive {
					directory,
					kind,
					conversation,
					archive: cap(3)?.clone(),
				})
			} else {
				Ok(Notice::OfferArchive {
					directory,
					kind,
					conversation,
					link: text(3)?,
				})
			}
		}
		DM => {
			let text = text(0).map_err(|_| Error::Line)?;
			if text.len() > MAX_LINE_BYTES {
				return Err(Error::Line);
			}
			let reply = cap(1).ok().cloned();
			let (attachments, extension) = attachment::read_prefix_with_end(args, if reply.is_some() { 2 } else { 1 });
			let previews = crate::open_graph::Selection::read_suffix(text, args, extension);
			Ok(Notice::Message {
				text,
				reply,
				previews,
				attachments,
			})
		}
		READY | TYPING | HAND_ROOM | OFFER_ROOM | HAND_ARCHIVE | OFFER_ARCHIVE => Err(Error::Fields),
		_ => Err(Error::Method),
	}
}
