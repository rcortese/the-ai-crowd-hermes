# Release note — A2A guard removal and Hermes/WebUI refresh

## Intent

This release removes the private Moss protected-A2A plugin guard that prevented normal Moss profile operations such as `scribe` and `reviewer`. It retains the explicitly configured, directional native A2A path from Moss to Denholm; it does not enable arbitrary peer routing.

## Source pins

- Hermes Agent: `27aa96b9ddb09c34f3868f35830368f65892f911`
- Hermes WebUI: `fe84511935c78533aaf5ab5518411813753416f7`
- Hermes Agent image: `the-ai-crowd/hermes-agent:20260819-relaxed-a2a`

## Runtime effect

- `MOSS_HERMES_PROTECTED_A2A` and related private seal variables are absent from the release Compose contract.
- Moss reuses the reviewed all-in-one runtime shell (including its installed Playwright browser) while replacing `/opt/hermes` wholesale from the pinned Agent image and rebuilding `/opt/hermes-webui` from the pinned WebUI revision.
- Existing profile plugin roots are supported again; Scribe and Reviewer are expected to start normally.
- Denholm remains the only configured A2A peer for Moss, using the existing internal-only receiver and directional credential.

## Acceptance validation

Before activation, validate the candidate image and rendered Compose configuration. After activation, verify all service health, a fresh Scribe worker start, and one bounded Moss-to-Denholm A2A call with receiver-side confirmation. Record the deployed image IDs and test receipts in the release evidence.
