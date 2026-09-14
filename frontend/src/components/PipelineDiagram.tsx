"use client";

import { motion } from "motion/react";

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

export function PipelineDiagram() {
  return (
    <div className="relative">
      <div
        className="grid grid-cols-2 gap-x-6 gap-y-10 md:grid-cols-4 md:gap-x-4"
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
              damping: 1,
              duration: 0.5,
              delay: i * 0.08,
            }}
          >
            {i < STAGES.length - 1 && (
              <div
                className="absolute top-[7px] left-[calc(100%_-_0px)] hidden h-px md:block"
                style={{
                  width: "calc(100% - 8px)",
                  marginLeft: "8px",
                  background:
                    "linear-gradient(90deg, var(--border-strong), var(--border-soft))",
                }}
              />
            )}
            <span
              className="h-[13px] w-[13px] shrink-0 rounded-full"
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
