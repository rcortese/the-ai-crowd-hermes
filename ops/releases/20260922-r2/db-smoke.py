import sys,json,sqlite3
from pathlib import Path
from hermes_state import SessionDB
from hermes_state_common import FTS_STORAGE_VERSION
mode=sys.argv[1]
p=Path('/fixture/state.db')
db=SessionDB(db_path=p)
if mode=='old-create':
 db.create_session('release-rollback-test',source='cli')
 db.append_message('release-rollback-test','user','beforeupgrade orchid')
 db.append_message('release-rollback-test','tool','orchid '*2000,tool_name='terminal')
elif mode=='new-write':
 db.append_message('release-rollback-test','user','afterupgrade tulip')
else:
 db.append_message('release-rollback-test','assistant','afterrollback violet')
rows=db._conn.execute('select role,content from messages order by id').fetchall()
assert any('beforeupgrade' in r[1] for r in rows)
if mode!='old-create': assert any('afterupgrade' in r[1] for r in rows)
assert db._conn.execute('pragma integrity_check').fetchone()[0]=='ok'
fts_integrity='ok'
try:
 db._conn.execute("INSERT INTO messages_fts(messages_fts, rank) VALUES('integrity-check', 1)")
except sqlite3.DatabaseError:
 if mode!='old-create': raise
 # 0.21.3's known external-content projection bug is reproduced by a long tool row.
 # The upgrade MUST fix this; later modes may not suppress the integrity failure.
 fts_integrity='known-old-projection-mismatch'
db._conn.commit()
assert db.search_messages('orchid')
if mode!='old-create': assert db.search_messages('tulip')
print(json.dumps({'mode':mode,'rows':len(rows),'runtime_fts_version':FTS_STORAGE_VERSION,'sqlite_integrity':'ok','fts_integrity':fts_integrity,'post_upgrade_writes_preserved':mode!='old-create'}))
db.close()
