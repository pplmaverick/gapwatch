"use client";

import { motion } from "motion/react";
import { useEffect, useRef, useState, type CSSProperties } from "react";

const STAGES = [
  { label: "Sequencer feed", detail: "Robinhood Chain mainnet feed" },
  { label: "Filter check", detail: "isTransactionFiltered" },
  { label: "L1 confirmation", detail: "block finality" },
  {
    label: "Reference model",
    detail: "recorded on testnet registry",
    final: true,
  },
];

// One lap of the pulse: a uniform-speed run down the line, then a short rest
// before it starts over. The band and the node glows are independent CSS
// animations kept in phase only because they share this cycle, so these must
// stay in sync with the percentages in globals.css (81.25% = TRAVEL/CYCLE,
// 21.875% = DECAY/CYCLE).
const TRAVEL_MS = 2600;
const PAUSE_MS = 600;
const CYCLE_MS = TRAVEL_MS + PAUSE_MS;

// Tall enough to hold the drop-shadow without the SVG viewport clipping it.
const TRACK_HEIGHT = 16;
const TRACK_WIDTH = 1.5;

interface Track {
  /** Offset of the whole track within the diagram, in px. */
  left: number;
  top: number;
  width: number;
  /** Node centres relative to the track's own left edge. */
  nodes: number[];
  bandWidth: number;
}

