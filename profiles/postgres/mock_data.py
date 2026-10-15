#!/usr/bin/env python3
"""Versioned project-owned PostgreSQL test data. Requires Python 3 and psql."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
from datetime import datetime, timezone

FORMAT = 1
MARKER = "harness mock-data disposable"


class Error(Exception):
    pass


def ident(value):
    return '"' + value.replace('"', '""') + '"'


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def relation(name):
    parts = name.split('.')
    if len(parts) != 2 or any(not p for p in parts):
        raise Error("Expected schema.table: " + name)
    return '.'.join(ident(p) for p in parts)


def component(value):
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", value) or value in ('.', '..'):
        raise Error("Unsafe version/path component: " + value)
    return value


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text())


def write_new(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write('\n')


class Database:
    def __init__(self, config, database=None):
        tokens = shlex.split(config.get('verify_command', ''))
        flags = {}
        self.env = os.environ.copy()
        for i, token in enumerate(tokens):
            if token in ('-h', '-p', '-U', '-d') and i + 1 < len(tokens):
                flags[token] = tokens[i + 1]
            if token.startswith('PGPASSWORD=') and 'PGPASSWORD' not in self.env:
                self.env['PGPASSWORD'] = token.split('=', 1)[1]
        configured = config.get('postgres_database')
        if not configured:
            match = re.search(r"datname\s*=\s*'([^']+)'", config.get('verify_command', ''), re.I)
            configured = match.group(1) if match else flags.get('-d')
        self.database = database or os.getenv('PSQL_DB') or os.getenv('PGDATABASE') or configured
        if not self.database:
            raise Error('Configure postgres_database or PGDATABASE')
        self.host = os.getenv('PSQL_HOST') or os.getenv('PGHOST') or flags.get('-h', 'localhost')
        self.port = os.getenv('PSQL_PORT') or os.getenv('PGPORT') or flags.get('-p', '5432')
        self.user = os.getenv('PSQL_USER') or os.getenv('PGUSER') or flags.get('-U', 'postgres')
        candidates = [os.getenv('PSQL_BIN')] + [t for t in tokens if t.endswith('/psql')]
        self.psql = next((p for p in candidates if p and Path(p).is_file()), None) or shutil.which('psql')
        if not self.psql:
            raise Error('psql is required (PSQL_BIN can select a version)')

    def run(self, sql):
        args = [self.psql, '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-h', self.host,
                '-p', self.port, '-U', self.user, '-d', self.database]
        result = subprocess.run(args, input=sql, text=True, capture_output=True, env=self.env)
        if result.returncode:
            raise Error('PostgreSQL command failed: ' + result.stderr.strip())
        return result.stdout

    def snapshot(self, schemas, support):
        condition = 'n.nspname IN (' + ','.join(literal(s) for s in schemas) + ')' if schemas else 'FALSE'
        if support:
            condition += ' OR n.nspname || \'.\' || c.relname IN (' + ','.join(literal(s) for s in support) + ')'
        # Each dynamically generated SELECT emits one JSON record in the same read-only snapshot.
        sql = """BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '120s';
