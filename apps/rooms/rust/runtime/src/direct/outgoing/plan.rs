//! The shared line state machine validates mutations before any delivery effect.
use super::*;
use glowcap::Argument;
use rooms_application::{
	files::{FileDescription, receiving::selection_fits},
	room::line::{Line, MAX_LINE_BYTES, MAX_MESSAGE_FILES},
};
use rooms_glowcap::Value;
pub(super) struct Plan {
	pub text: String,
	pub previews: rooms_application::open_graph::Selection,
	pub kind: ChangeKind,
	pub keep: Vec<u32>,
	pub kept: Vec<FileView>,
	pub fresh: Vec<Source>,
}
impl Plan {
	pub fn post(
		text: &str,
		previews: rooms_application::open_graph::Selection,
		fresh: Vec<Source>,
	) -> Result<Self, Error> {
		if text.len() > MAX_LINE_BYTES {
			return Err(Error::invalid("direct message exceeds its text ceiling"));
		}
		let plan = Self {
			text: text.into(),
			previews,
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
		previous_previews: &rooms_application::open_graph::Selection,
		previous: &[FileView],
		verb: &str,
		text: &str,
		keep: &[u32],
		fresh: Vec<Source>,
	) -> Result<Self, Error> {
		if keep.len() > MAX_MESSAGE_FILES || fresh.len() > MAX_MESSAGE_FILES || text.len() > MAX_LINE_BYTES {
			return Err(Error::invalid("direct mutation exceeds its argument ceiling"));
		}
		let mut line =
			Line::new(id, String::new(), (0..previous.len()).collect()).expect("retained selection is bounded");
		let mut args = Vec::with_capacity(1 + keep.len());
		if verb != rooms_application::protocol_data::WITHDRAW {
			args.push(Argument::String(text.into()));
		}
		args.extend(keep.iter().map(|&i| Argument::Integer(i.into())));
		let views: Vec<_> = args.iter().map(Value).collect();
		let mut staged = (previous.len()..previous.len() + fresh.len()).collect();
		let kind = line
			.dispatch(verb, &views, &mut staged)
			.map_err(Error::invalid_by)?
			.expect("retained line has not been withdrawn")
			.kind;
		let kept = line.files().iter().filter_map(|&i| previous.get(i).cloned()).collect();
		let previews = if kind == ChangeKind::Withdrawn {
			rooms_application::open_graph::Selection::default()
		} else {
			previous_previews.retained_for(text)
		};
		let plan = Self {
			text: text.into(),
			previews,
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
	fn validate(&self) -> Result<(), Error> {
		if !selection_fits(self.descriptions()) {
			return Err(Error::invalid(
				"direct selection exceeds its file count or byte ceiling",
			));
		}
		Ok(())
	}
	pub fn bytes<P: Platform>(&self) -> usize {
		self.descriptions().fold(
			self.text.len() + self.previews.retained_bytes() + core::mem::size_of::<Request<P>>(),
			|n, d| n.saturating_add(d.retained_bytes()).saturating_add(d.size()),
		)
	}
}
