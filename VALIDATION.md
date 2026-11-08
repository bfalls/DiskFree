# Version 1.2 validation — October 11, 2026

The user builds and installs the application. No updated app bundle was built, installed or launched during this update.

Automated checks cover:

- All existing disk monitoring, monthly-history, preference and refresh checks.
- Cached growth baseline and targeted updates (an unchanged descendant stays cached).
- New/deleted directories, nested scope exclusions, symlink avoidance, missing roots and work limits.
- Durable growth archive, historical cutoff selection, scope-change baseline reset and bounded retention.
- Global/per-folder cooldown boundaries.
- Monitor opt-in/out, background baseline, manual cooldown enforcement and persistence integration using temporary fixtures only.

Compiler validation: all Swift sources, including SwiftUI, Charts, FSEvents, Spotlight and backup context, type-checked for x86_64 and arm64 targeting macOS 13. Xcode project and Info.plist parsed successfully.

Manual checks after building: enable tracking, allow paced baselines, inspect coverage/errors, cancel a check, disable tracking, modify a small tracked fixture folder, test pending-change cooldowns, view category charts and History-point clues, search Spotlight and check backup context. Comparisons need a baseline from at least yesterday/seven days ago. Native app UI and real Spotlight/Time Machine responses were not exercised here.

Personal folders were not scanned by the tests. Test caches/preferences use disposable directories/suites. Existing disk logs are untouched.

## Version 1.2.1 access and work-limit recovery

Scanner errors preserve POSIX error codes; EACCES/EPERM are classified separately from work-budget failures. Dependency-free checks exercise a permission-denied fixture, non-permission error classification, strict entry limits below the pacing boundary, and isolated per-folder retry/cooldown behavior. Existing history, preferences and monitoring checks also pass. Swift source type checking covers the native recovery UI; no updated app bundle was built or installed.

Manual checks after installing: open the help disclosure and Privacy Settings shortcut; grant access only if wanted, relaunch and retry one denied row. On a budget-limited category, choose one or more actual subfolders and confirm the broad category is replaced and each selected folder starts a fresh baseline. Cancel the chooser and verify no changes. Remaining paused folders should stay paused. Full Disk Access behavior and UI were not automated in this session; test fixtures never enumerate personal folders.

## Version 1.3 progressive investigation

Tests exercise a flat directory across many two-entry slices, verify bounded entry processing and identical final totals, force aggregate-only fallback with a one-directory cache, and deny a nested fixture folder to ensure accessible siblings still produce a labeled measurement. Coverage changes reset the baseline, and older caches decode without the new optional keys. Monitor integration covers migration of old paused categories and opt-in on first opening. Existing history and disk-monitor tests also run. No personal folders are scanned by these tests.

Manual check after your build/install: open Investigate, watch small categories finish while larger ones remain Gathering; ensure no work-limit warnings occur. Open the coverage disclosure for protected roots. Toggle tracking off/on, and confirm completed history remains. Grant/revoke access only if desired and check that coverage changes start a new baseline. Verify resource usage on your actual cache/application-data sizes. UI automation is unavailable, so the appearance and long-running real-data behavior remain manual checks. No app bundle was built, installed or launched in this update.

Additional version 1.3 checks cover fair scheduling of untouched categories ahead of continuation work, continuation without the category cooldown, stable partial-coverage targeted updates (one changed directory only), respecting an explicit user pause when reopening, and history-write failure retaining a useful size with a single persistence notice. Final fixture suite passed; all Swift sources type-checked for Intel and Apple Silicon during this update.

## Version 1.4 Time Machine summary and actions

Fixture tests cover installed `tmutil` status/list formats, unknown versus empty state, independent partial reads, whitelisted recovery amounts, fixed startup-Data-only mutation scope, active/unknown/no-snapshot preflight refusal, a simulated cleanup and observed free-space change. All cleanup executors are injected mocks; no snapshots are deleted or thinned by the tests. Existing monitoring/history/progressive checks also run.