SELECT format('SELECT jsonb_build_object(''table'', %L, ''schema'', %L::jsonb, ''rows'', COALESCE(jsonb_agg(to_jsonb(t)), ''[]''::jsonb)) FROM %I.%I t',
 n.nspname || '.' || c.relname,
 jsonb_build_object(
 'columns', (SELECT jsonb_agg(jsonb_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod),'not_null',a.attnotnull,'default',pg_get_expr(d.adbin,d.adrelid),'generated',a.attgenerated,'identity',a.attidentity) ORDER BY a.attnum) FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),
 'primary_key', COALESCE((SELECT jsonb_agg(a.attname ORDER BY k.ord) FROM pg_constraint co CROSS JOIN LATERAL unnest(co.conkey) WITH ORDINALITY k(num,ord) JOIN pg_attribute a ON a.attrelid=co.conrelid AND a.attnum=k.num WHERE co.conrelid=c.oid AND co.contype='p'), '[]'::jsonb),
 'foreign_keys', COALESCE((SELECT jsonb_agg(jsonb_build_object('name',co.conname,'columns',(SELECT jsonb_agg(a.attname ORDER BY k.ord) FROM unnest(co.conkey) WITH ORDINALITY k(num,ord) JOIN pg_attribute a ON a.attrelid=co.conrelid AND a.attnum=k.num), 'references',rn.nspname || '.' || rc.relname,'reference_columns',(SELECT jsonb_agg(a.attname ORDER BY k.ord) FROM unnest(co.confkey) WITH ORDINALITY k(num,ord) JOIN pg_attribute a ON a.attrelid=co.confrelid AND a.attnum=k.num), 'match',co.confmatchtype,'deferrable',co.condeferrable) ORDER BY co.conname) FROM pg_constraint co JOIN pg_class rc ON rc.oid=co.confrelid JOIN pg_namespace rn ON rn.oid=rc.relnamespace WHERE co.conrelid=c.oid AND co.contype='f'), '[]'::jsonb),
 'constraints', COALESCE((SELECT jsonb_agg(pg_get_constraintdef(co.oid) ORDER BY co.conname) FROM pg_constraint co WHERE co.conrelid=c.oid), '[]'::jsonb),
 'triggers', COALESCE((SELECT jsonb_agg(pg_get_triggerdef(tr.oid) ORDER BY tr.tgname) FROM pg_trigger tr WHERE tr.tgrelid=c.oid AND NOT tr.tgisinternal), '[]'::jsonb)), n.nspname,c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind = 'r' AND NOT c.relispartition AND (""" + condition + """) ORDER BY n.nspname,c.relname
