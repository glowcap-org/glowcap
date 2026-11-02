"""check.yml and the group workflow it calls, for infrastructure-check.

Read from the workflows as YAML: which events run what, that pull requests run
on read-only tokens, that every transfer is bounded and each required one
retried, when compile state is reused, and which artifacts a run keeps. The
gate runner (gates_test) and the state script (state_test) have their own
tests, and workflow_audit_test holds every workflow to the static audit.
"""

import json
import re
import subprocess
import sys
import tempfile
import unittest

from report_test import PASS, report_run
from workflows import ROOT, WORKFLOWS, jobs, on_path, run, selected, step, stub, text, workflow

CHECK = ".github/workflows/check.yml"
GROUP = ".github/workflows/check-group.yml"
IMAGE = ".github/workflows/devcontainer-image.yml"
AGENT_TOOLS = ".github/workflows/agent-tools.yml"
IMAGE_ACTION = ".github/actions/image/action.yml"
CONFIG = "--config .devcontainer/.ci/devcontainer.json"
SUITE_JOBS = ("plan", "gates", "macos-runtime", "scheduled-fuzz")
TRANSFER = re.compile(r"actions/(upload-artifact|download-artifact|cache(/restore|/save)?)@")
COMPOSITES = (IMAGE_ACTION, ".github/actions/start/action.yml", ".github/actions/pins/action.yml")


def read_only(permissions):
    """True when a permissions block grants nothing beyond reading."""
    if permissions is None:
        return True  # The workflow's contents: read applies.
    return isinstance(permissions, dict) and all(level in ("read", "none") for level in permissions.values())


def identified(job, id):
    """The step of a job with this `id`."""
    return next(found for found in job["steps"] if found.get("id") == id)


def used(job, action):
    """The steps of a job whose `uses` starts with this action (`actions/checkout@` is any version)."""
    return [found for found in job["steps"] if found.get("uses", "").startswith(action)]


class EventsTest(unittest.TestCase):
    def test_events_select_full_validation_or_the_fuzz_search(self):
        found = jobs(CHECK)
        for event, base, expected in [
            ("push", "", (True, True, True, False)),
            ("pull_request", "dev", (True, True, True, False)),
            ("pull_request", "main", (True, True, True, False)),
            ("schedule", "", (True, True, True, True)),
            ("workflow_dispatch", "", (True, True, True, False)),
        ]:
            context = {"event_name": event, "base_ref": base, "event": {"inputs": {"suite": "check"}}}
            with self.subTest(event=event, base=base):
                self.assertEqual(tuple(selected(found[name].get("if"), context) for name in SUITE_JOBS), expected)
        fuzz = {"event_name": "workflow_dispatch", "event": {"inputs": {"suite": "fuzz"}}}
        self.assertEqual(
            tuple(selected(found[name].get("if"), fuzz) for name in SUITE_JOBS), (False, False, False, True)
        )
        group = workflow(CHECK)["concurrency"]["group"]
        self.assertIn("${{ github.event.inputs.suite || 'check' }}", group, "a fuzz run cancels no check run")
        self.assertEqual(found["linux"].get("if"), None, "needs: [plan, image] gates the groups")
        self.assertEqual(
            found["gates"]["if"].removeprefix("always() && (").removesuffix(")").strip(), found["plan"]["if"]
        )

    def test_main_is_never_revalidated(self):
        for path in (CHECK, AGENT_TOOLS):
            with self.subTest(workflow=path):
                self.assertEqual(workflow(path)["on"]["push"]["branches"], ["dev"])

    def test_the_aggregate_requires_every_job_a_dev_push_runs(self):
        found = jobs(CHECK)
        aggregate = found["gates"]
        push = {"event_name": "push", "ref": "refs/heads/dev"}
        running = [name for name, job in found.items() if name != "gates" and selected(job.get("if"), push)]
        self.assertCountEqual(aggregate["needs"], running, "ci/report.py requires every need, so needs is the list")
        self.assertIn("always()", aggregate["if"])
        verdict = step(aggregate, "Summarize and require validation")
        self.assertEqual(verdict["env"]["VALIDATION_NEEDS"], "${{ toJSON(needs) }}")
        ran, _, _ = report_run(PASS, command=verdict["run"])
        self.assertEqual(ran.returncode, 0, ran.stderr)
        for name in PASS:
            ran, _, _ = report_run({**PASS, name: {"result": "failure"}}, command=verdict["run"])
            self.assertNotEqual(ran.returncode, 0, name)
        self.assertEqual(aggregate["name"], "${{ needs.plan.outputs.full == 'true' && 'gates' || 'dev-gates' }}")
        strategy = found["linux"]["strategy"]
        self.assertIs(strategy["fail-fast"], False)
        self.assertEqual(strategy["matrix"]["group"], "${{ fromJSON(needs.plan.outputs.groups) }}")


