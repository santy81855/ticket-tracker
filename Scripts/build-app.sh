#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
identifier="com.tickettracker.local"
if [ "${1:-}" = "--ui-validation" ]; then
  configuration="debug"
  identifier="com.tickettracker.local.validation"
fi
if [ "${1:-}" = "--theme-preview" ]; then
  configuration="debug"
  identifier="com.tickettracker.local.preview"
fi
bash Scripts/swift.sh build -c "$configuration"
bin="$(bash Scripts/swift.sh build -c "$configuration" --show-bin-path)"
output="$HOME/Library/Caches/TicketTracker/Apps/$(date +%Y%m%d-%H%M%S)-$$"
app="$output/Ticket Tracker.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Configuration/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier" "$app/Contents/Info.plist"
cp "$bin/TicketTracker" "$app/Contents/MacOS/TicketTracker"
cp "$bin/ticket-tracker" "$app/Contents/MacOS/ticket-tracker"
for resource in "$bin"/*.bundle; do
  if [ -d "$resource" ]; then
    ditto "$resource" "$app/Contents/Resources/$(basename "$resource")"
  fi
done
xcrun swift Scripts/MakeIcon.swift "$output/AppIcon.iconset"
iconutil -c icns "$output/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$app/Contents/MacOS/ticket-tracker"
codesign --force --sign - --timestamp=none --identifier "$identifier" "$app"
codesign --verify --strict --verbose=2 "$app"
if [ "${1:-}" = "--install" ]; then
  destination="$HOME/Applications/Ticket Tracker.app"
  mkdir -p "$HOME/Applications"
  if [ -e "$destination" ]; then
    identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist")"
    if [ "$identifier" != "com.tickettracker.local" ]; then
      printf 'Refusing to replace an app not owned by Ticket Tracker.\n' >&2
      exit 1
    fi
    if pgrep -f "^$destination/Contents/MacOS/TicketTracker" >/dev/null; then
      printf 'Quit Ticket Tracker before updating the installed app.\n' >&2
      exit 1
    fi
    mkdir -p "$HOME/Library/Caches/TicketTracker/PreviousApps"
    mv "$destination" "$HOME/Library/Caches/TicketTracker/PreviousApps/$(date +%Y%m%d-%H%M%S)-$$.app"
  fi
  ditto "$app" "$destination"
  codesign --verify --strict "$destination"
  printf '\nInstalled: %s\n' "$destination"
else
  printf '\nBuilt: %s\n' "$app"
fi
