# Credential Revocation Runbook

Use this when OS1 suspects a company, browser session, runner, or integration has been compromised.

1. Pause the affected company only, unless the anomaly is fleet-wide.
2. Capture an immutable abuse audit snapshot before deleting local evidence.
3. Revoke affected provider keys in the provider dashboard.
4. Remove revoked names from the company credential allowlist and grant files.
5. Rotate replacements only after the incident owner approves the audit.
6. Record proof of revocation in the incident timeline.

OS1 surfaces the same steps through `CompanyAbuseContainmentEngine.revocationRunbook`.
