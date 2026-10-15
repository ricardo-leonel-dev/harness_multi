import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('mock_data', Path(__file__).resolve().parents[1] / 'profiles/postgres/mock_data.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def table(name, rows, refs=None, columns=None):
    return {'table':name,'schema':{'primary_key':['id'],'foreign_keys':refs or [],'columns':columns or [{'name':'id','type':'integer','not_null':True,'default':None,'generated':'','identity':''}],'constraints':[],'triggers':[]},'rows':rows}


class Tests(unittest.TestCase):
    def test_generate_reuses_unchanged_templates_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as d:
            project=Path(d)
            m.write_new(project/'.harness.json',{'postgres_schemas':['s']})
            a=table('s.a',[{'id':1}]); b=table('s.b',[{'id':2}])
            with patch.object(m,'Database') as db:
                db.return_value.database='test'
                db.return_value.snapshot.return_value={'s.a':a,'s.b':b}
                m.main(['generate','--project',d,'--version','initial'])
                original=(project/'mock-data/s/a/initial.json').read_bytes()
                changed=json.loads(json.dumps(a)); changed['rows'][0]['new']=None
                changed['schema']['columns'].append({'name':'new','type':'text','not_null':False,'default':None,'generated':'','identity':''})
                db.return_value.snapshot.return_value={'s.a':changed,'s.b':b}
                m.main(['generate','--project',d,'--version','feature-028','--extends','initial'])
                manifest,templates=m.load_manifest(project/'mock-data','feature-028')
                self.assertEqual(manifest['tables']['s.b']['version'],'initial')
                self.assertEqual(manifest['tables']['s.a']['version'],'feature-028')
                self.assertEqual((project/'mock-data/s/a/initial.json').read_bytes(),original)
                m.main(['check','--project',d,'--version','feature-028','--offline'])
                with self.assertRaisesRegex(m.Error,'Version already exists'):
                    m.main(['generate','--project',d,'--version','initial'])
                with self.assertRaisesRegex(m.Error,'explicit --target-database'):
                    m.main(['load','--project',d,'--version','initial','--target-database','source'])

    def test_parent_closure_and_order(self):
        ref={'columns':['parent'],'reference_columns':['id'],'references':'s.parents'}
        parents=table('s.parents',[{'id':1},{'id':2}])
        columns=parents['schema']['columns']+[{'name':'parent','type':'integer','not_null':True,'default':None,'generated':'','identity':''}]
        children=table('s.children',[{'id':3,'parent':2}],[ref],columns)
        chosen=m.select_rows({'s.parents':parents,'s.children':children},{'tables':[{'table':'s.parents','ids':[]},{'table':'s.children','ids':[3]}]},10,[])
        self.assertEqual(chosen['s.parents']['rows'],[{'id':2}])
        self.assertEqual([n for n,r in m.insertion_plan(chosen,[])],['s.parents','s.children'])

    def test_cycle_is_actionable(self):
        ref={'columns':['id'],'reference_columns':['id'],'references':'s.b'}
        a=table('s.a',[{'id':1}],[ref])
        b=table('s.b',[{'id':1}],[{**ref,'references':'s.a'}])
        with self.assertRaisesRegex(m.Error,'Cyclic'):
            m.insertion_plan({'s.a':a,'s.b':b},[])

    def test_traversal_and_checksum(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            with self.assertRaises(m.Error): m.safe_file(root,'../../secret')
            with self.assertRaises(m.Error): m.component('../version')
            t=table('s.a',[{'id':1}])
            m.write_new(root/'s/a/initial.json',t)
            m.write_new(root/'manifests/initial.json',{'format_version':1,'tables':{'s.a':{'path':'s/a/initial.json','sha256':'wrong'}}})
            with self.assertRaisesRegex(m.Error,'checksum'): m.load_manifest(root,'initial')
            with self.assertRaises(FileExistsError): m.write_new(root/'s/a/initial.json',t)

    def test_schema_drift_and_required_columns(self):
        initial=table('s.a',[{'id':1}])
        changed=json.loads(json.dumps(initial))
        changed['schema']['columns'].append({'name':'required','type':'text','not_null':True,'default':None,'generated':'','identity':''})
        with self.assertRaisesRegex(m.Error,'required values are never guessed'):
            m.check_schema({'s.a':initial},{'s.a':changed})

    def test_additive_defaults_are_compatible(self):
        initial=table('s.a',[{'id':1}])
        for nullable,default,generated,identity in [(True,None,'',''),(False,"'x'::text",'',''),(False,None,'s',''),(False,None,'','a')]:
            changed=json.loads(json.dumps(initial))
            changed['schema']['columns'].append({'name':'new','type':'text','not_null':not nullable,'default':default,'generated':generated,'identity':identity})
            m.check_schema({'s.a':initial},{'s.a':changed})

    def test_unowned_sequence_defaults_advance_safely(self):
        t=table('s.a',[{'id':12}],columns=[{'name':'id','generated':'','identity':'','default':"nextval('public.a_seq'::regclass)"}])
        sql=m.load_sql({'s.a':t},[])
        self.assertIn("to_regclass('public.a_seq')",sql)
        self.assertIn('pg_sequence_last_value',sql)
        self.assertIn('GREATEST',sql)

    def test_missing_parent_and_null_fk(self):
        ref={'columns':['id'],'reference_columns':['id'],'references':'s.b'}
        with self.assertRaisesRegex(m.Error,'Missing parent'):
            m.validate_tables({'s.a':table('s.a',[{'id':1}],[ref]),'s.b':table('s.b',[])},[])

    def test_generated_identity_and_quoting(self):
        t=table('s.a',[{'id':5,'computed':10}],columns=[{'name':'id','generated':'','identity':'a','default':None},{'name':'computed','generated':'s','identity':'','default':'id*2'}])
        sql=m.load_sql({'s.a':t},[])
        self.assertIn('OVERRIDING SYSTEM VALUE',sql)
        self.assertIn('("id")',sql)
        self.assertNotIn('("id","computed")',sql)
        self.assertIn('setval',sql)
        self.assertEqual(m.ident('a"b'),'"a""b"')
        self.assertEqual(m.literal("a'b"),"'a''b'")


if __name__=='__main__': unittest.main()
