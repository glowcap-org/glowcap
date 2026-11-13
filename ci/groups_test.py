"""Every command CI runs names real steps and programs, and every step it never runs has a reason.

Reads each step's nearest containers from docs/build-steps.md and
docs/build-steps-apps.md, which gen-build-steps-check holds to the build
graph, and the `zig build` steps CI names: ci/groups.py's gates, the workflow
and composite action scripts, and the ci programs. A step is reached when CI
names it or a step containing it. Every other step matches one row of
groups.LOCAL, a proof (`-test` or `-check`) by its own name, and every row
matches a step CI does not reach. The named-step graph does not see a run
two steps share, so such a step needs a row that says so.

A word in a `zig build` command that is neither an option nor a step is
refused, and so is a bash or python3 program path the repository lacks.
"""

import ast
import fnmatch
import re
import shlex
import unittest

import groups as GROUPS
from workflows import ROOT, workflow

DOCS = ("docs/build-steps.md", "docs/build-steps-apps.md")


def containers(texts):
    """step -> the steps the documents say contain it."""
    found = {}
    for text in texts:
        for line in text.splitlines():
            if match := re.match(r"zig build (\S+)\s+# (.*)$", line):
                name, description = match.groups()
                part = re.search(r"; part of (.*)$", description)
                found[name] = set(part.group(1).split(", ")) if part else set()
    return found


# The `zig build` options whose value is the next word.
VALUED = (
    "--summary",
    "--test-timeout",
    "--prefix",
    "-p",
    "--build-file",
    "--seed",
    "--cache-dir",
    "--global-cache-dir",
)
# The word a Python command line holds where the program computes one.
COMPUTED = "<computed>"


def named(command, steps):
    """The steps one `zig build` command names, from its arguments as the shell passes them.

    An option, an option's value, and everything after `--` name no step. Any
    other argument must be a step, so a misspelled or renamed one is refused here.
    """
    found = set()
    words = iter(command)
    for word in words:
        if word == "--":
            break
        if word in VALUED:
            next(words, None)
        elif not word.startswith("-"):
            if word not in steps:
                raise ValueError(f"zig build {shlex.join(command)}: {word!r} is not a build step")
            found.add(word)
    return found


def commands(script):
    """The arguments after each `zig build` in a shell script, as the shell splits them.

    A command ends at its operator, a word that starts with `#` starts a
    comment, and a quoted word stays one argument with its text, so a quoted
    or computed step is read and refused.
    """
    found = []
    for line in script.replace("\\\n", " ").splitlines():
        if "zig build" not in line:
            continue
        lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        lexer.commenters = ""
        try:
            words = list(lexer)
        except ValueError as error:
            raise ValueError(f"{line.strip()}: {error}") from error
        words = words[: next((at for at, word in enumerate(words) if word.startswith("#")), len(words))]
        for at, word in enumerate(words):
            if " " in word:
                try:
                    found += commands(word)
                except ValueError as error:
                    raise ValueError(f"{line.strip()}: {error}") from error
            if words[at : at + 2] != ["zig", "build"]:
                continue
            tail: list[str] = []
            for following in words[at + 2 :]:
                if following and following[0] in lexer.punctuation_chars:
                    if tail and tail[-1].isdigit() and following[0] in "<>":
                        tail.pop()
                    break
                tail.append(following)
            found.append(tail)
    return found


def programs(script):
    """Each repository program a shell line hands to bash or python3, as its path from the root."""
    found = []
    words = iter(re.findall(r"[^\s;&|()`]+", script.replace("\\\n", " ")))
    for word in words:
        if not re.search(r"\b(?:bash|python3)$", word):
            continue
        for argument in words:
            if argument in ("-o", "-W"):
                next(words, None)
            elif not argument.startswith("-"):
                program = re.match(r"[\"']?(?:\./)?((?:\.?[\w-]+/)+[\w.-]+)", argument)
                if program:
                    found.append(program.group(1))
                break
    return found


def cited(text):
    """The step each `zig build` in a file's comment lines names: the first word that is no option or option value."""
    found = []
    for line in text.splitlines():
        if not line.lstrip().startswith("#"):
            continue
        for tail in line.split("zig build ")[1:]:
            words = iter(tail.split())
            for word in words:
                if word in VALUED:
                    next(words, None)
                elif not word.startswith("-"):
                    found += re.findall(r"^[a-z][\w-]*", word)
                    break
    return found


def python_commands(source):
    """Each `"zig", "build", ...` run of string constants in a Python program, as the arguments after `zig build`."""
    found = []
    for node in ast.walk(ast.parse(source)):
        arguments = node.elts if isinstance(node, (ast.List, ast.Tuple)) else getattr(node, "args", None)
        if not isinstance(arguments, list):
            continue
        words = [
            word for item in arguments if not isinstance(item, (ast.Starred, ast.keyword)) for word in [spelled(item)]
        ]
        if words[:2] == ["zig", "build"]:
            found.append(words[2:])
    return found


