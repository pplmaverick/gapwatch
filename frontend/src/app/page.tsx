import Link from "next/link";
import { NavBar } from "@/components/NavBar";
import { PipelineDiagram } from "@/components/PipelineDiagram";

const SHIPPED = [
  "Tier 1 — GapwatchRegistry deployed to Robinhood Chain Testnet",
  "Tier 2 — challenge-bond mechanism live on-chain (testnet)",
  "Tier 2.5 — MockLendingPool demo downstream consumer deployed (testnet)",
  "Database + API layer (modules 6+7) reading the registry directly",
];

export default function Home() {
  return (
    <>
      <NavBar />
      <main className="flex-1">
        <section className="mx-auto flex max-w-6xl flex-col px-6 pt-40 pb-28 md:px-10 md:pt-52 md:pb-36">
          <p className="mb-6 text-[11px] font-medium uppercase tracking-[0.16em] text-foreground-muted">
            Independent verification layer &middot; Robinhood Chain
          </p>

          <h1 className="flex flex-col text-[15vw] font-semibold leading-[0.95] tracking-[-0.04em] text-foreground sm:text-[9vw] md:text-[6.4rem]">
            <span>Detected.</span>
            <span>Verified.</span>
            <span>Confirmed.</span>
          </h1>

          <p className="mt-8 max-w-md text-[15px] leading-relaxed text-foreground-muted">
            Gapwatch watches the Robinhood Chain sequencer feed, independently
            recomputes every corporate-action event, and records the result
            on-chain — separate from Robinhood Predictor, verifiable by
            anyone.
          </p>

          <div className="mt-10 flex flex-wrap items-center gap-4">
            <Link
              href="/feed"
              className="rounded-full px-5 py-2.5 text-[14px] font-medium text-background transition-transform active:scale-[0.97]"
              style={{ background: "var(--interactive)" }}
            >
              View live feed
            </Link>
            <a
              href="https://github.com/pplmaverick/gapwatch"
              target="_blank"
              rel="noreferrer"
              className="rounded-full border px-5 py-2.5 text-[14px] font-medium text-interactive transition-colors active:scale-[0.97]"
              style={{ borderColor: "var(--border-strong)" }}
            >
              View on GitHub
            </a>
          </div>
        </section>

        <section className="border-t border-border-soft">
          <div className="mx-auto max-w-6xl px-6 py-20 md:px-10 md:py-28">
            <p className="mb-14 text-[11px] font-medium uppercase tracking-[0.16em] text-foreground-muted">
              How a corporate action gets confirmed
            </p>
            <PipelineDiagram />
          </div>
        </section>

        <section className="border-t border-border-soft">
          <div className="mx-auto max-w-6xl px-6 py-20 md:px-10 md:py-28">
            <p className="mb-8 text-[11px] font-medium uppercase tracking-[0.16em] text-foreground-muted">
              Shipped so far
            </p>
            <ul className="flex flex-col gap-4">
              {SHIPPED.map((item) => (
                <li
                  key={item}
                  className="flex items-baseline gap-3 text-[14px] text-foreground-muted"
                >
                  <span
                    className="mt-[3px] h-[6px] w-[6px] shrink-0 rounded-full"
                    style={{ background: "var(--semantic-confirmed)" }}
                  />
                  <span>{item}</span>
                </li>
              ))}
            </ul>
          </div>
        </section>
      </main>

      <footer className="border-t border-border-soft">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-8 text-[12px] text-foreground-dim md:px-10">
          <span>Gapwatch</span>
          <span>Built for Arbitrum Open House Singapore</span>
        </div>
      </footer>
    </>
  );
}
