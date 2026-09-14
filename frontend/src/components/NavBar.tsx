import Link from "next/link";

export function NavBar() {
  return (
    <header className="fixed inset-x-0 top-0 z-50">
      <div
        className="mx-auto flex max-w-6xl items-center justify-between px-6 py-3.5 md:px-10"
        style={{
          backdropFilter: "blur(20px) saturate(160%)",
          WebkitBackdropFilter: "blur(20px) saturate(160%)",
          background: "rgba(5, 6, 8, 0.55)",
          borderBottom: "1px solid var(--border-soft)",
        }}
      >
        <Link href="/" className="text-[15px] font-medium tracking-tight text-foreground">
          Gapwatch
        </Link>
        <nav className="flex items-center gap-6 text-sm text-foreground-muted">
          <Link
            href="/feed"
            className="transition-colors hover:text-interactive"
          >
            Live feed
          </Link>
          <a
            href="https://github.com/pplmaverick/gapwatch"
            target="_blank"
            rel="noreferrer"
            className="transition-colors hover:text-interactive"
          >
            GitHub
          </a>
        </nav>
      </div>
    </header>
  );
}