def spelled(node):
    """One argument as its word: a constant, an option with a computed value, or the computed marker."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr) and node.values and isinstance(node.values[0], ast.Constant):
        head = node.values[0].value
        if isinstance(head, str) and head.startswith("-"):
            return head + COMPUTED
    return COMPUTED


def run_scripts(document):
    """Each step's `run` script in a workflow's jobs or a composite action's `runs`, never a comment or a name."""
    holders = [*(document.get("jobs") or {}).values(), document.get("runs") or {}]
    return [step["run"] for holder in holders for step in holder.get("steps") or [] if "run" in step]


def ci_scripts():
    """Every shell line CI runs: each gate's command and each workflow or action step's script."""
    found = [command for gates in GROUPS.PHASES.values() for _, command in gates]
    for path in [*ROOT.glob(".github/workflows/*.yml"), *ROOT.glob(".github/actions/*/action.yml")]:
        found += run_scripts(workflow(path.relative_to(ROOT)))
    return found


def ci_roots(steps):
    roots = set()
    for script in ci_scripts():
        for command in commands(script):
            roots |= named(command, steps)
    for path in ROOT.glob("ci/*.py"):
        if not path.name.endswith("_test.py"):
            for command in python_commands(path.read_text()):
                roots |= named(command, steps)
    return roots


def unreached(steps, roots):
    def reached(name, seen):
        return name in roots or any(reached(parent, seen | {name}) for parent in steps[name] - seen if parent in steps)

    return sorted(name for name in steps if not reached(name, frozenset()))


def audit(steps, roots, local):
    """Each problem with the local list, as one line."""
    missing = unreached(steps, roots)
    problems = []
    for name in missing:
        rows = [row for row in local if fnmatch.fnmatchcase(name, row)]
        proof = name.endswith(("-test", "-check"))
        if not rows:
            problems.append(f"{name}: CI never runs it; add it to a phase or a reasoned row of groups.LOCAL")
        elif proof and name not in rows:
            problems.append(f"{name}: a proof CI never runs needs a row of its own, not {rows[0]}")
    for row in local:
        if not any(fnmatch.fnmatchcase(name, row) for name in missing):
            problems.append(f"{row}: names no step CI leaves unrun; remove the row")
    return problems


