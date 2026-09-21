import { useEffect, useRef, useState } from "react";

/**
 * Fires `true` once the returned ref's element first scrolls into (near)
 * view, then disconnects -- used to gate an expensive per-row fetch (a real
 * mainnet RPC call) so it only fires for rows the user actually scrolls to,
 * not for all ~200 rows in the collapsed token list at once. `rootMargin`
 * gives it a head start so the balance is usually already loaded by the
 * time a row is actually visible.
 */
export function useInView<T extends HTMLElement>(rootMargin = "200px") {
  const ref = useRef<T | null>(null);
  const [inView, setInView] = useState(false);

  useEffect(() => {
    if (inView) return;
    const el = ref.current;
    if (!el) return;

    if (typeof IntersectionObserver === "undefined") {
      // No IntersectionObserver support (or SSR): fail open rather than
      // silently never loading a balance.
      setInView(true);
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          setInView(true);
          observer.disconnect();
        }
      },
      { rootMargin }
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, [inView, rootMargin]);

  return [ref, inView] as const;
}
