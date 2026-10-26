# Navigation SDK for iOS: init/quota request retry loop

A minimal UIKit app (no React Native) for a bug report about Google Navigation SDK for iOS 11.1.0.

**The bug:** when the SDK's navigation init/quota request fails, the SDK retries it with no backoff, on the main thread, for as long as it keeps failing. That uses 40–160 % CPU while the app is idle, and each attempt writes `NSUserDefaults` (about 1,000 writes a second).

**The quickest way to see it:** call a `GMSNavigationServices` API while the terms haven't been accepted. Even `areTermsAndConditionsAccepted` starts the loop, and so does the terms dialog while it's open. Accepting the terms stops it.

## Quick reproduction

1. Do the setup below and install the app on an iPhone or a simulator.
2. Launch it with `-navSession YES -resetTerms YES`. The terms dialog appears.
3. Leave the dialog open and watch **CPU** and **defaults writes/s** in the panel (or the `stats` lines in the console).
4. Tap OK. Both drop to near zero.

Without the dialog: `-navSession YES -resetTerms YES -skipTermsDialog YES` calls `createNavigationSession` only. Adding `-termsCheckOnly YES` calls `areTermsAndConditionsAccepted` only.

Recording a device run from the command line (note the `--` before the app's arguments):

```sh
xcrun devicectl device process launch --device <UDID> --terminate-existing --console \
  com.example.navsdkretryrepro -- -mode off -navSession YES -resetTerms YES
```

## Background: marker updates

The app started as a test of a first theory: that marker updates trigger the loop. That theory isn't supported. The app updates markers the same way `@googlemaps/react-native-navigation-sdk` 0.17.3 does. When JS calls `addMarker` with an id that already exists, the wrapper:

1. builds a temporary `GMSMarker`, setting `[UIImage imageNamed:]` as its icon when one is given (`NavViewModule.mm`);
2. copies the temporary marker's properties onto the existing marker, including the icon (`NavViewController addMarker:visible:result:` → `ObjectTranslationUtil updateMarker:…`).

The app does the same with 10 markers every 0.25 s (40 calls per second). Those controls are still there (modes, Recreate map).

## Setup

1. `cp Secrets.example.xcconfig Secrets.xcconfig`, then fill it in:
   - `GMS_API_KEY`: a key whose project has the Navigation SDK enabled. If the key is restricted to iOS apps, add `REPRO_BUNDLE_ID` to its allowed bundle IDs. Otherwise the map stays blank and the SDK's requests fail for an unrelated reason.
   - `DEVELOPMENT_TEAM`: your team ID (device builds only).
2. Open `NavSDKRetryRepro.xcodeproj`. Swift Package Manager fetches Navigation SDK 11.1.0 and Maps SDK 11.1.0 (both pinned exactly).

Command-line builds:

```sh
# Simulator
xcodebuild -project NavSDKRetryRepro.xcodeproj -scheme NavSDKRetryRepro \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build -onlyUsePackageVersionsFromResolvedFile build

# Device
xcodebuild -project NavSDKRetryRepro.xcodeproj -scheme NavSDKRetryRepro \
  -destination 'id=<UDID>' -allowProvisioningUpdates \
  -derivedDataPath build -onlyUsePackageVersionsFromResolvedFile build
xcrun devicectl device install app --device <UDID> \
  build/Build/Products/Debug-iphoneos/NavSDKRetryRepro.app
```

## What the app shows

The panel at the bottom has:

- **Off / Default pin / Custom icon**: the mode. Off makes no marker calls. Default pin re-adds markers without an icon. Custom icon re-adds them with an asset-catalog image, as the wrapper's `imgPath` does.
- **Recreate map**: replaces the map view with a new one (the RN app created one per screen visit).
- **Settings forwarding**: on each defaults change, does what React Native's `RCTSettingsManager` does (reads the whole defaults dictionary, cleans it for JSON and serialises it).
- **Navigation session**: shows the terms dialog if needed, then creates and starts a navigation session and attaches it to the map. Turning it off stops the session and recreates the map.
- **CPU (all threads)**: the process's CPU, as in Xcode's gauge (100 % = one core).
- **defaults writes/s**: `NSUserDefaultsDidChangeNotification`s per second. React Native's `RCTSettingsManager` sends the whole defaults dictionary to JS on each one.
- **off main / not standard**: defaults changes posted off the main thread, and from an `NSUserDefaults` instance other than the standard one.
- **addMarker calls** and **maps created**.

The same numbers are logged once a second (subsystem `navsdk-retry-repro`, category `stats`).

Launch arguments:

- `-mode customIcon` (or `defaultPin`, `off`) starts in that mode.
- `-skipTemporaryMarker YES` updates existing markers directly, without building the temporary `GMSMarker`. This is a diagnostic, not what the wrapper does.
- `-settingsForwarding YES` and `-navSession YES` turn the two switches on at launch.
- `-resetTerms YES` calls `resetTermsAndConditionsAccepted` first, so the terms dialog shows again.
- `-skipTermsDialog YES` (with `-navSession YES`) calls `createNavigationSession` without the dialog. Adding `-termsCheckOnly YES` makes it call only `areTermsAndConditionsAccepted`.
- `-logDefaultsKeys YES` logs, for each defaults change, the keys that changed and the code that wrote them (`defaults writer:` lines).

## Marker steps (background)

1. Install on an iPhone (the loop was not seen in the simulator).
2. Leave it on **Off** for 30 s. CPU and defaults writes/s should be near 0.
3. Switch to **Custom icon**, and tap **Recreate map** every 10–20 s for a few minutes.
4. Switch back to **Off** and wait 30 s.
5. If the loop started, CPU stays high and defaults writes/s keeps counting with no marker calls. Confirm in Instruments (Time Profiler, main thread): `GMSNavigationQuotaService sendNavigationInitRequestWithHandler:` → `GMSDASHProtobufferRequest scheduleRetryIfApplicableForResponse:error:connection:`.
6. Repeat with **Default pin** as the control.

For the DNS case, launch the app on a network whose DNS blocks a Google endpoint (seen with a Pi-hole), in Off mode.

## Results so far

iOS 27.0 simulator, Xcode 27.0, 2026-10-26, 12–25 s per run:

| Mode | addMarker calls/s | defaults writes/s |
|---|---|---|
| Off | 0 | 0 |
| Default pin | 40 | 40 |
| Custom icon | 40 | 40 |
| Default pin, `-skipTemporaryMarker YES` | 40 | 0 |
| Custom icon, `-skipTemporaryMarker YES` | 40 | 0 |

- **Every new `GMSMarker` writes `NSUserDefaults` once, with or without an icon.** Updating an existing marker writes nothing. So the wrapper's temporary marker turns every `addMarker` call into a defaults write.
- **The simulator showed no retry loop.** CPU stayed under ~60 % while markers were added, and under ~10 % after that.
- **The map loads normally once the key allows this bundle ID.** The earlier runs, with a blank map because the key rejected the bundle ID, gave the same numbers.
iPhone 15 Pro Max, iOS 27.0.1, Debug build installed from Xcode, 2026-10-26, one run of 7.8 minutes recorded with `devicectl device process launch --console`:

| Phase | Time | Maps created | CPU avg (max) | defaults writes/s avg (max) |
|---|---|---|---|---|
| Off | 0–53 s | 1 | 5 % (91 %) | 1.4 (17) |
| Custom icon, map recreated about every 12 s | 54–256 s | 18 | 12 % (80 %) | 42 (54) |
| Off | 258–321 s | 18 | 3 % (5 %) | 1.0 (1) |
| Default pin, map recreated a few times | 322–398 s | 28 | 24 % (106 %) | 43 (54) |
| Off | 400–467 s | 28 | 3 % (6 %) | 1.0 (1) |

- **The retry loop didn't start on the device either.** That's 11,200 marker calls and 28 maps. After each phase, CPU went straight back to about 3 %.
- **With no marker calls, the device writes `NSUserDefaults` about once a second.** This was later traced to the app's own `setPadding:` calls (see below). It's fixed, and idle writes are now 0/s.
- **What the React Native app had that this app didn't, at that point:**
  - React Native's `RCTSettingsManager`, which reads and sends the whole defaults dictionary on each change;
  - possibly a navigation session (`GMSNavigationServices`) created earlier in the same process.

### Navigation session switch (2026-10-26)

`-navSession YES` does what the React Native app does on its riding screen: it shows the terms dialog if needed, creates a navigation session, starts it, and attaches it to the map. `-resetTerms YES` first clears an earlier acceptance. `-settingsForwarding YES` does `RCTSettingsManager`'s work on each defaults change.

iPhone 15 Pro Max, iOS 27.0.1, Off mode (no marker calls):

| Run | Phase | CPU avg (max) | defaults writes/s avg (max) |
|---|---|---|---|
| `-navSession YES -resetTerms YES`, 2 min | terms dialog showing, 0–46 s | 67 % (85 %) | 891 (1,281) |
| | after OK: session created and attached | 3 % | 1 |
| `-navSession YES`, terms already accepted, 60 s | whole run | 3 % (27 % in the first second) | 1 (87 in the first second) |

Simulator, Off mode, 15 s per flag: no flags 4 % and 1/s; `-settingsForwarding YES` 5 % and 1/s; `-navSession YES` (dialog showing) 31–84 % and 300–540/s, steady over 3 minutes.

- **The retry loop runs while the terms dialog is up and the terms aren't accepted yet.** A main-thread `sample` on the simulator shows 41 % of samples in `GMSDASHProtobufferRequest scheduleRetryIfApplicableForResponse:error:connection:` → `GMSNavigationQuotaService sendRequestWithQuotaEvent:completionHandler:` → `sendNavigationInitRequestWithHandler:`.
- **Each retry writes the SDK's own defaults keys:** `kNavSDKPreviousSessionIDKey`, `kNavSDKRealtimeLoggingCounterToPreviousLoggedTimeMsMapKey`, `kGMSDefaultKeyNavigationSDKLastUsedTimestamp` and `kGMSDefaultKeyNextLoggerSequenceID`, all on the main thread.
- **Markers and Settings forwarding aren't needed.** It stops as soon as the terms are accepted.
- **Recording:** `devicectl` needs `--` before the app's arguments, e.g. `… --console com.example.navsdkretryrepro -- -mode off -navSession YES`.

### Narrowing the trigger (simulator, terms not accepted, no markers)

| What the app did | CPU | defaults writes/s |
|---|---|---|
| no `GMSNavigationServices` call | 5 % | 1 |
| `areTermsAndConditionsAccepted` only (`-skipTermsDialog YES -termsCheckOnly YES`) | 28 % (waves up to 71 %) | 285 (up to 551) |
| `createNavigationSession` only, no dialog (`-skipTermsDialog YES`) | 73 % | 1,034 |

The once-a-second idle write in the earlier runs came from this app: `viewDidLayoutSubviews` set `mapView.padding` each time the stats label updated. Each `GMSMapView setPadding:` call writes `NSUserDefaults`, even with an unchanged value. The padding is now set only when it changes, and idle writes are 0/s.
