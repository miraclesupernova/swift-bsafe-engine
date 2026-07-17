# BSafeEngine

A pure-Swift port of the DSP layer that runs inside the Phonicbloom BSAFE (also known as Gecho, and later as the MMXX T-APE) hardware synthesizer. The original firmware was written in C for the ESP32; this library is a line-for-line translation into Swift that preserves the C signed-integer overflow behavior the bytebeat formulas depend on, and verifies that behavior sample-for-sample against reference audio generated from the C source itself.

If you have never heard the BSAFE, the short version is that it plays eight one-line mathematical formulas (a genre called bytebeat, originated by Ville-Matias Heikkilä), and adds a small collection of surrounding effects and voices: a ring-buffer echo, a stereo mixer, a monophonic wavetable synth, an arpeggiator, and an eight-slot step sequencer. This library gives you all of that as a headless Swift package that you can drop into your own audio project, with no dependency on AudioKit, UIKit, or any Apple audio framework other than the standard library and Foundation. It compiles on iOS 17, macOS 14, macCatalyst, tvOS, and visionOS.

[![Swift 6](https://img.shields.io/badge/swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20iPadOS%20%7C%20macOS%20%7C%20macCatalyst%20%7C%20tvOS%20%7C%20visionOS-blue.svg)]()
[![License: LGPL-3.0](https://img.shields.io/badge/license-LGPL--3.0-green.svg)](LICENSE)

## Installing it

Add the package to your `Package.swift` dependencies list:

```swift
dependencies: [
    .package(url: "https://github.com/miraclesupernova/swift-bsafe-engine.git", from: "0.1.0"),
]
```

And add the product as a dependency of the target that will use it:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "BSafeEngine", package: "swift-bsafe-engine"),
    ]
)
```

If you are on an early build and the tag you want has not been published yet, you can pin to a specific branch or commit hash for the time being with `.package(url: "...", branch: "main")` or `.package(url: "...", revision: "abc123")`. Either form resolves the same way at SwiftPM time; the difference is only in whether you get moving updates or a locked snapshot.

For an Xcode project (as opposed to another Swift package), open File then Add Package Dependencies, paste the URL above, and choose the version rule that suits you. Xcode will download and build the package on the next compile.

## Making a sound

Here is the smallest amount of code that produces audible bytebeat on a Mac (or an iOS device, with a couple of small changes noted at the end). It creates a parameter store, feeds it into the top-level orchestrator, and connects that to `AVAudioEngine` through a source node.

```swift
import AVFoundation
import BSafeEngine

// Two objects handle everything. One holds mutable parameters that a UI
// (or your own code) can change over time; the other is the audio-thread
// side that reads a stable snapshot and produces one sample at a time.
let params = SynthParameters()
let core = SynthCore()

// Pick a song. The BSAFE ships with eight built-in Viznut-style formulas
// numbered 0 through 7; selectSong also loads the song's default bit
// dividers atomically so the audio thread never sees a torn parameter set.
params.selectSong(3)
params.echoOn = true

// The engine renders at 32,768 Hz internally (matching the hardware's
// I2S clock) and returns stereo Float samples in the range -1 to 1.
// AVAudioEngine will happily resample that to whatever the output
// hardware wants.
let format = AVAudioFormat(
    standardFormatWithSampleRate: BytebeatEngine.deviceSampleRate,
    channels: 2
)!

let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
    // At the top of every render buffer, pull the latest parameter values
    // through the lock-guarded snapshot. This is the only synchronization
    // point between the audio thread and the rest of your app.
    core.applySnapshot(params.snapshot())

    let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let left  = abl[0].mData!.assumingMemoryBound(to: Float.self)
    let right = abl[1].mData!.assumingMemoryBound(to: Float.self)

    for frame in 0..<Int(frameCount) {
        let (l, r) = core.renderNextSample()
        left[frame]  = l
        right[frame] = r
    }
    return noErr
}

let engine = AVAudioEngine()
engine.attach(sourceNode)
engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
try engine.start()

