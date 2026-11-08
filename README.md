# DiskFree

A tiny native macOS menu bar app showing immediately available space on the startup disk, with durable monthly history logs, a native history graph and opt-in folder-growth investigation. Swift, SwiftUI, Swift Charts, AppKit, Foundation, CoreServices and ServiceManagement only. No dependencies, network requests, helper services or privileged processes.

Requires macOS 13 or later and Xcode 14 or later to build. Developed and checked on macOS 13.7.8 using Xcode 15.2 / macOS SDK 14.2. The build script produces a universal Intel / Apple Silicon app.

## Build and run

Open `DiskFree.xcodeproj`, choose the DiskFree scheme and My Mac destination, then Run (⌘R). The app appears in the menu bar, with no Dock icon or startup window. Click its colored disk-space indicator to open the dropdown. Settings opens a small, closable native window.

Or, from the repository directory:

```sh
./scripts/build.sh
open build/Build/Products/Release/DiskFree.app
```

The default signing identity is local ad-hoc signing, so no Apple developer account is needed for local builds. For distribution to other Macs, configure your own Developer ID signing and notarization in Xcode.

## Install

Quit any running development copy first. Drag the built `DiskFree.app` into `/Applications`, or install just for your user in `~/Applications`:

```sh
mkdir -p ~/Applications
ditto build/Build/Products/Release/DiskFree.app ~/Applications/DiskFree.app
open ~/Applications/DiskFree.app
```

For the delivered standalone app, drag it to Applications and open it. Enable **Launch automatically at login** from DiskFree Settings after installing. Registration uses `SMAppService.mainApp`; macOS stores that registration. If approval is required, the Settings window provides a button to General → Login Items. Quit DiskFree from its dropdown. Disable login launch before removing the installed app.

## Updating an existing installation (version 1.2)

1. Quit **every** running DiskFree copy from its menu dropdown. Stop an Xcode Run session too, if one is active.
2. Build the updated source:

```sh
cd ~/github/DiskFree
./scripts/build.sh
```

3. In Finder, open `~/github/DiskFree/build/Build/Products/Release/` and drag `DiskFree.app` into the same Applications folder where you installed it previously. Choose **Replace**.
4. Open that installed copy again. Choose **History…** from the dropdown. History recording begins with the first successful refresh in this version; past readings from version 1.0 cannot be reconstructed.

Rebuilding only updates the app inside the build directory. Quitting and reopening an older installed copy will still run the older version until you replace it. If you always run directly from the build directory, simply quit, build, and reopen that newly built copy instead. Keep one installed copy for reliable login launch. The new version rejects a second running instance, including an already-running version 1.0 copy.

## History

Every successful refresh writes a UTC timestamp, immediately free bytes and total bytes to:

```text
~/Library/Application Support/DiskFree/History/YYYY-MM.csv
```

The CSV header is `timestamp_utc,free_bytes,total_bytes`. The third column makes future used-space calculations possible even if capacity changes. Logs remain outside the source, build directory and app bundle, so normal rebuilds, updates and app removal do not delete them. They are plain files you can copy or archive from **Show Logs in Finder**. No logs are automatically retired.

The **History…** window offers 1 hour, 6 hours, 24 hours, 7 days, 30 days and 1 year. Previous/next buttons let you browse earlier periods; **Live** returns to now. Click or drag the graph to inspect a reading. The vertical axis displays free GB and scales to the visible values. Short ranges use one-minute summaries; longer ranges use 10-minute, 30-minute or 6-hour summaries. The line is the last reading in each bucket; shading preserves its minimum and maximum, so longer views do not hide sharp drops. Missing time buckets break the line.

Use a refresh interval of 60 seconds or faster for minute-level history. At 300 seconds, actual samples are five minutes apart; the app does not invent intervening readings. Time spent asleep, quit or encountering a disk-read error is not recorded. Manual refreshes are recorded too. The live chart reloads at most once a minute while open; its Refresh button reads saved logs immediately without polling the disk. Closing it releases the chart and its subscriptions. Log reads stream in bounded chunks, with about 1,500 plotted buckets even for a year.

At the default interval, CSV storage is roughly 25–30 MB per year of continuous operation (about four times that at 15 seconds). The Settings **Remove History Older Than One Year…** button asks for confirmation before deleting. It uses a rolling calendar-year cutoff, deleting full old months and atomically rewriting a partial cutoff month to retain newer samples. Archive old CSV files first if you want to keep them elsewhere. Malformed files are preserved and cleanup reports the problem; valid rows can still be graphed. History write failures appear in the menu without disabling the live disk-space display.

## Investigate Space Changes (version 1.3)

Open **Investigate Space Changes…** from the menu or **Investigate…** from History. On its first opening, folder collection starts automatically if you have not already chosen a tracking preference. An explicit off preference is respected. You can pause/resume with **Track folder growth**. Normal free-space refreshes never enumerate folders.

Folder sizes arrive progressively. Larger categories show **Gathering…** while DiskFree continues in small batches; already completed sizes remain available. Growth dates indicate when yesterday/seven-day comparisons become possible. No user retry or narrowing is required merely because a folder exceeds a batch limit. Existing version 1.2 paused folders are automatically returned to collection.

Defaults cover Downloads, Trash, app caches, application data, Xcode builds/archives, simulators, device backups, and swap/sleep files. Use Add Folder for more specific local locations, or remove categories you do not need. All settings, folder paths and tracking history remain local.

Performance and collection policy:

