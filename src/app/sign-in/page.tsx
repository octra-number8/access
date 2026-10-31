import Image from "next/image";
import { SignInForms } from "./forms";

// Sign-in, laid out from the "Octra Access Sign In" design: a dark panel saying what the product
// records, beside the two-step code form. The panel's wording stays within what Octra does
// (CLAUDE.md §1): it records decisions and who made them; it does not make work safe.
const points = [
  "Permits reviewed and issued by appointed people",
  "Inductions completed on any phone",
  "Gate decisions recorded with a reason and an owner",
];

export default async function SignIn({ searchParams }: { searchParams: Promise<{ next?: string; email?: string }> }) {
  const { next = "/", email = "" } = await searchParams;
  return (
    <div className="signin">
      <section className="signin-panel" aria-label="About Octra Access">
        <div className="flex items-center gap-3">
          <Image src="/brand/octra-mark-reversed.png" alt="OCTRA" width={100} height={24} priority />
          <span className="border-l border-[#3a3d45] pl-3 text-[15px] font-medium leading-none text-[#b8b6af]">Access</span>
        </div>

        <div className="signin-pitch">
          <p className="inline-flex items-center gap-2 self-start rounded-full border border-[#3a3d45] px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.08em] text-[#d8d6cf]">
            <span aria-hidden="true" className="inline-block size-2 rounded-full bg-brand-accent" />
            Contractor access and permit to work
          </p>
          <p className="m-0 text-[2.5rem] font-bold leading-[1.1] tracking-[-0.02em] text-[#f6f5f2]">
            Inductions, permits and site access, recorded in one place.
          </p>
          <p className="m-0 text-[17px] leading-relaxed text-[#b8b6af]">
            For venues and estates with contractors, events and shared spaces. Each decision is recorded with who made it, and when.
          </p>
          <ul className="m-0 grid list-none gap-3.5 p-0">
            {points.map((p) => (
              <li key={p} className="flex items-center gap-3 text-[15px] text-[#e6e4dd]">
                <svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true" fill="none" className="shrink-0">
                  <circle cx="10" cy="10" r="9" stroke="var(--octra-brand-accent)" strokeWidth="1.6" />
                  <path d="M6 10.3l2.6 2.6L14 7.6" stroke="var(--octra-brand-accent)" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
                {p}
              </li>
            ))}
          </ul>
        </div>

        <p className="signin-foot m-0 flex flex-wrap gap-5 text-[13px] text-[#8f8d86]">
          <span>Octra Online Ltd</span>
          <a href="https://octra.co.uk" className="text-[#b8b6af] no-underline hover:underline">octra.co.uk</a>
        </p>
      </section>

      <div className="signin-side">
        <div className="signin-card">
          <SignInForms next={next} initialEmail={email} />
        </div>
      </div>
    </div>
  );
}
