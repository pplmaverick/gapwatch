"use client";

import { useEffect, useRef } from "react";

/** One completed `/audit-log` poll. Pushed by the page that owns the polling. */
export interface FeedPoll {
  /** `Date.now()` when the response resolved. */
  at: number;
  /** Events that were NOT present in the previous poll. Usually empty. */
  detections: FeedDetection[];
}

export interface FeedDetection {
  eventId: number;
  /** Token symbol when known, else a shortened address. */
  token: string;
  at: number;
}

/** Seconds of history across the full width. */
const WINDOW_MS = 60_000;
/** How fast a spike falls back to the baseline (exponential time constant). */
const DECAY_MS = 2_400;
/** Rise time of a spike. Short enough to read as instantaneous. */
const ATTACK_MS = 70;

const TRACE_WIDTH = 1.5;
const SPIKE_COLOR = "#f59e0b";

export function FeedWaveform({ polls }: { polls: FeedPoll[] }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  // Read in the draw loop rather than through props, so a new poll never has to
  // restart the animation frame loop. Synced in an effect, not during render;
  // the resulting one-frame lag is invisible against a 5s poll interval.
  const pollsRef = useRef(polls);
  // Exposed so the reduced-motion path, which runs no animation loop, can
  // still repaint when new poll data arrives.
  const drawRef = useRef<(() => void) | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const styles = getComputedStyle(document.documentElement);
    const traceColor = styles.getPropertyValue("--foreground-dim").trim() || "#565d69";
    const labelColor = styles.getPropertyValue("--foreground-muted").trim() || "#8b93a1";

    let width = 0;
    let height = 0;

    const resize = () => {
      const dpr = window.devicePixelRatio || 1;
      const rect = canvas.getBoundingClientRect();
      width = rect.width;
      height = rect.height;
      canvas.width = Math.max(1, Math.round(width * dpr));
      canvas.height = Math.max(1, Math.round(height * dpr));
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    resize();

    const observer = new ResizeObserver(resize);
    observer.observe(canvas);

    // Deterministic, slow, and tiny: this is "the monitor is powered on", not a
    // data series. Derived from the timestamp so it travels with the trace
    // instead of shimmering in place, which would read as decoration.
    const ambient = (t: number) =>
      Math.sin(t / 1730) * 0.42 + Math.sin(t / 970) * 0.3 + Math.sin(t / 430) * 0.16;

    // A completed poll that found nothing still leaves a mark -- that is the
    // honest signal here: "checked, nothing there", once per real request.
    const pollTick = (dt: number) => {
      const w = 190;
      if (dt < 0 || dt > w) return 0;
      return Math.sin((dt / w) * Math.PI) * 0.85;
    };

    const spike = (dt: number) => {
      if (dt < 0) return 0;
      const attack = Math.min(1, dt / ATTACK_MS);
      return attack * Math.exp(-dt / DECAY_MS);
    };

    const draw = () => {
      const now = Date.now();
      const current = pollsRef.current;
      const mid = height * 0.58;
      const ambientPx = 2.0;
      const tickPx = 4.5;
      const spikePx = height * 0.4;

      ctx.clearRect(0, 0, width, height);

      const timeAt = (x: number) => now - WINDOW_MS * (1 - x / width);

      const yAt = (t: number) => {
        let y = ambient(t) * ambientPx;
        for (const p of current) y += pollTick(t - p.at) * tickPx;
        for (const p of current) {
          for (const d of p.detections) y += spike(t - d.at) * spikePx;
        }
        return mid - y;
      };

      // Baseline trace.
      ctx.beginPath();
      for (let x = 0; x <= width; x += 1) {
        const y = yAt(timeAt(x));
        if (x === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
      ctx.strokeStyle = traceColor;
      ctx.lineWidth = TRACE_WIDTH;
      ctx.lineJoin = "round";
      ctx.stroke();

      // Each live detection re-draws its own stretch in amber, on top. Flat
      // colour only -- no shadow blur, matching the rest of the project.
      for (const p of current) {
        for (const d of p.detections) {
          const startX = ((d.at - (now - WINDOW_MS)) / WINDOW_MS) * width;
          const endX = startX + (DECAY_MS * 2.6 / WINDOW_MS) * width;
          if (endX < 0 || startX > width) continue;

          ctx.beginPath();
          let started = false;
          for (let x = Math.max(0, startX - 1); x <= Math.min(width, endX); x += 1) {
            const y = yAt(timeAt(x));
            if (!started) {
              ctx.moveTo(x, y);
              started = true;
            } else ctx.lineTo(x, y);
          }
          if (started) {
            ctx.strokeStyle = SPIKE_COLOR;
            ctx.lineWidth = TRACE_WIDTH;
            ctx.stroke();
          }

          // Marker + token label below the baseline, travelling with the spike.
          if (startX >= 0 && startX <= width) {
            const markerY = height - 9;
            ctx.beginPath();
            ctx.arc(startX, markerY, 2, 0, Math.PI * 2);
            ctx.fillStyle = SPIKE_COLOR;
            ctx.fill();

            ctx.font = "500 10px ui-monospace, SFMono-Regular, Menlo, monospace";
            ctx.fillStyle = labelColor;
            ctx.textBaseline = "middle";
            const label = d.token;
            const tw = ctx.measureText(label).width;
            // Flip the label inward when the spike is near the right edge.
            const lx = startX + 6 + tw > width ? startX - 6 - tw : startX + 6;
            ctx.fillText(label, lx, markerY);
          }
        }
      }
    };

    // Reduced motion: no continuous loop. Redraw only when the data actually
    // changes, so the trace still reports real polls without animating.
    drawRef.current = draw;

    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
    let raf = 0;
    const loop = () => {
      draw();
      raf = requestAnimationFrame(loop);
    };

    if (reduced.matches) draw();
    else raf = requestAnimationFrame(loop);

    const onPreferenceChange = () => {
      cancelAnimationFrame(raf);
      if (reduced.matches) draw();
      else raf = requestAnimationFrame(loop);
    };
    reduced.addEventListener("change", onPreferenceChange);

    return () => {
      cancelAnimationFrame(raf);
      observer.disconnect();
      reduced.removeEventListener("change", onPreferenceChange);
      drawRef.current = null;
    };
  }, []);

  // One effect so the ref is always current before the redraw below reads it.
  useEffect(() => {
    pollsRef.current = polls;
    // The reduced-motion path runs no animation loop, so it needs an explicit
    // repaint to pick the new poll up.
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      drawRef.current?.();
    }
  }, [polls]);

  const detectionCount = polls.reduce((n, p) => n + p.detections.length, 0);

  return (
    <div>
      <canvas
        ref={canvasRef}
        className="block h-16 w-full"
        role="img"
        aria-label={
          detectionCount > 0
            ? `Sequencer feed monitor: ${detectionCount} multiplier update detected in the last minute`
            : "Sequencer feed monitor: no multiplier updates detected in the last minute"
        }
      />
      <p className="mt-3 text-[11px] leading-relaxed text-foreground-dim">
        Sequencer feed monitor — one small tick per completed{" "}
        <code>/audit-log</code> poll, so the trace advances only when a real
        request returns. A spike turns amber, labelled with the token, the
        moment a poll returns an <code>UIMultiplierUpdated</code> event that
        was not in the previous response. Last 60 seconds.
      </p>
    </div>
  );
}
