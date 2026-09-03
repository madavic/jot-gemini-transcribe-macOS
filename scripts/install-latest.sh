#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Installs the newest "Jot Dev" build of the fork's `main` on this Mac, next to
# the real Jot.
#
#   scripts/install-latest.sh [commit]
#
# With a commit (full or short SHA), waits for that commit's CI run on `main`
# to succeed and checks that the `latest` pre-release was cut from it, so a
# stale zip is never installed as if it were the new one. Without a commit,
# installs whatever `latest` currently is.
#
# Jot Dev is its own app (bundle com.ammaar.jot.dev, see AppFlavor.swift): its
# own Keychain item, Application Support folder, defaults and permissions.
# This script never touches /Applications/Jot.app. It does quit a running Jot
# before launching Jot Dev, because both listen to the same dictation key.
#
# The build CI publishes is ad-hoc signed, and an ad-hoc signature changes with
# every build — macOS keys the Accessibility and Microphone grants to the
# signature, so each new build would ask for them again. The app is therefore
# re-signed here with a STABLE local identity before it is installed. That is
# also why this is a fork-only tool: the result is an unnotarized Debug build
# for the machine it is installed on, never something to hand to anyone.
#
#   JOT_FORK           owner/repo of the fork      (default madavic/jot-gemini-transcribe-macOS)
#   JOT_SIGN_IDENTITY  codesigning identity name   (default "Jot Dev")
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${JOT_FORK:-madavic/jot-gemini-transcribe-macOS}"
IDENTITY="${JOT_SIGN_IDENTITY:-Jot Dev}"
WANT="${1:-}"
API="https://api.github.com/repos/$REPO"
ZIP_URL="https://github.com/$REPO/releases/download/latest/Jot-Dev-latest.zip"
APP="/Applications/Jot Dev.app"
BUNDLE_ID="com.ammaar.jot.dev"

for tool in curl jq codesign ditto xattr; do
  command -v "$tool" >/dev/null || { echo "✗ $tool is required" >&2; exit 1; }
done
security find-identity -v -p codesigning | grep -q "\"$IDENTITY\"" \
  || { echo "✗ no codesigning identity named \"$IDENTITY\" in the keychain (security find-identity -v -p codesigning)" >&2; exit 1; }

# Unauthenticated, the GitHub API allows 60 requests an hour per address. The
# release PAGE on github.com is not metered, and its title carries the short
# SHA the build was cut from, so that is what the wait watches. The API is
# consulted only once, at the end, to tell a failed run from a slow one.
release_sha() {
  curl -fsSL "https://github.com/$REPO/releases/tag/latest" \
    | sed -n 's/.*Latest Jot Dev build of main (\([0-9a-f]*\)).*/\1/p' | head -1
}

if [ -n "$WANT" ]; then
  echo "▸ Waiting for CI on main@${WANT:0:7}"
  ready=""
  tick=0
  while [ "$tick" -lt 60 ]; do # up to 30 minutes
    current=$(release_sha || true)
    if [ -n "$current" ]; then
      # Either may be the shorter spelling of the same commit.
      case "$WANT" in "$current"*) ready=1 ;; esac
      case "$current" in "$WANT"*) ready=1 ;; esac
      [ -n "$ready" ] && break
    fi
    # Every two minutes, one metered API call: has the run already failed?
    # Without this a red build would only surface as a 30-minute timeout.
    if [ $((tick % 4)) -eq 0 ]; then
      verdict=$(curl -fsS "$API/actions/runs?branch=main&per_page=5" 2>/dev/null \
        | jq -r --arg sha "$WANT" '.workflow_runs[] | select(.name == "CI") | select(.head_sha | startswith($sha)) | "\(.status) \(.conclusion) \(.html_url)"' \
        | head -1 || true)
      case "$verdict" in
        "completed failure"*|"completed cancelled"*) echo "✗ CI ${verdict#completed }" >&2; exit 1 ;;
      esac
    fi
    echo "  waiting (latest release is ${current:-none}, want ${WANT:0:7})…"
    sleep 30
    tick=$((tick + 1))
  done
  [ -n "$ready" ] || { echo "✗ no build of ${WANT:0:7} after 30 minutes — check https://github.com/$REPO/actions" >&2; exit 1; }
  echo "  build of ${WANT:0:7} is published"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "▸ Downloading $ZIP_URL"
curl -fL --progress-bar -o "$TMP/Jot-Dev-latest.zip" "$ZIP_URL"
ditto -x -k "$TMP/Jot-Dev-latest.zip" "$TMP"
[ -d "$TMP/Jot Dev.app" ] || { echo "✗ the zip did not contain Jot Dev.app" >&2; exit 1; }
# Never let a zip built with the release identifiers land here: that app would
# share the real Jot's Keychain item and data, which is the whole thing this
# flavor exists to avoid.
built_id=$(defaults read "$TMP/Jot Dev.app/Contents/Info.plist" CFBundleIdentifier)
[ "$built_id" = "$BUNDLE_ID" ] || { echo "✗ the build identifies as $built_id, expected $BUNDLE_ID — not installing" >&2; exit 1; }

echo "▸ Re-signing with \"$IDENTITY\""
codesign --force --deep --sign "$IDENTITY" --entitlements App/Jot.entitlements "$TMP/Jot Dev.app"
xattr -dr com.apple.quarantine "$TMP/Jot Dev.app" 2>/dev/null || true

echo "▸ Installing to $APP"
# Both apps grab the dictation key; only one may run. The real Jot stays
# installed and is one click away in Launchpad when it is wanted back.
osascript -e 'tell application "Jot Dev" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "Jot" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$APP"
ditto "$TMP/Jot Dev.app" "$APP"
open -a "$APP"

version=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
build=$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)
# No pipe here: `grep -m1` closing the pipe early gave codesign a SIGPIPE,
# and under pipefail that failed the whole script after a successful install.
signature=$(codesign -dv --verbose=2 "$APP" 2>&1 || true)
authority="unknown"
while IFS= read -r line; do
  case "$line" in Authority=*) authority=${line#Authority=}; break ;; esac
done <<<"$signature"
echo "✓ Jot Dev $version ($build) installed, signed by $authority${WANT:+, built from main@${WANT:0:7}}"
