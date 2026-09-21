# Translation content

For the design rationale and deferred reflection/history ideas, see [translation-architecture.md](translation-architecture.md).

Projects own sheets and a language catalogue. Active sheet languages are the union of project-wide and sheet-specific selections. Membership language assignments apply across sheets; owners/admins edit all active languages. Translators with no assignments are read-only.

Each sheet has one initial TranslationTree. Recording stores structural identity, parent, tree, delegated payload, lock_version, deletion state and timestamps. TranslationKey stores name, description and pluralized. TextTranslation stores language_id and text. Recordable prevents in-place edits; PostgreSQL triggers enforce immutable payloads and structural integrity even for raw writes. Retained payloads may outlive their originating project; their language identity remains archived in the catalogue.

Case sensitivity defaults off. Each sheet has a one-to-three-character delimiter (dot by default); active key names cannot contain it, and changing it to a conflicting character is rejected in Rails and PostgreSQL. Paths, parent lookup and CSV exports use this delimiter. Missing default translations are warnings only; the default language is optional. Values may be saved before the default language is filled. Sheet settings apply to its tree. Parent-value restrictions are enforced through shared mutation methods; disabling them rejects existing mixed parents.

The editor shows two languages, initially fetches 20 key rows and appends batches of 20 as needed and batches payload loading. Enter saves, Shift+Enter adds a line, blur saves, Escape cancels. A stale recording version returns 409 and preserves the user's edit for conflict resolution. Empty editing removes the translation recording; empty payloads cannot be stored. Whitespace is preserved.

Pluralization creates the six Unicode child keys. One and other are always visible; the others appear when either selected language has a value, or are temporarily revealed from the parent menu. Active plural parents cannot carry translations. Conversion moves parent values to other and rejects conflicting values without changing either. Disabling the sheet plural editor leaves every key intact and displays them normally. Missing plural values are always omitted from exports.

Exports read a consistent database snapshot. CSV has escaped dotted paths and one column per active language. YAML/JSON export a ZIP with one nested file per language. Parent values use string key 0; literal child 0 and backslashes are escaped to preserve both. Missing values follow omit (default), empty, or default-language fallback. Imports, images, history, branch management, external integration and custom adapters are deferred.

Database functions/triggers are preserved in db/structure.sql; schema.rb is no longer authoritative. Run migrations and the Rails tests against the isolated test database. Retaining immutable payloads does not provide an event history; that remains deliberately out of scope.

The global sidebar stays visible for signed-in accounts. Project and sheet navigation use tabs, each with an Export modal; project export first selects an accessible sheet. Public anonymous views use tabs without account navigation.

## Reproducible scale check

Run `bin/rails runner -e test script/benchmark_translations.rb` against the isolated test database. It creates and rolls back 10,000 keys with 15 languages (150,000 translations); fixture loading bypasses recording user triggers inside that rollback-only transaction, then reenables them before measurements. This measures reads/individual edits, not bulk import throughput.

Measured locally: uncached 51-row database reads 220–232 ms, one guarded edit 49 ms, complete 11 MB CSV 6.22 seconds. Browser requests fetch only the two visible languages plus the default-language warning state. Page positions carry a tree revision; stale continuation requests ask the viewer to refresh. Parent lookup starts after three characters and returns at most 20 results. The shared key modal uses remote se-select (v0.14.3) with debounced, cancellable Stimulus requests. The current tree lock serializes writers within a sheet, not across sheets; bulk import throughput is not optimized in this scope.

Linked key paths create missing ancestors in one transaction. Preview badges distinguish existing (brand) and new (success) path segments. Separate-parent entry also supports paths; field errors report invalid names. Removal is a separate, confirmed menu action; translators can only reveal plural categories. Table menus use ghost buttons except compact translation tables.

## Export jobs and identifier sets

Project languages have a default identifier set. Advanced language configuration exposes additional named sets and per-language identifiers; disabling it preserves those mappings. A blank sheet selection enables a language in all sheets.

Exports use the Solid Queue worker (`docker compose up -d worker`, or `bin/jobs` outside Docker). Queue tables live in the primary database. One worker processes one export at a time. The modal polls progress and offers cancellation; hiding progress lets the export continue. Downloads are private to the initiating browser session and account, and sheet access is checked again before delivery. Export files expire after one day.

YAML/JSON generate one file per language, CSV one file per sheet, and Excel one workbook with a worksheet per sheet. Multiple ordinary files are zipped, with sheet folders for multi-sheet YAML/JSON. CSV/Excel can include key descriptions. Sheet delimiters accept one to three characters.