class PrivilegeTest(unittest.TestCase):
    def test_pull_requests_run_on_read_only_tokens(self):
        check = workflow(CHECK)
        self.assertIn("pull_request", check["on"])
        self.assertNotIn("pull_request_target", check["on"])
        self.assertEqual(check["permissions"], {"contents": "read", "packages": "read"})
        self.assertNotIn("secrets.", text(CHECK))
        self.assertEqual(workflow(GROUP)["permissions"], {"contents": "read", "packages": "read"})
        self.assertNotIn("secrets", text(GROUP))
        linux = check["jobs"]["linux"]
        self.assertEqual(linux["uses"], "./.github/workflows/check-group.yml")
        self.assertNotIn("secrets", json.dumps(linux))
        checked = [(name, job) for name, job in check["jobs"].items() if name in ("plan", "gates", "macos-runtime")]
        checked += [(f"group {name}", job) for name, job in jobs(GROUP).items()]
        self.assertEqual(len(checked), 5)
        for name, job in checked:
            with self.subTest(job=name):
                self.assertTrue(read_only(job.get("permissions")), name)
                self.assertNotIn("self-hosted", json.dumps(job))
                self.assertFalse([found for found in job["steps"] if "ref" in found.get("with", {})])
                checkouts = used(job, "actions/checkout@")
                self.assertTrue(checkouts)
                for checkout in checkouts:
                    self.assertIs(checkout["with"]["persist-credentials"], False)
        for permissions, allowed in (
            ({"actions": "read", "contents": "read"}, True),
            ({"actions": "write", "contents": "read"}, False),
            ({"contents": "write"}, False),
            ("write-all", False),
            ("${{ inputs.permissions }}", False),
        ):
            with self.subTest(permissions=permissions):
                self.assertEqual(read_only(permissions), allowed)

    def test_only_a_trusted_push_publishes_the_image(self):
        events = workflow(IMAGE)["on"]
        self.assertIn("workflow_call", events)
        self.assertNotIn("push", events)
        found = jobs(IMAGE)
        for event, ref, trusted in [
            ("push", "refs/heads/dev", True),
            ("push", "refs/heads/main", True),
            ("pull_request", "refs/heads/dev", False),
            ("pull_request", "refs/pull/7/merge", False),
            ("workflow_dispatch", "refs/heads/topic", False),
        ]:
            context = {"event_name": event, "ref": ref}
            self.assertEqual(selected(found["trusted"].get("if"), context), trusted)
            self.assertEqual(selected(found["readonly"].get("if"), context), not trusted)
        self.assertEqual(found["trusted"]["permissions"], {"contents": "read", "packages": "write"})
        self.assertIs(identified(found["trusted"], "prepare")["with"]["publish"], True)
        self.assertEqual(found["readonly"]["permissions"], {"contents": "read", "packages": "read"})
        self.assertFalse([each for each in found["readonly"]["steps"] if "publish" in each.get("with", {})])
        consumer = jobs(CHECK)["linux"]
        self.assertEqual(consumer["needs"], ["plan", "image"])
        self.assertNotIn("devcontainers/ci@", json.dumps(consumer))
        self.assertEqual(consumer["with"]["image"], "${{ needs.image.outputs.image }}")
        self.assertEqual(consumer["with"]["archive"], "${{ needs.image.outputs.archive }}")
        # The composite publishes only on the literal input, never on a ref.
        script = run(workflow(IMAGE_ACTION)["runs"], "Resolve or build the toolchain image once")
        with tempfile.TemporaryDirectory() as directory:
            stub(directory, "python3", '#!/bin/sh\nprintf "%s\\n" "$@" > "$CALL"\n')
            for publish in ("true", "false"):
                with self.subTest(publish=publish):
                    result = subprocess.run(
                        ["bash", "-e", "-c", script],
                        cwd=ROOT,
                        capture_output=True,
                        text=True,
                        env=on_path(directory, PUBLISH=publish, CALL=f"{directory}/call"),
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(open(f"{directory}/call").read(), f"ci/image.py\nprepare\n--publish\n{publish}\n")
        for value in ("", "yes", "TRUE"):
            with self.subTest(publish=value):
                refused = subprocess.run(
                    [sys.executable, "ci/image.py", "prepare", "--publish", value],
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    refused.returncode, 2, "anything but the literal true or false is refused before any effect"
                )

    def test_other_consumers_start_the_prepared_image_read_only(self):
        for name, consumer in (("pages", "build"), ("agent-tools", "install")):
            document = workflow(f".github/workflows/{name}.yml")
            job = document["jobs"][consumer]
            every = [found for each in document["jobs"].values() for found in each.get("steps", [])]
            grants = [document.get("permissions"), *(each.get("permissions") for each in document["jobs"].values())]
            with self.subTest(workflow=name):
                self.assertFalse([found for found in every if found.get("uses", "").startswith("devcontainers/ci@")])
                self.assertEqual(job.get("permissions", document["permissions"])["packages"], "read")
                self.assertNotIn("write", [grant.get("packages") for grant in grants if grant])
                self.assertEqual([found.get("id") for found in used(job, "./.github/actions/image")], ["image"])
                self.assertFalse([found for found in every if "publish" in found.get("with", {})])
                self.assertEqual(
                    [found["with"] for found in used(job, "./.github/actions/start")],
                    [{"image": "${{ steps.image.outputs.image }}"}],
                )
                configured = [found for found in job["steps"] if CONFIG in found.get("run", "")]
                self.assertTrue(configured)

    def test_agent_downloads_have_their_own_result(self):
        document = workflow(AGENT_TOOLS)
        job = document["jobs"]["install"]
        command = run(job, "Cold-install the pinned coding agents")
        self.assertTrue(
            command.startswith("devcontainer exec --workspace-folder . --config .devcontainer/.ci/devcontainer.json ")
        )
        self.assertIn("python3 tools/run-with-timeout.py", command)
        self.assertIn("bash .devcontainer/test/tool-install.sh", command)
        self.assertEqual(document["permissions"], {"contents": "read", "packages": "read"})
        self.assertNotIn("secrets.", text(AGENT_TOOLS))
        self.assertNotIn("pull_request_target", document["on"])
        checkouts = used(job, "actions/checkout@")
        self.assertTrue(checkouts)
        for checkout in checkouts:
            self.assertIs(checkout["with"]["persist-credentials"], False)
        self.assertFalse([name for name, each in document["jobs"].items() if "needs" in each])


class TransferTest(unittest.TestCase):
    def test_group_jobs_reclaim_disk_and_stage_the_image_before_starting_it(self):
        consumers = 0
        for job in jobs(GROUP).values():
            declared = job["steps"]
            start = 0
            for index, item in enumerate(declared):
                if item.get("uses", "").startswith("actions/checkout@"):
                    start = index
                if item.get("uses") != "./.github/actions/start":
                    continue
                consumers += 1
                preceding = declared[start:index]
                reclaim = [i for i, other in enumerate(preceding) if other.get("run") == "python3 ci/image.py reclaim"]
                images = [
                    i for i, other in enumerate(preceding) if other.get("with", {}).get("name") == "devcontainer-image"
                ]
                self.assertEqual(len(reclaim), 1)
                self.assertEqual(len(images), 2, "stage the image, with one bounded retry, before startup")
                self.assertLess(reclaim[0], images[0])
                for archive, successful in (("true", True), ("false", True), ("true", False)):
                    self.assertEqual(
                        selected(
                            preceding[images[0]]["if"], context={"inputs": {"archive": archive}}, success=successful
                        ),
                        archive == "true" and successful,
                    )
        self.assertEqual(consumers, 2)

    def test_transfers_have_step_deadlines(self):
        files = [(str(path.relative_to(ROOT)), False) for path in sorted(WORKFLOWS.glob("*.yml"))]
        files += [(path, True) for path in COMPOSITES]
        found = []
        for path, composite in files:
            document = workflow(path)
            if composite:
                declared = document["runs"]["steps"]
            else:
                declared = [item for job in document["jobs"].values() for item in job.get("steps", [])]
            for item in declared:
                if TRANSFER.match(item.get("uses", "")):
                    found.append(item)
                    with self.subTest(path=path, name=item.get("name", item["uses"])):
                        self.assertFalse(composite, "transfer deadlines belong to workflow steps, not composites")
                        # Downloads are bounded by what they carry at the slowest
                        # runner rate measured: the 1.62 GB image took 255 s, the
                        # largest group's 4.7 GB compiled state took over five
                        # minutes, and the release collects every artifact of its
                        # run. Every other transfer finishes in seconds.
                        with_ = item.get("with", {})
                        collects_everything = "name" not in with_ and "pattern" not in with_
                        if with_.get("name") == "devcontainer-image" or collects_everything:
                            ceiling = 10
                        elif with_.get("pattern", "").startswith("state-"):
                            ceiling = 12
                        else:
                            ceiling = 5
                        budget = item.get("timeout-minutes")
                        self.assertIs(type(budget), int)
                        self.assertGreater(budget, 0)
                        self.assertLessEqual(budget, ceiling)
        self.assertTrue(found, "no transfer declarations were read")

    def test_required_handoffs_retry_identical_inputs_without_hiding_failure(self):
        pairs = []
        for path in sorted(WORKFLOWS.glob("*.yml")):
            for job in workflow(str(path.relative_to(ROOT)))["jobs"].values():
                declared = job.get("steps", [])
                for index, first in enumerate(declared):
                    if first.get("continue-on-error") is not True or "-artifact@" not in first.get("uses", ""):
                        continue
                    retry = declared[index + 1]
                    pairs.append(first)
                    with self.subTest(workflow=path.name, transfer=first.get("name")):
                        self.assertEqual(retry["uses"], first["uses"])
                        self.assertEqual(retry["with"], first["with"])
                        self.assertIsNot(
                            retry.get("continue-on-error"), True, "the final transfer attempt must fail the job"
                        )
                        self.assertIn("id", first)
                        for outcome in ("success", "failure", "cancelled", "skipped"):
                            context = {
                                "inputs": {"archive": "true"},
                                "needs": {"build": {"result": "success"}},
                                "steps": {
                                    "prepare": {"outputs": {"archive": "true"}},
                                    "fetch": {"outcome": "success"},
                                    first["id"]: {"outcome": outcome},
                                },
                            }
                            for cancelled in (False, True):
                                self.assertEqual(
                                    selected(retry["if"], context=context, success=not cancelled, cancelled=cancelled),
                                    outcome == "failure" and not cancelled,
                                )
                            if first.get("id") == "hand" and outcome == "failure":
                                self.assertTrue(
                                    selected(retry["if"], context=context, success=False),
                                    "a compile failure must not suppress its state handoff retry",
                                )
                        if first["with"].get("name") == "devcontainer-image":
                            context["inputs"]["archive"] = "false"
                            context["steps"]["prepare"]["outputs"]["archive"] = "false"
                            self.assertFalse(selected(first["if"], context=context))
        self.assertTrue(
            any(item["with"].get("name") == "devcontainer-image" for item in pairs),
            "the unpublished image needs a bounded handoff too",
        )


class GroupTest(unittest.TestCase):
    def test_every_job_fetches_dependencies_through_the_runner(self):
        for path, skipped in ((CHECK, ("gates", "plan", "image", "linux", "workflows", "dependencies")), (GROUP, ())):
            for name, job in jobs(path).items():
                if name not in skipped:
                    fetches = [found for found in job["steps"] if "python3 ci/gates.py fetch" in found.get("run", "")]
                    self.assertTrue(fetches, f"{path}: {name}")

    def test_a_group_compiles_in_shards_then_runs_each_phase(self):
        found = jobs(GROUP)
        build, test = found["build"], found["test"]
        for shards, expected in (("[]", False), ("[1]", True), ("[1, 2]", True)):
            self.assertEqual(selected(build["if"], context={"inputs": {"shards": shards}}), expected)
        self.assertEqual(build["strategy"]["matrix"]["shard"], "${{ fromJSON(inputs.shards) }}")
        compiling = step(build, "Compile this shard of what the group's phases run")
        self.assertEqual(
            compiling["env"],
            {
                "SHARD": "${{ matrix.shard }}/${{ strategy.job-total }}",
                "PHASES": "${{ join(fromJSON(inputs.phases), ' ') }}",
            },
        )
        self.assertEqual(compiling["run"], '$EXEC python3 ci/gates.py compile "$SHARD" $PHASES')
        packing = step(build, "Pack the compiled state")
        self.assertEqual(packing["env"], {"SHARD": "${{ matrix.shard }}"})
        self.assertEqual(packing["run"], 'python3 ci/state.py pack "$RUNNER_TEMP/state-$SHARD.tar.zst"')
        self.assertEqual(
            step(build, "Hand the compiled state to the test jobs")["with"]["path"],
            "${{ runner.temp }}/state-${{ matrix.shard }}.tar.zst",
        )
        # download-artifact extracts a lone match into `path` and gives each of
        # several matches its own directory, so only merged, uniquely named
        # archives sit at one path for every shard count.
        receive = step(test, "Receive the group's compiled state")
        self.assertEqual(receive["with"]["path"], "${{ runner.temp }}/state")
        self.assertIs(receive["with"]["merge-multiple"], True)
        restoring = step(test, "Restore the group's compiled state")
        self.assertEqual(restoring["env"], {"SHARDS": "${{ inputs.shards }}", "BUILD": "${{ needs.build.result }}"})
        self.assertEqual(restoring["run"], 'python3 ci/state.py restore "$RUNNER_TEMP/state" "$SHARDS" "$BUILD"')
        self.assertEqual(test["strategy"]["matrix"]["phase"], "${{ fromJSON(inputs.phases) }}")
        phase = step(test, "Run the phase")
        self.assertEqual(phase["env"], {"PHASE": "${{ matrix.phase }}"})
        self.assertEqual(phase["run"], '$EXEC python3 ci/gates.py run "$PHASE"')
        self.assertEqual(run(test, "Summarize gate results"), "python3 ci/gates.py summary")
        # Every shard and phase reports, and the phases run after a failed
        # compile, so one run names every failure in a group.
        for job in (build, test):
            self.assertIs(job["strategy"]["fail-fast"], False)
        for result, expected in (("success", True), ("failure", True), ("skipped", True), ("cancelled", False)):
            self.assertEqual(selected(test["if"], context={"needs": {"build": {"result": result}}}), expected)
        self.assertFalse(selected(test["if"], context={"needs": {"build": {"result": "success"}}}, cancelled=True))
        self.assertEqual(
            step(test, "Keep the evidence record")["with"]["name"], "evidence-${{ github.sha }}-${{ matrix.phase }}"
        )

    def test_pull_requests_reuse_compile_state_and_everything_else_builds_cold(self):
        build = jobs(GROUP)["build"]
        for name, expected in (
            ("Restore build state", {"pull_request"}),
            ("Bound the restored build state", {"pull_request"}),
            ("Save build state", {"push", "schedule", "workflow_dispatch"}),
        ):
            for event in ("pull_request", "push", "schedule", "workflow_dispatch"):
                with self.subTest(step=name, event=event):
                    allowed = selected(
                        step(build, name)["if"],
                        {"event_name": event},
                        context={"steps": {"fetch": {"outcome": "success"}}},
                    )
                    self.assertEqual(allowed, event in expected)
            self.assertFalse(selected(step(build, name)["if"], {"event_name": "pull_request"}, cancelled=True))
        self.assertEqual(run(build, "Bound the restored build state"), "python3 ci/state.py bound 12 20")
        # The state key names the run, so a restore falls back to the shard's
        # newest state and an unrelated manifest edit keeps it.
        family = "build-${{ runner.os }}-${{ runner.arch }}-${{ inputs.group }}-${{ matrix.shard }}of${{ strategy.job-total }}-"
        keys = []
        for name in ("Restore build state", "Save build state"):
            block = step(build, name)["with"]
            key = block["key"]
            self.assertTrue(key.startswith(family))
            self.assertNotIn("hashFiles", key)
            self.assertTrue(key.endswith("${{ github.run_id }}-${{ github.run_attempt }}"))
            keys.append(key)
            if name == "Restore build state":
                self.assertEqual(block["restore-keys"], family)
        self.assertEqual(keys[0], keys[1])
        # Downloads follow the dependency manifests.
        downloads = step(build, "Restore dependency downloads")["with"]["key"]
        self.assertIn("hashFiles('build.zig.zon'", downloads)
        self.assertIn("'**/Cargo.lock'", downloads)

    def test_runs_keep_fuzzer_findings(self):
        for path, job in ((CHECK, "scheduled-fuzz"), (GROUP, "test")):
            with self.subTest(workflow=path):
                block = step(jobs(path)[job], "Keep a fuzzer finding")
                self.assertEqual(block["if"], "${{ !cancelled() && hashFiles('zig-out/fuzz-finding.bin') != '' }}")
                self.assertEqual(block["with"]["path"], "zig-out/fuzz-finding.bin")
                self.assertEqual(block["with"]["if-no-files-found"], "error")
        fuzz = jobs(CHECK)["scheduled-fuzz"]
        self.assertIn("github.run_attempt", step(fuzz, "Keep a fuzzer finding")["with"]["name"])
        self.assertIn("zig build fuzz -Dfuzz-runs=250K", run(fuzz, "Deep mutation fuzzing"))


if __name__ == "__main__":
    unittest.main()
