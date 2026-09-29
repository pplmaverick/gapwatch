# Gapwatch — Project Design Direction

## AESTHETIC

**Marketing vs App split**: deliberate but unified register — both halves use Deep Space Tech, so there's no dark→light→dark inconsistency across the Landing → App transition.

- **Landing page**: Deep Space Tech, Vercel-style. Dark background, oversized headline typography, generous negative space, minimal chrome. This is the "convince the judge" surface — restraint and confidence, not a spec sheet.
- **App screens (A/B/C)**: Deep Space Tech + the `apple-design` motion/interaction layer applied on top. This is the "get work done" surface — data-dense, live-updating, needs real depth and hierarchy so it doesn't collapse into a flat table under load.

## REFERENCE

- **Vercel homepage** — borrow: oversized 3-line headline rhythm ("Develop. Preview. Ship." pattern), muted small-caps micro-copy beneath the headline, a single bright accent used sparingly (not spread across every element), abstract line-based architecture diagrams for scroll sections below the fold. This is also the source of the interactive-accent choice (white/cyan over purple).
- **Ledger** — borrow: dark-mode restraint, single-hue glow accents on interactive elements only, no gradient soup.
- **apple-design (emilkowalski/skills)** — borrow: critically-damped springs (`damping 1.0`) as the default for all UI transitions, `backdrop-filter` translucent layers for nav/floating cards instead of flat opaque panels, size-specific letter-tracking (tight negative tracking on large display type, near-zero on body text), materialize-don't-fade transitions for any glass/blur surface entering or leaving.

## INTENT

- **Audience**: Arbitrum Open House Singapore judges, and secondarily developers/protocols evaluating whether to build on top of Gapwatch's verification layer. Not retail end users.
- **Desired action in the first ~30 seconds**: understand that Gapwatch is an independent, developer-facing verification layer for Robinhood Chain corporate actions — not a trading tool, not an extension of Robinhood Predictor — and see enough of the live pipeline to trust it's a real, working system rather than a mockup.

## LANDING HERO SPEC (finalized)

- **Headline** (three-part rhythm, one stage per line, Vercel "Develop. Preview. Ship." cadence): "Detected. Verified. Confirmed." — deliberately mirrors Screen B's exact three-stage pipeline (Detected on feed → Verified not filtered → Confirmed on L1) so the Landing page and the live monitor tell the same story in the same words.
- **Below-fold**: abstract line diagram of the 4-stage pipeline — Sequencer feed → Filter check → L1 confirmation → Reference model — thin connecting lines, neutral node color for the first 3 stages, the mint-green state accent (`#4ADE80`) on the final "Reference model" node only, to visually tie the diagram's endpoint to the same "confirmed/verified" semantic used everywhere else on the site.

## GUARDRAILS

**Always**:
- Two-color accent system, roles kept strictly separate — never merge them onto the same element:
  - **Interactive accent — cyan `#5EEAD4`**: buttons, links, hover states, any clickable element. This is the "brand" color.
  - **Semantic state accent — mint green `#4ADE80`**: reserved exclusively for "confirmed / verified" states (e.g. "Confirmed on L1" badges, the Registry's verified checkmark). Never used for anything interactive or decorative.
  - No other accent hues anywhere on the site. Purple is explicitly excluded (see Never, below).
- One clear focal element per screen with heavier weight (larger type, stronger border, more surrounding whitespace); everything else on that screen quiets down (thinner borders, dimmer text, tighter spacing). No two elements on the same screen compete for attention.
- Real `backdrop-filter` translucent layers for nav bars and floating/overlay cards — flat opaque panels with a thin border are the default "AI slop" tell to avoid.
- Critically-damped springs (`damping ~1.0`) for all state transitions (Screen B's pipeline stage changes, new events entering the Screen C log) — no fixed-duration CSS keyframe animations for anything state-driven.
- Size-specific type tracking: tight negative letter-spacing on the Landing headline, neutral/near-zero on body and data-table text.
- Real on-chain/API data everywhere, including in exploration variants — never a fabricated transaction count, percentage, or "live" stat. This audience will notice.

**Never**:
- Purple as the accent color — it's the default Web3-project choice (see: Midnight Private Auction) and reads as generic rather than as "verification/infrastructure."
- Reusing the interactive cyan (`#5EEAD4`) for a "confirmed" badge, or the state mint-green (`#4ADE80`) for a button — this collapses the two-color system back into the single-accent confusion it was designed to avoid.
- Uniform border weight / uniform card padding across a screen — every card at the same visual weight is the single biggest "looks like every other hackathon project" signal.
- Purple-blue gradients, Inter as the only typeface, rounded icon tiles stacked above every heading, cards nested inside cards.
- Structural changes (component boundaries, hooks, data-fetching, contract-call logic) during a cosmetic/visual pass — cosmetic passes touch only `className`/`style`/CSS values. Any new interactive element is a separate, explicitly-scoped task.
- Reusing Robinhood Predictor's cyberpunk-terminal / crypto-native-dashboard trading aesthetic — Gapwatch must read as a distinct, independent project.
