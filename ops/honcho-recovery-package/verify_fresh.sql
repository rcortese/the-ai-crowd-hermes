\set ON_ERROR_STOP on
BEGIN READ ONLY;
DO $$ DECLARE r record; n bigint; BEGIN
 IF (SELECT count(*) FROM workspaces WHERE name='moss-rodolfo' AND metadata='{"purpose":"Fresh direct Rodolfo-Moss conversational memory","legacy_import":false}'::jsonb)<>1 THEN
   RAISE EXCEPTION 'Fresh workspace seed metadata mismatch';
 END IF;
 IF (SELECT count(*) FROM peers WHERE workspace_name='moss-rodolfo')<>2 OR
    EXISTS (SELECT 1 FROM peers WHERE workspace_name='moss-rodolfo' AND
      (internal_metadata<>'{}'::jsonb OR NOT
       ((name='Rodolfo' AND metadata='{"role":"human"}'::jsonb) OR
        (name='Moss' AND metadata='{"role":"assistant"}'::jsonb)))) THEN
   RAISE EXCEPTION 'Fresh peer set or seed metadata mismatch';
 END IF;
 -- Enumerate every scoped base table, including future schema additions. No
 -- orphaned documents, collections, embeddings, queues or webhooks may hide
 -- behind an empty sessions list. Peers above are the only permitted seed rows.
 FOR r IN
   SELECT c.table_schema,c.table_name
   FROM information_schema.columns c JOIN information_schema.tables t
     ON t.table_schema=c.table_schema AND t.table_name=c.table_name
   WHERE c.table_schema='public' AND c.column_name='workspace_name'
     AND t.table_type='BASE TABLE' AND c.table_name<>'peers'
 LOOP
   EXECUTE format('SELECT count(*) FROM %I.%I WHERE workspace_name=$1',r.table_schema,r.table_name)
     INTO n USING 'moss-rodolfo';
   IF n<>0 THEN RAISE EXCEPTION 'Fresh workspace has retained rows in %',r.table_name; END IF;
 END LOOP;
END $$;
SELECT 'fresh_workspace_all_scoped_tables_PASS';
COMMIT;
