# Task 2 Report: Atomic Overwrite, Copy, and Recovery

## Scope

- Added `BookPackImporter` and its conflict-result API in
  `reader_app/lib/data/bookpack/book_pack_importer.dart`.
- Kept `BookPackValidator` validation-only and updated the importer test to
  import the new module directly.
- Removed `ShelfBook.bookId` after confirming no production or test caller
  remains.

## Behavior Delivered

- Reject detects identical packages across all entries with the same source
  ID, otherwise returns a conflict entry that prefers the original library ID
  and then the oldest import.
- Overwrite stages extraction, renames the current directory to an importer
  backup, installs the replacement, replaces the index entry, and deletes the
  backup. A failure after backup creation restores the original directory and
  attempts to restore the original index row.
- Save-copy uses `nextCopyNumber`, gives the copy a distinct library ID and
  directory, and leaves extracted manifest and alignment bytes unchanged.
- Recovery processes only direct importer staging/backup directories: staging
  directories are removed, while backups are restored only when their target
  is absent.

## TDD Evidence

- RED: `flutter test test\\book_pack_validator_test.dart --reporter expanded`
  failed as expected because the new importer file, resolution enum,
  `conflictEntry`, and recovery API did not yet exist.
- GREEN: `flutter test test\\book_pack_validator_test.dart test\\shelf_index_test.dart --reporter expanded`
  passed with all focused importer, validator, and index tests.
- Full suite: `flutter test --reporter expanded` passed, 24 tests.

## Self-Review

- Checked direct imports and confirmed no validator compatibility export or
  remaining `ShelfBook.bookId` caller.
- Checked the atomic sequence against the task brief, including rollback after
  an injected `ShelfIndex.replace` failure and direct-child-only recovery.
- `git diff --check` completed without whitespace errors.
