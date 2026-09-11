//! Native scheduling for shared media custody.
use crate::client::Deadline;
pub use rooms_runtime::media_files::{FileView, Materialized, PreviousFile, Selection, Usage};
pub type MediaFiles = rooms_runtime::media_files::MediaFiles<Deadline>;

#[cfg(test)]
mod batch_tests;
#[cfg(test)]
mod local_tests;
#[cfg(test)]
mod tests;
