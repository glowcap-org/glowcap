//! Host scheduling for shared media custody.
use rooms_platform::HostPlatform;
pub use rooms_runtime::files::media_files::{FileView, Materialized, PreviousFile, Selection, Usage};
pub type MediaFiles = rooms_runtime::files::media_files::MediaFiles<HostPlatform>;

#[cfg(test)]
mod batch_tests;
#[cfg(test)]
mod local_tests;
#[cfg(test)]
mod tests;
