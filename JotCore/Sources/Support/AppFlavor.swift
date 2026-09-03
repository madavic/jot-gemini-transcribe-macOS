// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// Which Jot this process is.
///
/// One codebase, two apps that can sit side by side in /Applications: the real
/// `Jot` (bundle `com.ammaar.jot`) and a development build, `Jot Dev`
/// (`com.ammaar.jot.dev`), produced by passing `PRODUCT_NAME` and
/// `PRODUCT_BUNDLE_IDENTIFIER` to xcodebuild. The bundle identifier is the only
/// input; everything that persists is keyed off it here, in one place, so the
/// two apps never touch each other's state:
///
/// - **Keychain.** The API key item's ACL belongs to the app that created it. A
///   dev build reading the release app's item, under a different signature,
///   gets a permission dialog on every read — and the app reads the key on
///   every request. A separate service name means the dev build creates and
///   owns its own item, and asks once, in onboarding.
/// - **Application Support.** History, recordings and the SQLite store. Two
///   processes over one database and one recordings folder would race the
///   recovery scanner and the retention sweep against each other.
/// - **UserDefaults and TCC** separate on their own, by bundle identifier.
///
/// For the release bundle every value below is byte-identical to what shipped,
/// so existing users keep their key, their history and their grants.
public enum AppFlavor {
    public static let releaseBundleID = "com.ammaar.jot"

    /// The main bundle's identifier. In the test runner this is xctest's, which
    /// resolves to the release values — tests sandbox `FileLayout` anyway and
    /// never touch the real Keychain.
    public static let bundleID: String = Bundle.main.bundleIdentifier ?? releaseBundleID

    /// True for the fork's own builds, `Jot Dev`.
    public static var isDev: Bool { bundleID.hasSuffix(".dev") }

    public static var displayName: String { isDev ? "Jot Dev" : "Jot" }

    /// `kSecAttrService` of the API key item. MUST stay `com.ammaar.jot` for the
    /// release flavor — changing it silently loses every user's key.
    public static var keychainService: String { isDev ? "\(releaseBundleID).dev" : releaseBundleID }

    /// Folder name under ~/Library/Application Support.
    public static var supportDirectoryName: String { displayName }
}
