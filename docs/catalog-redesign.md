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
  These audit records are not a second user-facing history: the earlier-draft
  reapply interface has been removed. Pending changes still represents current
  proposals; accepted events remain on History.
- `catalog_change_sets` groups accepted changes. `catalog_events` stores only
  inverse operations (old payload/parent pointers, creation/removal). Actors
  become null when their accounts are deleted.
- `CatalogState` projects accepted, pending or inclusive historical states and
  handles validation/publication. `CatalogWriter` serializes writes per project
  and checks an optimistic revision before editing. Failed requests preserve
  the form; successful requests close it.
- Standalone edits are persisted immediately, including invalid/incomplete values;
  validation still excludes invalid groups from exports, but never means unsaved.
  Connected projects propose
  valid edits to GitHub, and accept them only when the authoritative branch does.
- Pending changes is GitHub-only: one outgoing batch plus paginated incoming open
  translation PRs targeting the configured branch. Diff dialogs compare string
  values and file groups, not descriptions, review flags, comments or formatting.
  Incoming diffs use the PR merge base and head without modifying local state.
  Descriptions are accepted locally with history even while a key has a pending
  rename. Translation rows do not display Pending badges; conflicts and validation
  remain separate. The branch badge stays unchanged.
- PR overviews and diffs are display-only JSONB snapshots in
  `catalog_pull_request_caches`, refreshed in background after sync/webhooks or
  when a visited snapshot is over ten minutes old. Unchanged base/head SHAs reuse
  their diffs. Closed PRs are removed, and reconnects invalidate the old cache.
  Browsing PRs never modifies the catalog. Changed malformed YAML marks the PR
  as invalid without a diff button; unrelated unchanged files are not parsed.
  Previews show translation values by key and language, never raw YAML.
  Empty outgoing batches show an empty state rather than a table or old PR link.
- Restore computes the net difference to the selected inclusive change set;
  it is a normal edit, including draft validation and GitHub publication rules.

## Locales, plural forms and placeholders

Only standard CLDR locales are supported. English display names and cardinal
categories come from Unicode CLDR JSON **48.0.0** (`availableLocales.json`,
`plurals.json`, English `languages.json` / `territories.json`). The derived
`config/catalog_locales.json` ships with the app; license: `UNICODE-LICENSE.txt`.
Update this data as a reviewed dependency upgrade, not a runtime network lookup.

The source locale defines structure. Projects choose Off, Simple, or Unicode CLDR
pluralization. Existing projects migrate to CLDR; new projects default to Simple.
Simple requires one/other in every language. Imported groups with one and other may also contain ordinary keys such as none; only recognized category keys participate in plural validation. An other-only group is inferred as plural when all its children are plural categories. Off interprets stored plural nodes
as ordinary branches without deleting their translations; count has no special
validation and is suggested on keys named other. Mode changes retain extra forms
and refresh required category nodes. Switching back restores the interpretation
of stored plural nodes; branches created while Off remain ordinary branches.
In CLDR mode, plurals have locale-specific required
forms; an entirely untranslated locale is omitted, a partially completed plural
is held back as a group. `%{count}` is magenta, required in other/few/many,
optional in zero/one/two, and invalid for scalar translations. Ordinary
`%{name}` placeholders are yellow. Scalars require an exact source-placeholder
match; plural ordinary-placeholder differences are warnings. Reviews record
both source and translation revisions so stale reviews cannot be submitted.

Project settings managers can approve all existing translations for an active
target language from its three-dot menu in Settings. Bulk approval records the
current source and translation payloads without changing strings or accepting
GitHub drafts. Missing translations, conflicts and validation issues remain;
later source edits require review again. A stale settings page must be reloaded
before approval.

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

Each root key has an optional lowercase **file group**, inherited by its descendants.
The empty group is displayed as Default and exports to `<identifier>.yml`;
`devise` exports to `devise.<identifier>.yml`. Multiple roots can share a group.
The literal group `default` is allowed and is distinct from Default. Groups are
immutable key payload attributes, so drafts, reconciliation and history restoration
include changes to file placement. CSV/Excel still use ordinary dotted key paths.
The translations filter supports multiple groups (none selected means all).

Git snapshots accept `.yml` and `.yaml` and retain existing extensions on publication.
Each file has its locale wrapper. A root must belong to one group across all locales;
ambiguous roots split over different groups are rejected rather than silently losing
data. Reassigning a root clears its managed strings from the old file while keeping
unsupported values there. Empty old files are retained, not deleted. YAML
comments are preserved from the current GitHub file when publishing, without storing
them as catalog data. Comments follow matching YAML keys; inline comments become
standalone lines, and comments for removed keys stay at the end of their original
file. New files and standalone downloads have no repository comments. Existing
formatting and quoting may still be normalized by the YAML writer. Non-string YAML
leaves are ignored by the catalog but preserved when writing existing files.
Aliases, duplicate keys, excessive depth/size and unsupported locale IDs are
rejected. Deleting all files for a locale archives its values; deleting source keys
removes their target subtree. Connected projects can add languages in Settings:
they remain active as pending repository additions until their locale files appear
on the authoritative branch. Sync includes these files even before any
translations have been entered (empty locale mappings, never copied source text).
Once merged, removing the locale files in GitHub archives the language as usual.
Archiving/restoring existing connected languages remains managed in GitHub.

