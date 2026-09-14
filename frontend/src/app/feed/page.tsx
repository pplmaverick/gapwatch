import { NavBar } from "@/components/NavBar";

export default function FeedPage() {
  return (
    <>
      <NavBar />
      <main className="flex-1 px-6 pt-40 md:px-10">
        <p className="text-[14px] text-foreground-muted">
          Screen B — live pipeline status. Coming next.
        </p>
      </main>
    </>
  );
}
