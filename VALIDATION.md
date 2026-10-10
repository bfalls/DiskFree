# Version 1.1 validation — October 10, 2026

Environment: macOS 13.7.8; Xcode 15.2; macOS SDK 14.2; Swift 5.9.2.

This update leaves app building and installation to the user. No updated application bundle was built, installed or launched.

- Swift type-check: macOS 13 deployment target, including Swift Charts and all UI sources.
- Existing capacity, formatting, threshold, persistence, refresh interval, automatic/manual refresh, overlap and recovery checks.
- History: monthly rollover, reopening durable CSVs, exact cutoff-month cleanup, newer/cutoff samples preserved, repeated cleanup, bounded chart aggregation, minimum/maximum preservation, missing buckets, malformed tail recovery/preservation, and write errors.
- Monitor integration: each successful refresh logged; a failed disk read not logged.

Run `./scripts/test.sh` to repeat the checks. Test logs use disposable temporary directories and preferences use a disposable suite. Existing personal history is untouched.

After building: visually check History time ranges, previous/next, Live, sample inspection, empty ranges and Settings cleanup confirmation. Check that closing/reopening the graph refreshes its contents and starting another app copy leaves a single indicator. These UI/runtime behaviors were not exercised by native desktop automation here.
