"use client";

import { motion } from "motion/react";

export interface Tick {
  id: number;
  detected: boolean;
}

const MAX_BARS = 48;

export function FeedThroughput({ ticks }: { ticks: Tick[] }) {
  const visible = ticks.slice(-MAX_BARS);
  const padding = MAX_BARS - visible.length;

  return (
    <div>
      <div className="flex h-16 items-end gap-[3px] overflow-hidden">
        {Array.from({ length: padding }).map((_, i) => (
          <div key={`pad-${i}`} className="w-[5px] shrink-0" />
        ))}
        {visible.map((tick) => (
          <motion.div
            key={tick.id}
            initial={{ height: 6, opacity: 0.4 }}
            animate={{
              height: tick.detected ? 56 : 10 + (tick.id % 5) * 2,
              opacity: 1,
              background: tick.detected
                ? "#f59e0b"
                : "var(--foreground-dim)",
            }}
            transition={{ type: "spring", damping: 1, duration: 0.5 }}
            className="w-[5px] shrink-0 rounded-full"
            style={{
              boxShadow: tick.detected ? "0 0 12px rgba(245,158,11,0.6)" : "none",
            }}
          />
        ))}
      </div>
      <p className="mt-3 text-[11px] leading-relaxed text-foreground-dim">
        Sequencer feed activity — baseline motion is ambient (not a real
        tx/sec count); a bar turns amber only on an actual detected{" "}
        <code>updateMultiplier()</code> call.
      </p>
    </div>
  );
}
