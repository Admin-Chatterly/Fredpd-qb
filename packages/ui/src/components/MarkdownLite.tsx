// SPDX-License-Identifier: GPL-3.0-only
// Report text (docs/contracts.md §C14 "markdown-lite"): `# ` / `## ` / `### ` headings, `- ` or `* ` list items and
// `**bold**`, nothing else. The text is parsed into blocks and rendered as React text nodes only: no HTML
// passthrough, no links, no images, no dangerouslySetInnerHTML, so a report can never inject markup. Shared by the
// tablet report editor preview and (Phase 7) the portal.
import type { ReactNode } from 'react';
import { cn } from '../cn';

export type InlineSpan = { bold: boolean; text: string };
export type MarkdownBlock =
  | { type: 'heading'; level: 1 | 2 | 3; spans: InlineSpan[] }
  | { type: 'list'; items: InlineSpan[][] }
  | { type: 'paragraph'; lines: InlineSpan[][] };

/** `a **b** c` → [a ][b, bold][ c]. An unmatched `**` stays literal text. */
export function parseInline(text: string): InlineSpan[] {
  const spans: InlineSpan[] = [];
  let rest = text;
  while (rest.length > 0) {
    const open = rest.indexOf('**');
    const close = open >= 0 ? rest.indexOf('**', open + 2) : -1;
    if (open < 0 || close < 0) {
      spans.push({ bold: false, text: rest });
      break;
    }
    if (open > 0) spans.push({ bold: false, text: rest.slice(0, open) });
    const inner = rest.slice(open + 2, close);
    if (inner.length > 0) spans.push({ bold: true, text: inner });
    rest = rest.slice(close + 2);
  }
  return spans;
}

const HEADING_RE = /^(#{1,3})\s+(.*)$/;
const LIST_RE = /^\s*[-*]\s+(.*)$/;

export function parseMarkdownLite(text: string): MarkdownBlock[] {
  const blocks: MarkdownBlock[] = [];
  let paragraph: InlineSpan[][] | null = null;
  let list: InlineSpan[][] | null = null;
  const flush = () => {
    if (paragraph) blocks.push({ type: 'paragraph', lines: paragraph });
    if (list) blocks.push({ type: 'list', items: list });
    paragraph = null;
    list = null;
  };
  for (const raw of text.replace(/\r\n?/g, '\n').split('\n')) {
    const line = raw.trimEnd();
    const heading = HEADING_RE.exec(line);
    const item = heading ? null : LIST_RE.exec(line);
    if (line.trim() === '') {
      flush();
    } else if (heading) {
      flush();
      blocks.push({ type: 'heading', level: heading[1]!.length as 1 | 2 | 3, spans: parseInline(heading[2]!) });
    } else if (item) {
      if (paragraph) flush();
      (list ??= []).push(parseInline(item[1]!));
    } else {
      if (list) flush();
      (paragraph ??= []).push(parseInline(line));
    }
  }
  flush();
  return blocks;
}

function Spans({ spans }: { spans: readonly InlineSpan[] }) {
  return (
    <>
      {spans.map((s, i) => (s.bold ? <strong key={i}>{s.text}</strong> : <span key={i}>{s.text}</span>))}
    </>
  );
}

const HEADING_CLASS = { 1: 'text-lg font-semibold', 2: 'text-base font-semibold', 3: 'text-sm font-semibold' } as const;

export interface MarkdownLiteProps {
  text: string;
  /** Shown when the text has no content. */
  empty?: ReactNode;
  className?: string;
}

export function MarkdownLite({ text, empty, className }: MarkdownLiteProps) {
  const blocks = parseMarkdownLite(text);
  if (blocks.length === 0) return empty ? <p className="text-sm text-muted">{empty}</p> : null;
  return (
    <div data-markdown-lite className={cn('flex flex-col gap-2 text-sm text-fg', className)}>
      {blocks.map((block, i) => {
        switch (block.type) {
          case 'heading': {
            const Tag = (['h3', 'h4', 'h5'] as const)[block.level - 1]!;
            return (
              <Tag key={i} className={HEADING_CLASS[block.level]}>
                <Spans spans={block.spans} />
              </Tag>
            );
          }
          case 'list':
            return (
              <ul key={i} className="list-disc pl-5">
                {block.items.map((spans, j) => (
                  <li key={j}>
                    <Spans spans={spans} />
                  </li>
                ))}
              </ul>
            );
          case 'paragraph':
            return (
              <p key={i} className="whitespace-pre-wrap">
                {block.lines.map((spans, j) => (
                  <span key={j}>
                    {j > 0 && <br />}
                    <Spans spans={spans} />
                  </span>
                ))}
              </p>
            );
        }
      })}
    </div>
  );
}
