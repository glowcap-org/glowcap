"""Read the hand-written workflow files and evaluate their predicates.

The workflows are block-style YAML written by hand, so these readers match
lines and indentation and refuse a shape they do not know. `selected`
interprets the boolean and string subset of Actions expressions the
predicates use, with the job or step context the caller supplies. None of
this runs on a GitHub runner.
"""

import ast
import os
from pathlib import Path
import re
import textwrap
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / '.github/workflows'


def text(path):
    return (ROOT / path).read_text()


class Job(NamedTuple):
    condition: str  # The `if` expression, folded onto one line, or None.
    body: str


def jobs(path):
    """Every job of a workflow by name, with its `if` and indented body."""
    source = text(path).split('\njobs:\n', 1)[1]
    found = {}
    for match in re.finditer(r'^  ([\w-]+):\n((?: {4}[^\n]*\n|\n)*)', source, re.M):
        name, body = match.groups()
        condition = re.search(r'^    if: (?:&[\w-]+ )?(.+)\n', body, re.M)
        expression = condition and condition[1]
        if expression == '>-':
            lines = re.match(r'(?: {6}[^\n]*\n)+', body[condition.end():])
            if lines is None:
                raise AssertionError(f'{path}: {name} has no folded predicate')
            expression = ' '.join(line.strip() for line in lines.group().splitlines())
        found[name] = Job(expression, body)
    anchors = {}
    for job in found.values():
        anchor = re.search(r'^    if: &([\w-]+) ', job.body, re.M)
        if anchor:
            anchors[anchor[1]] = job.condition
    for name, job in found.items():
        if job.condition and job.condition.startswith('*'):
            found[name] = Job(anchors[job.condition[1:]], job.body)
    return found


def steps(source, indent=6):
    """Each step's scalar fields, with anchored `with` mappings resolved to text.

    `indent` is 6 for a workflow's jobs and 4 for a composite action's steps.
    """
    source = source.split('\njobs:\n' if indent == 6 else '\nruns:\n', 1)[-1]
    anchors = {}
    pattern = rf'^ {{{indent}}}- ([\w-]+): ([^\n]+)\n((?:(?: {{{indent + 2}}}[^\n]*|)\n)*)'
    declarations = list(re.finditer(pattern, source, re.M))
    if len(declarations) != len(re.findall(rf'^ {{{indent}}}- ', source, re.M)):
        raise AssertionError('unsupported workflow step declaration')
    for match in declarations:
        body = match[3]
        fields = dict(re.findall(rf'^ {{{indent + 2}}}([\w-]+):(?: ([^\n]*))?$', body, re.M))
        fields[match[1]] = match[2]
        if 'uses' in fields:
            fields['uses'] = fields['uses'].split(' #', 1)[0].strip('"\'')
        if 'with' in fields:
            reference = fields['with']
            if reference.startswith('*'):
                fields['with'] = anchors[reference[1:]]
            else:
                mapping = re.search(rf'^ {{{indent + 2}}}with:[^\n]*\n((?: {{{indent + 4}}}[^\n]*\n)*)', body, re.M)
                fields['with'] = textwrap.dedent(mapping[1])
                if reference.startswith('&'):
                    anchors[reference[1:]] = fields['with']
        yield fields


def step(body, name):
    """A named step's block within a job body or workflow, name line included."""
    found = re.search(rf'(?m)^      - (?:name: {re.escape(name)}|uses: [^\n]*\n(?: {{8}}[^\n]*\n)*? {{8}}name: {re.escape(name)})\n((?: {{8,}}[^\n]*\n|\n)*)', body)
    if found is None:
        raise AssertionError(f'no step named {name!r}')
    return found[0]


def shell_step(source, name):
    """The script a named step runs, dedented."""
    block = step(source, name)
    script = re.search(r'(?m)^        run: \|\n((?: {10}[^\n]*\n|\n)*)', block)
    if script is not None:
        return textwrap.dedent(script[1])
    return re.search(r'(?m)^        run: (.+)$', block)[1]


