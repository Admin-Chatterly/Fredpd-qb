// SPDX-License-Identifier: GPL-3.0-only
// Report editor toolbar (docs/contracts.md §C14 markdown-lite: **bold**, # heading, - list). Pure edits on the
// textarea value and selection; the result is rendered as text by @fredpd/ui MarkdownLite (no HTML).

export interface TextEdit {
  text: string;
  start: number;
  end: number;
}

/** Wraps the selection in `**`; without a selection inserts `****` with the caret in the middle. */
export function applyBold({ text, start, end }: TextEdit): TextEdit {
  const selected = text.slice(start, end);
  const next = `${text.slice(0, start)}**${selected}**${text.slice(end)}`;
  return { text: next, start: start + 2, end: end + 2 };
}

function lineRange(text: string, start: number, end: number): [number, number] {
  const from = text.lastIndexOf('\n', start - 1) + 1;
  const nl = text.indexOf('\n', end > start && text[end - 1] === '\n' ? end - 1 : end);
  return [from, nl < 0 ? text.length : nl];
}

/** Prefixes every selected line with `prefix` (toggles it off when every line already has it). */
function prefixLines({ text, start, end }: TextEdit, prefix: string, strip: RegExp): TextEdit {
  const [from, to] = lineRange(text, start, end);
  const lines = text.slice(from, to).split('\n');
  const all = lines.every((l) => strip.test(l));
  const changed = lines.map((l) => (all ? l.replace(strip, '') : `${prefix}${l.replace(strip, '')}`)).join('\n');
  const next = text.slice(0, from) + changed + text.slice(to);
  return { text: next, start: from, end: from + changed.length };
}

export const applyHeading = (edit: TextEdit) => prefixLines(edit, '# ', /^#{1,3}\s+/);
export const applyList = (edit: TextEdit) => prefixLines(edit, '- ', /^\s*[-*]\s+/);
