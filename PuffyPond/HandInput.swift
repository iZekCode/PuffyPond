import Foundation
import QuartzCore
import simd

/// Big, forgiving poses only — no fiddly finger gestures.
enum HandPose: Equatable {
    case open   // fish swims along with you (and can dip into paint pots)
    case pinch  // thumb + index together: the fish blows ink
    case fist   // starfish erases
}

/// One hand as the game sees it, in view UV (0…1, y down).
struct HandState {
    var slot: Int            // 0 = left side of the screen, 1 = right
    var pose: HandPose
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var tracking: Bool
    var isPointer = false
}

/// Palm-level reading of one Vision observation.
struct PalmReading {
    var palm: SIMD2<Float>
    var extendedFingers: Int
    /// Thumb-tip to index-tip distance, in hand sizes.
    var pinchRatio: Float = 10
    /// Index tip to wrist, in hand sizes (a curled index in a fist sits close to the palm).
    var indexReach: Float = 0

    init?(_ hand: HandObservation, aspect: Float) {
        guard let wrist = hand[.wrist] else { return nil }
        let knuckles = [hand[.indexMCP], hand[.middleMCP], hand[.ringMCP], hand[.littleMCP]].compactMap { $0 }
        guard knuckles.count >= 2 else { return nil }
        let points = [wrist] + knuckles
        palm = points.reduce(SIMD2<Float>.zero, +) / Float(points.count)

        let scale = SIMD2<Float>(aspect, 1)
        func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { simd_distance(a * scale, b * scale) }
        var count = 0
        let fingers: [(HandJoint, HandJoint)] = [(.indexTip, .indexPIP), (.middleTip, .middlePIP),
                                                 (.ringTip, .ringPIP), (.littleTip, .littlePIP)]
        for (tip, pip) in fingers {
            if let t = hand[tip], let p = hand[pip], distance(t, wrist) > distance(p, wrist) * 1.12 {
                count += 1
            }
        }
        extendedFingers = count

        let middleKnuckle = hand[.middleMCP] ?? knuckles[0]
        let size = max(distance(wrist, middleKnuckle), 0.02)
        if let thumb = hand[.thumbTip], let index = hand[.indexTip] {
            pinchRatio = distance(thumb, index) / size
            indexReach = distance(index, wrist) / size
        }
    }
}

/// Turns camera frames into two smooth, predicted hands.
final class HandInput {
    struct Tracked {
        let id: Int
        var slot: Int
        var pose: HandPose = .open
        var candidateFrames = 0
        var filter = OneEuroFilter2D(minCutoff: 1.2, beta: 0.7, derivativeCutoff: 1.2)
        var palmImage: SIMD2<Float> = .zero
        var target: SIMD2<Float> = .zero
        var targetVelocity: SIMD2<Float> = .zero
        var lastSample: Double = 0
        var cursor: SIMD2<Float> = .zero
        var previousCursor: SIMD2<Float> = .zero
        var hasCursor = false
    }

    // The part of the camera image that spans the whole view. Generous, so big arm moves reach the edges.
    static let reachMin = SIMD2<Float>(0.08, 0.08)
    static let reachMax = SIMD2<Float>(0.92, 0.86)

    private(set) var tracked: [Tracked] = []
    private var nextID = 1

    private func viewUV(fromImage p: SIMD2<Float>) -> SIMD2<Float> {
        (p - Self.reachMin) / (Self.reachMax - Self.reachMin)
    }

    func ingest(_ frame: HandFrame) {
        let now = CACurrentMediaTime()
        let readings = frame.hands.compactMap { PalmReading($0, aspect: frame.imageAspect) }

        var available = Array(tracked.indices)
        for reading in readings.prefix(2) {
            var best: Int?
            var bestDistance: Float = 0.35
            for i in available {
                let d = simd_distance(tracked[i].palmImage, reading.palm)
                if d < bestDistance { bestDistance = d; best = i }
            }
            if let i = best {
                available.removeAll { $0 == i }
                update(&tracked[i], with: reading, now: now)
            } else if tracked.count < 2 {
                let uv = viewUV(fromImage: reading.palm)
                let used = Set(tracked.map(\.slot))
                var slot = uv.x < 0.5 ? 0 : 1
                if used.contains(slot) { slot = 1 - slot }
                var hand = Tracked(id: nextID, slot: slot)
                nextID += 1
                hand.pose = reading.extendedFingers == 0 ? .fist : .open
                update(&hand, with: reading, now: now)
                tracked.append(hand)
            }
        }
        tracked.removeAll { now - $0.lastSample > 0.6 }
    }

    private func update(_ hand: inout Tracked, with reading: PalmReading, now: Double) {
        let dt = Float(min(max(now - hand.lastSample, 1.0 / 120.0), 0.1))
        // Pinch wins first (with hysteresis so it doesn't flicker while drawing).
        // In a fist the thumb also rests on the index, but the index tip is tucked near the palm.
        let pinchThreshold: Float = hand.pose == .pinch ? 0.55 : 0.33
        let pinching = reading.pinchRatio < pinchThreshold && reading.indexReach > 0.95
        let raw: HandPose
        if pinching {
            raw = .pinch
        } else if hand.pose == .fist {
            raw = reading.extendedFingers >= 2 ? .open : .fist
        } else {
            raw = reading.extendedFingers == 0 ? .fist : .open
        }
        if raw != hand.pose {
            hand.candidateFrames += 1
            let needed: Int
            switch raw {
            case .pinch: needed = 1
            case .open: needed = 2
            case .fist: needed = 3
            }
            if hand.candidateFrames >= needed {
                hand.pose = raw
                hand.candidateFrames = 0
            }
        } else {
            hand.candidateFrames = 0
        }
        let filtered = hand.filter.filter(reading.palm, dt: dt)
        let span = Self.reachMax - Self.reachMin
        hand.palmImage = reading.palm
        hand.target = viewUV(fromImage: filtered)
        let v = hand.filter.velocity / span
        let speed = simd_length(v)
        hand.targetVelocity = speed > 6 ? v * (6 / speed) : v
        hand.lastSample = now
    }

    /// Render-rate smoothing with a little prediction to hide camera latency.
    func advance(dt: Float, now: Double) -> [HandState] {
        var states: [HandState] = []
        let follow = 1 - exp(-dt * 22)
        for i in tracked.indices {
            var hand = tracked[i]
            let age = Float(now - hand.lastSample)
            let tracking = age < 0.25
            let lead: Float = tracking ? min(age, 0.06) + 0.02 : 0
            let target = hand.target + hand.targetVelocity * lead
            if !hand.hasCursor {
                hand.cursor = target
                hand.previousCursor = target
                hand.hasCursor = true
            }
            hand.previousCursor = hand.cursor
            hand.cursor += (target - hand.cursor) * follow
            tracked[i] = hand
            states.append(HandState(slot: hand.slot, pose: hand.pose, position: hand.cursor,
                                    velocity: (hand.cursor - hand.previousCursor) / max(dt, 1e-4),
                                    tracking: tracking))
        }
        return states
    }

    /// Raw joints (image space) for the camera preview.
    static func previewPoints(_ frame: HandFrame) -> [[SIMD2<Float>]] {
        frame.hands.map { $0.joints.compactMap { $0 } }
    }
}
