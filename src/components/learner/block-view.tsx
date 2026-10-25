// Adapted from OCTRA Induct (src/components/participant/block-view.tsx), D-015.
// Media is released through /api/induction-media, which checks the learner's link first.
import { TextBody } from "@/components/induction/text-body";
import type { LearnerBlock } from "./types";

const toneStyles: Record<string, string> = {
  info: "border-l-4 border-brand bg-brand-subtle",
  warning: "border-l-4 border-warning bg-warning-subtle",
  risk: "border-l-4 border-risk bg-warning-subtle",
};
const toneLabels: Record<string, string> = { info: "Information", warning: "Warning", risk: "Danger" };

export function BlockView({ block, courseId }: { block: LearnerBlock; courseId: string }) {
  const media = (id: string | null) => (id ? `/api/induction-media/${id}?course=${courseId}` : null);
  switch (block.type) {
    case "rich_text":
      return <TextBody text={block.text} />;
    case "callout": {
      const tone = block.tone ?? "info";
      return (
        <div className={`rounded-md px-4 py-3 ${toneStyles[tone] ?? toneStyles.info}`}>
          <p className="text-xs font-semibold uppercase tracking-wide text-ink">{toneLabels[tone] ?? "Note"}</p>
          <TextBody text={block.text} />
        </div>
      );
    }
    case "image":
      return block.media_id ? (
        // Signed storage URLs expire, so they are not routed through next/image.
        // eslint-disable-next-line @next/next/no-img-element
        <img src={media(block.media_id)!} alt={block.decorative ? "" : (block.alt ?? "")} className="h-auto w-full rounded-md" />
      ) : null;
    case "video":
      return block.media_id ? (
        <div className="flex flex-col gap-2">
          <video controls preload="metadata" playsInline src={media(block.media_id)!} className="w-full rounded-md bg-ink">
            {block.caption_media_id ? <track kind="captions" src={media(block.caption_media_id)!} srcLang="en" label="English" default /> : null}
          </video>
          {block.transcript ? (
            <details className="text-sm">
              <summary className="inline-flex min-h-11 cursor-pointer items-center font-semibold text-ink">Read the transcript</summary>
              <TextBody text={block.transcript} />
            </details>
          ) : null}
        </div>
      ) : null;
    case "document":
      return block.media_id ? (
        <a href={media(block.media_id)!} rel="noopener noreferrer"
           className="flex min-h-11 items-center justify-between gap-3 rounded-md border border-line px-4 py-3 font-semibold text-ink underline-offset-4 hover:underline">
          <span>{block.title}</span>
          <span className="shrink-0 text-sm font-normal text-muted">PDF</span>
        </a>
      ) : null;
  }
}
