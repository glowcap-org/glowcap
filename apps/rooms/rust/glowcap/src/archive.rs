//! Archive passables use the shared tuple contract and the existing binding.
use glowcap::Argument;
use rooms_application::archive::{Error, Filter, Record, index::Page, output};
pub fn record_row(record: &Record) -> Argument {
	Argument::List(output::record::<crate::Arguments>(record))
}
pub fn filter_row(filter: &Filter) -> Result<Argument, Error> {
	output::filter::<crate::Arguments>(filter)
}
pub fn page_row(page: &Page, filter: &Filter, after: u64, limit: usize) -> Result<Argument, Error> {
	output::page::<crate::Arguments>(page, filter, after, limit)
}

pub fn share_row(
	share: &rooms_application::archive::shares::Share,
	link: &str,
) -> Result<Argument, rooms_application::archive::shares::Error> {
	rooms_application::archive::shares::protocol::row::<crate::Arguments>(share, link)
}

pub fn share_issue(
	share: &rooms_application::archive::shares::Share,
) -> Result<Vec<Argument>, rooms_application::archive::shares::Error> {
	rooms_application::archive::shares::protocol::issue::<crate::Arguments>(share)
}
