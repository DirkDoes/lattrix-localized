# Catalog redesign

The project **is** the catalog: no sheet layer. This replaces the older
`translation-architecture.md` design. Accounts, login methods, project roles,
membership and public/private visibility remain.

## Local review

Run `docker compose up -d`, then `docker compose exec web bin/rails db:migrate`.
The app is at http://localhost:3021 and development email at http://localhost:1080.
Tests: `docker compose exec web bin/rails test` (dedicated test databases).
An optional development-only `bin/rails runner db/catalog_demo.rb` populates a
small English/Dutch/Arabic catalog for the first local user.

**Destructive prelaunch migration:** `20260930000000` resets projects and their
old catalog/history/membership data, retaining user accounts and authentication.
It is intentionally not a production data conversion. Do not deploy this onto
valuable catalog data without a separate migration/backup plan.

## Storage and editing

- `catalog_nodes` are stable identities; immutable `catalog_keys` (scalar,
  branch, plural) and `catalog_texts` are their typed payloads.
- A dot separates path segments. Branches never carry values. A scalar must
  be moved to a child before its former position can become a branch/plural.
- `catalog_drafts` stores the proposed pointer and its accepted base pointer.
  `catalog_draft_edits` preserves previous proposals, including conflict choices.
- `catalog_change_sets` groups accepted changes. `catalog_events` stores only
  inverse operations (old payload/parent pointers, creation/removal). Actors
  become null when their accounts are deleted.
- `CatalogState` projects accepted, pending or inclusive historical states and
  handles validation/publication. `CatalogWriter` serializes writes per project
  and checks an optimistic revision before editing. Failed requests preserve
  the form; successful requests close it.
- Standalone valid edits are accepted immediately. Invalid/incomplete values
  remain drafts; accepted values remain exportable. Connected projects propose
  valid edits to GitHub, and accept them only when the authoritative branch does.
- Restore computes the net difference to the selected inclusive change set;
  it is a normal edit, including draft validation and GitHub publication rules.

## Locales, plural forms and placeholders

Only standard CLDR locales are supported. English display names and cardinal
categories come from Unicode CLDR JSON **48.0.0** (`availableLocales.json`,
`plurals.json`, English `languages.json` / `territories.json`). The derived
`config/catalog_locales.json` ships with the app; license: `UNICODE-LICENSE.txt`.
Update this data as a reviewed dependency upgrade, not a runtime network lookup.

The source locale defines structure. Plurals have locale-specific required
forms; an entirely untranslated locale is omitted, a partially completed plural
is held back as a group. `%{count}` is magenta, required in other/few/many,
optional in zero/one/two, and invalid for scalar translations. Ordinary
`%{name}` placeholders are yellow. Scalars require an exact source-placeholder
match; plural ordinary-placeholder differences are warnings. Reviews record
both source and translation revisions so stale reviews cannot be submitted.

## GitHub App setup

Login OAuth and repository integration are separate. An application owner can
configure one shared App under **Administration → GitHub App**. Credentials are
encrypted at rest using a purpose-specific key derived from Rails secret_key_base;
keep the existing Rails credentials/master key when restoring the database.
Secrets are never rendered back into the form, and blank fields preserve them.
Project admins configure only their repository, installation, branch and directory.
Other accounts/organizations can install the same App if its registration allows
installation on any account. Installation tokens and webhook routing isolate repositories.

Staging should use its own App with webhook URL
`https://staging.localized.lattrix.com/github/webhook`; production uses
`https://localized.lattrix.com/github/webhook`. Do not point one App's webhook at
two environments. The registration's homepage is the corresponding site root.
Keep webhook SSL verification enabled. Generate a random webhook secret of at
least 32 characters, paste it into both GitHub and the global settings, and save
the downloaded RSA private key there. No redeploy is required after saving.

Environment configuration remains an optional fallback until global settings are saved:

| Variable/secret | Purpose |
| --- | --- |
| `GH_APP_ID` variable | GitHub App numeric ID |
| `GH_APP_PRIVATE_KEY` secret | App RSA private key (PEM; escaped newlines accepted) |
| `GH_WEBHOOK_SECRET` secret | Secret matching the App webhook configuration |

Docker, Kamal and the deployment workflow forward these values. Never commit
real credentials. Install the App on the desired repository with repository
Contents and Pull requests read/write, Checks read/write, Metadata read access.
Subscribe to Push, Pull request and Create events. The webhook endpoint is
`https://<app-host>/github/webhook`; local testing needs a reachable development
endpoint. Webhooks are HMAC-verified and scoped by repository and installation.

Configure the project
repository (`owner/name`), installation ID, branch (blank means repository
default branch), and locale directory (default `config/locales`). Connecting
requires Lattrix project admin/owner permission and repository access through the
configured App installation. Personal GitHub login is not required or consulted.

Initial connection performs a three-way merge: identical and non-overlapping
values reconcile automatically; differing values become explicit conflicts.
The editor shows the accepted GitHub side for conflicted values. Other drafts
remain editable. Malformed authoritative data retains the last accepted catalog
and pauses writes/exports until repaired.

The worker syncs/publishes daily at 03:00, and admins can Sync now. It creates a
PR or updates its open PR with valid non-conflicting changes. Closing an unmerged
PR retains drafts; the next publication makes a new PR. Merging accepts matching
drafts. PR validation uses the same reconciliation inside a rolled-back
transaction. Disconnecting keeps the catalog and drafts, and leaves the PR alone.

Each locale is one `<identifier>.yml`, with its locale root. Non-string YAML
leaves are ignored by the catalog but preserved when writing existing files.
Aliases, duplicate keys, excessive depth/size and unsupported locale IDs are
rejected. Deleting a locale file archives its values; deleting source keys
removes their target subtree. While connected, locale-file availability is
managed in GitHub; standalone projects manage languages in Settings.

Tag creation pins an immutable commit SHA. Tagged exports read that SHA and
validate/project it in a rolled-back transaction, without changing the live
catalog. Accepted history exports replay local inverse events. Existing tags
predating the connection are not automatically backfilled.

## Export and intentionally removed features

`CatalogExport` is used both by real exports and the format showcase. YAML has
a locale wrapper; CSV/Excel have key and locale columns without that wrapper.
Missing values are always omitted (blank spreadsheet cells). JSON, manual
import, configurable delimiters/placeholder syntax, branch values and the
sheet-level plural toggle are out of scope.

Network integration is covered with simulated API responses locally. A real
App installation is required to verify end-to-end PR/check delivery. Sync holds
a per-project database lock through network I/O; use a leased sync lock if
large repositories or network latency make that a practical bottleneck.