Read-only checks on the actual installed tools confirmed `Running = 0` and a recognized startup-Data snapshot list. The administrator AppleScript was compiled with `osacompile` without execution. Full Swift sources are type-checked for Intel and Apple Silicon. The app bundle is left for the user to build/install.

Manual validation after installation: inspect the summary and disclaimer; open settings/Disk Utility; confirm Cancel on each destructive confirmation changes nothing. An actual cleanup test is optional and irreversible: only proceed if local restore points can be discarded and important files are externally backed up. Verify native authorization, cancellation, sustained progress, and the result/refresh afterward. Administrator authorization, Full Disk Access behavior, and actual reclamation were not exercised in this session.

## Version 1.5 Docker history

Fixture checks verify allocated blocks versus a sparse image's logical length, collection without content-read permissions, source identity changes on replacement, symlink/missing handling, configured DataFolder discovery and five-minute caching. Docker CSV checks cover monthly rollover, durable reopening, unavailable-sample gaps, image changes within a bucket, aggregation, shared one-year cleanup and preservation of malformed tails. Monitor integration verifies that a Docker metadata failure does not fail a free-space read, and Docker logging continues through a simulated free-space read failure. Existing checks pass.

The preview is built as a universal app and launched from the build folder for review, leaving Applications and the login item unchanged. No Docker daemon calls, scans or cleanup commands are used by this feature or its tests. Manual review: open History, confirm the orange graph has a current allocated size and only starts with the new samples; inspect both graphs at a shared time; compare a range before this update to see no invented Docker data. Check the revised Time Machine recommendation.

## Version 1.6 backup markers

Fixture checks cover observed start bounds using the most recent unpersisted idle observation; idle write suppression; stop handling without an asserted success outcome; durable reopening and UTC monthly rollover; cropped ranges; run-ID changes, sleep gaps and unknown status splitting spans; stale open-span truncation; visible-span limits; source-matched free/Docker deltas; retention and malformed-tail preservation. Monitor integration checks one-minute gating, overlap suppression, active/stop-only metadata reads and unavailable status. All tests use injected status and measurements; no real backup is started, stopped or cleaned up. Existing suites pass.

Swift source type checking and a universal Xcode build validate the new chart/hover APIs. The preview is launched from the build directory without replacing Applications or the login item. A real idle observation can verify journal persistence; active spans and hover appearance require an actual observed backup. Manual review: open History, toggle Show backups, hover a green band and both boundaries after a backup is observed; verify approximate times and changes, then close/reopen History to confirm saved spans. Quit/sleep during a backup and confirm unknown coverage is marked rather than bridged.

## Version 1.7: single-graph system evidence

- Environment checked: macOS 13.7.8, Xcode 15.2, SDK 14.2. Native swap and pressure counters verified on this host.
- Added deterministic checks for swap growth/recovery, pressure changes, unavailable counters, session/gap isolation, sleep spans crossing the chart boundary, missing wake/restarted sessions, month rollover, exact retention cutoff, malformed journal preservation, and persistent default-folder migration.
- Run `scripts/test.sh` for the complete dependency-free regression suite; run `scripts/build.sh` for the universal Release application.
- Manual review: open History, inspect purple swap events and teal launch marker, toggle Docker and Swap lines on the same graph, click evidence and reveal its source. Select a sample to inspect historical swap/pressure values. Sleep and wake normally to review the duration span. Quit and reopen to review the recording gap and app lifecycle markers.
- Development checks do not trigger real sleep, shutdown, memory pressure, backup, or cleanup operations. No fabricated history is written to the user's records. Notification pairing uses deterministic fixtures; real power transitions need normal usage validation.
- Preview remains outside Applications pending approval; the existing installed copy and login item are not replaced.

