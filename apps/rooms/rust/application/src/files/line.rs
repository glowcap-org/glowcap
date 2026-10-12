//! Commit line mutation and staged-upload ownership as one synchronous act.
use super::*;
use crate::room::{
	ArgumentView,
	line::{Line, LineChange, LineError},
	message::LineId,
};

#[derive(Debug, PartialEq, Eq)]
pub enum FileLineError {
	Files(FileError),
	Line(LineError),
}

/// One exact room generation owns the line. The holder may be on a different
/// connection. Its staged files must still come from this room's membership.
#[derive(Debug)]
pub struct HostedLine {
	room: Key,
	line: Line<HostedFile>,
}

impl HostedLine {
	pub fn id(&self) -> LineId {
		self.line.id()
	}
	pub fn files(&self) -> &[HostedFile] {
		self.line.files()
	}
	pub fn is_withdrawn(&self) -> bool {
		self.line.is_withdrawn()
	}
}

impl FileStore {
	/// Admission borrows the candidate files so a wrong-store/room refusal
	/// preserves their owner. A successful construction takes the entire batch.
	pub fn line(
		&self,
		room: &FileRoom,
		id: LineId,
		from: String,
		files: &mut Vec<HostedFile>,
	) -> Result<HostedLine, FileError> {
		self.check(&room.key)?;
		if !room.life.active.get() {
			return Err(FileError::Closed);
		}
		if files.len() > crate::room::line::MAX_MESSAGE_FILES {
			return Err(FileError::StagedLimit);
		}
		for file in files.iter() {
			self.check(&file.blob.key)?;
			if file.blob.room != room.key.id {
				return Err(FileError::WrongRoom);
			}
		}
		let line = match Line::new(id, from, core::mem::take(files)) {
			Ok(line) => line,
			Err(returned) => {
				*files = returned;
				return Err(FileError::StagedLimit);
			}
		};
		Ok(HostedLine {
			room: room.key.clone(),
			line,
		})
	}
	/// The room owner resolves the caller's membership in this room. None is a
	/// legitimate holder of handed line authority with no local staged uploads.
	/// Refusal leaves uploads staged. Removed files expire before additions enter
	/// held-media accounting, so replacing a file cannot evict one it keeps.
	pub fn dispatch_line<'line, 'call, A: ArgumentView>(
		&mut self,
		member: Option<&FileMember>,
		line: &'line mut HostedLine,
		verb: &str,
		args: &'call [A],
	) -> Result<Option<LineChange<'line, 'call, HostedFile>>, FileLineError> {
		self.check(&line.room).map_err(FileLineError::Files)?;
		if let Some(member) = member {
			self.check(&member.key).map_err(FileLineError::Files)?;
			if member.room != line.room.id {
				return Err(FileLineError::Files(FileError::WrongRoom));
			}
		}
		let mut staged = if verb == crate::protocol_data::REFILE {
			match member {
				Some(member) => self.prepare_post(member).map_err(FileLineError::Files)?,
				None => Vec::new(),
			}
		} else {
			Vec::new()
		};
		let change = line
			.line
			.dispatch(verb, args, &mut staged)
			.map_err(FileLineError::Line)?;
		if let Some(change) = &change {
			for retired in &change.retired {
				self.expire(retired.blob.key.id);
			}
			self.commit_post(change.files);
		}
		Ok(change)
	}
}