- One detached **background-priority** worker performs metadata-only slices of up to **one second or 2,000 entries**, with at least **30 seconds between starts**. Limits are checked between filesystem calls, so a single slow filesystem operation can exceed the time budget. Small pacing pauses further reduce pressure. There are no overlapping scans and no file-content reads.
- A large directory keeps its enumeration cursor between slices. Work resumes without re-reading its first entries. Categories rotate fairly, so a large category does not block smaller ones. Initial measurements can take minutes or longer; an unfinished traversal never creates a historical sample.
- Native FSEvents batches changed directory paths. Completed directory caches support targeted updates without walking unchanged descendants. Each completed category has a 30-minute refresh cooldown. A once-daily paced reconciliation covers missed changes. Continuation slices of a single measurement do not wait 30 minutes.
- Retained directory caches are bounded across configured categories (up to 30,000 totals; at most 10,000 per category). Trees that outgrow the cache still finish as streamed aggregate totals. Their later refreshes also stream in batches rather than failing at a cache limit. Symlinks and other mounted filesystems are skipped. Each session opens at most 32 directory handles; unusually deep paths are marked outside coverage.
- Completed measurements are saved atomically. The last result remains visible while a new scan is underway. In-progress enumeration cursors are memory-only: pausing or quitting closes them, and unfinished work restarts on the next enable/launch. Already saved measurements and free-space logs remain intact.
- **Update Sizes** queues updates without changing these resource limits. **Pause Gathering** turns collection off cooperatively. Preferences retain the pause; opening the window does not override an explicit off preference.

Access and coverage:

- If a nested folder is protected, its accessible siblings are still measured. The category is labeled **Accessible files measured**. This is an allocated-size estimate for accessible contents, not a complete category total.
- If the category root itself cannot be read, it moves to the collapsed **Coverage and optional access** section. Other results continue updating. macOS privacy restrictions are not displayed as repeated yellow failure banners. Original error details are available there on demand; root failures never overwrite a saved size with zero.
- To include protected data such as Trash or device backups, optionally enable the installed `/Applications/DiskFree.app` in **System Settings → Privacy & Security → Full Disk Access**, quit/reopen, then click Update Sizes. DiskFree cannot grant itself access. It retries unavailable roots daily, or on explicit Check Again. An explicit retry of a restricted root does not wait for the category cooldown, but still respects the global batch rest.
- Changed scope, skipped paths or skipped-count coverage resets the comparable baseline so newly granted access is not shown as file growth. Existing readable version 1.2 cache files are migrated automatically. A damaged cache is preserved and reported once, with details in the coverage disclosure. If a history write fails, newly collected sizes remain visible with a single saving-status notice; a later successful write includes the retained in-memory samples.

The ranked list compares the latest complete measurement with the latest saved measurement at or before **yesterday** or **seven days ago**, using calendar-day cutoffs. Actual measurement timestamps are shown; until an older baseline exists, the view shows when growth comparisons will become available. Folder charts show measurement history, not invented minute-by-minute samples. Select a folder name to change the chart; Finder buttons reveal locations. Selecting a point in the free-space History graph also shows positive tracked-folder changes around the preceding hour when suitable baselines exist.

These are allocated-size **estimates**, not an exact explanation of every lost disk byte: APFS clones/shared blocks, hard links, snapshots, reserved space, untracked locations and inaccessible files complicate accounting. Nested tracked folders are excluded from parent totals to reduce overlap. Changing a folder's scope/exclusions resets its comparable growth baseline. A renamed/moved file can shift usage between categories without consuming additional volume space.

**Spotlight clues** runs an on-demand NSMetadataQuery against selected folders for indexed files at least 500 MB and changed in the last seven days. It displays at most 50 results and stops after completion or a 15-second timeout; no permanent live query. Indexed sizes are logical sizes, and recent modification does not prove growth. Excluded/system locations and unavailable metadata may be absent. This can identify large suspects now, but cannot reconstruct last week's 60 GB decline.

## Time Machine backup markers (version 1.6)

History's **Show backups** checkbox overlays subtle green bands, Time Machine start icons and end markers on the free-space graph. Hover a band/start/end to see observed times, approximate duration and free-space/Docker allocated-size changes between the recorded endpoints. A changed/missing Docker image suppresses that comparison. The tooltip explicitly treats these as changes during the observed activity, not proof that Time Machine caused them. The checkbox controls visibility; recording continues while DiskFree is running.

A separate tolerant timer checks local `tmutil status` **at most once per 60 seconds**, independent of the disk refresh interval. Work runs at background priority with the existing five-second subprocess timeout. No snapshot enumeration, mounting, network requests, administrator prompts, cleanup or Docker daemon commands occur in this monitor. While running, and on an observed stop, a `statfs` lookup and Docker image metadata lookup capture endpoint sizes. Repeated idle checks do not gather those extra metrics or write repeated log rows.

Start/stop times are approximate observations. If the app first encounters an already-running backup, its actual start is unknown. A stop does not establish success: it can also reflect cancellation or failure. A status error, app restart or observation gap exceeding 150 seconds ends the known segment at its last running observation, rather than drawing a backup across unknown time. Uncertain boundaries use dashed markers. Very short backups entirely between checks can be missed.

Events persist in **`~/Library/Application Support/DiskFree/History/Backups/YYYY-MM.csv`**. The compact journal stores one initial/changed idle-or-unknown state and one heartbeat for each observed running minute, with a per-launch run ID and optional size measurements. This saves open spans without rewriting an entire month's history. It also retains the most recent observed idle time in a start record to bound an approximate start without writing idle heartbeats. No file names, backup destinations or file contents are collected. The one-year Settings cleanup includes this journal and preserves malformed data.