Final local verification: full regression suite passed; universal x86_64/arm64 Release build succeeded and its signature verified. The live preview saved real swap allocation, swap usage, normal pressure, free space and Docker metadata. An orderly quit saved appStop; relaunch saved appStart and resumed measurements. A startup stall exposed by native validation was fixed by moving bounded watcher setup off the UI actor, coalescing home-folder roots and excluding the VM volume from FSEvents. No real sleep/shutdown was triggered.

## Version 1.8: storage composition and discovery

- Test 1 TB / 970 GB free totals without counting used space twice; whole/used partitions sum to capacity.
- Test nested scopes, duplicate roots, stale and future observations, shared-block/overlarge estimates, configured cache paths, symlink rejection, and explicit discovery opt-out/removal persistence.
- Test sparse journal reconstruction without future carry-back, growth versus scope-change events, retirements, exact cleanup cutoff, and malformed-data preservation.
- Full dependency-free regression suite and universal Release build must pass. Native mount metadata checks require running outside Codex's restricted subprocess sandbox.
- Review the graph switch, all three composition scales, hover details, source reveal actions, and the click-to-open cleanup panel. Review Time Machine navigation and confirmation without executing cleanup.
- No model/container/cache deletion or real snapshot cleanup is performed during validation. New consumer observations begin with this version; earlier file-category history is not fabricated.

Final checks: the full regression suite passed, including the new composition/discovery cases. The universal x86_64/arm64 Release build succeeded and its code signature verified. The live preview wrote real consumer observations and native Docker-path/reclaimable metadata. Existing Applications version 1.4.1 and login registration were retained. No cleanup action was executed. Fresh History windows start in Free-space trend; composition is selected explicitly.

## Version 1.8.1: composition readability

- All composition scales show a used/free capacity bar, free GB and percentage,
  with the configured warning color. It follows the hovered sample or the latest
  observation in the selected range, with an explicit historical timestamp.
- Subdued remainder region, actual event-color symbols, and shorter hover cards.
- Deterministic checks cover exact small swap reversals, sustained growth, large
  recovered excursions, elevated pressure, missing shared observations, long gaps,
  intervening lifecycle events, and different recording sessions. Filtering affects
  display only; original journals and chart samples remain unchanged.
- Full native regression suite passed. Universal Release build and signature
  verification passed (x86_64 and arm64, version 1.8.1 build 13). The preview
  was launched with History open; the Applications copy was retained. No cleanup
  was executed.

## Version 1.8.2: tooltip headings and last-capture labels

- Category-colored bold headings precede hover-card measurements and provenance;
  the duplicate composition metric is removed from the body.
- Time ticks use explicit text, disabled automatic truncation and reserved space
  for the latest observed sample. A right-aligned full Last captured timestamp
  appears immediately beneath the chart in both graph modes.
- Power notification observers and persisted events were inspected; no power-state
  semantics were changed and no actual sleep or shutdown was triggered.
- UI-only changes; native universal Release compilation and signature verification
  validate the macOS 13-compatible Charts/SwiftUI APIs. Backend regression checks
  passed in the preceding build and backend code is unchanged.

Final checks: universal x86_64/arm64 Release build succeeded; strict signature
verification and source whitespace checks passed. Version 1.8.2 build 14 was
launched with History open, without replacing the installed Applications copy.

## Version 1.8.3: compact ranges and capacity endpoints

- Same-day event ranges coalesce the date; cross-day ranges retain both dates.
  Deterministic checks cover both cases. The formatter is shared by recording
  gaps and sleep spans.
- Whole disk uses the capacity rounded up to one GB as its domain maximum,
  without percentage headroom, and explicit ticks including 0 and capacity.
- Composition context markers share a top event row. Rendering now uses the
  same filtered event list as hit testing and the event menu, so hidden small
  swap reversals are also omitted from chart dots.

Final checks: full native regression suite passed; universal x86_64/arm64 Release
build and strict code signature verification passed. Version 1.8.3 build 15 was
launched for review. The Applications copy and login registration were retained.

