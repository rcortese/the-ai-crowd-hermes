# Fleet release — Hermes Agent 0.21.3 / WebUI 0.52.113

Status: accepted in production
Applied: 2026-09-21
Operation: 20260921T015109Z-d40d5c8

## Result

All six personas run immutable images built from stack source commit `d40d5c84ea295f5bb98cfbb7cd15c572a4fc9d19` and Agent commit `12f3b6a9eeeb917268592e8a1e85eab7cb94c8cb`. Moss and Roy include WebUI commit `e3d93f6a692372e7ad8c644d2986eb34d1c7776d` based on WebUI v0.52.113.

| Service | Active image ID |
| --- | --- |
| Moss | `sha256:9ed081da116daa3036ac32bd06b8a0069eaec540ad6239de4611c7a6df9ecf97` |
| Roy | `sha256:6aa783ac1a6e5cc578769be3f65a5df671b0be99ef304c732af4c94b273f2f87` |
| Jen | `sha256:46a767de5686a913ee1f4ff2e2ad2f39e8e622b0850b73fac51fc80704555cfa` |
| Denholm | `sha256:5dfb1c2eb9da930e50e2b5f8d72a610c2d940320779c47fb1950d73ddd900ce1` |
| Richmond | `sha256:0936b491e6da252273520dbeafc532faaaedda8c2b20c5c5acff39caecf3de56` |
| The Elders | `sha256:5b94e5d6e9fbc934624b005a1b84457751b3b535aaf1b9755b559460685b0180` |

Acceptance confirmed six healthy containers, zero restarts, exact image IDs, six HTTP 200 gateway health responses, matching persona identities and matching Agent build commits. Moss and Roy WebUI health checks passed. Dashboards are not an acceptance surface because they are neither exposed nor used.

## What worked

1. Reconcile downstream behavior against fixed upstream releases before building.
2. Build one immutable image per persona; include WebUI only for Moss and Roy.
3. Run source tests and isolated image smoke tests before touching production.
4. Render and validate the final Compose configuration with exact image IDs.
5. Apply all six selectors in one bounded host operation, recreate the six services, then verify health and active image IDs.

The accepted evidence included 104 Agent tests and 37 WebUI tests inside the Moss image plus isolated smoke tests for all six images.

## Retired approaches

The Moss-only HDDT executor and its bootstrap, authorization, retention and rollback machinery did not deliver this fleet release and are retired. The successful cutover used a bounded one-shot fleet script. That script, its lock, build receipts, candidate checkouts and pre-cutover rollback copies are release-temporary material and are removed after operator acceptance.

The source branch `candidate/full-stack-release` is retained as immutable build provenance. Scripts in that historical branch are not installed executors and must not be treated as an active deployment path.

## Future release shape

Keep the next update equally small:

1. Freeze upstream versions and reconcile required downstream behavior.
2. Build and test six immutable images.
3. Record exact source commits and image IDs.
4. Validate the rendered production Compose configuration.
5. Use one release-specific host command to set the six image selectors and recreate the services.
6. Verify exact running images, gateway health, identity and the two WebUIs.
7. After operator acceptance, remove one-shot scripts, temporary candidates and recovery copies.

Do not install a permanent custom release orchestrator unless repeated releases demonstrate a concrete need for one.
