"use client";

import { motion } from "motion/react";
import { useState } from "react";

const LINES = ["Detected.", "Verified.", "Confirmed."];

/**
 * Survives the unmount/remount that a client-side navigation back to "/"
 * causes, so the entrance reads as a first-load moment rather than something
 * that replays every time someone taps the logo. A full page reload starts a
 * new module instance and plays it again, which is the intent.
 *
 * Set only once the entrance has actually *finished*, not on mount. That keeps
 * StrictMode's dev-only double mount honest -- its first mount is torn down
 * long before the ~0.74s reveal completes, so the surviving mount still plays
 * -- and it means someone who navigates away mid-animation, having never seen
 * it, gets it on their way back.
 *
 * Never mutated during render, so the server's copy of this module (shared
 * across every request) stays false and SSR output is identical for everyone.
 */
let hasPlayedThisSession = false;

type Entrance = "spring" | "crossfade" | "instant";

function resolveEntrance(): Entrance {
  // SSR has no media query to read and no session history; it emits the
  // hidden `initial` state either way, so the choice here only has to be
  // stable, not correct.
  if (typeof window === "undefined") return "spring";
  if (hasPlayedThisSession) return "instant";
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ? "crossfade"
    : "spring";
}

export function HeroTitle({ className }: { className?: string }) {
  // Resolved once per mount and then frozen: the flag flips while the
  // animation is still running, and re-deriving it would retarget the
  // transition mid-flight.
  const [entrance] = useState(resolveEntrance);

  return (
    <h1 className={className}>
      {LINES.map((line, i) => (
        <motion.span
          key={line}
          initial={{ opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={transitionFor(entrance, i)}
          onAnimationComplete={
            i === LINES.length - 1
              ? () => {
                  hasPlayedThisSession = true;
                }
              : undefined
          }
        >
          {line}
        </motion.span>
      ))}
    </h1>
  );
}

function transitionFor(entrance: Entrance, i: number) {
  switch (entrance) {
    // Already seen this session -- snap to the resting state with no motion.
    case "instant":
      return { duration: 0 };

    // Reduced motion still gets the staggered reveal, but as a pure opacity
    // cross-fade: `y` is snapped to its target so no vestibular translation
    // happens, while the sequencing that makes the three lines read in order
    // is preserved.
    case "crossfade":
      return {
        opacity: { duration: 0.24, ease: "easeOut" as const, delay: i * 0.05 },
        y: { duration: 0 },
      };

    // Critically damped (bounce 0) -- nothing here carried momentum from a
    // gesture, so overshoot would be decoration rather than physics.
    // visualDuration is Apple's "response": how long a line takes to visually
    // arrive. 0.24s of stagger + 0.5s response lands the last line at ~0.74s.
    case "spring":
      return {
        type: "spring" as const,
        bounce: 0,
        visualDuration: 0.5,
        delay: i * 0.12,
      };
  }
}
