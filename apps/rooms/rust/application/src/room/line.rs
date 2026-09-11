//! One line capability's protocol behavior. Possession authorizes a mutation;
//! the caller's nickname is not an authorization input. File resources move
//! between owners, and a refused command leaves both owned and staged files
//! untouched. The host adapter supplies only the calling session's staged files.
use super::{
	message::{ChangeKind, LineId},
	ArgumentView,
};
use alloc::{string::String, vec::Vec};
use core::{fmt, mem};

// Compatibility bounds from lib/limits.ts, held by the migration fixtures.
pub const MAX_LINE_BYTES: usize = 8192;
pub const MAX_MESSAGE_FILES: usize = 8;

/// A committed mutation, borrowing its text and surviving file resources.
/// The adapter retires removed resources, broadcasts this change, and updates
/// retained history. Encoding must borrow the files, never clone file bytes.
/// No change is produced for a repeated withdrawal. Effects are synchronous
/// handoffs here; pending I/O and delivery failure belong to the session owner.
#[must_use = "a committed line change needs notification, file retirement, and history effects"]
#[derive(Debug)]
pub struct LineChange<'line, 'call, F> {
	pub id: LineId,
	pub from: &'line str,
	pub text: &'call str,
	pub kind: ChangeKind,
	/// Only a refile carries file records. An edit preserves the current files
	/// without re-exporting their capabilities.
	pub files: &'line [F],
	pub retired: Vec<F>,
}

/// Fully validated resulting state, borrowed only during effect admission.
/// Unlike the wire delta, an edit includes its preserved attachment selection.
pub struct Proposal<'a, F> {
	pub id: LineId,
	pub from: &'a str,
	pub text: &'a str,
	pub kind: ChangeKind,
	files: [Option<&'a F>; MAX_MESSAGE_FILES],
}
impl<F> Proposal<'_, F> {
	pub fn files(&self) -> impl Iterator<Item = &F> + Clone {
		self.files.iter().filter_map(|file| *file)
	}
}
#[derive(Debug)]
pub enum DispatchError<E> {
	Line(LineError),
	Admission(E),
}
impl<E> From<LineError> for DispatchError<E> {
	fn from(error: LineError) -> Self {
		Self::Line(error)
	}
}

/// The actor behind a line reference. A displayed LineId cannot look this up
/// through this API or recreate it after retirement. The CapTP adapter owns the
/// actor's lifetime and keeps it alive while any remote capability retains it.
#[derive(Debug)]
pub struct Line<F> {
	id: LineId,
	from: String,
	files: Vec<F>,
	withdrawn: bool,
}

impl<F> Line<F> {
	/// Files already admitted by the posting owner. On excess count, return all
	/// resources to that owner without constructing an actor or dropping a file.
	pub fn new(id: LineId, from: String, files: Vec<F>) -> Result<Self, Vec<F>> {
		if files.len() > MAX_MESSAGE_FILES {
			return Err(files);
		}
		Ok(Self {
			id,
			from,
			files,
			withdrawn: false,
		})
	}

	pub fn files(&self) -> &[F] {
		&self.files
	}

	pub fn is_withdrawn(&self) -> bool {
		self.withdrawn
	}

	/// Dispatch an existing Rooms line verb. Incoming arguments stay borrowed
	/// and in the binding's custody, including when nested capabilities refuse
	/// the whole call. The staged batch must be the calling session's, even when
	/// the line capability was handed to that session by someone else.
	pub fn dispatch<'line, 'call, A: ArgumentView>(
		&'line mut self,
		verb: &str,
		args: &'call [A],
		staged: &mut Vec<F>,
	) -> Result<Option<LineChange<'line, 'call, F>>, LineError> {
		match self.dispatch_with(verb, args, staged, |_| Ok::<_, core::convert::Infallible>(())) {
			Ok(change) => Ok(change.map(|((), change)| change)),
			Err(DispatchError::Line(error)) => Err(error),
			Err(DispatchError::Admission(never)) => match never {},
		}
	}