export function PipelineDiagram() {
  const containerRef = useRef<HTMLDivElement>(null);
  const gridRef = useRef<HTMLDivElement>(null);
  const dotRefs = useRef<(HTMLSpanElement | null)[]>([]);
  const [track, setTrack] = useState<Track | null>(null);

  useEffect(() => {
    const container = containerRef.current;
    const grid = gridRef.current;
    if (!container || !grid) return;

    // Below `md` the stages wrap onto two rows, so there is no single
    // left-to-right line to run a current along -- the original design shows
    // no connectors there either, and that stays true.
    const isRow = window.matchMedia("(min-width: 768px)");
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

    const measure = () => {
      if (!isRow.matches || reduced.matches) {
        setTrack(null);
        return;
      }

      const dots = dotRefs.current.slice(0, STAGES.length);
      if (dots.some((dot) => dot === null)) {
        setTrack(null);
        return;
      }

      const base = container.getBoundingClientRect();
      const rects = (dots as HTMLSpanElement[]).map((dot) =>
        dot.getBoundingClientRect()
      );

      // Horizontal centres come straight off the dots: the entrance animation
      // only translates on Y, so X is already at its resting value. Y cannot
      // be read the same way -- mid-entrance the dots sit up to 16px low. The
      // grid itself is never transformed, and on a single row each dot's top
      // edge is the grid's top edge, so the grid supplies the stable baseline.
      const gridTop = grid.getBoundingClientRect().top - base.top;
      const centreY = gridTop + rects[0].height / 2;

      const startX = rects[0].left - base.left + rects[0].width / 2;
      const endX =
        rects[rects.length - 1].left - base.left +
        rects[rects.length - 1].width / 2;
      const width = endX - startX;
      if (width <= 0) {
        setTrack(null);
        return;
      }

      setTrack({
        left: startX,
        top: centreY - TRACK_HEIGHT / 2,
        width,
        nodes: rects.map((r) => r.left - base.left + r.width / 2 - startX),
        // Short relative to the run, but clamped so it neither disappears on a
        // wide viewport nor swamps the line on a narrow one.
        bandWidth: Math.min(Math.max(width * 0.13, 72), 150),
      });
    };

    measure();

    const observer = new ResizeObserver(measure);
    observer.observe(container);
    isRow.addEventListener("change", measure);
    reduced.addEventListener("change", measure);

    return () => {
      observer.disconnect();
      isRow.removeEventListener("change", measure);
      reduced.removeEventListener("change", measure);
    };
  }, []);

  // The band's bright head starts at the first node and travels the full line
  // plus its own length (so the tail clears the end too), at a constant speed.
  // A node lights the moment the head reaches it.
  const nodeDelayMs = (i: number) => {
    if (!track) return 0;
    return (track.nodes[i] / (track.width + track.bandWidth)) * TRAVEL_MS;
  };

  return (
    <div ref={containerRef} className="relative">
      {track && (
        <motion.svg
          aria-hidden
          className="pointer-events-none absolute"
          style={{
            left: track.left,
            top: track.top,
            width: track.width,
            height: TRACK_HEIGHT,
          }}
          width={track.width}
          height={TRACK_HEIGHT}
          viewBox={`0 0 ${track.width} ${TRACK_HEIGHT}`}
          initial={{ opacity: 0 }}
          whileInView={{ opacity: 1 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.4, delay: 0.1 }}
        >
          <defs>
            {/* Bright at the head (right), falling away through the tail, with
              * a short soft tip so the leading edge isn't a hard cut. */}
            <linearGradient id="gw-pulse-gradient" x1="0" y1="0" x2="1" y2="0">
              <stop
                offset="0%"
                style={{ stopColor: "var(--interactive)" }}
                stopOpacity={0}
              />
              <stop
                offset="62%"
                style={{ stopColor: "var(--interactive)" }}
                stopOpacity={0.18}
              />
              <stop
                offset="94%"
                style={{ stopColor: "var(--interactive)" }}
                stopOpacity={0.95}
              />
              <stop
                offset="100%"
                style={{ stopColor: "var(--interactive)" }}
                stopOpacity={0.3}
              />
            </linearGradient>
          </defs>

          <line
            x1={0}
            y1={TRACK_HEIGHT / 2}
            x2={track.width}
            y2={TRACK_HEIGHT / 2}
            strokeWidth={TRACK_WIDTH}
            style={{ stroke: "var(--border-strong)" }}
          />

          {/* Parked just off the left edge; the SVG viewport clips it at both
            * ends, so the rest at the end of each lap is genuinely invisible
            * and the restart has no seam. The drop-shadow follows the fill's
            * alpha, which puts the glow on the head and almost none on the
            * tail. */}
          <rect
            className="gw-pulse-band"
            x={-track.bandWidth}
            y={(TRACK_HEIGHT - TRACK_WIDTH) / 2}
            width={track.bandWidth}
            height={TRACK_WIDTH}
            fill="url(#gw-pulse-gradient)"
            style={
              {
                "--gw-pulse-travel": `${track.width + track.bandWidth}px`,
                animationDuration: `${CYCLE_MS}ms`,
                filter: "drop-shadow(0 0 5px rgba(94, 234, 221, 0.5))",
              } as CSSProperties
            }
          />
        </motion.svg>
      )}

      <div
        ref={gridRef}
        className="relative grid grid-cols-2 gap-x-6 gap-y-10 md:grid-cols-4 md:gap-x-4"
        role="list"
      >
        {STAGES.map((stage, i) => (
          <motion.div
            key={stage.label}
            role="listitem"
            className="relative flex flex-col items-start gap-3"
            initial={{ opacity: 0, y: 16 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-80px" }}
            transition={{
              type: "spring",
              bounce: 0,
              visualDuration: 0.5,
              delay: i * 0.08,
            }}
          >
            <span
              ref={(el) => {
                dotRefs.current[i] = el;
              }}
              className={`h-[13px] w-[13px] shrink-0 rounded-full ${
                track
                  ? stage.final
                    ? "gw-pulse-node-confirmed"
                    : "gw-pulse-node"
                  : ""
              }`}
              style={{
                background: stage.final
                  ? "var(--semantic-confirmed)"
                  : "transparent",
                border: stage.final
                  ? "none"
                  : "1.5px solid var(--foreground-dim)",
                boxShadow: stage.final
                  ? "0 0 14px var(--semantic-confirmed-dim)"
                  : "none",
                animationDelay: track ? `${nodeDelayMs(i)}ms` : undefined,
                animationDuration: track ? `${CYCLE_MS}ms` : undefined,
              }}
            />
            <div>
              <p
                className="text-[13px] font-medium tracking-tight"
                style={{
                  color: stage.final
                    ? "var(--semantic-confirmed)"
                    : "var(--foreground)",
                }}
              >
                {stage.label}
              </p>
              <p className="mt-1 text-[12px] leading-snug text-foreground-dim">
                {stage.detail}
              </p>
            </div>
          </motion.div>
        ))}
      </div>
      <p className="mt-10 text-[12px] leading-relaxed text-foreground-dim">
        Feed monitored: Robinhood Chain{" "}
        <span className="text-foreground-muted">mainnet</span>. Verification
        recorded: Robinhood Chain{" "}
        <span className="text-foreground-muted">testnet</span> registry — the
        monitoring target and the deployed verification contracts are on
        different networks.
      </p>
    </div>
  );
}
