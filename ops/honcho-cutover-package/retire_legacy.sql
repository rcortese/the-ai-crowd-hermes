\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
LOCK TABLE workspaces,peers,sessions,session_peers,messages,message_embeddings,collections,documents,document_sources,queue IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE retiring(peer text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO retiring VALUES ('Moss'),('hermes_moss'),('MossHonchoTest');
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM queue WHERE workspace_name='the-ai-crowd' AND NOT processed) THEN
    RAISE EXCEPTION 'Shared workspace queue is not quiescent';
  END IF;
  IF EXISTS (SELECT 1 FROM workspaces WHERE name='hermes_moss') THEN
    RAISE EXCEPTION 'Exclusive legacy workspace unexpectedly exists; reconcile before applying';
  END IF;
END $$;
CREATE TEMP TABLE affected ON COMMIT DROP AS
 SELECT DISTINCT session_name FROM messages WHERE workspace_name='the-ai-crowd' AND peer_name IN (SELECT peer FROM retiring)
 UNION
 SELECT DISTINCT session_name FROM documents WHERE workspace_name='the-ai-crowd' AND observer IN (SELECT peer FROM retiring) AND session_name IS NOT NULL;
CREATE TEMP TABLE protected_messages ON COMMIT DROP AS
 SELECT id,md5(to_jsonb(messages)::text) fingerprint FROM messages WHERE workspace_name='the-ai-crowd' AND peer_name NOT IN (SELECT peer FROM retiring);
CREATE TEMP TABLE protected_documents ON COMMIT DROP AS
 SELECT id,md5(to_jsonb(documents)::text) fingerprint FROM documents WHERE workspace_name='the-ai-crowd' AND observer NOT IN (SELECT peer FROM retiring);
CREATE TEMP TABLE protected_peers ON COMMIT DROP AS
 SELECT id,md5(to_jsonb(peers)::text) fingerprint FROM peers WHERE workspace_name='the-ai-crowd' AND name NOT IN (SELECT peer FROM retiring);
-- Processed work items linked to the retiring messages retain old payloads.
DELETE FROM queue WHERE workspace_name='the-ai-crowd' AND message_id IN
 (SELECT id FROM messages WHERE workspace_name='the-ai-crowd' AND peer_name IN (SELECT peer FROM retiring));
DELETE FROM messages WHERE workspace_name='the-ai-crowd' AND peer_name IN (SELECT peer FROM retiring);
-- Explicit in addition to the message FK cascade: catches any orphaned peer embeddings.
DELETE FROM message_embeddings WHERE workspace_name='the-ai-crowd' AND peer_name IN (SELECT peer FROM retiring);
DELETE FROM documents WHERE workspace_name='the-ai-crowd' AND observer IN (SELECT peer FROM retiring);
DELETE FROM collections WHERE workspace_name='the-ai-crowd' AND observer IN (SELECT peer FROM retiring);
-- Other personas' observations ABOUT Moss are deliberately preserved. FK peer
-- nodes are tombstones, not restored memories or active observation peers.
UPDATE peers SET metadata='{"retired":true,"memory_erased":true}'::jsonb,
 internal_metadata='{}'::jsonb,
 configuration='{"reasoning":{"enabled":false},"dream":{"enabled":false}}'::jsonb
 WHERE workspace_name='the-ai-crowd' AND name IN (SELECT peer FROM retiring);
UPDATE session_peers SET configuration='{"observe_me":false,"observe_others":false}'::jsonb,
 internal_metadata='{}'::jsonb,left_at=COALESCE(left_at,now())
 WHERE workspace_name='the-ai-crowd' AND peer_name IN (SELECT peer FROM retiring);
-- Shared summaries are a cache of the pre-deletion messages, not authority.
-- Invalidate affected caches, retaining all surviving persona messages/documents.
UPDATE sessions SET internal_metadata=internal_metadata-'summaries'
 WHERE workspace_name='the-ai-crowd' AND name IN (SELECT session_name FROM affected);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM protected_messages p FULL JOIN
      (SELECT id,md5(to_jsonb(m)::text) fingerprint FROM messages m WHERE workspace_name='the-ai-crowd' AND peer_name NOT IN (SELECT peer FROM retiring)) n
      USING(id) WHERE p.fingerprint IS DISTINCT FROM n.fingerprint) THEN RAISE EXCEPTION 'Protected messages changed'; END IF;
  IF EXISTS (SELECT 1 FROM protected_documents p FULL JOIN
      (SELECT id,md5(to_jsonb(d)::text) fingerprint FROM documents d WHERE workspace_name='the-ai-crowd' AND observer NOT IN (SELECT peer FROM retiring)) n
      USING(id) WHERE p.fingerprint IS DISTINCT FROM n.fingerprint) THEN RAISE EXCEPTION 'Protected documents changed'; END IF;
  IF EXISTS (SELECT 1 FROM protected_peers p FULL JOIN
      (SELECT id,md5(to_jsonb(q)::text) fingerprint FROM peers q WHERE workspace_name='the-ai-crowd' AND name NOT IN (SELECT peer FROM retiring)) n
      USING(id) WHERE p.fingerprint IS DISTINCT FROM n.fingerprint) THEN RAISE EXCEPTION 'Protected peer data changed'; END IF;
  IF EXISTS (SELECT 1 FROM messages WHERE workspace_name='the-ai-crowd' AND peer_name IN (SELECT peer FROM retiring)) OR
     EXISTS (SELECT 1 FROM documents WHERE workspace_name='the-ai-crowd' AND observer IN (SELECT peer FROM retiring)) OR
     EXISTS (SELECT 1 FROM message_embeddings WHERE workspace_name='the-ai-crowd' AND peer_name IN (SELECT peer FROM retiring)) OR
     EXISTS (SELECT 1 FROM collections WHERE workspace_name='the-ai-crowd' AND observer IN (SELECT peer FROM retiring)) THEN
    RAISE EXCEPTION 'Owned legacy residue remains';
  END IF;
END $$;
SELECT 'protected_messages',count(*) FROM protected_messages;
SELECT 'protected_documents',count(*) FROM protected_documents;
COMMIT;
