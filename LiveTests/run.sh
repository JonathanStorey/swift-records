#!/bin/bash
# Builds the live app, signed for your team, and runs it with these arguments. See README.md.
set -euo pipefail
cd "$(dirname "$0")"
xcodebuild build -project SwiftRecordsLive.xcodeproj -scheme SwiftRecordsLive -configuration Debug \
  -derivedDataPath .build -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation -quiet
exec .build/Build/Products/Debug/SwiftRecordsLive.app/Contents/MacOS/SwiftRecordsLive "$@"
