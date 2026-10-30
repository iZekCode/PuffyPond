import AVFoundation
import os

/// Sound effects the game can ask for.
nonisolated enum Sfx: UInt8, Sendable {
    case blip      // a fish blows a bead (a = height 0…1, b = pan)
    case squeak    // starfish scrubbing (b = pan)
    case pop       // something pops (b = pan)
    case boing     // a creature gets bumped (a = size 0…1, b = pan)
    case rise      // drawing starts to transform
    case fanfare   // creature is born
    case swap      // fish ↔ starfish
    case fizzle    // transform with nothing to inflate
    case gurgle    // a fish rubbing in a paint pot (a = progress 0…1, b = pan)
    case pick      // a fish soaks up a new color (a = color index, b = pan)
    case sparkle   // twinkly glitter after a pop
}

nonisolated struct SfxEvent: Sendable {
    var kind: Sfx
    var a: Float
    var b: Float
}

nonisolated private enum Wave: UInt8 { case sine, triangle, square, fm, noise }

nonisolated private struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    static func bandPass(_ f: Float, q: Float, sr: Float) -> Biquad {
        let w0 = 2 * Float.pi * min(f, sr * 0.45) / sr
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w0) / a0, a2: (1 - alpha) / a0)
    }

    static func highPass(_ f: Float, q: Float, sr: Float) -> Biquad {
        let w0 = 2 * Float.pi * min(f, sr * 0.45) / sr
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + cw) / 2 / a0, b1: -(1 + cw) / a0, b2: (1 + cw) / 2 / a0,
                      a1: -2 * cw / a0, a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

nonisolated private struct Voice {
    var active = false
    var delay = 0
    var wave: Wave = .sine
    var frequency: Float = 440
    var glideTarget: Float = 440
    var glideRate: Float = 0          // 0 = no glide
    var phase: Float = 0
    var modPhase: Float = 0
    var modRatio: Float = 2
    var modIndex: Float = 0
    var modDecay: Float = 1
    var amplitude: Float = 0
    var peak: Float = 0
    var attackStep: Float = 1
    var attacking = true
    var decay: Float = 0.999
    var vibratoDepth: Float = 0
    var vibratoRate: Float = 0
    var vibratoPhase: Float = 0
    var lowpass: Float = 1            // one-pole coefficient (1 = off)
    var lowState: Float = 0
    var useFilter = false
    var filter = Biquad()
    var left: Float = 0.7
    var right: Float = 0.7
}

