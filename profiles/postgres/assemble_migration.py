#!/usr/bin/env python3
"""Assemble explicit UTF-8 SQL fragments; never execute SQL (see postgres.md)."""
import argparse
import os
from pathlib import Path
import re
import sys
import tempfile


def statements(sql):
    """Lex only statement boundaries, skipping SQL literals/comments/body quotes.

    This is a fragment-format validator, not a SQL grammar or correctness parser.
    """
    words, i, n = [], 0, len(sql)
    while i < n:
        c = sql[i]
        if c.isspace():
            i += 1
        elif sql.startswith('--', i):
            end = sql.find('\n', i + 2)
            i = n if end < 0 else end + 1
        elif sql.startswith('/*', i):
            depth, i = 1, i + 2
            while i < n and depth:
                if sql.startswith('/*', i):
                    depth, i = depth + 1, i + 2
                elif sql.startswith('*/', i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            if depth:
                raise ValueError('unterminated block comment')
        elif c in "'\"":
            quote = c
            escaped = c == "'" and i > 0 and sql[i-1] in 'eE' and (i < 2 or not (sql[i-2].isalnum() or sql[i-2] == '_'))
            i += 1
            while i < n:
                if escaped and sql[i] == '\\':
                    i += 2
                elif sql[i] == quote:
                    if i + 1 < n and sql[i+1] == quote:
                        i += 2
                    else:
                        i += 1
                        break
                else:
                    i += 1
            else:
                raise ValueError('unterminated quoted literal/identifier')
            words.append('<quoted>')
        elif c == '$' and (match := re.match(r'\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$', sql[i:])):
            tag = match.group(0)
            end = sql.find(tag, i + len(tag))
            if end < 0:
                raise ValueError('unterminated dollar quote')
            i = end + len(tag)
            words.append('<body>')
        elif c == '\\':
            raise ValueError('psql metacommands/includes are not allowed outside quotes/comments')
        elif c == ';':
            if words:
                yield words
            words, i = [], i + 1
        elif c.isalpha() or c == '_':
            match = re.match(r'[\w$]+', sql[i:])
            words.append(match.group(0).upper())
            i += len(match.group(0))
        else:
            words.append(c)
            i += 1
    if words:
        raise ValueError('every fragment statement must end with a semicolon')


def validate(sql):
    if '\ufeff' in sql:
        raise ValueError('UTF-8 BOM is not supported in SQL fragments')
    found = False
    for words in statements(sql):
        found = True
        first = words[0]
        if words[:3] == ['SET', 'LOCAL', 'TRANSACTION'] or first in {'BEGIN', 'COMMIT', 'END', 'ROLLBACK', 'ABORT', 'SAVEPOINT', 'RELEASE'} or words[:2] in [
            ['START', 'TRANSACTION'], ['PREPARE', 'TRANSACTION'], ['SET', 'TRANSACTION'], ['SET', 'SESSION']
        ]:
            # SET SESSION is conservatively excluded (including transaction defaults).
            raise ValueError('top-level transaction control (or SET SESSION) is not allowed')
    if not found:
        raise ValueError('empty SQL fragment (comments do not count)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ddl', required=True, type=Path)
    parser.add_argument('--definition', action='append', default=[], type=Path,
                        help='full canonical SQL definition; repeat in required execution order')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    temporary = None
    try:
        paths = [args.ddl, *args.definition]
        resolved = [p.resolve() for p in paths]
        if len(set(resolved)) != len(resolved):
            raise ValueError('duplicate input path')
        if args.output.resolve() in resolved:
            raise ValueError('output must not be an input')
        fragments = []
        for path in paths:
            sql = path.read_bytes().decode('utf-8')
            validate(sql)
            fragments.append(sql)
        output = 'BEGIN;\n\n' + '\n\n'.join(fragments) + '\n\nCOMMIT;\n'
        with tempfile.NamedTemporaryFile(mode='wb', dir=args.output.parent, delete=False) as handle:
            temporary = handle.name
            handle.write(output.encode('utf-8'))
        os.replace(temporary, args.output)
        temporary = None
    except (OSError, UnicodeError, ValueError) as error:
        print(f'assemble_migration: {error}', file=sys.stderr)
        return 2
    finally:
        if temporary is not None:
            os.unlink(temporary)
    return 0


if __name__ == '__main__':
    sys.exit(main())
