//! Operation identity and safe-integer revisions. Durability lives in the managed runtime.
pub use super::fields::{SafeInteger, Text};

pub type OperationId = Text<128, true>;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Impact {
	Presentation,
	Standing,
	Realization,
}