/// A cheerful 118 BPM toy-pop groove, synthesized live:
/// four-on-the-floor kick, claps on 2 & 4, offbeat hats, a bouncy bass, chord stabs and a
/// sing-along lead over I–V–vi–IV in C. Layers swell with how much you're moving.
/// Also renders every sound effect, and publishes a beat clock for animations.
nonisolated final class GrooveDSP: @unchecked Sendable {
    static let bpm: Double = 118
    private static let voiceCount = 64
    private static let tableSize = 4096
    private static let queueCapacity = 64

    private static let roots: [Float] = [36, 43, 45, 41]            // C G A F
    private static let triads: [[Float]] = [[60, 64, 67], [59, 62, 67], [60, 64, 69], [60, 65, 69]]
    private static let bassSteps: [Int: Float] = [0: 0, 3: 0, 6: 12, 8: 0, 10: 7, 14: 12]
    private static let melody: [[Float]] = [
        [72, -1, 76, -1, 79, -1, 76, -1, 81, -1, 79, 76, 74, -1, 72, -1],
        [74, -1, 79, -1, 83, -1, 79, -1, 81, -1, 79, -1, 74, 76, 79, -1],
        [76, -1, 72, -1, 76, -1, 81, -1, 79, -1, 76, -1, 72, -1, 74, -1],
        [77, -1, 76, -1, 74, -1, 72, -1, 69, -1, 72, 74, 76, -1, -1, -1],
        [84, -1, -1, 79, -1, -1, 76, -1, 79, -1, 81, -1, 79, -1, 76, -1],
        [79, -1, -1, 74, -1, -1, 79, -1, 83, -1, 81, -1, 79, -1, 74, -1],
        [81, -1, -1, 76, -1, -1, 72, -1, 76, -1, 79, -1, 81, -1, 84, -1],
        [81, -1, 79, -1, 77, -1, 76, -1, 74, -1, 72, -1, -1, -1, -1, -1],
    ]
    private static let blipScale: [Float] = [79, 81, 84, 86, 88, 91, 93, 96, 98, 100]

    static func hz(_ midi: Float) -> Float { 440 * pow(2, (midi - 69) / 12) }

    private let sampleRate: Float
    private let samplesPerStep: Double

    // Shared with the main thread
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private let queue = UnsafeMutablePointer<SfxEvent>.allocate(capacity: GrooveDSP.queueCapacity)
    private var queueCount = 0                     // guarded by `lock`
    private let shared = UnsafeMutablePointer<Double>.allocate(capacity: 3)   // [beat, energy, master]

    // Audio thread
    private let table = UnsafeMutablePointer<Float>.allocate(capacity: GrooveDSP.tableSize)
    private let voices = UnsafeMutablePointer<Voice>.allocate(capacity: GrooveDSP.voiceCount)
    private var nextVoice = 0
    private var stepClock: Double = 0
    private var step = 0                 // 16th within the bar
    private var bar = 0
    private var totalSteps: Double = 0
    private var energy: Float = 0
    private var master: Float = 0
    private var noiseSeed: UInt32 = 0x9E37_79B9

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        samplesPerStep = Double(sampleRate) * 60 / Self.bpm / 4
        lock.initialize(to: os_unfair_lock())
        queue.initialize(repeating: SfxEvent(kind: .blip, a: 0, b: 0), count: Self.queueCapacity)
        shared.initialize(repeating: 0, count: 3)
        shared[2] = 1
        for i in 0..<Self.tableSize {
            table[i] = sin(2 * Float.pi * Float(i) / Float(Self.tableSize))
        }
        voices.initialize(repeating: Voice(), count: Self.voiceCount)
        stepClock = samplesPerStep   // first downbeat right away
    }

    deinit {
        lock.deallocate()
        queue.deallocate()
        shared.deallocate()
        table.deallocate()
        voices.deallocate()
    }

    // MARK: Main-thread API

    func play(_ event: SfxEvent) {
        os_unfair_lock_lock(lock)
        if queueCount < Self.queueCapacity {
            queue[queueCount] = event
            queueCount += 1
        }
        os_unfair_lock_unlock(lock)
    }

    func setEnergy(_ value: Float) { shared[1] = Double(value) }
    func setMuted(_ muted: Bool) { shared[2] = muted ? 0 : 1 }
    /// Musical time in beats (quarter notes) since start.
    var beat: Double { shared[0] }

    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        return { _, _, frameCount, audioBufferList in
            self.render(frameCount: Int(frameCount), bufferList: audioBufferList)
            return noErr
        }
    }

    // MARK: Synthesis helpers (audio thread)

    @inline(__always)
    private func sine(_ phase: Float) -> Float {
        let p = phase - phase.rounded(.down)
        let x = p * Float(Self.tableSize)
        let i = Int(x)
        let f = x - Float(i)
        let a = table[i & (Self.tableSize - 1)]
        let b = table[(i + 1) & (Self.tableSize - 1)]
        return a + (b - a) * f
    }

    @inline(__always)
    private func noise() -> Float {
        noiseSeed ^= noiseSeed << 13
        noiseSeed ^= noiseSeed >> 17
        noiseSeed ^= noiseSeed << 5
        return Float(noiseSeed) / Float(UInt32.max) * 2 - 1
    }

    private static func polyBLEP(_ t: Float, _ dt: Float) -> Float {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        } else if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }

    private func coefficient(seconds: Float) -> Float { exp(-1 / (max(seconds, 0.0005) * sampleRate)) }
    private func lowpass(_ cutoff: Float) -> Float { 1 - exp(-2 * Float.pi * cutoff / sampleRate) }

    /// Starts a voice. `decay` is the time to fade by ~60 dB.
    private func start(_ wave: Wave, _ frequency: Float, peak: Float, decay: Float, at delay: Int,
                       pan: Float = 0, attack: Float = 0.002, glideFrom: Float? = nil, glideTime: Float = 0,
                       vibrato: (depth: Float, rate: Float) = (0, 0), cutoff: Float? = nil,
                       filter: Biquad? = nil, fm: (ratio: Float, index: Float, decay: Float)? = nil) {
        var v = Voice()
        v.active = true
        v.delay = max(delay, 0)
        v.wave = wave
        v.glideTarget = frequency
        v.frequency = glideFrom ?? frequency
        v.glideRate = glideFrom == nil ? 0 : 1 - coefficient(seconds: glideTime)
        v.peak = peak
        v.attackStep = peak / max(attack * sampleRate, 1)
        v.decay = exp(-6.9 / (max(decay, 0.01) * sampleRate))
        v.vibratoDepth = vibrato.depth
        v.vibratoRate = vibrato.rate / sampleRate
        v.lowpass = cutoff.map { lowpass($0) } ?? 1
        if let filter {
            v.useFilter = true
            v.filter = filter
        }
        if let fm {
            v.modRatio = fm.ratio
            v.modIndex = fm.index
            v.modDecay = coefficient(seconds: fm.decay)
            v.modPhase = 0.25
        }
        let angle = (max(-1, min(pan, 1)) + 1) * Float.pi / 4
        v.left = cos(angle)
        v.right = sin(angle)
        voices[nextVoice] = v
        nextVoice = (nextVoice + 1) % Self.voiceCount
    }

    // MARK: The groove

    private func playStep(at offset: Int) {
        let chord = bar % 4
        let section = bar % 8
        let root = Self.roots[chord]
        let groove: Float = 0.75 + 0.25 * energy

        // Drums
        if step % 4 == 0 {
            start(.sine, 48, peak: 0.85, decay: 0.38, at: offset, attack: 0.001, glideFrom: 170, glideTime: 0.035)
            start(.noise, 0, peak: 0.12, decay: 0.012, at: offset, filter: .highPass(3000, q: 0.7, sr: sampleRate))
        }
        if step == 4 || step == 12 || (section == 7 && step >= 12) {
            let peak: Float = step == 12 || step == 4 ? 0.42 : 0.25
            start(.noise, 0, peak: peak, decay: 0.16, at: offset, filter: .bandPass(1350, q: 0.9, sr: sampleRate))
            start(.noise, 0, peak: peak * 0.6, decay: 0.12, at: offset + Int(0.011 * sampleRate),
                  filter: .bandPass(1600, q: 1.1, sr: sampleRate))
        }
        if step % 4 == 2 {
            start(.noise, 0, peak: 0.16 * groove, decay: 0.05, at: offset, pan: 0.3,
                  filter: .highPass(7500, q: 0.8, sr: sampleRate))
        } else if step % 2 == 1 && energy > 0.35 {
            start(.noise, 0, peak: 0.06, decay: 0.03, at: offset, pan: -0.3,
                  filter: .highPass(9000, q: 0.8, sr: sampleRate))
        }

        // Bouncy bass
        if let interval = Self.bassSteps[step] {
            start(.square, Self.hz(root + interval), peak: 0.26, decay: 0.22, at: offset,
                  attack: 0.003, cutoff: 650 + 500 * energy)
        }

        // Chord stabs on the offbeats ("and" of 2 and 4, plus one push)
        if step == 6 || step == 14 || step == 10 {
            let stab: Float = (0.04 + 0.05 * energy) * (step == 10 ? 0.7 : 1)
            for (k, note) in Self.triads[chord].enumerated() {
                start(.square, Self.hz(note), peak: stab, decay: 0.16, at: offset,
                      pan: Float(k - 1) * 0.5, attack: 0.002, cutoff: 2600)
            }
        }

        // Lead melody — always there, louder when you play.
        let note = Self.melody[section][step]
        if note > 0 {
            let lead: Float = 0.07 + 0.09 * energy
            start(.square, Self.hz(note), peak: lead, decay: 0.32, at: offset, pan: 0.1,
                  attack: 0.004, vibrato: (0.006, 5.5), cutoff: 3200)
            start(.fm, Self.hz(note + 12), peak: lead * 0.35, decay: 0.45, at: offset, pan: -0.15,
                  fm: (3.5, 1.6, 0.12))
        }
    }

    private func playEffect(_ e: SfxEvent) {
        let pan = e.b
        switch e.kind {
        case .blip:
            let i = min(max(Int(e.a * Float(Self.blipScale.count)), 0), Self.blipScale.count - 1)
            let f = Self.hz(Self.blipScale[i])
            start(.sine, f, peak: 0.17, decay: 0.16, at: 0, pan: pan, attack: 0.002, glideFrom: f * 0.7, glideTime: 0.025)
            start(.fm, f * 2, peak: 0.04, decay: 0.12, at: 0, pan: pan, fm: (2, 1.2, 0.04))
        case .squeak:
            start(.sine, 900, peak: 0.1, decay: 0.12, at: 0, pan: pan, glideFrom: 1500, glideTime: 0.05,
                  vibrato: (0.07, 26))
            start(.noise, 0, peak: 0.07, decay: 0.08, at: 0, pan: pan, filter: .bandPass(3200, q: 2, sr: sampleRate))
        case .pop:
            start(.noise, 0, peak: 0.5, decay: 0.07, at: 0, pan: pan, filter: .bandPass(1000, q: 0.7, sr: sampleRate))
            start(.sine, 180, peak: 0.4, decay: 0.12, at: 0, pan: pan, glideFrom: 700, glideTime: 0.02)
            start(.sine, Self.hz(96), peak: 0.08, decay: 0.2, at: Int(0.03 * sampleRate), pan: pan)
        case .boing:
            let base: Float = 420 - 200 * min(max(e.a, 0), 1)
            start(.sine, base * 0.35, peak: 0.3, decay: 0.55, at: 0, pan: pan, glideFrom: base, glideTime: 0.12,
                  vibrato: (0.07, 9))
        case .rise:
            start(.triangle, 1300, peak: 0.12, decay: 1.2, at: 0, attack: 0.25, glideFrom: 260, glideTime: 0.35)
            start(.noise, 0, peak: 0.08, decay: 0.9, at: 0, attack: 0.4, filter: .bandPass(1800, q: 1.2, sr: sampleRate))
        case .fanfare:
            start(.noise, 0, peak: 0.45, decay: 0.08, at: 0, filter: .bandPass(900, q: 0.7, sr: sampleRate))
            start(.sine, 70, peak: 0.6, decay: 0.3, at: 0, glideFrom: 240, glideTime: 0.03)
            let notes: [Float] = [72, 76, 79, 84, 88, 91]
            for (k, n) in notes.enumerated() {
                start(.fm, Self.hz(n), peak: 0.13, decay: 1.1, at: Int(Float(k) * 0.065 * sampleRate),
                      pan: Float(k) / 3 - 0.8, fm: (3.5, 2.0, 0.3))
            }
        case .swap:
            start(.sine, Self.hz(84), peak: 0.1, decay: 0.08, at: 0, glideFrom: Self.hz(79), glideTime: 0.02)
            start(.sine, Self.hz(91), peak: 0.08, decay: 0.1, at: Int(0.06 * sampleRate))
        case .gurgle:
            let f = Self.hz(60 + 12 * max(0, min(e.a, 1)) + Float(Int.random(in: 0...4)))
            start(.sine, f, peak: 0.09, decay: 0.07, at: 0, pan: pan, glideFrom: f * 0.6, glideTime: 0.02)
        case .pick:
            // Slurp up, then a bright two-note "ding" whose pitch matches the color.
            let base = Self.blipScale[min(max(Int(e.a), 0), 5) + 2]
            start(.sine, 900, peak: 0.12, decay: 0.15, at: 0, pan: pan, glideFrom: 250, glideTime: 0.06)
            start(.fm, Self.hz(base), peak: 0.15, decay: 0.7, at: Int(0.07 * sampleRate), pan: pan, fm: (3.5, 2.2, 0.15))
            start(.fm, Self.hz(base + 7), peak: 0.12, decay: 0.8, at: Int(0.15 * sampleRate), pan: pan, fm: (3.5, 2.2, 0.15))
        case .sparkle:
            for k in 0..<6 {
                let n = Self.blipScale[Int.random(in: 4..<Self.blipScale.count)]
                start(.fm, Self.hz(n), peak: 0.05, decay: 0.35, at: Int(Float(k) * 0.04 * sampleRate),
                      pan: Float.random(in: -0.7...0.7), fm: (3.5, 1.5, 0.08))
            }
        case .fizzle:
            start(.sine, 220, peak: 0.12, decay: 0.4, at: 0, glideFrom: 500, glideTime: 0.2)
            start(.noise, 0, peak: 0.1, decay: 0.3, at: 0, filter: .bandPass(700, q: 0.8, sr: sampleRate))
        }
    }

    // MARK: Render

    private func render(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        if os_unfair_lock_trylock(lock) {
            for i in 0..<queueCount { playEffect(queue[i]) }
            queueCount = 0
            os_unfair_lock_unlock(lock)
        }
        let block = Float(frameCount) / sampleRate
        energy += (Float(shared[1]) - energy) * (1 - exp(-block / 1.2))
        let masterTarget = Float(shared[2])

        // Sequencer: trigger every 16th note sample-accurately.
        for n in 0..<frameCount {
            stepClock += 1
            if stepClock >= samplesPerStep {
                stepClock -= samplesPerStep
                playStep(at: n)
                step += 1
                totalSteps += 1
                if step == 16 {
                    step = 0
                    bar += 1
                }
            }
        }
        shared[0] = (totalSteps - 1 + stepClock / samplesPerStep) / 4

        for n in 0..<frameCount {
            left[n] = 0
            right[n] = 0
        }

        let inverseRate = 1 / sampleRate
        for i in 0..<Self.voiceCount where voices[i].active {
            var v = voices[i]
            var first = 0
            if v.delay >= frameCount {
                v.delay -= frameCount
                voices[i] = v
                continue
            } else if v.delay > 0 {
                first = v.delay
                v.delay = 0
            }
            for n in first..<frameCount {
                if v.glideRate > 0 { v.frequency += (v.glideTarget - v.frequency) * v.glideRate }
                var f = v.frequency
                if v.vibratoDepth > 0 {
                    v.vibratoPhase += v.vibratoRate
                    if v.vibratoPhase >= 1 { v.vibratoPhase -= 1 }
                    f *= 1 + v.vibratoDepth * sine(v.vibratoPhase)
                }
                let dt = f * inverseRate
                var s: Float
                switch v.wave {
                case .sine:
                    s = sine(v.phase)
                case .triangle:
                    s = 4 * abs(v.phase - 0.5) - 1
                case .square:
                    var q: Float = v.phase < 0.5 ? 1 : -1
                    q += Self.polyBLEP(v.phase, dt)
                    var shifted = v.phase + 0.5
                    if shifted >= 1 { shifted -= 1 }
                    q -= Self.polyBLEP(shifted, dt)
                    s = q * 0.6
                case .fm:
                    s = sine(v.phase + v.modIndex * 0.159 * sine(v.modPhase))
                    v.modPhase += f * v.modRatio * inverseRate
                    if v.modPhase >= 1 { v.modPhase -= 1 }
                    v.modIndex *= v.modDecay
                case .noise:
                    s = noise()
                }
                v.phase += dt
                if v.phase >= 1 { v.phase -= 1 }
                if v.useFilter { s = v.filter.process(s) }
                if v.lowpass < 1 {
                    v.lowState += (s - v.lowState) * v.lowpass
                    s = v.lowState
                }
                if v.attacking {
                    v.amplitude += v.attackStep
                    if v.amplitude >= v.peak {
                        v.amplitude = v.peak
                        v.attacking = false
                    }
                } else {
                    v.amplitude *= v.decay
                }
                let out = s * v.amplitude
                left[n] += out * v.left
                right[n] += out * v.right
            }
            if !v.attacking && v.amplitude < 0.0003 { v.active = false }
            voices[i] = v
        }

        let masterStep = 1 - exp(-1 / (0.1 * sampleRate))
        for n in 0..<frameCount {
            master += (masterTarget - master) * masterStep
            left[n] = tanh(left[n] * 0.9) * master
            right[n] = tanh(right[n] * 0.9) * master
        }
        if buffers.count > 2 {
            for b in 2..<buffers.count {
                if let data = buffers[b].mData { memset(data, 0, Int(buffers[b].mDataByteSize)) }
            }
        }
    }
}