Loads stream the selected months plus one previous month of context. At most the latest 500 intersecting spans are rendered in a dense range, with a displayed count when capped; saved events are retained. Markers begin with this version's observations. Prior backups are not inferred from snapshot names. Real backup activity is not started for development tests or preview.

## Docker disk-image history (version 1.5)

History now shows the original free-space graph and an orange **Docker disk image** graph on the same selected time range. Click/drag either graph to inspect both series. A summary reports Docker's measured change over the dates actually recorded; there is no reconstruction of earlier usage. The two graphs use independent, labeled GB scales so Docker's smaller fluctuations remain visible.

Collection reads file metadata (`st_blocks × 512`) at the existing free-space refresh interval, including when Docker is stopped. It does not read the image contents, scan folders, start Docker, query its daemon, or run Docker commands. Docker's advertised virtual capacity is not its allocated footprint. APFS sharing and local snapshots mean the live file's allocated bytes do not fully reconcile the volume's free-space change.

Discovery checks Docker's bounded local `settings-store.json`/legacy `settings.json` for `DataFolder`/`dataFolder`, cached for five minutes, and otherwise tries standard Docker.raw/Docker.qcow2 locations. A configured custom folder takes precedence over default images. Network mounts, symlink image files and images on another volume are excluded from the startup-disk comparison. Missing/unreadable image metadata remains unavailable rather than becoming zero; it does not interrupt the free-space monitor. The image path plus filesystem/inode identity creates a hashed source ID, so replacing/moving the image breaks the plotted baseline instead of generating a false growth comparison.

Docker measurements are saved separately in **`~/Library/Application Support/DiskFree/History/Docker/YYYY-MM.csv`**, with UTC timestamp, allocated bytes, source ID and availability state. Existing three-column free-space CSV files remain unchanged. No Docker log is created until an image has been measured. After tracking begins, unavailable samples mark gaps. Streaming reads and range-dependent buckets bound history loading, and buckets never merge different image identities or bridge availability gaps. The Settings one-year cleanup includes both histories and preserves malformed files.

The Time Machine recommendation no longer declares “No action needed” merely because free space is above the warning threshold. It explicitly states that the summary does not measure snapshot sizes or explain recent disk-space changes.

## Time Machine space recovery (version 1.4)

The Investigate window shows **macOS reclaimable** and **Local restore points**, plus the oldest point's date and a short recommendation. This summary checks when opened (if its cached data is over a minute old) or when Refresh is clicked. Separately, the history activity monitor checks only backup status once per minute; snapshot lists remain on demand. Read-only checks run at background priority with five-second timeouts. Missing status/list data remains unknown rather than becoming a false zero.

macOS reclaimable is the system's important-usage capacity estimate minus immediately free capacity. It covers caches, snapshots and other purgeable data combined. It is **not an exact Time Machine size** or a promise of what cleanup will recover. For additional APFS Private Size/Cumulative Size details, the disclosure offers Disk Utility and brief instructions; DiskFree does not use private APIs or add shared snapshot sizes together.

**Recover Space…** asks Time Machine to try to reclaim 5, 10 or 20 GB (default 10 GB). macOS selects local snapshots to thin, at the lowest explicit urgency. **Remove Local Restore Points…**, inside the details disclosure, removes all local Time Machine restore points on the startup Data volume. Both actions require an explicit confirmation explaining the loss of local restore history, recommend having a current external backup, and then use macOS administrator authorization. Permissions may also require Full Disk Access. Existing files, external backups and non-Time-Machine system snapshots are not cleanup targets.

The fixed cleanup scope is `/System/Volumes/Data`. Only whitelisted targets and fixed verbs reach the authorization script; no snapshot names or user paths are interpolated into shell commands. Cleanup is disabled during active or unknown backup status, and a fresh preflight checks status and snapshot availability. The authorized script checks idle status again after the password dialog. There is no background privileged helper, automatic cleanup, backup stopping or permanent privilege grant.

A progress indicator remains active during authorization/cleanup. The app checks capacity afterward and reports the **observed free-space change**, which can be affected by other disk activity and delayed reclamation. A request can recover less than requested or no space. Use Refresh for a later reading. Authorization cancellation is handled quietly; failures retain useful information and expose details. A timed-out authorized command may still be finishing, so refresh before attempting it again. Closing/reopening Investigate preserves the same operation model, preventing overlapping actions within the app. No real snapshot deletion was performed during development validation.

