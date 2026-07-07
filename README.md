# AVPlayer + custom AVVideoCompositing playback failure (repro)

Minimal, self-contained reproduction of an `AVPlayer` playback failure that occurs when an
`AVMutableComposition`-backed `AVPlayerItem` is given an `AVMutableVideoComposition` driven by a
**custom `AVVideoCompositing`** (`customVideoCompositorClass`).

## Symptom

After tapping **Reproduce**, `AVPlayerItem.status` transitions to `.failed` with:

- `AVFoundationErrorDomain` code **-11800** (`AVErrorUnknown`)
- underlying `NSOSStatusErrorDomain` code **-12784**

and the console logs:

```
FPSupport_CreateDefaultCoordinationIdentifierForPlaybackItem signalled
err=-12927 (kFigPlayerError_IncompatibleAsset) (not a URL asset) at FigPlayerSupport.m
❌ AVPlayerItem.status == .failed
```

Playing the **same composition without attaching the custom video composition** works fine.

## What the repro does

Everything lives in a single file, [`VideoPlayer/CompositorRepro.swift`](VideoPlayer/CompositorRepro.swift):

1. Loads a bundled clip (`IMG_8366.mov`) and wraps it in an `AVMutableComposition` — i.e. the item is
   **not** a URL asset.
2. Attaches an `AVMutableVideoComposition` whose `customVideoCompositorClass` is a trivial
   **pass-through** compositor (`startRequest` simply forwards the source frame to
   `finish(withComposedVideoFrame:)`). No custom rendering, Core Image, threading, or model
   inference is involved.
3. Creates an `AVPlayer`, plays it, and reports `AVPlayerItem.status` and the exact error on screen
   and in the console.

Because the compositor is a pass-through, the failure is purely about **having a custom video
compositor attached to a composition-backed item** — not about any per-frame work.

## Environment

**This reproduces only on Xcode 27.** The same project built with earlier Xcode versions plays
back correctly — the failure appears specific to the Xcode 27 toolchain / SDK / Simulator runtime.

## Running

Open `VideoPlayer.xcodeproj`, build the `VideoPlayer` target, run on an iOS Simulator, and tap
**Reproduce**.

- Requires: **Xcode 27** (does not reproduce on earlier Xcode versions)
- Deployment target: iOS 17.0
- No third-party dependencies.