def duplicate_mapping_keys(source):
    """Keys repeated inside one YAML mapping, which GitHub refuses as an invalid workflow file.

    Walks the indentation structure of the block-style workflows this
    repository writes: a key at an indent closes every deeper mapping, a list
    item opens a fresh mapping for its members, and the lines of a block
    scalar (a `run: |` script) are text, not keys.
    """
    duplicates, levels, scalar_indent = [], [], None
    for number, raw in enumerate(source.splitlines(), 1):
        line = raw.split(' #', 1)[0].rstrip() if not raw.lstrip().startswith('#') else ''
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(' '))
        if scalar_indent is not None and indent > scalar_indent:
            continue
        scalar_indent = None
        content = line.lstrip(' ')
        if content.startswith('- '):
            while levels and levels[-1][0] >= indent:
                levels.pop()
            levels.append((indent + 2, set()))
            content, indent = content[2:], indent + 2
        match = re.match(r'([A-Za-z0-9_.\-"\'$]+|\$\{\{[^}]*\}\}):(?:\s|$)', content)
        if not match:
            continue
        while levels and levels[-1][0] > indent:
            levels.pop()
        if not levels or levels[-1][0] < indent:
            levels.append((indent, set()))
        keys = levels[-1][1]
        if match[1] in keys:
            duplicates.append((number, match[1]))
        keys.add(match[1])
        if re.fullmatch(r'(?:&[\w-]+ )?[|>][-+]?', content[match.end():].strip()):
            scalar_indent = indent
    return duplicates


def stub(directory, name, source):
    """An executable stand-in for a tool, first on PATH when `directory` is."""
    path = Path(directory) / name
    path.write_text(source)
    path.chmod(0o755)
    return path


def on_path(directory, **extra):
    """The environment with `directory` first on PATH, plus `extra`."""
    return dict(os.environ, PATH=f'{directory}{os.pathsep}{os.environ["PATH"]}', **extra)


def selected(expression, github=None, *, context=None, success=True, cancelled=False):
    """Evaluate an `if` expression. Refuses syntax the predicates do not use."""
    expression = expression.strip().removeprefix('${{').removesuffix('}}').strip()
    expression = re.sub(r'!(?!=)', ' not ', expression).replace('&&', ' and ').replace('||', ' or ').strip()
    root = ast.parse(expression, mode='eval').body
    values = {'github': github or {}, **(context or {})}
    status = {'always': True, 'success': success and not cancelled, 'cancelled': cancelled}

    def evaluate(node):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and not node.args and not node.keywords:
            if node.func.id in status:
                return status[node.func.id]
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id == 'startsWith' and len(node.args) == 2 and not node.keywords):
            value, prefix = (evaluate(argument) for argument in node.args)
            if isinstance(value, str) and isinstance(prefix, str):
                return value.casefold().startswith(prefix.casefold())
        if isinstance(node, ast.Constant) and isinstance(node.value, (str, bool)):
            return node.value
        if isinstance(node, ast.Name) and node.id in values:
            return values[node.id]
        if isinstance(node, ast.Attribute):
            return evaluate(node.value).get(node.attr, {})
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return not evaluate(node.operand)
        if isinstance(node, ast.BoolOp):
            operands = (evaluate(value) for value in node.values)
            if isinstance(node.op, ast.And):
                return all(operands)
            if isinstance(node.op, ast.Or):
                return any(operands)
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], (ast.Eq, ast.NotEq)):
            left, right = evaluate(node.left), evaluate(node.comparators[0])
            if isinstance(left, str) and isinstance(right, str):
                left, right = left.casefold(), right.casefold()
            equal = left == right
            return equal if isinstance(node.ops[0], ast.Eq) else not equal
        raise AssertionError(f'unsupported CI predicate: {ast.dump(node)}')

    # Actions adds success() unless the expression supplies a status function.
    explicit = any(isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                   and node.func.id in status for node in ast.walk(root))
    return bool((explicit or status['success']) and evaluate(root))
