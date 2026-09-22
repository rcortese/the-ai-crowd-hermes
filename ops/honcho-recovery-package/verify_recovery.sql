\set ON_ERROR_STOP on
BEGIN READ ONLY;
DO $$ BEGIN
 IF (SELECT count(*) FROM workspaces WHERE name='moss-rodolfo' AND metadata='{"purpose":"Fresh direct Rodolfo-Moss conversational memory","legacy_import":false}'::jsonb)<>1 THEN
   RAISE EXCEPTION 'Recovery workspace provenance mismatch';
 END IF;
 IF (SELECT count(*) FROM peers WHERE workspace_name='moss-rodolfo')<>2 OR
    EXISTS (SELECT 1 FROM peers WHERE workspace_name='moss-rodolfo' AND name NOT IN ('Moss','Rodolfo')) THEN
   RAISE EXCEPTION 'Recovery peer set mismatch';
 END IF;
 IF EXISTS (SELECT 1 FROM sessions WHERE workspace_name='moss-rodolfo' AND NOT
   (name ~ '^moss-(telegram|webui)-[a-f0-9]{32}$' OR name='private')) THEN
   RAISE EXCEPTION 'Unknown recovery session';
 END IF;
 IF EXISTS (SELECT 1 FROM messages WHERE workspace_name='moss-rodolfo' AND
   (peer_name NOT IN ('Moss','Rodolfo') OR session_name !~ '^moss-(telegram|webui)-[a-f0-9]{32}$')) THEN
   RAISE EXCEPTION 'Unauthorized recovery message';
 END IF;
END $$;
SELECT 'recovery_workspace_preserved_PASS';
COMMIT;
