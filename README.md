# DiskFree

A tiny native macOS menu bar app showing immediately available space on the startup disk, with durable monthly history logs and a native history graph. Swift, SwiftUI, Swift Charts, AppKit, Foundation and ServiceManagement only. No dependencies, network requests, helper services or privileged processes.

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

## Updating an existing installation (version 1.1)

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

To add a statistic, define a Sendable snapshot and a struct conforming to `StatisticsProvider`, then implement `collect()`. Keep collection synchronous inside the provider and dispatch it off the main actor in a small monitor, as DiskMonitor does. Give the new monitor its own suitable refresh policy, then add its view to the dropdown or indicator. Do not introduce a shared provider registry until there is an actual need for one. No additional providers are implemented here.

## Validation

```sh
./scripts/test.sh
```

The dependency-free Swift checks cover live startup-disk reads, invalid volume errors, units, color boundaries, preferences restoration/validation, manual refresh, overlap suppression, error recovery, interval changes and a real 15-second automatic refresh. They use an isolated UserDefaults suite and remove it afterward. The final `df -k` output offers an independent capacity comparison (multiply its blocks by 1,024; free bytes may change between samples).

The original version 1.0 universal Release build and checks passed on the development Mac. The app executable stayed running during a short direct-launch smoke check. Launch Services and process visibility were limited in the tool session, so a normal Finder launch remains a manual check. Native UI automation is unavailable in this session, so visually check the colored menu indicator and Settings window when opening the app. Login registration should be checked from the installed copy; the build does not enable it on your behalf.

Suggested UI checks: change prefix and warning threshold, confirm the indicator updates; reopen Settings to confirm values; refresh manually and check the timestamp; close Settings and verify the menu item remains; quit and relaunch; enable login launch from the installed app and verify its entry in System Settings.

Version 1.1 validation: Swift sources type-checked against the installed macOS SDK; history and existing monitoring checks passed, including durable reopening, monthly rollover, aggregation/extrema, exact cleanup boundaries, malformed data preservation, write failures and monitor-to-log integration. The app bundle was intentionally not built, installed or launched for this update; those steps are left to you. Visually check the History and expanded Settings windows after your build.