// Change parameters at any time; the audio thread will pick them up
// on the next render buffer without any coordination on your side.
params.variableA = 128
params.setTempo(bpm: 140)
```

On iOS the only extra step is that you need to activate an audio session before starting the engine. Something like:

```swift
try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
try AVAudioSession.sharedInstance().setActive(true)
```

The `BSafeAudioKit` adapter that lives in a separate proprietary package handles that plus interruption and route-change notifications, but you can absolutely wire your own session if you would rather not depend on AudioKit.

## The threading model, and why it matters

Audio playback is a real-time task. If the render callback takes too long, or if it blocks on a lock, or allocates memory, or takes a syscall, the output will glitch audibly. This library is built around that constraint from the start, so you can put its render function inside any audio callback (Core Audio, `AVAudioSourceNode`, an `AUv3` render block, or the equivalent from a third-party framework) without worrying that some internal detail will trip the real-time constraint.

The design has two pieces. On the UI side, `SynthParameters` is a plain `ObservableObject` that SwiftUI (or any Combine subscriber) can bind to normally. Every mutation on the main actor triggers `objectWillChange` for observers, and separately writes a value-type `Snapshot` into a slot guarded by `OSAllocatedUnfairLock`. The audio side calls `params.snapshot()` once per render buffer, which returns a copy of that slot without ever waiting on a contended lock (unfair locks are extremely cheap in the uncontended case, which is the case here because the UI thread is not writing constantly). From that point until the next buffer starts, the audio thread reads from its local copy and needs no further coordination.

If you need to change several parameters together and want the audio thread to observe them as a single atomic transition (rather than potentially seeing an intermediate state), wrap the changes in `updateAtomically`:

```swift
params.updateAtomically {
    params.songIndex = 5
    params.bit1 = 4
    params.bit2 = 2
    params.echoOn = true
}
```

Inside the block, individual `@Published` notifications still fire (which is unavoidable if you want SwiftUI to update), but the snapshot slot is written only once at the block's exit. This is how `selectSong` is implemented internally, and it's the pattern to reach for whenever atomicity matters.

## What is in the library

At the top level, `SynthCore` is an orchestrator that owns every subengine and produces one stereo sample per call. Most consumers will only ever touch `SynthCore` and `SynthParameters`. The rest of the types are public so you can build something more selective if you want.

- **`BytebeatEngine`** is the pure sample generator. It maintains the monotonic counter that all bytebeat formulas index into, applies the current formula (`BytebeatSongs.render`), packs the byte through the volume shift the hardware DAC does, and passes through the echo and stereo mixer. If you only want bytebeat and none of the sine or arpeggiator features, you can use this directly.
- **`BytebeatSongs`** contains the eight formulas as `@inlinable` static functions. They are self-contained; nothing else in the library depends on them, so if you want to write your own bytebeat host you can call them straight.
- **`EchoBuffer`** is a fixed-length feedback delay with a mixing factor of 0.5, matching the hardware's default. The buffer length is configurable at runtime through `setLength`.
- **`StereoMixer`** implements the four-preset blend table from the firmware. In the shipping configuration it is a passthrough (this matches what the real BSAFE does today), but the blend math is available if you want to opt in.
- **`SineWavesEngine`** is a monophonic wavetable oscillator with a decay envelope. It supports six waveforms (sine, saw, square, a synthesized multi-wave, a noise-plus-tone table, and a pure PRNG noise voice), all triggered through `trigger(note:octaveShift:)`. Notes are one-indexed 1 through 8, matching the eight capacitive keys on the hardware.
- **`Arpeggiator`** and **`StepSequencer`** are the two pattern generators. They are ticked once per beat by `SynthCore` (not per sample), and each emits `(note, octave)` events that get routed to `SineWavesEngine.trigger`. Between them they cover nine arp modes and eight sequencer slots of up to 64 steps each.
- **`MiniPiano`** and **`Wavetables`** hold the shared constants and precomputed tables used by the sine layer. `Wavetables.warmup()` forces the tables to compute up front so the first note you play does not stall the audio thread.
- **`SynthParameters`** is the observable parameter store described above.

Every public API is annotated with the realtime-safety contract it adheres to (thread safety, allocation behavior, whether it can be called from the audio thread or only from a lifecycle path). Look at the doc comments in the source when you are wiring the engine into something nontrivial.

## Correctness and how to verify it

Bytebeat sounds the way it does precisely because of signed integer overflow. If you change a `>>` to a `>>>` somewhere in a naive port, or convert an intermediate value through the wrong signed or unsigned type, the audio comes out sounding faintly wrong in a way that is hard to detect by ear but easy to catch by comparison. This library translates the C to Swift using the overflow operators (`&+`, `&-`, `&*`, `&<<`, `&>>`) and `truncatingIfNeeded:` conversions, and then verifies the result against reference audio generated by a small C harness (compiled at `-O0` to match the ARM and Xtensa hardware, whose behavior on out-of-range shift amounts is well-defined even though the C standard leaves it undefined).

To run the whole suite:

```
swift test
```

You will see 54 tests total, split across seven suites:

- The song test compares five seconds of stereo output for every one of the eight built-in formulas against golden WAV files. If any formula drifts, the test tells you which song and which sample offset diverged.
- The other six suites cover the individual components (`EchoBuffer`, `StereoMixer`, `Arpeggiator`, `StepSequencer`, `SynthParameters`, `Wavetables`) with focused unit tests that guard each component's contract.

If you have changed a formula deliberately and want to regenerate the golden reference, the harness lives at `tools/harness/` and is a small C++ program that produces the WAVs the tests compare against:

```
cd tools/harness
make run
cp ../reference_wavs/*.wav ../../Tests/BSafeEngineTests/ReferenceWavs/
```

The `-O0` compile flag in the Makefile is deliberate and important. Several of the bytebeat formulas produce shift amounts greater than 31, which is undefined behavior in C. At `-O2` clang exploits that inconsistently between builds, which means the reference audio would change every time you rebuilt the harness. At `-O0` you get the same behavior the ARM and Xtensa hardware use (the shift amount masked to 5 bits), which is also exactly what Swift's `&>>` and `&<<` do. Compiling the harness this way is what makes the sample-for-sample comparison meaningful.

## Attribution

`BSafeEngine` is a Swift port of the DSP layer of the [Phonicbloom BSAFE (Gecho) ESP32 firmware](https://github.com/phonicbloom/gecho). Full attribution to the original firmware source, the individual files each Swift file was translated from, and the port maintainers is in [NOTICE](NOTICE).

The eight built-in bytebeat formulas descend from the algorithmic music tradition originated by [Ville-Matias Heikkilä (Viznut)](https://countercomplex.blogspot.com/2011/10/algorithmic-symphonies-from-one-line-of.html) in 2011. That tradition is a widely-republished body of one-line mathematical expressions, and the credit is preserved here as a courtesy.

## License

`BSafeEngine` is released under the [GNU Lesser General Public License version 3.0](LICENSE). The LGPL v3.0 explicitly permits linking from closed-source applications (including apps distributed through the Apple App Store), provided the usual LGPL obligations are honored: the library's source stays available, and downstream users have the ability to relink the application against a modified version of this library. If you use `BSafeEngine` in your own project, please keep the `NOTICE` file intact and make it clear that your users are entitled to the library's source under LGPL v3.0.

The LGPL v3.0 text incorporates the [GNU General Public License version 3.0](LICENSE.GPL) by reference (see LGPL v3.0 §0), which is why both licenses ship in the repository.
