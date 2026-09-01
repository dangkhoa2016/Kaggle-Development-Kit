## Summary

Describe the problem and the change concisely.

## Validation

List the commands, tests, or real-environment checks you ran.

## Impact

- [ ] The change is focused and does not include unrelated refactoring.
- [ ] Relevant regression coverage was added or updated when behavior changed.
- [ ] `bash scripts/refresh-manifest.sh` was run after tracked-file changes.
- [ ] `sha256sum -c MANIFEST.sha256` passes.
- [ ] `(cd install && sha256sum -c MANIFEST.sha256)` passes when installer content changed.
- [ ] User-facing English and Vietnamese documentation were updated together when applicable.
- [ ] No secrets, private keys, tokens, runtime state, logs, database data, tunnel details, PIDs, or sockets are included.
- [ ] Security, cold-restore, persistence, compatibility, and release implications were considered.

## Additional notes

Call out any breaking behavior, migration requirement, validation limitation, or follow-up work.
