#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/checks
xcrun swiftc -O -module-cache-path build/checks/module-cache -parse-as-library DiskFree/StatisticsProvider.swift DiskFree/DockerDiskStatistics.swift DiskFree/Preferences.swift \
  DiskFree/DiskMonitor.swift DiskFree/BackupContext.swift DiskFree/BackupHistory.swift DiskFree/BackupLog.swift DiskFree/SpaceChanges.swift DiskFree/FileSuspects.swift DiskFree/AppLeftovers.swift DiskFree/SystemHistory.swift DiskFree/StorageComposition.swift DiskFree/HistoryStore.swift DiskFree/GrowthStore.swift DiskFree/GrowthMonitor.swift Tests/GrowthChecks.swift Tests/DockerChecks.swift Tests/BackupHistoryChecks.swift Tests/BackupLogChecks.swift Tests/SpaceChangeChecks.swift Tests/FileSuspectChecks.swift Tests/AppLeftoverChecks.swift Tests/HistoryLoadingChecks.swift Tests/HistoryReuseChecks.swift Tests/SystemHistoryChecks.swift Tests/StorageCompositionChecks.swift Tests/Checks.swift -o build/checks/DiskFreeChecks
build/checks/DiskFreeChecks "$@"
printf '\nCompare available blocks below (1 block = 1,024 bytes):\n'
df -k /System/Volumes/Data
