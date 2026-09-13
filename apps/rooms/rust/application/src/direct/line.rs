//! Direct refiling carries inline attachment records. Mutation and file
//! selection remain owned by the same Line used by room-hosted lines.
use crate::room::{
	attachment::{self, Attachment, AttachmentArgument, AttachmentError},
	line::{DispatchError, Line, LineChange, LineError, MAX_MESSAGE_FILES, Proposal},
};
use alloc::vec::Vec;
pub const MAX_ARGUMENTS: usize = 1 + MAX_MESSAGE_FILES * attachment::RECORD_SPAN;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
	Arguments,
	Line(LineError),
	Attachments(AttachmentError),
}
impl core::fmt::Display for Error {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Arguments => f.write_str("a direct posted line has too many arguments"),
			Self::Line(error) => error.fmt(f),
			Self::Attachments(_) => f.write_str("refile has a malformed or excessive attachment record suffix"),
		}
	}
}
impl core::error::Error for Error {}

/// Validate inline records before handing their custody to Line. Refused
/// selection or metadata leaves the original files and withdrawal state intact.
/// Incoming occurrences remain in the binding's custody on every path.
pub fn dispatch<'line, 'call, A: AttachmentArgument>(
	line: &'line mut Line<Attachment<A::Capability>>,
	verb: &str,
	args: &'call [A],
) -> Result<Option<LineChange<'line, 'call, Attachment<A::Capability>>>, Error> {
	match dispatch_with(line, verb, args, |_| Ok::<_, core::convert::Infallible>(())) {
		Ok(change) => Ok(change.map(|((), change)| change)),
		Err(AdmissionError::Protocol(error)) => Err(error),
		Err(AdmissionError::Admission(never)) => match never {},
	}
}
#[derive(Debug)]
pub enum AdmissionError<E> {
	Protocol(Error),
	Admission(E),
}
impl<E: core::fmt::Display> core::fmt::Display for AdmissionError<E> {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::Protocol(error) => error.fmt(f),
			Self::Admission(error) => error.fmt(f),
		}
	}
}
pub type AdmissionResult<'line, 'call, C, R, E> =
	Result<Option<(R, LineChange<'line, 'call, Attachment<C>>)>, AdmissionError<E>>;

/// Reserve against the validated full selection before the shared line commits.
pub fn dispatch_with<'line, 'call, A: AttachmentArgument, R, E>(
	line: &'line mut Line<Attachment<A::Capability>>,
	verb: &str,
	args: &'call [A],
	admit: impl FnOnce(Proposal<'_, Attachment<A::Capability>>) -> Result<R, E>,
) -> AdmissionResult<'line, 'call, A::Capability, R, E> {
	if args.len() > MAX_ARGUMENTS {
		return Err(AdmissionError::Protocol(Error::Arguments));
	}
	let mut additions = Vec::new();
	let command = if verb == crate::protocol_data::REFILE {
		let record_at = 1 + args.iter().skip(1).take_while(|arg| arg.integer().is_some()).count();
		additions = attachment::read_exact(args, record_at)
			.map_err(|error| AdmissionError::Protocol(Error::Attachments(error)))?;
		&args[..record_at]
	} else {
		args
	};
	line.dispatch_with(verb, command, &mut additions, admit)
		.map_err(|error| match error {
			DispatchError::Line(error) => AdmissionError::Protocol(Error::Line(error)),
			DispatchError::Admission(error) => AdmissionError::Admission(error),
		})
}
