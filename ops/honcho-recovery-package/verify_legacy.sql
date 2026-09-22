\set ON_ERROR_STOP on
BEGIN READ ONLY;
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM workspaces WHERE name='hermes_moss') OR
    EXISTS (SELECT 1 FROM messages WHERE workspace_name='the-ai-crowd' AND peer_name IN ('Moss','hermes_moss','MossHonchoTest')) OR
    EXISTS (SELECT 1 FROM message_embeddings WHERE workspace_name='the-ai-crowd' AND peer_name IN ('Moss','hermes_moss','MossHonchoTest')) OR
    EXISTS (SELECT 1 FROM documents WHERE workspace_name='the-ai-crowd' AND observer IN ('Moss','hermes_moss','MossHonchoTest')) OR
    EXISTS (SELECT 1 FROM collections WHERE workspace_name='the-ai-crowd' AND observer IN ('Moss','hermes_moss','MossHonchoTest')) OR
    EXISTS (SELECT 1 FROM peers WHERE workspace_name='the-ai-crowd' AND name IN ('Moss','hermes_moss','MossHonchoTest') AND internal_metadata<>'{}'::jsonb) THEN
   RAISE EXCEPTION 'Owned legacy readback failed';
 END IF;
END $$;
SELECT 'owned_legacy_readback_PASS';
COMMIT;
