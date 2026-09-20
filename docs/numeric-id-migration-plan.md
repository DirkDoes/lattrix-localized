# Numeric ID conversion — completed

Migration `20260921000000_use_numeric_application_ids` is applied to the development database.

- All 17 former non-user UUID primary keys and their foreign keys are bigint. Users and user foreign keys remain UUIDs. Existing queue bigint IDs and natural string keys are unchanged.
- Polymorphic recording pointers, export options, and queued export job arguments were remapped. Existing export files and email challenge digests retain their independent storage/digest keys.
- `numeric_id_mappings` contains rollback metadata only; the app does not resolve old IDs or provide compatibility URLs.
- The forward migration, rollback, exact row comparison, and a second forward migration passed on an isolated restored database. All 162 application tests (1,707 assertions) and the JavaScript checks passed.
- The app and worker were stopped for a fresh backup and migration, then restarted. Live verification confirmed that only users.id is UUID and no foreign keys or guards are disabled.

## Recovery
The pre-conversion database backup and export files are in ignored `tmp/numeric-id-backup/`. Keep these private and out of Git.

The migration can roll back immediately before reopening writes. Once new rows exist, use the database/file backup for full recovery rather than mixing pre- and post-migration data. `script/check_numeric_ids.rb` exercises the forward/rollback path only against the explicitly named disposable database `lattrix_numeric_rehearsal` restored from a pre-conversion backup.