## Version 1.8.4: scale alignment and footer

- Right-aligned, monospaced scale numbers share the same label width across all
  graph modes, including the explicit whole-disk 0 and capacity endpoints.
- Removed Docker/swap optional-line instructions and the refresh-interval footer.
  Clarified bottom memory-pressure strips and vertical backup spans in the key.
- Presentation-only changes; backend code and the preceding passing regression
  suite remain unchanged. Universal Release compilation validates the UI change.

Final checks: universal x86_64/arm64 Release build, strict signature verification,
and source whitespace checks passed. Version 1.8.4 build 16 was launched with
History open. The Applications copy and login registration were retained.

## Version 1.8.5: deterministic axis-label alignment

- Charts reserves the axis-label column, but all visible labels are drawn at the
  same overlay x coordinate and fixed width, including both domain endpoints.
  Only the endpoint y position is clamped to keep text inside the plot height.
- Removed the concurrency disclaimer from generated swap/Docker event details.
- Added a manual baseline/load/recovery pressure-check plan. No memory stress
  workload was launched. Pressure counters, strips, sampling and persistence are
  unchanged; backend behavioral regressions passed in version 1.8.3.

Final checks: universal x86_64/arm64 Release build, strict signature verification
and source whitespace checks passed. Version 1.8.5 build 17 was launched for
review, with the Applications copy and login registration retained.

## Interactive memory-pressure tool

- Added executable tools/memory-pressure; direct execution uses the native
  Swift toolchain and no package manager. The app target is unchanged.
