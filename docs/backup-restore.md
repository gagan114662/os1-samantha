# OS1 State Backup and Restore Runbook

Version: 1
Owner: OS1 operator
Last updated: 2026-05-13

## Scope

OS1 state backups cover company sessions, event logs, journals, audits, revenue records, ledgers, approval decisions, and operational logs selected by the caller. Secrets are not copied into backup payloads; restore requires Keychain or provider credential reauthorization after state is recovered.

## Backup Policy

- Frequency: create at least one backup every 24 hours before live autonomy; set `OS1_BACKUP_STALE_THRESHOLD_HOURS` lower for stricter Doctor alerts.
- Retention: keep 30 days of restorable bundles unless a legal hold or incident response record requires longer retention.
- Location: store bundles under `~/.os1/codex-tasks/backups/<backup-id>/` by default, or an operator-approved encrypted volume/cloud location with the same file layout.
- Permissions: restore is limited to the local OS1 operator or an explicitly delegated incident responder.
- Encryption: payload entries are AES-GCM sealed at rest. The encryption key is either derived from an operator-supplied secret for bring-your-own-key recovery, or generated and stored in macOS Keychain under `ai.os1.state-backup-key/default`.

## Bundle Layout

Each stored bundle contains:

- `bundle.json`: encrypted entries, the manifest, key-source descriptor, and the expected manifest SHA-256.
- `manifest.json`: readable recovery metadata for Doctor and incident review.
- `manifest.sha256`: the stable SHA-256 over the canonical manifest encoding.

Restore validates `manifest.sha256` against the manifest embedded in `bundle.json` before decrypting entries. A mismatch fails restore with the structured `manifest_hash_mismatch` error.

## Restore Procedure

1. Start on a clean machine or a clean destination directory with OS1 installed.
2. Retrieve the selected backup directory from `~/.os1/codex-tasks/backups` or the approved off-machine storage location.
3. Resolve the encryption key:
   - Operator-supplied: enter the recovery secret used when the bundle was created.
   - Keychain-managed: migrate or recreate the `ai.os1.state-backup-key/default` Keychain item from the approved secure key backup.
4. Decode `bundle.json` and validate the manifest hash before any state is written.
5. Decrypt each AES-GCM entry and compare its plaintext SHA-256 against the manifest entry.
6. Restore into a new destination root, preserving relative paths.
7. Review the restore drill report. It must show `passed`, the restored entry count, RPO/RTO values, and a passing integrity report.
8. Reauthorize credentials in Keychain or provider vaults. Secrets are intentionally excluded from state backups.

## Restore Drill

CI runs `CompanyStateBackupTests/ciSmokeTestEncryptedBackupBundleRoundTripsThroughStoreRetrieveDecryptAndIntegrityVerify`, which performs:

create -> encrypt -> store -> retrieve -> decrypt -> verify integrity -> restore.

The full `swift test` suite also runs afterward. The Doctor tab reads the backup inventory, shows last-successful-backup age and oldest backup age, and warns when the latest successful backup is older than `OS1_BACKUP_STALE_THRESHOLD_HOURS` or the manifest's RPO.