class LocalSteps(unittest.TestCase):
    def setUp(self):
        self.steps = containers((ROOT / doc).read_text() for doc in DOCS)
        self.assertGreater(len(self.steps), 100)

    def test_every_step_ci_leaves_unrun_has_its_reason(self):
        self.assertEqual(audit(self.steps, ci_roots(self.steps), GROUPS.LOCAL), [])

    def test_a_word_that_is_no_step_is_refused(self):
        steps: dict[str, set[str]] = {"check": set(), "unit-test": set()}
        self.assertEqual(
            named("-Doptimize=safe check --summary all --test-timeout 30s unit-test -- gone".split(), steps),
            {"check", "unit-test"},
        )
        for command in ("chekc", "check unit-tset", "check --summary all gone", "check all"):
            with self.subTest(command=command), self.assertRaisesRegex(ValueError, "is not a build step"):
                named(command.split(), steps)

    def test_an_argument_keeps_its_shell_boundaries(self):
        steps: dict[str, set[str]] = {"check": set(), "test": set()}
        self.assertEqual(commands('zig build "check test"\n'), [["check test"]])
        with self.assertRaisesRegex(ValueError, "'check test' is not a build step"):
            named(["check test"], steps)
        quoted = commands('zig build -Dname="two words" check\n')
        self.assertEqual(quoted, [["-Dname=two words", "check"]])
        self.assertEqual(named(quoted[0], steps), {"check"})
        self.assertEqual(named(["--summary", "all words", "check"], steps), {"check"})
        self.assertEqual(commands('zig build "" check\n'), [["", "check"]])
        with self.assertRaisesRegex(ValueError, "'' is not a build step"):
            named(["", "check"], steps)
        self.assertEqual(commands('bash -c "zig build check test"\n'), [["check", "test"]])
        with self.assertRaisesRegex(ValueError, "^bash -c .*can't.*No closing quotation"):
            commands('bash -c "zig build check; echo can\'t"\n')

    def test_every_program_ci_runs_is_in_the_repository(self):
        self.assertEqual(
            programs(
                "bash -e .x/a.sh; python3 ci/gates.py run x && bash tools/b-c.sh\npython3 -m unittest; bash go\n"
                'bash "tools/q.sh"; python3 ./ci/y.py; bash -o pipefail tools/x.sh; python3 -W error ci/z.py\n'
                "python3 ci/m.py;bash tools/n.sh&&python3 ci/o.py|bash tools/p.sh; $(bash -e \\\n  tools/r.sh) `python3 ci/s.py`"
            ),
            [
                ".x/a.sh",
                "ci/gates.py",
                "tools/b-c.sh",
                "tools/q.sh",
                "ci/y.py",
                "tools/x.sh",
                "ci/z.py",
                "ci/m.py",
                "tools/n.sh",
                "ci/o.py",
                "tools/p.sh",
                "tools/r.sh",
                "ci/s.py",
            ],
        )
        # Options are walked a word at a time, so a long run of them costs one pass.
        self.assertEqual(programs("bash " + "-W -! " * 64 + "go"), [])
        found = {program for script in ci_scripts() for program in programs(script)}
        self.assertGreater(len(found), 15)
        self.assertEqual(sorted(program for program in found if not (ROOT / program).is_file()), [])

    def test_every_reason_is_a_sentence(self):
        for row, reason in GROUPS.LOCAL.items():
            with self.subTest(row=row):
                self.assertRegex(reason, r"^\S.*\.$")

    def test_a_planted_orphan_and_a_stale_row_fail(self):
        steps = {"check": set(), "unit-test": {"check"}, "alone-test": set(), "gen-x": set(), "demo-a": set()}
        self.assertEqual(
            audit(steps, {"check"}, {"gen-*": "Writes.", "*-test": "Wide.", "gone": "Stale."}),
            [
                "alone-test: a proof CI never runs needs a row of its own, not *-test",
                "demo-a: CI never runs it; add it to a phase or a reasoned row of groups.LOCAL",
                "gone: names no step CI leaves unrun; remove the row",
            ],
        )

    def test_only_run_scripts_name_a_step(self):
        document = {
            "jobs": {
                "build": {"steps": [{"name": "zig build named-in-a-name", "run": "zig build ran-here --summary all"}]}
            },
            "runs": {"steps": [{"uses": "x"}, {"run": "zig build ran-in-action"}]},
        }
        self.assertEqual(run_scripts(document), ["zig build ran-here --summary all", "zig build ran-in-action"])

    def test_python_command_lines_are_read_from_the_program(self):
        source = (
            'run("zig", "build", "-Doptimize=safe", f"-Dtarget={target}", "--summary", mode, "c-sdk-pack", '
            'timeout=1)\nexecute(["zig", "fetch"])\nrun(["zig", "build", *extra, step])\n'
        )
        self.assertEqual(
            python_commands(source),
            [["-Doptimize=safe", f"-Dtarget={COMPUTED}", "--summary", COMPUTED, "c-sdk-pack"], [COMPUTED]],
        )
        with self.assertRaisesRegex(ValueError, "is not a build step"):
            named([COMPUTED], {"check": set()})

    def test_a_shell_command_ends_at_its_operator(self):
        script = (
            "zig build check >log 2>&1\nzig build a \\\n  b && echo done\nzig build c; zig build d | tee x\n"
            'echo "zig build e"  # zig build f\n# run zig build check before pushing\n'
            'zig build "chekc" --summary all\nzig build \'g\' 2>log\nzig build "$STEP"\nzig build $(pick) x\n'
            "zig build h -Dname=a#b chekc # zig build i\n"
        )
        self.assertEqual(
            commands(script),
            [
                ["check"],
                ["a", "b"],
                ["c"],
                ["d"],
                ["e"],
                ["chekc", "--summary", "all"],
                ["g"],
                ["$STEP"],
                ["$"],
                ["h", "-Dname=a#b", "chekc"],
            ],
        )
        with self.assertRaisesRegex(ValueError, "zig build check \\|\\| echo can't: No closing quotation"):
            commands("  zig build check || echo can't\n")
        for command in (["chekc", "--summary", "all"], ["$STEP"], ["$"]):
            with self.assertRaisesRegex(ValueError, "is not a build step"):
                named(command, {"check": set()})

    def test_a_workflow_comment_cites_only_real_steps(self):
        self.assertEqual(
            cited("  # run zig build a then `zig build b-c`\nrun: zig build d\n# zig build -Dx --summary all e."),
            ["a", "b-c", "e"],
        )
        paths = [
            *ROOT.glob(".github/workflows/*.yml"),
            *ROOT.glob(".github/actions/*/action.yml"),
            *ROOT.glob("ci/*.py"),
        ]
        found = {(path.name, step) for path in paths for step in cited(path.read_text())}
        self.assertGreater(len(found), 1)
        self.assertEqual(sorted(pair for pair in found if pair[1] not in self.steps), [])


if __name__ == "__main__":
    unittest.main()
