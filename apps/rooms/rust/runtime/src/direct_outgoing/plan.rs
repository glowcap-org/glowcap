//! The shared line state machine validates mutations before any delivery effect.
use super::*;
use glowcap::Argument;
use rooms_application::{
	files::{receiving::selection_fits, FileDescription},
	room::line::{Line, MAX_LINE_BYTES, MAX_MESSAGE_FILES},
};
use rooms_glowcap::Value;
pub(super) struct Plan {
	pub text: String,
	pub kind: ChangeKind,
	pub keep: Vec<u32>,
	pub kept: Vec<FileView>,
	pub fresh: Vec<Source>,
}
impl Plan {
	pub fn post(text: &str, fresh: Vec<Source>) -> Result<Self, String> {
		if text.len() > MAX_LINE_BYTES {
			return Err("direct message exceeds its text ceiling".into());
		}
		let plan = Self {
			text: text.into(),
			kind: ChangeKind::Said,
			keep: Vec::new(),
			kept: Vec::new(),
			fresh: fresh.into_boxed_slice().into_vec(),
		};
		plan.validate()?;
		Ok(plan)
	}
	pub fn change(
		id: LineId,
		previous: &[FileView],
		verb: &str,
		text: &str,
		keep: &[u32],
		fresh: Vec<Source>,
	) -> Result<Self, String> {
		if keep.len() > MAX_MESSAGE_FILES || fresh.len() > MAX_MESSAGE_FILES || text.len() > MAX_LINE_BYTES {
			return Err("direct mutation exceeds its argument ceiling".into());
		}
		let mut line =
			Line::new(id, String::new(), (0..previous.len()).collect()).expect("retained selection is bounded");
		let mut args = Vec::with_capacity(1 + keep.len());
		if verb != "withdraw" {
			args.push(Argument::String(text.into()));
		}
		args.extend(keep.iter().map(|&i| Argument::Integer(i.into())));
		let views: Vec<_> = args.iter().map(Value).collect();
		let mut staged = (previous.len()..previous.len() + fresh.len()).collect();
		let kind = line
			.dispatch(verb, &views, &mut staged)
			.map_err(|e| e.to_string())?
			.expect("retained line has not been withdrawn")
			.kind;
		let kept = line.files().iter().filter_map(|&i| previous.get(i).cloned()).collect();
		let plan = Self {
			text: text.into(),
			kind,
			keep: keep.to_vec(),
			kept,
			fresh: fresh.into_boxed_slice().into_vec(),
		};
		plan.validate()?;
		Ok(plan)
	}
	pub fn descriptions(&self) -> impl Iterator<Item = &FileDescription> {
		self.kept
			.iter()
			.map(FileView::description)
			.chain(self.fresh.iter().map(Source::description))
	}
	fn validate(&self) -> Result<(), String> {
		if !selection_fits(self.descriptions()) {
			return Err("direct selection exceeds its file count or byte ceiling".into());
		}
		Ok(())
	}
	pub fn bytes<P: Platform>(&self) -> usize {
		self.descriptions()
			.fold(self.text.len() + core::mem::size_of::<Request<P>>(), |n, d| {
				n.saturating_add(d.retained_bytes()).saturating_add(d.size())
			})
	}
}
