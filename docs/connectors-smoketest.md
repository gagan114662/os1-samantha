# Connectors Smoke Test

Use this checklist before marking a social or community Composio toolkit ready for company use.

## Scope

Smoke-test the curated social toolkits in ComposioToolkitService.curatedToolkits: twitter, linkedin, instagram, tiktok, youtube, reddit, pinterest, discord, telegram, and threads.

## Manual Steps

1. Open the Connectors tab with a fresh Composio account configured.
2. For each toolkit above, click Connect and confirm the OAuth redirect opens.
3. Complete the provider consent screen, then return to OS1.
4. Refresh the Connectors tab and verify the toolkit status is connected.
5. Confirm the consent UI exposed the toolkit tag, required scopes, and risk tier before redirect.
6. For social, video, marketing, and community toolkits, confirm company access control treats the connection as approval-required until the company has at least 7 clean-history days.

## Evidence To Record

Record date, Composio account, toolkit slug, connected account id, redirect result, required scopes shown, risk tier shown, and whether the status refreshed successfully. Do not store OAuth tokens or provider secrets in this file.
