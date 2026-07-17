# BSafeEngine

A bit-exact Swift port of the DSP layer of the Phonicbloom BSAFE (Gecho /
MMXX T-APE) ESP32 firmware.

[![Swift 6](https://img.shields.io/badge/swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20iPadOS%20%7C%20macOS%20%7C%20macCatalyst%20%7C%20tvOS%20%7C%20visionOS-blue.svg)]()
[![License: LGPL-3.0](https://img.shields.io/badge/license-LGPL--3.0-green.svg)](LICENSE)

## What it does

- Renders the **eight Viznut-style bytebeat songs** that ship with the
  BSAFE firmware, sample-for-sample identical to the C reference.
- Provides the **ring-buffer echo**, **stereo mixer**, **sine-waves
  wavetable voice**, **arpeggiator** and **8-slot step sequencer** from the
  original firmware.
- Runs on the audio thread with **no locks, no allocations, no syscalls**
  on the hot path (except the RNG waveform — see the API docs for the
  caveat).
- Zero dependency on AudioKit, UIKit or AVFoundation — a pure-Swift DSP
  library that you plug into any audio host.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/santos-ee/BSafeEngine.git", from: "0.1.0"),
]
```

Then depend on the `BSafeEngine` product from your target.

## Quick start

```swift
import BSafeEngine

// UI thread: parameters SwiftUI can bind to.
let params = SynthParameters()
params.selectSong(3)
params.echoOn = true

// Audio thread: create the core, apply a snapshot per buffer,
// pull one sample at a time.
let core = SynthCore()
core.applySnapshot(params.snapshot())

for _ in 0..<1024 {
    let (l, r) = core.renderNextSample()
    // ... write to your AVAudioSourceNode's output buffer
}
```

To drive it from AVAudioEngine, wrap `SynthCore.renderNextSample()` in an
`AVAudioSourceNode` render block. The engine renders at 32,768 Hz — the
device's `I2S_AUDIOFREQ` — and `AVAudioEngine` handles resampling to the
hardware rate.

## Threading model

- ``SynthParameters`` is `@MainActor`-isolated. SwiftUI observes it
  through `@Published` properties.
- Every mutation copies an immutable ``SynthParameters.Snapshot`` into an
  `OSAllocatedUnfairLock` slot.
- The audio thread calls the `nonisolated` `snapshot()` accessor once per
  render buffer. No locks on the per-sample path.
- Use `updateAtomically { ... }` to coalesce a group of parameter changes
  into a single snapshot the audio thread will observe.

## Bit-exact correctness

The bytebeat formulas rely on C signed-integer overflow. This port uses
Swift's overflow operators (`&+`, `&-`, `&*`, `&<<`, `&>>`) and
`truncatingIfNeeded:` conversions so the math matches C exactly.

Tests compare 5 seconds of output for all 8 songs against WAVs produced by
the original C harness. If any formula translates wrong (missed overflow,
wrong precedence, sign extension bug) the test fails loud with the exact
index of the first mismatched sample.

```sh
swift test
```

## Attribution

`BSafeEngine` is a Swift port of the DSP layer of the [Phonicbloom BSAFE
(Gecho) ESP32 firmware](https://github.com/phonicbloom/gecho). See
[NOTICE](NOTICE) for the full attribution.

The eight built-in bytebeat formulas descend from the "bytebeat" tradition
originated by [Ville-Matias Heikkilä
(Viznut)](https://countercomplex.blogspot.com/2011/10/algorithmic-symphonies-from-one-line-of.html).

## License

`BSafeEngine` is released under the [GNU Lesser General Public License
v3.0](LICENSE). LGPLv3 explicitly permits dynamic linking from
closed-source applications — including Apple App Store apps — provided the
usual LGPL obligations (source availability, ability to relink) are
honored.

The library incorporates the [GNU General Public License v3.0](LICENSE.GPL)
by reference (LGPLv3 §0).
