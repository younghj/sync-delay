# About this fork

This is a fork of [leviholliday/sync-delay](https://github.com/leviholliday/sync-delay) with local changes:

- **Runs in the background.** Closing the window keeps sync running. A menu bar icon has Start/Stop, delay nudges, mute, Open Sync Delay and Quit. The Dock icon goes away while the window is closed.
- **No UI freezes from the meters.** The level meters redraw only themselves, and only while the window is visible. Before, the whole window redrew 30 times a second, even in the background.
- **Slow audio calls are off the main thread.** Starting and stopping the audio engine and setting per-speaker volume no longer block the window. That matters most with Bluetooth speakers.
- **Reconnects when audio stops.** If audio stops flowing for 3 seconds (a speaker dropping out, a sample-rate switch) or the Mac wakes from sleep, sync reconnects on its own. After 3 tries in a minute it stops and says so.
- **Updates don't overwrite this build.** The app still checks upstream releases but only tells you one is available.

## Updating from upstream

```bash
./update-from-upstream.sh
```

This merges `upstream/main` into the current branch, rebuilds, installs to `/Applications`, relaunches the app and pushes to the fork. If the merge conflicts, it stops before building and lists the files to resolve.

Remotes: `origin` is this fork and `upstream` is leviholliday/sync-delay.
