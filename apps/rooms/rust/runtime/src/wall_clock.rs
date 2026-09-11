//! Wall time for message timestamps, separate from monotonic scheduling.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	BeforeEpoch,
	OutOfRange,
}
impl std::fmt::Display for Error {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.write_str(match self {
			Self::BeforeEpoch => "wall clock predates the Unix epoch",
			Self::OutOfRange => "wall clock timestamp is out of range",
		})
	}
}
impl std::error::Error for Error {}
pub trait WallClock {
	fn unix_millis(&self) -> Result<u64, Error>;
}
