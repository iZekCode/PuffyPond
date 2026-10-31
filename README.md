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
| Open hand | Your hand's **brush animal** swims along with you (no ink). Its soft parts (tentacles, tail, shell, spikes) are springy: they trail, swing and wobble whenever you move. |
| **Pinch** (thumb + index) | Keep pinching and sweep your arm to paint — every brush animal paints its own way (see below). The paint is real-looking: flat wet strokes with ragged edges and bristle grooves; hold still and it pools into a blob, move fast for a dry streaky brush. Wet paint levels out, blends with neighbouring colors and thick blobs drip a little before drying. Let go to stop. |
| Rub your animal in a **paint pot** | The pots stand in a column down the right side of the canvas. Swipe it back and forth through one: it slowly turns that color while a ring fills around the pot, then *splash!* — new color. Chips under the hint show each hand's color and animal. |
| Rub a critter in a **bubble** | Bubbles in a column down the left side of the canvas hold little brush animals. Rub yours in one until the ring fills and it turns into that animal. |
| Fist | Your animal spins into a **Starfish** that scrubs paint away. |
| Clap | The drawing jiggles, inflates into a 3D creature, then shrinks to a cute half size and floats off the canvas. |
| Bump a creature with your animal | It boings away, surprised. |
| Starfish into a creature | It swells, trembles and **POPS**: rubber shards in its colors, flying googly eyes, a shockwave ring, sparkles, confetti and a puffy "POP!". |

The brush animals are expressive: calm while swimming, puffed-cheek and determined while blowing ink, wide-eyed and excited when drawing fast, surprised when they soak up a color or bump a creature, and happy (eyes closed, blushing) after finishing a line or when a creature is born.

### Brush animals

| Animal | Brush | How it paints |
|---|---|---|
| Octopus | Bundle brush | The mouth paints the main stroke; all eight tentacle tips trail thin lines. |
| Snail | Palette knife | Slow and heavy. Lays wide flat sheets with ridged edges and shoves wet paint along. |
| Pufferfish | Splatter | Swells up while you pinch (dribbling drops); let go and it bursts into a blob and a spray of dots — bigger the longer you held. |
| Seahorse | Calligraphy nib | A flat nib at 45°: thick or thin depending on the direction you move. |
| Jellyfish | Watercolor | Pale transparent washes that bloom outward, a bigger wash on every beat, and thin drips from the tentacles. |
| Frog | Dot prints | Hops after your hand; every landing stamps a round print with four toe dots. |

Up to 5 creatures live in the pond. When a 6th arrives, the oldest floats away like a lost balloon.

Mac extras: mouse-drag draws, double-click = bring to life, ⌥-drag or right-drag = erase.

## Under the hood

| File | Role |
|---|---|
| `HandTracker.swift` | Camera + Vision hand pose (2 hands, 720p, on device) |
| `HandInput.swift` | Palm tracking (big moves, not fingertips), open/fist with forgiving hysteresis, clap detection, smoothing + prediction |
| `Playground.swift` | The game: world, buddies, painting, erasing, transform, creature lifecycle, beat sync |
| `Critter.swift` | Brush animal base: follow spring, lean, squash, face and moods; each animal decides its own `dabs` (while pinching) and `released` (on letting go) |
| `Tentacles.swift` | Verlet-chain limbs (shape memory, lag, flare) rebuilt as tapered tubes every frame — octopus tentacles, jellyfish tentacles, seahorse tail |
| `Octopus.swift`, `Snail.swift`, `Pufferfish.swift`, `Seahorse.swift`, `Jellyfish.swift`, `Frog.swift` | The six brush animals |
| `Characters.swift` | Springs, faces/moods, Starfish rig, paint pots, critter bubbles, buddy (animal ↔ starfish) |
| `Strokes.swift` | Stroke paths that get inflated into creatures |
| `PaintLayer.swift`, `PaintShaders.metal` | Wet paint simulated on the GPU (Metal compute): brush dabs with rims and bristle grooves, the brush drags wet paint (advection), leveling, color mixing, drips and drying; drawn as one plane with a per-pixel normal map |
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
- Paint feel: constants at the top of `PaintLayer` (dry rate, leveling, drag damping, gravity, normal strength).
- Tentacle feel: `TentacleBundle.Shape` (stiffness = shape memory, drag, segment length) per animal. Each animal's brush: its `dabs` / `released` and the `BrushStyle` it uses (push, bristles, nib, watery, knife).
- Puffier creatures: `Inflator.puff`. Thicker lines: `Playground.strokeRadius`.
- Tempo/melody: top of `GrooveDSP`.
