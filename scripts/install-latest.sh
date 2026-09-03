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

# Installs the newest build of the fork's `main` on this Mac.
#
#   scripts/install-latest.sh [commit]
#
# With a commit (full or short SHA), waits for that commit's CI run on `main`
# to succeed and checks that the `latest` pre-release was cut from it, so a
# stale zip is never installed as if it were the new one. Without a commit,
# installs whatever `latest` currently is.
#
# The build CI publishes is ad-hoc signed, and an ad-hoc signature changes with
# every build — macOS keys the Accessibility and Microphone grants to the
# signature, so each new build would ask for them again. The app is therefore
# re-signed here with a STABLE local identity before it is installed. That is
# also why this is a fork-only tool: the result is an unnotarized Debug build
# for the machine it is installed on, never something to hand to anyone.
#
#   JOT_FORK           owner/repo of the fork      (default madavic/jot-gemini-transcribe-macOS)
#   JOT_SIGN_IDENTITY  codesigning identity name   (default "Masko Code Dev")
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${JOT_FORK:-madavic/jot-gemini-transcribe-macOS}"
IDENTITY="${JOT_SIGN_IDENTITY:-Masko Code Dev}"
WANT="${1:-}"
API="https://api.github.com/repos/$REPO"
ZIP_URL="https://github.com/$REPO/releases/download/latest/Jot-latest.zip"
APP=/Applications/Jot.app

for tool in curl jq codesign ditto xattr; do
  command -v "$tool" >/dev/null || { echo "✗ $tool is required" >&2; exit 1; }
done
security find-identity -v -p codesigning | grep -q "\"$IDENTITY\"" \
  || { echo "✗ no codesigning identity named \"$IDENTITY\" in the keychain (security find-identity -v -p codesigning)" >&2; exit 1; }

if [ -n "$WANT" ]; then
  echo "▸ Waiting for CI on main@${WANT:0:7}"
  for _ in $(seq 1 90); do # up to 15 minutes
    line=$(curl -fsS "$API/actions/runs?branch=main&per_page=10" \
      | jq -r --arg sha "$WANT" '.workflow_runs[] | select(.name == "CI") | select(.head_sha | startswith($sha)) | "\(.status) \(.conclusion) \(.html_url)"' \
      | head -1)
    if [ -z "$line" ]; then
      echo "  no run for that commit yet — are Actions enabled on https://github.com/$REPO/actions ?"
      sleep 10
      continue
    fi
    read -r status conclusion url <<<"$line"
    if [ "$status" = completed ]; then
      [ "$conclusion" = success ] || { echo "✗ CI $conclusion: $url" >&2; exit 1; }
      echo "  CI succeeded: $url"
      break
    fi
    echo "  $status…"
    sleep 10
  done
  target=$(curl -fsS "$API/releases/tags/latest" | jq -r '.target_commitish // ""')
  case "$target" in
    "$WANT"*) ;;
    *) echo "✗ the latest release was cut from ${target:0:7}, not ${WANT:0:7} — not installing" >&2; exit 1 ;;
  esac
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "▸ Downloading $ZIP_URL"
curl -fL --progress-bar -o "$TMP/Jot-latest.zip" "$ZIP_URL"
ditto -x -k "$TMP/Jot-latest.zip" "$TMP"
[ -d "$TMP/Jot.app" ] || { echo "✗ the zip did not contain Jot.app" >&2; exit 1; }

echo "▸ Re-signing with \"$IDENTITY\""
codesign --force --deep --sign "$IDENTITY" --entitlements App/Jot.entitlements "$TMP/Jot.app"
xattr -dr com.apple.quarantine "$TMP/Jot.app" 2>/dev/null || true

echo "▸ Installing to $APP"
osascript -e 'tell application "Jot" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$APP"
ditto "$TMP/Jot.app" "$APP"
open -a "$APP"

version=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
build=$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)
authority=$(codesign -dv --verbose=2 "$APP" 2>&1 | grep -m1 '^Authority=' | cut -d= -f2-)
echo "✓ Jot $version ($build) installed, signed by $authority${WANT:+, built from main@${WANT:0:7}}"
