"""check.yml and the group workflow it calls, for infrastructure-check.

Read from the workflows as YAML: which events run what, which jobs the one
required result waits for, what every workflow grants and keeps, that every
transfer is bounded and each required one retried, and when compile state is
reused. A fact the YAML states once is not copied here: the tests hold the
policies every file meets and what the predicates select. The gate runner
(gates_test) and the state script (state_test) have their own tests, and
workflow_audit_test holds every workflow to the static audit.
"""

import json
import re
import subprocess
import sys
import unittest

from report_test import PASS, report_run
from workflows import ROOT, WORKFLOWS, jobs, selected, step, text, workflow

CHECK = ".github/workflows/check.yml"
GROUP = ".github/workflows/check-group.yml"
IMAGE = ".github/workflows/devcontainer-image.yml"
SUITE_JOBS = ("plan", "gates", "macos-runtime", "scheduled-fuzz")
TRANSFER = re.compile(r"actions/(upload-artifact|download-artifact|cache(/restore|/save)?)@")
COMPOSITES = tuple(str(path.relative_to(ROOT)) for path in sorted(ROOT.glob(".github/actions/*/action.yml")))
# The jobs of a pull-request workflow that write, and the one reason each may:
# the image is published only by the trusted job, which a pull request skips,
# and the audit uploads its findings to code scanning.
WRITERS = {(CHECK, "image"): {"packages"}, (CHECK, "workflows"): {"security-events"}, (IMAGE, "trusted"): {"packages"}}


def every_job():
    """(workflow path, job name, job) for every job of every workflow."""
    for path in sorted(WORKFLOWS.glob("*.yml")):
        relative = str(path.relative_to(ROOT))
        for name, job in jobs(relative).items():
            yield relative, name, job


def every_step():
    """(file path, owner name, step) for every step of every workflow and composite action."""
    for path, name, job in every_job():
        for found in job.get("steps", ()):
            yield path, name, found
    for path in COMPOSITES:
        for found in workflow(path)["runs"]["steps"]:
            yield path, "runs", found


def read_only(permissions, writes=()):
    """True when a permissions block grants nothing beyond reading, except the scopes allowed to write."""
    if permissions is None:
        return True  # The workflow's own block applies.
    return isinstance(permissions, dict) and all(
        level in ("read", "none") or scope in writes for scope, level in permissions.items()
    )


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
        self.assertTrue(
            workflow(CHECK)["concurrency"]["cancel-in-progress"], "a newer push cancels the run it supersedes"
        )
        self.assertEqual(
            found["gates"]["if"].removeprefix("always() && (").removesuffix(")").strip(), found["plan"]["if"]
        )

    def test_main_is_never_revalidated(self):
        for path in (CHECK, ".github/workflows/agent-tools.yml"):
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

    def test_only_a_trusted_push_publishes_the_image(self):
        events = workflow(IMAGE)["on"]
        self.assertEqual(list(events), ["workflow_call"])
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
        self.assertEqual(found["trusted"]["permissions"]["packages"], "write")
        self.assertEqual(found["readonly"]["permissions"]["packages"], "read")
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


