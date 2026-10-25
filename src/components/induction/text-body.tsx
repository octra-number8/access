// Copied from OCTRA Induct (src/components/induction/text-body.tsx), D-015.
import { parseTextBody } from "./parse-text-body";

export function TextBody({ text }: { text: string }) {
  return (
    <div className="flex flex-col gap-2 text-body">
      {parseTextBody(text).map((part, index) =>
        part.kind === "paragraph" ? (
          <p key={index} className="whitespace-pre-line">
            {part.text}
          </p>
        ) : (
          <ul key={index} className="list-disc pl-6">
            {part.items.map((item, itemIndex) => (
              <li key={itemIndex}>{item}</li>
            ))}
          </ul>
        ),
      )}
    </div>
  );
}