	/// Validate first, then reserve effects, then commit. Refusal invokes no
	/// mutation and leaves staged custody intact. Admission runs at most once.
	pub fn dispatch_with<'line, 'call, A: ArgumentView, R, E>(
		&'line mut self,
		verb: &str,
		args: &'call [A],
		staged: &mut Vec<F>,
		admit: impl FnOnce(Proposal<'_, F>) -> Result<R, E>,
	) -> Result<Option<(R, LineChange<'line, 'call, F>)>, DispatchError<E>> {
		if args.iter().any(ArgumentView::contains_capability) {
			return Err(LineError::UnexpectedCapability.into());
		}
		match verb {
			"edit" => {
				self.require_live()?;
				let text = match args {
					[value] => value.text().ok_or(LineError::EditArguments)?,
					_ => return Err(LineError::EditArguments.into()),
				};
				check_text(text, LineError::TextTooLong)?;
				let reservation = self.propose(text, ChangeKind::Edited, self.files.iter(), admit)?;
				Ok(Some((reservation, self.change(text, ChangeKind::Edited, Vec::new()))))
			}
			"refile" => {
				self.require_live()?;
				let caption = args
					.first()
					.and_then(ArgumentView::text)
					.ok_or(LineError::CaptionRequired)?;
				check_text(caption, LineError::CaptionTooLong)?;
				// Fixed scratch bounds peer-controlled work and carries no resource
				// ownership. Validate every selection before draining either owner.
				let mut keep = [0_usize; MAX_MESSAGE_FILES];
				let mut count = 0;
				let mut seen = [false; MAX_MESSAGE_FILES];
				for arg in &args[1..] {
					let raw = arg.integer().ok_or(LineError::FileIndexType)?;
					let index = usize::try_from(raw)
						.ok()
						.filter(|&at| at < self.files.len())
						.ok_or(LineError::FileIndexOutOfRange(raw))?;
					if seen[index] {
						return Err(LineError::DuplicateFile(index).into());
					}
					seen[index] = true;
					keep[count] = index;
					count += 1;
				}
				if staged.len() > MAX_MESSAGE_FILES - count {
					return Err(LineError::TooManyFiles.into());
				}
				let kind = if count == 0 && staged.is_empty() && caption.is_empty() {
					ChangeKind::Withdrawn
				} else {
					ChangeKind::Refiled
				};
				let reservation = self.propose(
					caption,
					kind,
					keep[..count]
						.iter()
						.map(|&index| &self.files[index])
						.chain(staged.iter()),
					admit,
				)?;
				let mut replacement = Vec::with_capacity(count + staged.len());
				let mut retired = Vec::with_capacity(self.files.len() - count);
				let mut slots: [Option<F>; MAX_MESSAGE_FILES] = core::array::from_fn(|_| None);
				for (slot, file) in slots.iter_mut().zip(self.files.drain(..)) {
					*slot = Some(file);
				}
				for &index in &keep[..count] {
					replacement.push(slots[index].take().expect("validated distinct file index"));
				}
				retired.extend(slots.into_iter().flatten());
				replacement.append(staged);
				self.files = replacement;
				self.withdrawn = kind == ChangeKind::Withdrawn;
				Ok(Some((reservation, self.change(caption, kind, retired))))
			}
			"withdraw" => {
				if !args.is_empty() {
					return Err(LineError::WithdrawArguments.into());
				}
				if self.withdrawn {
					return Ok(None);
				}
				let reservation = self.propose("", ChangeKind::Withdrawn, core::iter::empty(), admit)?;
				self.withdrawn = true;
				let retired = mem::take(&mut self.files);
				Ok(Some((reservation, self.change("", ChangeKind::Withdrawn, retired))))
			}
			_ => Err(LineError::UnknownMethod(verb.into()).into()),
		}
	}

	fn propose<'a, R, E>(
		&'a self,
		text: &'a str,
		kind: ChangeKind,
		files: impl Iterator<Item = &'a F>,
		admit: impl FnOnce(Proposal<'_, F>) -> Result<R, E>,
	) -> Result<R, DispatchError<E>> {
		let mut selection = [None; MAX_MESSAGE_FILES];
		for (slot, file) in selection.iter_mut().zip(files) {
			*slot = Some(file);
		}
		admit(Proposal {
			id: self.id,
			from: &self.from,
			text,
			kind,
			files: selection,
		})
		.map_err(DispatchError::Admission)
	}

	fn require_live(&self) -> Result<(), LineError> {
		if self.withdrawn {
			Err(LineError::Withdrawn)
		} else {
			Ok(())
		}
	}

	fn change<'line, 'call>(
		&'line self,
		text: &'call str,
		kind: ChangeKind,
		retired: Vec<F>,
	) -> LineChange<'line, 'call, F> {
		LineChange {
			id: self.id,
			from: &self.from,
			text,
			kind,
			retired,
			files: if kind == ChangeKind::Refiled { &self.files } else { &[] },
		}
	}
}

fn check_text(text: &str, refusal: LineError) -> Result<(), LineError> {
	if text.len() > MAX_LINE_BYTES {
		Err(refusal)
	} else {
		Ok(())
	}
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LineError {
	UnexpectedCapability,
	Withdrawn,
	EditArguments,
	WithdrawArguments,
	CaptionRequired,
	TextTooLong,
	CaptionTooLong,
	FileIndexType,
	FileIndexOutOfRange(i128),
	DuplicateFile(usize),
	TooManyFiles,
	UnknownMethod(String),
}

impl fmt::Display for LineError {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(match self {
			Self::UnexpectedCapability => "a line does not take capability arguments",
			Self::Withdrawn => "that line was withdrawn",
			Self::EditArguments => "edit needs one text value",
			Self::WithdrawArguments => "withdraw takes no arguments",
			Self::CaptionRequired => "refile needs a caption",
			Self::TextTooLong => return write!(f, "a line may be at most {MAX_LINE_BYTES} bytes"),
			Self::CaptionTooLong => return write!(f, "a caption may be at most {MAX_LINE_BYTES} bytes"),
			Self::FileIndexType => "refile keeps files by index",
			Self::FileIndexOutOfRange(index) => return write!(f, "no file at index {index} on this line"),
			Self::DuplicateFile(index) => return write!(f, "file {index} is kept twice"),
			Self::TooManyFiles => return write!(f, "a message may carry at most {MAX_MESSAGE_FILES} files"),
			Self::UnknownMethod(verb) => return write!(f, "a line has no method {verb}"),
		})
	}
}

impl core::error::Error for LineError {}