class PolicyTest(unittest.TestCase):
    """What every workflow file meets, read from all of them."""

    def test_pull_request_workflows_run_on_read_only_tokens(self):
        triggered = [path for path in sorted(WORKFLOWS.glob("*.yml")) if "pull_request" in workflow(path)["on"]]
        self.assertTrue(triggered)
        for path in triggered:
            relative = str(path.relative_to(ROOT))
            called = [job["uses"] for job in jobs(relative).values() if job.get("uses", "").startswith("./")]
            for name in (relative, *(uses.removeprefix("./") for uses in called)):
                document = workflow(name)
                with self.subTest(workflow=name):
                    self.assertNotIn("pull_request_target", document["on"])
                    self.assertNotIn("secrets.", text(name))
                    self.assertTrue(read_only(document.get("permissions")))
                    for job_name, job in document["jobs"].items():
                        self.assertTrue(read_only(job.get("permissions"), WRITERS.get((name, job_name), ())), job_name)
                        self.assertNotIn("self-hosted", json.dumps(job))
        for permissions, allowed in (
            ({"actions": "read", "contents": "read"}, True),
            ({"actions": "write", "contents": "read"}, False),
            ({"contents": "write"}, False),
            ("write-all", False),
            ("${{ inputs.permissions }}", False),
        ):
            with self.subTest(permissions=permissions):
                self.assertEqual(read_only(permissions), allowed)

    def test_every_checkout_leaves_no_credentials(self):
        checkouts = [found for _, _, found in every_step() if found.get("uses", "").startswith("actions/checkout@")]
        self.assertTrue(checkouts)
        for checkout in checkouts:
            self.assertIs(checkout["with"]["persist-credentials"], False)

    def test_every_matrix_reports_every_leg(self):
        strategies = [job["strategy"] for _, _, job in every_job() if "strategy" in job]
        self.assertTrue(strategies)
        for strategy in strategies:
            self.assertIs(strategy["fail-fast"], False)

    def test_every_artifact_step_is_exact(self):
        uploads = downloads = 0
        for path, owner, found in every_step():
            uses, options = found.get("uses", ""), found.get("with", {})
            with self.subTest(path=path, step=found.get("name", uses)):
                if uses.startswith("actions/upload-artifact@"):
                    uploads += 1
                    self.assertEqual(options["if-no-files-found"], "error", "an upload with nothing to send fails")
                if uses.startswith("actions/download-artifact@") and "pattern" in options:
                    downloads += 1
                    self.assertIs(options["merge-multiple"], True, "a pattern's matches land at one path")
        self.assertTrue(uploads and downloads)

    def test_consumers_of_the_prepared_image_never_publish(self):
        consumers = 0
        for path, name, job in every_job():
            if path == IMAGE:
                continue
            for found in job.get("steps", ()):
                if found.get("uses") == "./.github/actions/image":
                    consumers += 1
                    with self.subTest(workflow=path, job=name):
                        self.assertNotIn("publish", found.get("with", {}))
                        self.assertEqual(job.get("permissions", workflow(path)["permissions"])["packages"], "read")
        self.assertGreater(consumers, 0)


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
        found = []
        for path, owner, item in every_step():
            if TRANSFER.match(item.get("uses", "")):
                found.append(item)
                with self.subTest(path=path, name=item.get("name", item["uses"])):
                    self.assertNotEqual(owner, "runs", "transfer deadlines belong to workflow steps, not composites")
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
        for path, _, job in every_job():
            declared = job.get("steps", [])
            for index, first in enumerate(declared):
                if first.get("continue-on-error") is not True or "-artifact@" not in first.get("uses", ""):
                    continue
                retry = declared[index + 1]
                pairs.append(first)
                with self.subTest(workflow=path, transfer=first.get("name")):
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
    def test_every_job_that_builds_fetches_dependencies_first(self):
        builders = 0
        for path, name, job in every_job():
            scripts = [found.get("run", "") for found in job.get("steps", ())]
            building = [
                i for i, script in enumerate(scripts) if re.search(r"zig build|ci/gates\.py (run|compile)", script)
            ]
            if building:
                builders += 1
                fetching = [i for i, script in enumerate(scripts) if "ci/gates.py fetch" in script]
                with self.subTest(workflow=path, job=name):
                    self.assertTrue(
                        fetching and fetching[0] < building[0], "a bounded, retried fetch precedes the build"
                    )
        self.assertGreater(builders, 2)

    def test_a_group_compiles_in_shards_then_runs_each_phase(self):
        found = jobs(GROUP)
        build, test = found["build"], found["test"]
        for shards, expected in (("[]", False), ("[1]", True), ("[1, 2]", True)):
            self.assertEqual(selected(build["if"], context={"inputs": {"shards": shards}}), expected)
        # The phases run after a failed compile, so one run names every failure in a group.
        for result, expected in (("success", True), ("failure", True), ("skipped", True), ("cancelled", False)):
            self.assertEqual(selected(test["if"], context={"needs": {"build": {"result": result}}}), expected)
        self.assertFalse(selected(test["if"], context={"needs": {"build": {"result": "success"}}}, cancelled=True))

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
        # The state key names the run, so a restore falls back to the shard's
        # newest state and an unrelated manifest edit keeps it.
        restore = step(build, "Restore build state")["with"]
        self.assertTrue(restore["key"].startswith(restore["restore-keys"]))
        self.assertNotIn("hashFiles", restore["key"])
        self.assertTrue(restore["key"].endswith("${{ github.run_id }}-${{ github.run_attempt }}"))


if __name__ == "__main__":
    unittest.main()
