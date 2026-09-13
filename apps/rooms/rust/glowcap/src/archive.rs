//! Archive passables use the shared tuple contract and the existing binding.
use glowcap::Argument;
use rooms_application::archive::{
	Error, Filter, Record,
	index::Page,
	output::{self, Output},
};
struct Passables;
impl Output for Passables {
	type Value = Argument;
	fn text(value: &str) -> Argument {
		value.into()
	}
	fn integer(value: u64) -> Argument {
		Argument::Integer(value as i64)
	}
	fn boolean(value: bool) -> Argument {
		value.into()
	}
	fn null() -> Argument {
		Argument::Void
	}
	fn list(values: Vec<Argument>) -> Argument {
		Argument::List(values)
	}
}
pub fn record_row(record: &Record) -> Argument {
	Argument::List(output::record::<Passables>(record))
}
pub fn filter_row(filter: &Filter) -> Result<Argument, Error> {
	output::filter::<Passables>(filter)
}
pub fn page_row(page: &Page, filter: &Filter, after: u64, limit: usize) -> Result<Argument, Error> {
	output::page::<Passables>(page, filter, after, limit)
}

pub fn share_row(
	share: &rooms_application::archive::shares::Share,
	link: &str,
) -> Result<Argument, rooms_application::archive::shares::Error> {
	rooms_application::archive::shares::protocol::row::<Passables>(share, link)
}

pub fn share_issue(
	share: &rooms_application::archive::shares::Share,
) -> Result<Vec<Argument>, rooms_application::archive::shares::Error> {
	rooms_application::archive::shares::protocol::issue::<Passables>(share)
}