Tag creation pins an immutable commit SHA. Tagged exports read that SHA and
validate/project it in a rolled-back transaction, without changing the live
catalog. Accepted history exports replay local inverse events. Existing tags
predating the connection are not automatically backfilled.

## Export and intentionally removed features

`CatalogExport` is used both by real exports and the format showcase. YAML has
a locale wrapper; CSV/Excel have key and locale columns without that wrapper.
Missing values are always omitted (blank spreadsheet cells). JSON, manual
import, configurable delimiters/placeholder syntax, branch values and the
the former sheet layer are out of scope.

Network integration is covered with simulated API responses locally. A real
App installation is required to verify end-to-end PR/check delivery. Sync holds
a per-project database lock through network I/O; use a leased sync lock if
large repositories or network latency make that a practical bottleneck.

## Synchronization feedback and catalog actions

Manual Sync first reconciles GitHub, then publishes eligible local drafts or newly added languages. No local publishable changes means no PR; daily publication uses the same flow. Push webhooks only pull. Status is shown as a header badge (Syncing, Synced, Sync Failed, or Not synced), with details in a tooltip. The branch badge sits beside the project title and links to GitHub. During synchronization, editing/export is disabled; polling replaces the app-content frame when finished. A 15-minute execution timeout and a 30-minute stale-queue limit prevent abandoned workers from leaving the UI permanently busy.

The header uses a direct split button: Export, disabled Import, and (for connected projects with management permissions) Sync. Sync is the connected administrator's default; Export is the default otherwise. Branch/plural key menus offer Add child key, prefilling the existing add-key dialog with the full parent path.

## Translation editor loading

Ordinary editor reads load source and selected-target payloads, and calculate
whole-catalog target validation only for status filters. Cross-language search
and edit-date sorting retain their catalog-wide behavior. Full write/export/sync
validation is unchanged. View permission checks and key paths are reused within
one request; policy reauthorization under write locks still reads current roles.

Language switches send target cells for known rows and complete rows only for
newly applicable keys. Source cells, tree state and the visible scroll anchor
are preserved. A header spinner identifies the language being loaded; the
selector stays usable and a newer selection cancels the previous request. Large
DOM updates yield between batches. Key and translation dialogs are fetched only
when opened, with normal project/language authorization and fresh revisions.

Scrolling prefetches one 40-row batch up to two viewports before the sentinel,
holding it until the reader is within 400 pixels. Language changes, navigation
and edits abort or discard obsolete work. A table-local memory cache is limited
to four responses / roughly 2 MB of markup. Reuse requires a conditional GET; its private ETag
covers project revision/settings, review timestamps, languages and the current
user's role/membership/assignments. Changed metadata refreshes the page rather
than restoring stale controls. Initialized component nodes are retained rather
than serialized and reconstructed from their generated markup.

`Server-Timing` reports catalog, database, projection and rendering durations.
Browser Performance measures use `catalog-language-fetch`,
`catalog-language-render`, `catalog-prefetch-fetch` and
`catalog-prefetch-render`. A local 320-key / four-language development fixture
reduced the median page-eight switch from 5.49 s / 3.10 MB to 0.74 s / 0.73 MB.
Initial reads fell from 1.24 s to 0.60 s, and 40-row batches from 1.18 s to
0.62 s. Revalidation returned an empty 304 response with about 10 ms in the
catalog action; development request middleware added further overhead. These
are local uncompressed-response measurements, not production latency claims.

The loading regression checks cover cancellation, rollback of partially applied
cells, bounded prefetch/cache behavior, fresh review/permission validators and
authorized lazy editors. Five older JavaScript harnesses already fail on the
unchanged base: `app_forms_test.cjs`, `sheet_import_form_test.cjs`,
`table_action_test.cjs`, `translations_test.cjs` and
`wildcard_highlight_test.cjs` (missing registration mocks or the removed
`translations.js`). They are unrelated to this loading change.

## File limits and PR validation settings

Project owners can set file-count/per-file/combined limits, defaulting to
100 files / 3 MiB / 15 MiB. Normal ceilings are 500 / 5 MiB / 30 MiB.
Only application owners can save higher limits. Existing elevated limits survive
unrelated updates; a project owner cannot increase an elevated limit beyond the
normal ceiling. Fetching and parsing both enforce the saved project limits.

PR validation defaults on. Its master switch preserves individual choices.
Optional checks are source-key correspondence, scalar placeholder matching,
plural completeness, and count usage. Plural/count controls hide in Off mode;
plural completeness descriptions adapt to Simple/CLDR. The editor and sync still
enforce catalog validity independently of the PR switches. With source structure
disabled, target-only keys are ignored; a missing source skips source-dependent
validation. Disabling all PR validation reports a neutral check without fetching
locale files. Required parsing/safety checks are listed but cannot be disabled:
YAML syntax/aliases/duplicate keys/depth, file/locale/group identity, representable
key/value structure, translation size, and project resource limits.

Checks are attached to a pinned PR head SHA and report in-progress before
validation, then success/failure. Validation runs in a rolled-back transaction.