/// Owns the audio graph: groove synth → small room reverb → speakers.
final class GrooveEngine {
    private let engine = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private var dsp: GrooveDSP?
    private var muted = false
    private var lastRestart: Double = 0

    func start() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
        if dsp == nil {
            let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let sampleRate = hardwareRate > 0 ? hardwareRate : 48_000
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
            let dsp = GrooveDSP(sampleRate: Float(sampleRate))
            dsp.setMuted(muted)
            let source = AVAudioSourceNode(format: format, renderBlock: dsp.makeRenderBlock())
            reverb.loadFactoryPreset(.mediumRoom)
            reverb.wetDryMix = 14
            engine.attach(source)
            engine.attach(reverb)
            engine.connect(source, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.85
            self.dsp = dsp
        }
        if !engine.isRunning {
            do { try engine.start() } catch { print("Audio engine failed to start: \(error)") }
        }
    }

    func pause() {
        if engine.isRunning { engine.pause() }
    }

    func play(_ kind: Sfx, a: Float = 0, pan: Float = 0) {
        dsp?.play(SfxEvent(kind: kind, a: a, b: pan))
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        dsp?.setMuted(muted)
    }

    /// Beats since the music started (fractional). Drives the dance-to-the-beat animations.
    var beat: Double { dsp?.beat ?? 0 }

    func update(energy: Float, now: Double) {
        dsp?.setEnergy(energy)
        if dsp != nil && !engine.isRunning && now - lastRestart > 1 {
            lastRestart = now
            try? engine.start()
        }
    }
}
