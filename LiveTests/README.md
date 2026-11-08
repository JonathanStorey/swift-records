# Live tests

A small Mac app that runs SwiftRecords' sync scenarios and benchmarks against real CloudKit. The scenarios
are the same ones the package's tests run on the in-memory server (`Sources/SyncScenarios`), so the two
can't drift apart. It needs an app, not `swift test`, because only a signed app with the iCloud entitlement
can reach CloudKit.

Open `SwiftRecords.xcworkspace` at the repository root. It holds the package, this app and Crate, so the
whole of SwiftRecords is there to read, edit and set breakpoints in while the app runs.

## Setup, once

1. Sign in to iCloud on the Mac, and add your Apple ID in Xcode under Settings, Accounts.
2. In `LiveTests/Signing.xcconfig`, set your team ID and change the bundle ID to your own prefix, such as
   `com.yourname.SwiftRecordsLive`. Apple won't register one that starts with `com.example`. The app's
   iCloud container is `iCloud.<bundle ID>`, apart from your apps' own data. Your team ID is under
   Membership in your Apple developer account.
3. Select the SwiftRecordsLive target, open Signing & Capabilities, and check that iCloud shows the
   container ticked. If it shows red, press the refresh button, or + to add `iCloud.<bundle ID>`. A new
   container can take a minute to become usable.
4. If Xcode asks to trust the SwiftRecords macros, choose Trust & Enable.

## Running

**In Xcode.** Choose the SwiftRecordsLive scheme and My Mac, and press Run (⌘R). The window checks the
account, then lists every scenario with a Run button, and Run All runs them in order. Each row shows
waiting, running, ✔ or ✘, with its time and, for a failure, the check that didn't hold. To debug one, set a
breakpoint anywhere in SwiftRecords, such as in `SyncHub`, and press that row's Run button.

**In Terminal.** `run.sh` builds the app and runs it without a window, printing the same results:

```
./run.sh scenarios          # account checks, then every scenario
./run.sh scenarios edit     # only scenarios whose name contains "edit"
./run.sh benchmarks 200     # the benchmarks with 200 records (100 by default)
./run.sh all                # checks, scenarios and benchmarks
./run.sh list               # the scenario names
```

It exits 0 when everything passed, 1 when something failed, and 2 when CloudKit can't be reached.

**Without CloudKit.** The package's own scheme (named SwiftRecords or swift-records-Package, depending on
the Xcode version) runs the same scenarios on the in-memory server with Test (⌘U),
along with the rest of the package's tests, with no account.

Everything runs in CloudKit's development environment, never production. Each scenario works in a zone of
its own, named `swiftrecords-live-…`, and deletes it afterwards. A run also deletes any such zones a
crashed run left behind.

Two devices are two containers in the one app, each with its own store and sync engine, on your account.
Apple recommends this for testing `CKSyncEngine` across devices. The engines sync only when a scenario
asks, so the order of events is fixed. CloudKit can take a moment to show a save to another device, so a
check that waits on the server refreshes up to 15 times, a second apart, before it fails.

The offline scenario runs only on the in-memory server, since the app can't take CloudKit offline.

## Benchmarks

The benchmarks time one save of many records against one save each, then downloading, editing and deleting
them all. On CloudKit they mostly measure round trips, so they vary with the network. Compare runs from the
same place.

## On real devices

Some things can't be scripted: they need a person, a second device, or a change in System Settings. Run
through these with the Crate app (`Examples/Crate`) on two devices signed in to the same account before a
release.

- [ ] A record added on one device appears on the other within a minute, without touching it (push).
- [ ] An edit made while the app is in the background on the other device is there when it opens.
- [ ] An edit made in Airplane Mode is sent once the device is back online, and the status shows offline
      meanwhile.
- [ ] Signing out of iCloud shows the signed-out status, and the records stay on the device.
- [ ] Signing in to a different account removes the first account's records, and the new account's
      records arrive.
- [ ] Signing back in to the first account brings its records back.
- [ ] Turning off iCloud for the app in Settings shows the signed-out status, and turning it back on syncs.
- [ ] Deleting the app's iCloud data (Settings, iCloud, Manage Storage) empties every device after its
      next sync, and new records sync again afterwards.
- [ ] A photo added on one device appears on the other.

Sharing needs a second iCloud account, so its tests wait until one is available. The in-memory tests cover
the sharing logic meanwhile.
