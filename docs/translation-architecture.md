# Translation architecture: intent and extension points

Start here for the reasoning behind the translation model. See [translation-content.md](translation-content.md) for implementation details and [database-model.md](database-model.md) for the current schema. Future ideas below are not implemented requirements.

## Identity separate from content

A **project** owns sheets, languages and membership permissions. A **sheet** is one translation document across languages. Its **TranslationTree** is the container for the recording hierarchy; currently each sheet has exactly one tree.

**Recording** is the stable identity and structural position of an item: tree, parent, delegated payload pointer, deletion state, timestamps and `lock_version`. Keep domain content out of it:

- **TranslationKey** contains the local name, description and pluralization flag. A full path is derived from ancestors, not stored as the recording's name.
- **TextTranslation** contains the language reference and text. A translation recording is a child of its key recording.
- **Recordable** is the shared concern for immutable typed payloads. Rails `delegated_type` connects recordings to those payloads.

Editing creates a new payload and changes the recording's pointer in one transaction. It does not modify the previous payload. Moving a key changes its parent; descendants stay attached, so their derived paths move with it. Soft deletion retains identities and content. Reusing a deleted name is allowed; restoring it later may require conflict resolution.

This separation makes structural operations reusable across content types. Comments or image translations could eventually introduce additional recordables without replacing the identity model; their permitted parent relationships would still need explicit rules.

## Why these boundaries matter

- **Languages are symmetric.** A language ID represents its identity even if its display name or export identifier changes. That reference belongs in the translation payload. A default language is a sheet preference, not a different kind of translation.
- **Pluralization uses ordinary child keys.** The parent's flag gives the editor meaning for `zero`, `one`, `two`, `few`, `many`, and `other`. Disabling the plural editor preserves the same tree. When enabled, translations belong on category children rather than the plural parent.
- **Formats sit above the model.** YAML, JSON, CSV and Excel transform the same content. Identifier sets and export settings control that transformation; they do not define separate translation identities.
- **Integrity belongs in the database where possible.** Foreign keys, constraints and triggers protect immutable payloads, valid parent/payload relationships, tree boundaries and uniqueness. Policies separately govern who may perform an operation.
- **Browser editing still needs concurrency control.** `lock_version` detects stale updates; a sheet's tree lock serializes structural mutations. Immutable payloads alone cannot prevent two editors overwriting the same pointer.

## Snapshots and reflection — future

A future branch could have its own tree and recordings while sharing unchanged immutable payloads. Copy the recordings, remap their parent IDs, and retain payload pointers. An edit in that copy then replaces only its own pointer. This is an **independent snapshot**, not automatic synchronization with main.

**Reflection** would add an explicit relationship to a source recording: a local recording can refer to the same payload while retaining its own identity and position. A deliberate refresh could adopt a newer source payload, subject to conflict handling. Sharing a payload alone does not establish that relationship or implement merging.

The preferred direction discussed was independent snapshots first, with explicit synchronization later. Source tracking, merge rules and GitHub integration remain undecided and out of scope; do not introduce them merely because the model can support them.

## Events and history — future

Retaining payloads is not yet an ordered, attributable history. A future event can link to a recording and the **previous recordable type and ID**, with the actor, operation and ordering/time metadata. The current payload is already referenced by the recording; duplicating its contents into an event is unnecessary.

Write the event and pointer change atomically. Restoring content could point the recording back to a retained payload, subject to current permissions and constraints. Parent changes and deletions also affect history, so reconstructing structure would require recording their previous structural state, not just payload pointers.

The precise event schema was deliberately deferred. Preserve this extension point without implementing an event system now. Any future payload cleanup must respect references from recordings, snapshots and history.

## Loading and caching

Load keys in batches and fetch only the displayed translations. Immutable payloads are safe building blocks for caching, but recordings, descendants and permissions can change. A cached row or subtree therefore needs structural/revision invalidation as well; immutability does not make an entire rendered tree permanently cacheable.
