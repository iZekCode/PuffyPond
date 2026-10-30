# Puffy Pond

Draw in the air with both hands. Your strokes puff up into glossy balloon lines, then the whole drawing inflates into a jiggly 3D creature that floats around, dances to the music, watches your hands and boings when you bump it.

## Run it (Mac)

1. Open `PuffyPond.xcodeproj` in Xcode 26, choose **My Mac** as the run destination.
2. Signing & Capabilities → pick your team. Press **⌘R** and allow camera access.
3. Stand or sit back so the camera sees both hands (about an arm's length or more).

It also runs on iPhone/iPad (portrait). No camera? Drag with the mouse/finger to draw.

## How to play

| Move | What happens |
|---|---|
| Open hand | Your hand's **Little Fish** swims along with you (no ink). |
| **Pinch** (thumb + index) | The fish puffs its cheeks and blows ink — keep pinching and sweep your arm to paint. The paint is real-looking: flat wet strokes with ragged edges and bristle grooves; hold still and it pools into a blob, move fast for a dry streaky brush. Wet paint levels out, blends with neighbouring colors and thick blobs drip a little before drying. Let go to stop. |
| Rub a fish in a **paint pot** | The pots sit along the bottom. Swipe the fish back and forth through one: the fish slowly turns that color while a ring fills around the pot, then *splash!* — new color. Chips under the hint show each fish's color. |
| Fist | The fish spins into a **Starfish** that scrubs paint away. |
| Clap (or just pause ~3 s) | The drawing jiggles, inflates into a 3D creature, then shrinks to a cute half size and floats off the canvas. |
| Bump a creature with a fish | It boings away, surprised. |
| Starfish into a creature | It swells, trembles and **POPS**: rubber shards in its colors, flying googly eyes, a shockwave ring, sparkles, confetti and a puffy "POP!". |

The fish are expressive: calm while swimming, puffed-cheek and determined while blowing ink, wide-eyed and excited when drawing fast, surprised when they soak up a color or bump a creature, and happy (eyes closed, blushing) after finishing a line or when a creature is born.

Up to 5 creatures live in the pond. When a 6th arrives, the oldest floats away like a lost balloon.

Mac extras: mouse-drag draws, double-click = bring to life, ⌥-drag or right-drag = erase.

## Under the hood

| File | Role |
|---|---|
| `HandTracker.swift` | Camera + Vision hand pose (2 hands, 720p, on device) |
| `HandInput.swift` | Palm tracking (big moves, not fingertips), open/fist with forgiving hysteresis, clap detection, smoothing + prediction |
| `Playground.swift` | The game: world, buddies, painting, erasing, transform, creature lifecycle, beat sync |
| `Characters.swift` | Little Fish and Starfish rigs: spring physics, squash & stretch, tail wag, blinking googly eyes |
| `Strokes.swift` (PaintLayer) | Puffy tube meshes whose beads inflate with an overshoot |
| `Strokes.swift` | `PaintLayer`: wet textured paint as a tiled height field (bristles, rims, pooling, flow, drips, drying) + stroke paths for inflation |
| `Inflator.swift` | Drawing → 3D balloon: fills closed shapes, solves ∇²u = −1, height = √(2u) for round cross-sections; picks where the face goes |
| `Creature.swift` | Living creatures: inflate, wander, bob, wiggle, dance on the beat, look at hands, boing, pop |
| `Toybox.swift` | Glossy balloon material with a jiggle vertex shader, eyes/lips, backdrop, particles |
| `GrooveDSP.swift` | 118 BPM toy-pop groove synthesized live (kick, claps, hats, bass, stabs, lead over I–V–vi–IV) + all sound effects + beat clock |
| `HUDView.swift`, `Platform.swift` | Overlay and Mac/iOS differences |

## Tuning
- Hands don't reach the edges: `HandInput.reachMin/reachMax`.
- Pinch/fist detection: thresholds in `HandInput.update` (pinch enters below 0.33 hand-sizes, releases above 0.55).
- Creature size: `Creature.finalSize` (0.5). Color pick speed: `rubPots` in `Playground`.
- Clap too sensitive / not sensitive: distances in `HandInput.detectClap`.
- Puffier creatures: `Inflator.puff`. Thicker lines: `Playground.strokeRadius`.
- Tempo/melody: top of `GrooveDSP`.
