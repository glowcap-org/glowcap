//! Host cryptographic entropy for shared application execution and services.
use rooms_runtime::entropy::{Entropy, EntropyUnavailable};

pub struct OsEntropy;
pub fn fill(bytes: &mut [u8]) -> Result<(), getrandom::Error> {
	getrandom::fill(bytes)
}
impl Entropy for OsEntropy {
	fn fill(&mut self, bytes: &mut [u8]) -> Result<(), EntropyUnavailable> {
		fill(bytes).map_err(|_| EntropyUnavailable)
	}
}
