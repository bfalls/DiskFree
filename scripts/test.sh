#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/checks
xcrun swiftc -module-cache-path build/checks/module-cache -parse-as-library DiskFree/StatisticsProvider.swift DiskFree/Preferences.swift \
  DiskFree/DiskMonitor.swift DiskFree/HistoryStore.swift Tests/Checks.swift -o build/checks/DiskFreeChecks
build/checks/DiskFreeChecks
printf '\nCompare available blocks below (1 block = 1,024 bytes):\n'
df -k /System/Volumes/Data
