"""Read the workflow files as the YAML they are, and evaluate their predicates.

A workflow is a mapping: `on`, `permissions`, and `jobs`, each job a mapping
with its `if`, `needs`, `permissions`, and `steps`. The tests assert on those
mappings, so a change in the file's layout that keeps its meaning changes no
test, and a repeated key (which GitHub refuses as an invalid workflow file)
refuses to load. `selected` interprets the boolean and string subset of
Actions expressions the predicates use, with the job or step context the
caller supplies. None of this runs on a GitHub runner.
"""

import ast
import importlib.util
import json
import os
import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
BOOL = "tag:yaml.org,2002:bool"


def text(path):
    return (ROOT / path).read_text()


def load(path):
    """A first-party Python program under the root as a module, for one whose name or directory `import` cannot reach."""
    spec = importlib.util.spec_from_file_location(Path(path).stem.replace("-", "_"), ROOT / path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {ROOT / path} as a module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Loader(yaml.SafeLoader):
    """The safe loader, keeping the `on` key a string and refusing a repeated key."""

    def construct_mapping(self, node, deep=False):
        self.flatten_mapping(node)
        mapping = {}
        for key_node, value_node in node.value:
            key = key_node.value if key_node.tag == BOOL and key_node.value == "on" else self.construct_object(key_node)
            if key in mapping:
                raise yaml.constructor.ConstructorError(None, None, f"repeated key {key!r}", key_node.start_mark)
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


def workflow(path):
    """A workflow, composite action, or other YAML file under the root, as a mapping."""
    return yaml.load(text(path), Loader)


def jobs(path):
    """A workflow's jobs by name."""
    return workflow(path)["jobs"]


def step(job, name):
    """The step named `name` in a job (or a composite action's `runs`)."""
    for found in job["steps"]:
        if found.get("name") == name:
            return found
    raise AssertionError(f"no step named {name!r}")


def run(job, name):
    """The script the step named `name` runs."""
    return step(job, name)["run"]


def duplicate_mapping_keys(source):
    """Each repeated key in a YAML document, as (line, key), in document order."""
    duplicates, seen = [], set()

    def walk(node):
        if id(node) in seen:
            return
        seen.add(id(node))
        if isinstance(node, yaml.MappingNode):
            keys = set()
            for key, value in node.value:
                if key.value in keys:
                    duplicates.append((key.start_mark.line + 1, key.value))
                keys.add(key.value)
                walk(value)
        elif isinstance(node, yaml.SequenceNode):
            for item in node.value:
                walk(item)

    walk(yaml.compose(source, yaml.SafeLoader))
    return duplicates


def stub(directory, name, source):
    """An executable stand-in for a tool, first on PATH when `directory` is."""
    path = Path(directory) / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)
    path.chmod(0o755)
    return path


def on_path(directory, **extra):
    """The environment with `directory` first on PATH, plus `extra`."""
    return dict(os.environ, PATH=f"{directory}{os.pathsep}{os.environ['PATH']}", **extra)


def selected(expression, github=None, *, context=None, success=True, cancelled=False):
    """Evaluate an `if` expression (None for a job or step without one). Refuses syntax the predicates do not use."""
    if expression is None:
        return success and not cancelled
    return bool(value(expression, github, context=context, success=success, cancelled=cancelled))


def value(expression, github=None, *, context=None, success=True, cancelled=False):
    """Evaluate an expression to its value, as `a && b || c` and `fromJSON('...')` yield in a matrix or `with`."""
    expression = expression.strip().removeprefix("${{").removesuffix("}}").strip()
    expression = re.sub(r"!(?!=)", " not ", expression).replace("&&", " and ").replace("||", " or ").strip()
    root = ast.parse(expression, mode="eval").body
    values = {"github": github or {}, **(context or {})}
    status = {"always": True, "success": success and not cancelled, "cancelled": cancelled}

    def evaluate(node):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and not node.args and not node.keywords:
            if node.func.id in status:
                return status[node.func.id]
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "startsWith"
            and len(node.args) == 2
            and not node.keywords
        ):
            value, prefix = (evaluate(argument) for argument in node.args)
            if isinstance(value, str) and isinstance(prefix, str):
                return value.casefold().startswith(prefix.casefold())
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "fromJSON"
            and len(node.args) == 1
            and not node.keywords
        ):
            return json.loads(evaluate(node.args[0]))
        if isinstance(node, ast.Constant) and isinstance(node.value, (str, bool)):
            return node.value
        if isinstance(node, ast.Name) and node.id in values:
            return values[node.id]
        if isinstance(node, ast.Attribute):
            return evaluate(node.value).get(node.attr, {})
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return not evaluate(node.operand)
        if isinstance(node, ast.BoolOp) and isinstance(node.op, (ast.And, ast.Or)):
            # Actions returns the deciding operand, as Python does.
            for operand in node.values:
                found = evaluate(operand)
                if bool(found) != isinstance(node.op, ast.And):
                    return found
            return found
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], (ast.Eq, ast.NotEq)):
            left, right = evaluate(node.left), evaluate(node.comparators[0])
            if isinstance(left, str) and isinstance(right, str):
                left, right = left.casefold(), right.casefold()
            equal = left == right
            return equal if isinstance(node.ops[0], ast.Eq) else not equal
        raise AssertionError(f"unsupported CI predicate: {ast.dump(node)}")

    # Actions adds success() unless the expression supplies a status function.
    explicit = any(
        isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in status
        for node in ast.walk(root)
    )
    return evaluate(root) if explicit or status["success"] else False