\\gexec
COMMIT;
"""
        partitions = self.run("BEGIN READ ONLY; SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (c.relkind='p' OR c.relispartition) AND (" + condition + "); COMMIT;").strip()
        if partitions != '0':
            raise Error('Partitioned datasets require a project-specific strategy and are not supported')
        lines = self.run(sql).splitlines()
        return {item['table']: item for item in (json.loads(line) for line in lines if line.strip())}


def keys(row, columns):
    return tuple(canonical(row[c]) for c in columns)


def references(table, logical):
    return table['schema']['foreign_keys'] + [r for r in logical if r['table'] == table['table']]


def validate_tables(tables, logical):
    for name, table in tables.items():
        pk = table['schema']['primary_key']
        if not pk:
            raise Error('A primary key is required for deterministic selection: ' + name)
        seen = set()
        column_names = {c['name'] for c in table['schema']['columns']}
        for row in table['rows']:
            if set(row) != column_names:
                raise Error('Row columns differ from schema: ' + name)
            key = keys(row, pk)
            if key in seen:
                raise Error('Duplicate primary key: ' + name)
            seen.add(key)
        for ref in references(table, logical):
            parent = tables.get(ref['references'])
            if parent is None:
                raise Error('Missing dependency template ' + ref['references'] + ' for ' + name)
            available = {keys(r, ref['reference_columns']) for r in parent['rows']}
            for row in table['rows']:
                values = [row[c] for c in ref['columns']]
                if any(v is None for v in values):
                    if ref.get('match') == 'f' and not all(v is None for v in values):
                        raise Error('Partially NULL MATCH FULL reference: ' + name)
                    continue
                if keys(row, ref['columns']) not in available:
                    raise Error('Missing parent for ' + name + ' -> ' + ref['references'])


def select_rows(snapshot, selection, limit, logical):
    selectors = {t['table']: t for t in selection.get('tables', [])}
    unknown = set(selectors) - set(snapshot)
    if unknown:
        raise Error('Selected tables absent from snapshot: ' + ', '.join(sorted(unknown)))
    chosen = {}
    for name, table in snapshot.items():
        pk = table['schema']['primary_key']
        if not pk:
            raise Error('Table needs a primary key: ' + name)
        ordered = sorted(table['rows'], key=lambda r: keys(r, pk))
        selector = selectors.get(name)
        if selector is None:
            rows = ordered[:limit]
        else:
            ids = selector.get('ids', [])
            requested = {tuple(canonical(v) for v in (i if isinstance(i,list) else [i])) for i in ids}
            rows = [r for r in ordered if keys(r, pk) in requested]
            if len(rows) != len(requested):
                raise Error('Selected IDs absent from snapshot: ' + name)
        chosen[name] = {**table, 'rows': rows}
    # Recursively include FK/internal logical parents, never invent records.
    changed = True
    while changed:
        changed = False
        for name, table in chosen.items():
            for ref in references(table, logical):
                parent_name = ref['references']
                if parent_name not in snapshot:
                    raise Error('Declare support table in mock_data.support_tables: ' + parent_name)
                have = {keys(r,ref['reference_columns']) for r in chosen[parent_name]['rows']}
                required = {keys(r,ref['columns']) for r in table['rows'] if all(r[c] is not None for c in ref['columns'])} - have
                parents = [r for r in snapshot[parent_name]['rows'] if keys(r,ref['reference_columns']) in required]
                if len({keys(r,ref['reference_columns']) for r in parents}) != len(required):
                    raise Error('Source has missing parent: ' + name)
                if parents:
                    chosen[parent_name]['rows'].extend(parents)
                    changed = True
    for table in chosen.values():
        table['rows'].sort(key=lambda r: keys(r,table['schema']['primary_key']))
    validate_tables(chosen, logical)
    return chosen


def insertion_plan(tables, logical):
    nodes = {}
    for name, table in tables.items():
        pk = table['schema']['primary_key']
        for row in table['rows']:
            nodes[(name, keys(row,pk))] = row
    dependencies = {key:set() for key in nodes}
    for node, row in nodes.items():
        name = node[0]
        for ref in references(tables[name], logical):
            if any(row[c] is None for c in ref['columns']):
                continue
            parent = tables[ref['references']]
            match = next(r for r in parent['rows'] if keys(r,ref['reference_columns']) == keys(row,ref['columns']))
            dep = (ref['references'], keys(match,parent['schema']['primary_key']))
            if dep != node:
                dependencies[node].add(dep)
    order = []
    pending = set(nodes)
    while pending:
        ready = sorted(n for n in pending if not (dependencies[n] & pending))
        if not ready:
            raise Error('Cyclic row references require a project-specific seed strategy; no constraints are disabled: ' + ', '.join(sorted({n[0] for n in pending})))
        order.extend((n[0],nodes[n]) for n in ready)
        pending.difference_update(ready)
    return order


def safe_file(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise Error('Template path escapes mock-data directory')
    return path


def load_manifest(root, version):
    manifest = read_json(root / 'manifests' / (component(version) + '.json'))
    if manifest.get('format_version') != FORMAT:
        raise Error('Unsupported manifest format')
    tables = {}
    for name, entry in manifest['tables'].items():
        table = read_json(safe_file(root,entry['path']))
        if table['table'] != name or digest(table) != entry['sha256']:
            raise Error('Template identity/checksum mismatch: ' + name)
        tables[name] = table
    validate_tables(tables,manifest.get('logical_references',[]))
    insertion_plan(tables,manifest.get('logical_references',[]))
    return manifest,tables


def generate(args, config, root):
    component(args.version)
    if (root / 'manifests' / (args.version + '.json')).exists():
        raise Error('Version already exists; choose a new version')
    logical = config.get('mock_data',{}).get('logical_references',[])
    support = config.get('mock_data',{}).get('support_tables',[])
    schemas = config.get('postgres_schemas')
    if not isinstance(schemas,list) or not schemas or any(not isinstance(s,str) or not s for s in schemas):
        raise Error('postgres_schemas must be a non-empty JSON array of schema names')
    selection = read_json(args.selection) if args.selection else {'tables':[]}
    snapshot = Database(config,args.database).snapshot(schemas,support)
    for schema in schemas:
        if not any(name.startswith(schema + '.') for name in snapshot):
            raise Error('Configured schema has no tables: ' + schema)
    tables = select_rows(snapshot,selection,args.limit,logical)
    insertion_plan(tables,logical)
    previous = load_manifest(root,args.extends) if args.extends else (None,{})
    manifest = {'format_version':FORMAT,'version':args.version,'extends':args.extends,
                'generated_at':datetime.now(timezone.utc).isoformat(), 'schemas':schemas,
                'source_database':Database(config,args.database).database,
                'logical_references':logical,'tables':{},
                'external_logical_references':'preserved without checks against other databases'}
    writes = []
    for name, table in tables.items():
        if previous[1].get(name) == table:
            manifest['tables'][name] = previous[0]['tables'][name]
            continue
        schema, tab = name.split('.')
        relative = '/'.join((component(schema),component(tab),component(args.version)+'.json'))
        path = safe_file(root,relative)
        if path.exists():
            raise Error('Immutable template already exists: ' + relative)
        writes.append((path,table))
        manifest['tables'][name] = {'path':relative,'version':args.version,'sha256':digest(table),'row_count':len(table['rows'])}
    created=[]
    try:
        for path,table in writes:
            write_new(path,table)
            created.append(path)
        write_new(root / 'manifests' / (args.version+'.json'),manifest)
    except Exception:
        for path in created:
            path.unlink()
        raise
    print('[OK] generated ' + args.version + ': ' + str(len(tables)) + ' tables, ' + str(sum(len(t['rows']) for t in tables.values())) + ' rows; ' + str(len(writes)) + ' new templates')


def check_schema(tables, snapshot):
    for name, table in tables.items():
        if name not in snapshot:
            raise Error('Target table missing: ' + name)
        if table['schema'] != snapshot[name]['schema']:
            before = {c['name']:c for c in table['schema']['columns']}
            after = {c['name']:c for c in snapshot[name]['schema']['columns']}
            added = sorted(after.keys()-before.keys())
            removed = sorted(before.keys()-after.keys())
            changed = sorted(k for k in before.keys() & after.keys() if before[k] != after[k])
            unsafe_added = [k for k in added if after[k]['not_null'] and not after[k]['default'] and not after[k]['generated'] and not after[k]['identity']]
            other_changed = any(table['schema'][k] != snapshot[name]['schema'][k] for k in table['schema'] if k != 'columns')
            if not removed and not changed and not unsafe_added and not other_changed:
                continue
            raise Error('Schema drift in ' + name + '; added=' + str(added) + ', removed=' + str(removed) + ', changed=' + str(changed) + '. Generate a new version from an explicitly prepared/migrated database; required values are never guessed.')


def load_sql(tables, logical):
    parts = ['BEGIN;', "SET LOCAL statement_timeout = '120s';"]
    for name in sorted(tables):
        parts.append('LOCK TABLE ' + relation(name) + ' IN SHARE ROW EXCLUSIVE MODE;')
        parts.append('DO $guard$ BEGIN IF EXISTS (SELECT 1 FROM ' + relation(name) + ') THEN RAISE EXCEPTION ' + literal('Target table must be empty: '+name) + '; END IF; END $guard$;')
    for name,row in insertion_plan(tables,logical):
        columns = [c['name'] for c in tables[name]['schema']['columns'] if not c['generated']]
        encoded = literal(canonical(row))
        cols = ','.join(ident(c) for c in columns)
        parts.append('INSERT INTO ' + relation(name) + ' (' + cols + ') OVERRIDING SYSTEM VALUE SELECT ' + cols + ' FROM jsonb_populate_record(NULL::' + relation(name) + ', ' + encoded + '::jsonb);')
    # setval is not transactional: run only after all inserts/constraints succeed.
    parts.append('SET CONSTRAINTS ALL IMMEDIATE;')
    for name,table in sorted(tables.items()):
        for column in table['schema']['columns']:
            if column['identity'] or (column.get('default') or '').startswith('nextval('):
                qname=relation(name)
                col=ident(column['name'])
                default = column.get('default') or ''
                match = re.fullmatch(r"nextval\('((?:[^']|'')+)'::regclass\)", default)
                fallback = 'to_regclass(' + literal(match.group(1).replace("''", "'")) + ')' if match else 'NULL::regclass'
                seq = 'COALESCE(pg_get_serial_sequence(' + literal(qname) + ',' + literal(column['name']) + ')::regclass,' + fallback + ')'
                parts.append('SELECT setval(' + seq + ', GREATEST((SELECT MAX(' + col + ') FROM ' + qname + '), COALESCE(pg_sequence_last_value(' + seq + '),1)),true) WHERE ' + seq + ' IS NOT NULL AND EXISTS(SELECT 1 FROM ' + qname + ');')
    parts.append('COMMIT;')
    return '\n'.join(parts)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['generate','check','load'])
    parser.add_argument('--project',default='.')
    parser.add_argument('--version',required=True)
    parser.add_argument('--selection',help='JSON with tables [{table, ids}] (composite PK IDs are arrays)')
    parser.add_argument('--extends',help='Reuse identical table templates from this explicit version')
    parser.add_argument('--limit',type=int,default=10,help='Initial rows per table without an explicit selection; FK closure can add rows')
    parser.add_argument('--database',help='Explicit read-only source/check database override')
    parser.add_argument('--target-database',help='Load only into a prepared empty harness_mock_* database marked disposable')
    parser.add_argument('--offline',action='store_true',help='Check files, hashes and relationship closure without connecting')
    args=parser.parse_args(argv)
    if args.limit < 0:
        raise Error('--limit must be non-negative')
    project=Path(args.project).resolve()
    config=read_json(project / '.harness.json')
    root=project / 'mock-data'
    if args.command=='generate':
        generate(args,config,root)
        return
    manifest,tables=load_manifest(root,args.version)
    if args.command=='check':
        if not args.offline:
            snapshot=Database(config,args.database).snapshot(manifest['schemas'],[n for n in tables if n.split('.')[0] not in manifest['schemas']])
            check_schema(tables,snapshot)
        print('[OK] checked '+args.version+': schema, checksums and internal references' if not args.offline else '[OK] checked '+args.version+': checksums and internal references (offline)')
        return
    if not args.target_database or not args.target_database.startswith('harness_mock_'):
        raise Error('Load requires explicit --target-database harness_mock_*; it never creates/drops databases or schema objects')
    source=Database(config)
    target=Database(config,args.target_database)
    if target.database==source.database:
        raise Error('Refusing to load into the configured source database')
    marker=target.run("BEGIN READ ONLY; SELECT COALESCE(shobj_description(oid,'pg_database'),'') FROM pg_database WHERE datname=current_database(); COMMIT;").strip()
    if marker != MARKER:
        raise Error('Target database must have COMMENT ON DATABASE ... IS '+repr(MARKER))
    snapshot=target.snapshot(manifest['schemas'],[n for n in tables if n.split('.')[0] not in manifest['schemas']])
    check_schema(tables,snapshot)
    if any(snapshot[n]['rows'] for n in tables):
        raise Error('Target tables must be empty; existing records are never deleted')
    target.run(load_sql(tables,manifest.get('logical_references',[])))
    print('[OK] loaded '+args.version+' into '+target.database+' ('+str(sum(len(t['rows']) for t in tables.values()))+' rows)')


if __name__=='__main__':
    try:
        main()
    except (Error,OSError,ValueError,KeyError) as exc:
        print('[FAIL] '+str(exc),file=sys.stderr)
        sys.exit(1)