Apple guidance: [local snapshot management](https://support.apple.com/en-ie/102154), [APFS snapshot review](https://support.apple.com/en-euro/guide/disk-utility/dskuf82354dc/mac).

Directory totals and up to 90 days / 10,000 category measurements are saved atomically in `~/Library/Application Support/DiskFree/Growth/growth.json`. The retained window can be shorter under the row limit. This bounded diagnostic cache is separate from the original monthly disk history, whose retention behavior is unchanged. Spotlight results are not saved. Backup activity and selected native log evidence are saved separately with history. Damaged growth data is preserved and monitoring stops with a message; Show Tracking Data lets you archive/move it aside before restarting.

## Display and preferences

- Refreshes once at launch, then every 60 seconds by default. Choose 15, 30, 60 or 300 seconds. Interval changes replace the existing timer; the next refresh follows the new interval. Refresh Now reads immediately, unless a read is already running.
- The optional `SSD:` prefix is off by default. It is a display label, not hardware detection.
- Warning threshold defaults to 20 GB and accepts 1–1,000 GB. Green is above the threshold; yellow is at or below it; orange is at or below half; red is at or below one quarter. The dropdown also names the status, so color is not the only signal.
- Units are decimal (1 GB = 1,000,000,000 bytes; 1 TB = 1,000 GB). The indicator shows one decimal for GB and two for TB.
- Preferences save to UserDefaults under `com.diskfree.utility`. Login registration is read from macOS directly, avoiding a saved toggle that disagrees with System Settings.
- If a read fails, the indicator says Unavailable. The dropdown shows the error and retains the last successful values with their timestamp until recovery.

## Capacity semantics

DiskFree monitors `/System/Volumes/Data`, the writable startup volume on modern macOS, with `/` as a fallback. It uses native `statfs`: total bytes are `f_blocks × f_bsize`; free bytes are `f_bavail × f_bsize`, immediately available to an ordinary user. These values match `df` on that volume and **exclude purgeable data**.

Used / unavailable is total minus immediately available space. APFS volumes share a container, so this includes space occupied by other volumes and reservations; it is not the sum of files in your home folder.

The separate **Reclaimable estimate** is the nonnegative difference between Foundation's `volumeAvailableCapacityForImportantUsage` and immediately free space. It estimates additional space macOS could make available, potentially by purging caches or reclaiming other data. It is not an exact purgeable-byte measurement and never increases the menu bar free-space amount. The row is omitted if macOS does not provide the estimate. Finder / Storage settings can show different available values because they include reclaimable space or use other accounting.

## Architecture and extension

- `StatisticsProvider.swift`: small provider protocol, immutable disk snapshot, native collector, capacity formatting and thresholds.
- `Preferences.swift`: validated UserDefaults-backed options.
- `DiskMonitor.swift`: UI state, one tolerant timer, and serialized background collection. Timer ticks do not perform I/O on the main thread; no overlapping reads.
- `DiskFreeApp.swift`: SwiftUI MenuBarExtra, original-color menu indicator, dropdown, native Settings window and login registration.
- `HistoryStore.swift`: serialized monthly CSV append, bounded streaming aggregation and manual cleanup.
- `HistoryView.swift`: native Swift Charts window, time ranges and sample inspection.
- `InstanceGuard.swift`: process-lifetime file lock and detection of existing app copies.
- `GrowthStore.swift`: metadata scanner, cached directory totals, bounded growth archive and pure cooldown policy.
- `GrowthMonitor.swift`: opt-in FSEvents watcher and serialized background work scheduling.
- `InvestigationView.swift`: yesterday/seven-day comparisons, per-folder charts and coverage/errors.
- `BackupHistory.swift`: sparse backup observations, native-evidence reconciliation and one-minute background status monitor.
- `BackupLog.swift`: bounded unified-log queries, copied-size/file-count parsing, durable evidence and resumable historical import.
- `SpotlightClues.swift` / `BackupContext.swift`: bounded on-demand clues and explicitly confirmed Time Machine cleanup.

To add a statistic, define a Sendable snapshot and a struct conforming to `StatisticsProvider`, then implement `collect()`. Keep collection synchronous inside the provider and dispatch it off the main actor in a small monitor, as DiskMonitor does. Give the new monitor its own suitable refresh policy, then add its view to the dropdown or indicator. Do not introduce a shared provider registry until there is an actual need for one. No additional providers are implemented here.

## Validation

```sh
./scripts/test.sh
```

The dependency-free Swift checks cover live startup-disk reads, invalid volume errors, units, color boundaries, preferences restoration/validation, manual refresh, overlap suppression, error recovery, interval changes and a real 15-second automatic refresh. They use an isolated UserDefaults suite and remove it afterward. The final `df -k` output offers an independent capacity comparison (multiply its blocks by 1,024; free bytes may change between samples).

The original version 1.0 universal Release build and checks passed on the development Mac. The app executable stayed running during a short direct-launch smoke check. Launch Services and process visibility were limited in the tool session, so a normal Finder launch remains a manual check. Native UI automation is unavailable in this session, so visually check the colored menu indicator and Settings window when opening the app. Login registration should be checked from the installed copy; the build does not enable it on your behalf.

Suggested UI checks: change prefix and warning threshold, confirm the indicator updates; reopen Settings to confirm values; refresh manually and check the timestamp; close Settings and verify the menu item remains; quit and relaunch; enable login launch from the installed app and verify its entry in System Settings.

Version 1.1 validation: Swift sources type-checked against the installed macOS SDK; history and existing monitoring checks passed, including durable reopening, monthly rollover, aggregation/extrema, exact cleanup boundaries, malformed data preservation, write failures and monitor-to-log integration. The app bundle was intentionally not built, installed or launched for this update; those steps are left to you. Visually check the History and expanded Settings windows after your build.

Version 1.2 validation: existing checks plus targeted directory-cache updates, creation/deletion, exclusions, symlink avoidance, work budgets, durable growth baselines, retention, cooldowns and monitor opt-in/out integration. All Swift sources type-checked for Intel and Apple Silicon. The updated app bundle is intentionally left for the user to build/install. UI, Spotlight results and Time Machine subprocess behavior require manual validation after installation.

## Application icon

The drive-gauge application icon is bundled as `DiskFree/Resources/DiskFree.icns`; its transparent source PNG is in `artwork/AppIcon.png`. It includes standard macOS icon sizes from 16 through 1024 pixels. The menu-bar indicator continues to display its live status colors. Rebuild, quit DiskFree, replace the copy in Applications, and reopen to use the new application icon.

Version 1.3 validation: progressive cursor continuation within a large directory, strict per-slice limits, aggregate fallback at the directory cache limit, inaccessible-child coverage, coverage-change baseline resets, old-cache migration, and legacy-pause recovery/first opening are covered by fixture checks. Existing persistence, disk refresh and history checks remain in the suite. Sources are checked for Intel and Apple Silicon. Building/installing the app and visual validation remain with the user.

### Swap, memory pressure, and power events (1.7)

History now uses one graph. Free space stays blue; optional Docker (orange) and
swap-allocation (purple) lines share its GB axis. Enable either line to compare
levels, or leave it off to retain detail in the free-space curve. Event dots
remain visible without enabling those lines. Purple dots mark measured swap
allocation changes of at least 512 MiB; orange dots mark Docker changes of that
size for the same image. Yellow/red markers indicate sampled memory-pressure
changes, and small bands along the bottom summarize elevated pressure in each
bucket. Teal diamonds mark power and application lifecycle observations; paired
sleep/wake notifications produce a shaded sleep span. Green Time Machine spans
continue to use the existing backup observations.

Hover a marker or span for timing and evidence; click for details, source
measurements, and a Finder link to the monthly record. The Events menu provides
another way to select recent system events. App starts/stops are distinguished
from Mac starts/shutdown requests. `kern.boottime` identifies a restart between
sessions; missing monitoring is labeled a recording gap, never assumed to be
sleep or power-off time. Crashes, forced shutdowns and events while DiskFree is
closed cannot be recorded. Sleep duration measures the interval between macOS
sleep-request and wake notifications, rather than an exact hardware power state.

Two tiny native `sysctl` queries (`vm.swapusage` and
`kern.memorystatus_vm_pressure_level`) run in the background at the existing disk
refresh interval. Unsupported or denied counters remain unavailable. No folder
scan, continuous process tracing, privileged helper, or system-log query is used.
Memory pressure is sampled; transitions between samples may be missed. Swap
allocation, not just swap contents in use, is relevant to disk consumption.
Measurements show correlation and do not attribute every disk change to an app.

Records are append-only monthly `History/System/YYYY-MM.jsonl` files under
`~/Library/Application Support/DiskFree`. Existing history is preserved and the
one-year cleanup action includes system measurements and events. Graph reads
stream records in the background, aggregate samples, and limit visible events
to the latest 500 in the selected range. Earlier swap/power history cannot be
reconstructed. No sample events are inserted into your history for demonstration.

The default Swap and sleep files folder now uses `/System/Volumes/VM` when
present, with `/private/var/vm` as a fallback. Existing default entries migrate
to a new baseline identity so the scope correction does not appear as growth;
custom locations and deliberately removed entries are preserved.

Folder watcher setup runs in the background and coalesces home-folder watches to
one accessible ancestor. The special VM volume is excluded from FSEvents; native
swap counters provide its frequent history. Setup concurrency is bounded so an
unresponsive native watch registration cannot freeze the UI or spawn workers.

### Storage composition and consumer discovery (1.8)

History keeps **Free-space trend** as the initial view. **Storage composition**
uses stacked regions on the same graph. Its scale selector offers:

- **Whole disk:** measured consumers, Other used / system, and free space.
- **Used space:** omits the free region so a mostly empty 1 TB drive remains readable.
- **Tracked consumers:** compares smaller allocated-size estimates separately from
  the overall used total; shared APFS blocks may overlap.

Used space is a total, not an additional region on top of its consumers.
**Other used / system** is the remainder, including macOS, snapshots, inaccessible
and untracked data. It is not Apple's measured System Data category. macOS's
potentially reclaimable estimate overlaps used space and is shown separately in
the inspector, never stacked or described as snapshot-only storage.

Hover a region for totals, consumer sizes, measurement times and nearby events.
Click for saved sources and current cleanup options. Folder measurements use
last completed metadata checks, up to 48 hours old, and are never applied before
their first journal observation. Nested folders are excluded from parent totals;
parents with outdated exclusion scopes are omitted until updated. If consumer
estimates exceed the actual used total, the whole-disk and used-space views keep
a valid used/free split; estimates remain available in details and the tracked
view instead of being silently scaled to fit. Regions use stepwise summaries,
preserve recording gaps, and limit chart density for long time ranges.

Discovery checks a short registry of known storage paths on launch and about
once every 30 minutes while folder tracking is enabled. It uses directory
metadata only, skips symlinks and external/network disks, and never searches the
entire disk or starts applications. Newly found folders join the existing paced
background collector (at most 1 second / 2,000 entries per slice, 30 seconds
between slices). Discovery and folder updates are independent of the disk refresh
interval. Disable discovery in Settings or Investigate; explicitly removed
found folders stay removed. **Discover Now** checks paths again without forcing
an unpaced scan. Custom/moved locations can be added through Add Folder.

Initial definitions cover Ollama, current and legacy LM Studio model stores,
Hugging Face hub/download caches, GPT4All, Gradle/npm/pnpm caches, Android system
images/emulators and Steam's default library. Existing Xcode and device-backup
tracking continues. Docker retains its configured-image metadata provider.
Supported model-cache environment overrides are honored when present in
DiskFree's launch environment; variables set only in an interactive shell are
not visible to an app opened by Finder. This is a registry of common locations,
not a claim to discover every application's custom storage configuration.

The model locations follow the projects' documentation:
[Ollama](https://docs.ollama.com/faq#where-are-models-stored),
[LM Studio](https://lmstudio.ai/docs/app/advanced/import-model),
[Hugging Face](https://huggingface.co/docs/huggingface_hub/en/package_reference/environment_variables),
and [GPT4All](https://docs.gpt4all.io/gpt4all_desktop/settings.html).
To add another common consumer, add a stable `ConsumerDefinition` to
`StorageDiscovery.candidates` and map its ID to a `ConsumerKind`. It automatically
uses the same collector, sparse journal, graph and source inspector.

Completed observations and tracking retirements are stored sparsely in monthly
`History/Consumers/YYYY-MM.jsonl` files. Category growth and scope changes are
reconstructed from this journal, preserving provenance. Native records now also
include the Docker image path and macOS reclaimable estimate when available.
Original free-space CSV files remain compatible and unchanged. One-year history
cleanup includes the consumer journal and preserves malformed files.

Cleanup controls are in the click-to-open inspector, not hover cards. They open
owning apps, reveal folders, open Activity Monitor/macOS Storage, or jump to the
existing Time Machine cleanup section and confirmation flow. DiskFree does not
delete models, containers, package stores or personal files. Models may be used
by background servers/notebooks; unload them and stop downloads before removing
them in their owning tool. Actions concern current storage, not historical files.

### Composition readability (1.8.1)

Every composition scale includes a capacity bar: used/unavailable on the left,
free space on the right, with free GB, percentage, and the configured warning
level. It follows the hovered historical sample, or the latest sample in the
selected range. The neutral remainder region is subdued; event legends use
matching colored symbols and hover cards omit repeated instructions.

Small swap round trips are hidden from event markers and the event menu only
when two adjacent changes exactly cancel within five minutes, peak movement is
at most 2 GiB, all samples report normal memory pressure, and the changes share
an uninterrupted sample. Larger excursions, pressure transitions and recording
gaps remain visible. The saved observations and optional swap line are unchanged.

### Tooltip headings and capture time (1.8.2)

Hover cards lead with a bold category-colored heading (for example, Docker:
38.1 GB). The time axis uses explicit, non-truncated labels, reserving room for
the last recorded sample. A right-aligned Last captured timestamp includes the
full date and seconds, including when viewing older ranges.

Sleep/wake notifications are saved while DiskFree runs and paired into an
observed span. A shutdown notification records a request, not verified power-off.
A changed native boot time identifies a subsequent startup when DiskFree next
launches. App stop/start and recording gaps remain separate; unknown intervals
are not inferred to be sleep or power-off.

### Whole-disk scale and event placement (1.8.3)

Whole disk uses a zero-to-capacity axis, rounded up to the next GB, with explicit
endpoint ticks (for example, 0 and 500). Context events share a row just inside
the chart's top edge; marker height is not a storage measurement. Same-day
recording gaps and sleep spans show their date once; cross-day spans retain both.

### Scale labels and graph key (1.8.4)

All GB-axis numbers use a shared right-aligned label column. The graph footer
omits the optional-line and refresh-interval instructions. Yellow/red bottom
strips identify elevated/critical sampled RAM pressure; vertical green spans
identify observed Time Machine activity. These are context for disk changes,
not additional amounts of disk usage or proof of causation.

### Fixed scale column and shorter tooltips (1.8.5)

Scale numbers are drawn in a single chart-overlay column, avoiding Charts'
automatic endpoint offsets. Measurement tooltips omit the long concurrency
sentence; source data and free-space change remain visible.

Memory-pressure check (no stress load is started by DiskFree):
1. Set refresh to 15 seconds; open History, choose 1 hour, and enable Events.
2. Open Activity Monitor's Memory tab and record two quiet minutes as a baseline.
3. Run a familiar memory-heavy workload, such as your usual Docker build or
   an existing local model. A CPU-only busy loop need not raise RAM pressure.
4. Watch for sustained yellow pressure; allow several 15-second samples, then
   stop the workload. Stop sooner if the Mac becomes sluggish; red is unnecessary.
5. Refresh History. Yellow/red bottom strips should mark elevated/critical
   samples; hover or click for the saved sample and native counter source.
6. After recovery, new normal samples are light green in the pressure row.
   Historical yellow/red samples remain; neutral gaps indicate no recorded reading.

Activity Monitor and DiskFree have different update/aggregation intervals; brief
spikes may fall between DiskFree's samples. Existing swap files alone do not
mean memory pressure is currently elevated. Restore your preferred refresh rate.

### Interactive RAM-pressure test tool

From the repository directory, run the executable Swift script directly:

```sh
./tools/memory-pressure
```

No package manager, third-party libraries, or app rebuild is needed; the script
uses the Swift toolchain included with Xcode/Command Line Tools. Press **1** to
release its allocations, **2** to target yellow pressure, **3** to target red,
and **0** or **Ctrl-C** to release and exit. Enter is unnecessary. Run
`./tools/memory-pressure --check` to print current pressure/RAM without
allocating stress memory; `--help` lists controls.

Save work before testing: this applies real RAM pressure, and red can make the
Mac unresponsive. It allocates random-filled chunks gradually, watches the same
native counter as DiskFree, and stops growing when the target is reached. It
caps allocations at 85% of physical RAM, checks a free-disk reserve (at least
5 GiB or one-eighth of RAM), and releases its memory after five minutes. Targets
are best effort: other apps control their own memory, so 1 cannot guarantee
normal system pressure and the cap may prevent reaching yellow/red. Releasing
memory does not guarantee macOS immediately shrinks its swap files.

For DiskFree validation, enable Events and a 15-second refresh, observe baseline,
select 2 until several yellow samples are recorded, then press 1. Red is optional
and unnecessary to validate the warning strip. Restore your usual refresh rate.

### Dedicated memory-pressure row (1.8.6)

Memory pressure is always shown in an eight-point row attached directly below
its graph's lower GB baseline. It remains visible with Events turned off and
shares the same time coordinates, without moving the time labels. Normal samples
are light green, elevated samples yellow, critical samples red. Neutral gaps
mean no known pressure reading; they are never filled as normal. Hover/click the
row for the highest observed pressure in that time bucket and its saved source.
Sampling intervals and saved history are unchanged; no additional polling occurs.

### History alignment during pressure tests (1.8.7)

Disk, Docker and native-system histories now share a whole-second bucket origin.
This handles existing CSV millisecond timestamps and JSON whole-second timestamps
without putting same-refresh readings into neighboring minute summaries. At
15-second sampling, that mismatch previously hid fresh native consumer regions
as if their measurements had expired. Original journals are unchanged; existing
history is corrected when read. Actual missing/stale readings remain unavailable.
Scale labels retain a fixed right edge with a measured column width and a
six-point gap beside the plot instead of a wide empty gutter.

### History paging (1.9)

History windows load as complete frames. The current graph stays visible until
all sources are ready, then previous/next navigation uses a 0.3-second ease-in-out
slide. Reduce Motion uses a short fade. Axes and regions always belong to the
same immutable frame; live updates do not replay the paging transition.

History retains up to twelve aggregate pages across window closes during the app
session, within a conservative estimated 24 MiB cache budget, and warms immediate neighbors. Repeated redraws and cached navigation do not reread logs.
Background readers are bounded; rapid clicks supersede earlier display requests.
Refresh and history cleanup invalidate the cache. Closing History cancels pending
work and retains completed cached pages until eviction or app exit. No extra monitoring timer or disk writes.

### Verified Time Machine history (1.10)

Backup detection still uses one background `tmutil status` check per minute. On launch and state transitions, DiskFree queries narrowly filtered `backupd` unified-log messages for the preceding six hours. These queries run in the background with a 15-second timeout and 4 MiB output limit. Queries that hit their limit are split into smaller windows, down to one hour. They do not mount a destination, run a backup, or request administrator access.

A checkpointed, one-time import queries the preceding 30 days in daily slices. Only records still retained and readable by macOS can be restored. Queries are deduplicated into `History/Backups/TimeMachine/YYYY-MM.jsonl`; `import-v1.json` records import progress. Existing observation CSV files are preserved. History retention also applies to the imported evidence. No historical disk-space samples are invented.

Graph spans use native start/completion timestamps when present. Only explicit session-level completion, failure or cancellation records determine the outcome; component errors and intermediate progress dictionaries do not. Hover shows the result, copied size and file count when available. Click opens duration, destination, reported backup contents/destination free space, and the saved source messages. Missing log fields remain unavailable. Copied files come from per-volume copy summaries; progress item counts are a fallback, and preflight size estimates are never presented as actual copied bytes.

### Space-change milestones (1.11)

History marks net gains/losses of at least 5 GB in a burst lasting at most five minutes. Same-direction movements are grouped, small jitter is ignored, and a reversal, 90 quiet seconds or interrupted coverage ends the burst. Detection uses original samples before chart aggregation; it never bridges app sessions, boots or missing samples. The star sits at the last measurement in the burst. Hover gives the time and before/after space; click opens the report.

Reports compare native swap allocation and the same Docker image's allocated blocks. Unknown changes trigger a narrow, read-only unified-log query around the event, limited to 15 seconds and 512 KiB per query. Queries are serialized at utility priority, checking Time Machine first and explicit system reclamation messages if no snapshot deletion is found. Pure matching swap/image changes need no log query. Time Machine evidence must explicitly record local snapshot deletion on the startup Data volume; destination-drive pruning, purgeable estimates and cache-size queries are not cleanup evidence. Snapshot deletion sizes are not inferred from the space delta.

Existing folder measurements can add nearby changes for Trash, downloads, caches, models, developer tools and games, including automatically discovered Ollama, LM Studio, Hugging Face, GPT4All, Steam and package stores. These require matching folder identity, scope and coverage, with actual measurements bracketing the burst within 30 minutes. They are reported with their measurement times, never added together as an exact disk-space explanation. Folder evidence is refreshed when opening a cached report. No new folder scans, Docker daemon calls or vendor-log crawls are triggered by a space change.

Reports are saved atomically under `History/SpaceChanges/YYYY-MM/` and follow history retention. Live detection uses a constant-size in-memory state. On launch, the last seven days of the existing system journal are read once and up to twelve recent milestones get reports automatically; others are investigated when clicked. Reading a chart or hovering never runs a log query. Reports retain unknown causes and unavailable logs rather than inventing an explanation. No cleanup is executed.

### Files behind milestones (1.12)

Space-change reports include up to eight suspect files and a Reveal action. A bounded native Spotlight query searches the home folder for files of at least 100 MB created or modified near a space-loss interval. Searches run only for milestones, are serialized, stop after eight seconds and inspect at most 80 results. Actual allocated blocks are read with `lstat`; logical size alone does not qualify a sparse file. Candidates must be regular files on the startup Data device. File contents are never read or hydrated.

A home-folder FSEvents stream supplements Spotlight for unindexed model stores and other paths. It uses file notifications with a three-second latency; one utility-queue batch every ten seconds checks at most 128 paths. Pending paths, large-file baselines and recent observations are capped at 256, 512 and 512 respectively. Only significant allocated files (100 MB or more) retain observations, for up to 30 minutes. There is no initial traversal, per-refresh scan, process tracing or rescan after dropped events. Missing coverage is recorded. Renames alone do not establish freed space; deletion evidence needs an earlier measured file. External volumes, symlinks and directories do not become candidates.

Findings distinguish creation, measured growth/shrinkage, removal and other nearby changes. Metadata timestamps and current size are clues, not proof of a precise contribution to free space; APFS snapshots and shared blocks can affect reclamation. Saved report JSON contains candidate paths, sizes, metadata times, source, event ID/flags and before/after observations where available. Only report findings are persisted; the change-path buffer stays in memory. Findings follow report retention, survive restart and rechecks, and are reused when reopening reports. Legacy reports gain file findings when opened without requerying their recorded logs. Check Again is throttled to one minute. There are no automatic deletions or new destructive actions.


### On-demand app leftovers (1.13)

Investigate offers Find App Leftovers and Saved Results. Only Find starts work: one bounded Spotlight app-inventory query, a bounded pass through standard app locations, then metadata-only measurements of possible orphan folders directly under the user's Application Support. The check runs at utility priority with progress and Cancel. No watcher, repeating timer, startup scan, or refresh-interval work was added. Saved Results reads the last JSON only.

App names, bundle identifiers, running/registered apps and previously recorded app names inform matches. Apple/system folders and shared vendor roots are excluded; related installed publisher apps suppress cleanup suggestions. Trash and Time Machine backup copies do not count as installed apps. Uncertain names offer Finder and Keep, with no cleanup button. Size estimates use allocated blocks, avoid symlinks/cross-volume traversal and deduplicate hardlinks; matching complete size caches under 24 hours can be reused. Each folder is bounded to 25,000 entries/3 seconds; the support check is capped at 512 folders/120 seconds. Partial sizes are labeled; inaccessible folders do not interrupt the other results.

Latest results, app-name history and Keep choices are saved atomically in `~/Library/Application Support/DiskFree/AppLeftovers/results.json`. Cancel keeps prior saved results. Move to Trash requires confirmation, a fresh complete app inventory and running/registered-app check, plus unchanged parent and folder identities. Kept, uncertain, replaced or symlinked folders are rejected. Data is moved through the normal macOS Trash API; no permanent deletion or emptying of Trash is implemented. App absence is a clue, not proof the data is unwanted; the confirmation notes that personal data/models may be present.


### History loading and keyboard-accessible windows (1.14)

A visible circular progress indicator follows the five history sources. Streaming readers report bytes consumed from the selected monthly journals against their known file sizes; the visual indicator stays in a fixed 20-point header slot without loading text. Source details remain available to accessibility tools. The circle advances across sources, not a predicted time-to-completion. Preparation and steps without known byte totals use a spinner. The previous complete chart stays visible until replacement; cached navigation avoids journal reads. The cache stores aggregate pages, not a year of raw records. Larger pages may be evicted or left uncached to meet the estimated budget. Explicit Refresh and history cleanup invalidate cached pages. The range and graph choice persist across relaunch; historical navigation position is retained across window closes in the current app session. Live source updates continue to advance the visible graph.

History, Investigate and Settings temporarily make DiskFree a regular Mac app while any main window is open. DiskFree then appears in the Dock and Cmd-Tab; the Window menu lists its main windows. Cmd-` cycles windows according to macOS settings. Closing all main windows returns to menu-bar-only operation; minimized windows still count as open. Secondary sheets (reports, app leftovers and confirmations) remain attached to their parent. The menu popup remains transient. No always-on Dock icon or new monitoring timer is introduced.


### Shared historical data and thin loading ring (1.15)

The loading indicator uses a custom 14-point ring with a 1.6-point accent stroke inside the existing fixed 20-point slot. It retains determinate source progress and a rotating arc when work is unknown, respects Reduce Motion, and displays no loading text.

The page cache reuses grid-aligned narrower suffixes at the same aggregation interval: the one-hour, six-hour and 24-hour views share one-minute summaries. Cropping retains measurements, event evidence, pressure maxima, backup spans and composition frames; truncated event archives are reloaded instead of silently dropping evidence. Short-range system archives retain up to 8,192 events for safe reuse while rendering remains capped. Valid history with malformed-row notices is cacheable; real read failures remain retryable. Live endpoints are rounded up to a whole second to preserve the shared bucket grid without excluding the latest fractional-second sample.

A second shared cache retains parsed monthly free-space, Docker, native system, folder and backup journals within an estimated 24 MiB budget and 48-file limit. Unchanged journals use metadata checks without rereading or decoding file contents. Append growth verifies the existing prefix/boundary and decodes only the new tail. Partial last lines are reparsed when completed; inode replacement, shrinkage, timestamp changes and common in-place rewrites invalidate the cached contents. Repeating native session IDs and Docker metadata share string storage. Larger journals stream without unbounded retention. The independent aggregate-page cache keeps its estimated 24 MiB budget. These are cache estimates, not a cap on total app memory.

Different aggregation levels can rebuild from parsed memory without rereading journals; eviction, first access or app restart can require a cold load. Source updates can invalidate rendered pages while preserving parsed records. Explicit Refresh and history cleanup clear both layers. The native journals remain the source of truth and are not migrated or modified by caching. No new monitoring timer is introduced.