- Compiled with optimization and warnings treated as errors. Direct --check
  execution read this host's real RAM size and normal pressure without allocating
  stress memory. Temporary-terminal checks exercised 1/0 and SIGINT, verified
  exit codes and terminal restoration (ignoring macOS's transient PENDIN flag).
- Yellow/red stress modes were not run on the user's active Mac. Allocation-cap,
  disk-reserve and time-limit paths are implemented but not stress-tested here.

## Version 1.8.6: dedicated always-visible pressure row

- Reserved eight points within the existing plot range beneath its GB baseline;
  the x-axis and its time labels retain their layout. Canvas draws the pressure
  row at the exact lower-bound position, independent of the Events toggle.
- All known pressure summaries are rendered, including light-green normal.
  Unknown/missing samples retain neutral gaps instead of fabricated normal data.
- Pressure-row hover/click uses the same interval and highest-pressure record as
  rendering, and works with Events disabled. Existing high-GB pressure rectangles
  were removed; no sampler, journal, or background-task behavior changed.
- Review both graph modes, Events on/off, light-green normal samples and existing
  yellow/red history, row hover and evidence. No stress workload is started here.

Final checks: universal x86_64/arm64 Release build, strict signature verification,
and source whitespace checks passed. Version 1.8.6 build 18 was launched for
review. The Applications copy and login registration remain unchanged.

## Version 1.8.7: stable cross-source history buckets

- Reproduced native-consumer dropouts using saved 15-second history with
  fractional query-window starts. Whole-second system timestamps and millisecond
  disk timestamps sometimes entered adjacent buckets; the native sample then
  appeared too old or later than the corresponding disk point.
- All three history readers share an integer-second bucket origin. The native
  freshness limit and actual source timestamps remain unchanged; no future
  measurements or missing samples are invented and no journals are rewritten.
- Added a deterministic regression with mixed timestamp precision, changing swap,
  disk-free and pressure values, and multiple fractional query offsets. It checks
  native sample/free-space agreement and continuous Docker/swap regions.
- Read-only replay of the latest real hour with six query offsets found zero
  native gaps using the corrected alignment. No new memory stress was started.
- Scale labels use measured monospaced text widths and the same right edge,
  positioned six points from the plot. Pressure-row layout remains unchanged.

Final checks: full native regression suite passed in isolation after the build
(the concurrent run hit a short refresh-fixture deadline). Universal x86_64/arm64
Release build, strict signature verification and whitespace checks passed.
Version 1.8.7 build 19 was launched for review; Applications and login registration
were retained. Existing user journals were read only.

## Version 1.8.8: shorter History UI copy

Removed the requested chart explanations, folder-measurement paragraph, backup-band
paragraph, and repeated source/pressure instructions. Kept the short interaction
hint and sample counts. Presentation-only change; history and monitoring unchanged.

Universal Release build, strict signature verification and whitespace checks
passed. Version 1.8.8 build 20 launched for review; Applications was not replaced.

## Version 1.8.9: terse hover cards

Graph hover cards now show timestamps, key values and brief status only. Long
source descriptions remain in the click-through evidence view. Composition
cards omit per-folder detail lists, backup cards use a short status and free-space
change, and native backup help is a short label. Single observations show one
timestamp. Presentation-only changes; saved evidence and monitoring are unchanged.

Universal Release build, strict signature verification and whitespace checks
passed. Version 1.8.9 build 21 launched for review; Applications was not replaced.

## Version 1.9: complete-frame paging and bounded cache

- Separate requested and displayed windows; publish all five histories together.
  Immutable chart children retain their original data and domains during slides.
- Bound the window-local LRU to five frames and in-flight reads to three; prefetch
  only neighboring windows. Check cancellation between individual source reads.
- Cache tests cover reuse, duplicate requests, LRU eviction, explicit invalidation,
  cancelled in-flight results and rapid navigation. A complete-page fixture uses
  the existing mixed-precision disk/system history regression.
- Review left/right paging in both graph modes, rapid direction changes, empty
  ranges, time-range changes, Live, Refresh, cleanup and Reduce Motion. No new UI
  explanatory paragraphs, polling timers, user-history writes or cleanup actions.

Final checks: full clean regression suite passed, including complete frames,
cache hits/shared reads, LRU eviction, invalidation, cancellation and the three-
reader concurrency bound. The asynchronous suite uses a detached worker and a
main-actor completion flag; fixture deadlines allow 10 seconds for refresh and
30 seconds for history checks on a loaded host. Universal x86_64/arm64 Release
build, strict signature verification and whitespace checks passed. Version 1.9
build 22 launched for visual review; animation appearance remains a manual check.
Applications and login registration were retained; user journals were not edited.

## Version 1.10 Time Machine log evidence

Added deterministic fixtures for actual start/finish and success/failure/cancellation, intermediate results without completion, component-error isolation, process/boot separation, repeated and multiple volume summaries, exact copied bytes versus preflight estimates, log-only history, interrupted polling reconciliation, ambiguous observation intervals, persistent deduplication, resumable one-time migration, and malformed-evidence preservation.

Manual review: hover and click the Oct 24 evening backup. Confirm the span starts at the native log time and shows the explicit completion result; inspect copied bytes, files, duration and saved evidence. Older backups appear only where retained logs contain evidence. The import preserves original observation files. No backup or cleanup is executed during validation.

Validation completed: full native checks passed, including adaptive query splitting; universal x86_64/arm64 build and strict code-signature verification passed. The native six-hour utility-priority query retrieved this Mac's five backup records in approximately 6.5 seconds. The check runner now yields asynchronously instead of nesting run loops; fixture setup is completed before suspension points. UI appearance remains a user review check.

End-to-end preview validation saved the real Oct 24 backup's five native records: start 18:16:51, explicit completion 18:47:39, 9,206,951,936 copied bytes and 37,578 files. The one-time 30-day historical import completed; this Mac retained one completed backup in the queried records. Preview 1.10 (23) was launched from the build folder; Applications and login registration were not changed.

## Version 1.11 space-change reports

The real example rose from 86,543,233,024 to 108,452,397,056 free bytes between 18:16:52 and 18:17:52 on Oct 24: +21,909,164,032 bytes. Time Machine's LocalThinning log records two startup-volume snapshot deletions at 18:17:01. Swap allocation fell by 1,073,741,824 bytes and Docker allocation stayed unchanged. Snapshot-specific reclaimed sizes were not logged; the report distinguishes recorded cleanup from measured allocation changes.

New fixtures replay this burst and test grouping, quiet completion, losses, swap jitter, missing coverage and run changes; raw detection before chart downsampling; startup-volume/deletion deduplication and destination-volume exclusion; model-store comparisons and changed-coverage exclusion; concurrent report coalescing, persisted reopen, pure-swap query avoidance, unavailable logs, and malformed-report retention. Preview review: select 6 hours, click the mint diamond at the end of the 6:17 PM rise, inspect its report and expand recorded actions. No cleanup or memory stress is run during validation.

Final validation: native checks passed, including serialized distinct-event queries, same-event coalescing and milestone priority in dense indicator history. The universal 1.11 (24) preview built and passed strict signature verification. A process-specific snapshot lookup completed in about four seconds; the real running preview saved both LocalThinning deletion records. The detector groups a little earlier swap recovery into this burst: 85,469,958,144 → 108,452,397,056 free bytes (+22,982,438,912); swap 21,474,836,480 → 19,327,352,832 bytes; Docker unchanged at 38,105,145,344 bytes. The earlier failed validation-only report was preserved in the workspace before recollection. Applications and login registration were unchanged. Visual appearance remains for user review.


## Version 1.12 suspect files

Added fixtures for indexed creation, measured allocated growth, deletion with a prior baseline, direction and time-window filtering, sparse-file exclusion, rename safety, inode replacement, candidate provenance round-tripping, preserved findings on recheck, and legacy report compatibility/enrichment. Reopened reports must not requery Spotlight or native logs. Integration checks use a 1 MiB file in a disposable repository build directory to verify actual coalesced FSEvents creation/deletion, plus a sparse file and symlink to verify metadata-only inspection. The native Spotlight predicate must finish gathering. No 20 GB fixture, file-content scan or cleanup of user files is required.

Review: leave the preview running, create the suggested 20 GiB test file in the home folder, wait for the pink milestone, and click it. Inspect Suspect files and Reveal. Wait for the first event before deleting the test file, then check the mint milestone for the last observed allocated size. Very short-lived files can fall between coalesced observations; Spotlight exclusions and index delays remain possible. Historical file sizes are not invented. Visual appearance is a manual review step.

Validation completed: the full native suite passed, then focused checks passed after the file-only retry/cooldown changes. Actual Spotlight gathering and FSEvents creation/deletion completed; file checks used 1 MiB of real data, metadata-only sparse allocation and a symlink. Universal Release build 1.12 (27), strict signature verification and whitespace checks passed. Applications and login registration remain unchanged; the preview was launched for visual review.


## Version 1.13 on-demand app leftovers

Fixture checks cover app metadata inventory/canonical deduplication, Trash and backup exclusions, installed-app and shared-publisher suppression, historical names, uncertain ownership, cached sizes, sparse allocation, hardlink deduplication, symlink exclusion, measurement and inventory work limits, cancelled checks preserving saved results, Keep persistence/cleanup protection, fresh reinstall detection and folder replacement/symlink cleanup guards. A native Spotlight app query is explicitly cancelled and must release its continuation. No user-data discovery or Trash operation is performed by these checks.

Review: Investigate → Find App Leftovers starts the check. Cancel stops it and retains the prior results. Reopen Saved Results to verify no new check starts. Finder reveals each candidate; Keep persists across checks. Unknown associations offer no Trash action. Recognized candidates require a warning/confirmation and another app check before a Trash move. Review cleanup manually only on disposable data. The preview is launched to Investigate; Applications and login registration are unchanged.

Validation completed: targeted leftovers checks passed, including native query cancellation, bounded metadata measurement, safe retention of prior results on cancellation, Keep persistence, and cleanup rejection for uncertain/kept data, incomplete inventory, reinstalled apps, shared publishers and changed/symlinked folders. The 1.13 (30) universal x86_64/arm64 Release build, strict signature verification and whitespace checks passed. The preview was launched to Investigate without starting a leftovers scan; no user data was moved. Applications and login registration were not changed. Appearance and Finder/Trash interaction remain for user review.


## Version 1.14 progress, caching and window access

Release-optimized targeted checks passed for exact processed-byte totals, monotonic progress, detached observers, preserved completed pages after closing, estimate-based eviction, in-flight prefetch progress and shared reads, plus an actual complete-page fixture covering all five sources. The full Release native regression suite passed. On this macOS 13 / Swift 5.9 host the unoptimized test runner stalled at completion after all readers/cache finished; the optimized runner completed. The check script now uses -O, matching the app's Release configuration. Temporary stage diagnostics were removed from production code.

Review: navigate to an uncached 7-day or year range and observe source/byte progress with the previous chart retained. Revisit cached pages and close/reopen History. Change range/graph, relaunch and confirm the choices persist. Open History, Investigate and Settings, switch to another app and use Cmd-Tab back to DiskFree; use Cmd-` and Window to select its main windows. Check that closing one of several windows keeps Dock/Cmd-Tab presence and closing the last returns to menu-bar-only mode. Sheets retain normal parent-window modality, and minimized windows retain normal Mac behavior. Native appearance and keyboard interaction remain manual review checks; the preview does not replace Applications.

The universal 1.14 (31) Release build and strict signature/whitespace checks passed. The running preview was verified at the build path with NSRunningApplication.activationPolicy = regular (0) after opening History. Keyboard cycling, multi-window close behavior and sheet appearance remain for user review. Applications and login registration remain unchanged; no journal migration, history deletion or cleanup was performed.

Version 1.14.1 (32): removed visible progress text and the duplicate initial spinner. The header always reserves a 20 × 20 point progress slot, including when idle, so status changes do not alter control widths or row height. The determinate/indeterminate circle and accessibility stage labels remain. Universal build, strict signature and whitespace checks passed; the preview was launched without installing.


## Version 1.15 history reuse

New fixtures verify unchanged files incur no content reads/decoding, append-only parsing, larger in-place rewrites and atomic replacement, partial-last-line recovery, and streaming over-budget journals. End-to-end fixtures load six hours, derive one hour and return to six hours without content I/O or decoding; compare pressure/events/composition to an independent read; rebuild a different aggregation using parsed data; append live samples and verify only new lines are decoded. A legacy malformed row remains reported while valid pages are cached. The fixture reported approximately 0.6 ms for contained-range reuse and 2,362 bytes / three lines for live updates.

A read-only diagnostic against the real saved history identified a persistent unreadable-system-row notice that previously disabled page caching. No journals were changed. The diagnostic records timings, source notices and file-read/decoding counters; raw samples, filenames and event contents are not emitted. Visual review should compare the thinner ring, one-hour/six-hour switching and live updates. The preview remains separate from Applications.

Final read-only diagnostic on the user's journals: 873 six-hour samples, a complete 204/204 system-event archive, and a persistent skipped-row notice. With valid warned pages cacheable, the contained one-hour query took 0.87 ms; returning to six hours performed zero content reads and zero decodes. The cold load took about 10.6 seconds. The final fixture, including a legacy malformed row, took 0.51 ms for the contained view and read 2,362 bytes / decoded three lines for the live update. Full Release native regression checks passed. No user journals were changed.

Universal x86_64/arm64 Release build 1.15 (33), strict code-signature verification and whitespace checks passed. The preview was launched at the build path with History open; Applications and login registration were retained. Journal files were read-only during actual-history diagnostics; no migration, deletion or cleanup was run. The first load after app restart remains cold. Visual ring weight and end-to-end chart-transition responsiveness remain user review checks.
