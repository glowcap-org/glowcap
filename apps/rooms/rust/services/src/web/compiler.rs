//! App-owned Deno invocation. The publisher supplies an empty output directory
//! and owns this direct child; the recipe introduces no shell or task runner.
use std::path::Path;

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Recipe {
	pub args: Vec<String>,
	pub inputs: Vec<String>,
}
impl Recipe {
	pub fn read(root: &Path) -> Result<Self, String> {
		let bytes = super::assets::read(&root.join("compiler.json"), 64 * 1024)?;
		Self::parse(&bytes).map_err(|e| format!("compiler.json: {e}"))
	}
	fn parse(bytes: &[u8]) -> Result<Self, String> {
		let recipe: Self = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
		if recipe.args.first().is_none_or(|arg| arg.is_empty())
			|| recipe
				.args
				.iter()
				.map(|arg| arg.matches("{outdir}").count())
				.sum::<usize>()
				!= 1
		{
			return Err("args must name a Deno command and exactly one {outdir}".into());
		}
		for input in &recipe.inputs {
			if input.is_empty()
				|| !Path::new(input)
					.components()
					.all(|part| matches!(part, std::path::Component::Normal(_)))
			{
				return Err("inputs must be paths beneath the browser source root".into());
			}
		}
		Ok(recipe)
	}
	pub fn arguments(&self, outdir: &Path) -> Result<Vec<String>, String> {
		let outdir = outdir.to_str().ok_or("compiler output path is not Unicode")?;
		Ok(self.args.iter().map(|arg| arg.replace("{outdir}", outdir)).collect())
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn output_substitution_is_one_literal_argument_even_with_shell_characters() {
		let recipe = Recipe::parse(br#"{"args":["bundle","ui/page.js","--outdir","{outdir}"],"inputs":[]}"#).unwrap();
		assert_eq!(
			recipe.arguments(Path::new("/tmp/space and $(literal)")).unwrap(),
			["bundle", "ui/page.js", "--outdir", "/tmp/space and $(literal)"]
		);
	}

	#[test]
	fn malformed_recipes_fail_before_launch() {
		for source in [
			r#"{"args":[],"inputs":[]}"#,
			r#"{"args":["bundle"],"inputs":[]}"#,
			r#"{"args":["bundle","{outdir}","{outdir}"],"inputs":[]}"#,
			r#"{"args":["bundle","{outdir}"],"inputs":["../outside.ts"]}"#,
			r#"{"args":["bundle","{outdir}"],"inputs":[],"typo":true}"#,
		] {
			assert!(Recipe::parse(source.as_bytes()).is_err(), "{source}");
		}
	}
}
