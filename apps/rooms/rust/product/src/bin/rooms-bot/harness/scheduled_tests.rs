use super::{lines::words, *};

#[test]
fn scheduled_adapters_start_tool_free_without_resuming_a_full_permission_conversation() {
	let turn = Turn {
		prompt: "the scheduled task",
		system: "scheduled system prompt",
		session: Some("prior-conversation-session"),
		workdir: Path::new("/conversation"),
		home: Path::new("/home"),
		state: Path::new("/harness-state"),
		model: Some("test-model"),
		permission: Permission::Full,
	};
	for (name, requirements) in [
		(
			"pi",
			&[
				"--no-session",
				"--no-tools",
				"--exclude-tools",
				"*",
				"--no-extensions",
				"--no-mcp",
				"--no-context-files",
				"--no-prompt-templates",
				"--no-skills",
				"--no-approve",
			][..],
		),
		(
			"claude",
			&[
				"--no-session-persistence",
				"--safe-mode",
				"--restricted",
				"--strict-mcp-config",
				"--disable-slash-commands",
				"--settings",
				r#"{"disableAllHooks":true}"#,
			][..],
		),
	] {
		let harness = lookup(name, Path::new("/glowcap")).unwrap();
		let invocation = harness.scheduled().unwrap().scheduled_invocation(&turn);
		assert!(invocation.prepare.is_empty());
		assert!(invocation.resume.is_none());
		assert_eq!(invocation.stdin.as_deref(), Some(turn.prompt));
		let args = words(&invocation);
		assert!(
			requirements.iter().all(|flag| args.iter().any(|arg| arg == flag)),
			"{name}: {args:?}"
		);
		assert!(!args.iter().any(|arg| matches!(
			arg.as_str(),
			"--session"
				| "--resume"
				| "--dangerously-skip-permissions"
				| "--allowedTools"
				| "prior-conversation-session"
		)));
		assert!(
			args.windows(2)
				.any(|pair| pair == ["--system-prompt", "scheduled system prompt"])
		);
		assert!(args.windows(2).any(|pair| pair == ["--model", "test-model"]));
		if name == "claude" {
			assert!(args.windows(2).any(|pair| pair == ["--tools", ""]));
		}
	}
	assert!(lookup("codex", Path::new("/glowcap")).unwrap().scheduled().is_none());
}
