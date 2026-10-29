"""The boolean/string Actions predicates exercised by the workflow tests.

Callers supply the job or step context. This interprets declarations, not the
GitHub runner. Refuse unfamiliar syntax instead of guessing its behavior.
"""

import ast
import re


def selected(expression, github=None, *, context=None, success=True, cancelled=False):
    expression = expression.strip().removeprefix('${{').removesuffix('}}').strip()
    expression = re.sub(r'!(?!=)', ' not ', expression).replace('&&', ' and ').replace('||', ' or ').strip()
    root = ast.parse(expression, mode='eval').body
    values = {'github': github or {}, **(context or {})}
    status = {'always': True, 'success': success and not cancelled, 'cancelled': cancelled}

    def evaluate(node):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and not node.args and not node.keywords:
            if node.func.id in status:
                return status[node.func.id]
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
