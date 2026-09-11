//! Native cryptographic entropy for shared application execution.
use rooms_runtime::entropy::{Entropy, EntropyUnavailable};

pub struct OsEntropy;
impl Entropy for OsEntropy {
	fn fill(&mut self, bytes: &mut [u8]) -> Result<(), EntropyUnavailable> {
		getrandom::fill(bytes).map_err(|_| EntropyUnavailable)
	}
}
