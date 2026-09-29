// SPDX-License-Identifier: GPL-3.0-only
// Task 5.3: report editor. Draft autosave is a debounce (≥ 10 s after the last keystroke, only while focused and
// dirty; no interval), the preview renders markdown-lite as text only, the toolbar edits the selection, and the
// charge picker sums fines/jail live and only lets "Utfärda ordningsbot" through for ordningsbot lines.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, renderHook, screen, waitFor, within } from '@testing-library/react';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { RECORDS_ACTIONS, ReportDetailSchema } from '@fredpd/types/records';
import type { Charge } from '@fredpd/types/records';
import { AUTOSAVE_DELAY_MS, useDraftAutosave } from '../src/autosave';
import { addLine, canIssueFine, clampQuantity, filterCharges, removeLine, setQuantity, sumLines } from '../src/charges';
import { applyBold, applyHeading, applyList } from '../src/markdown';
import { newerDraft } from '../src/pages/ReportPage';
import { fmtCurrency } from '../src/format';
import { clearNuiMocks } from '../src/utils/fetchNui';
import { installMockRegister, renderAt } from './helpers';

afterEach(() => {
  vi.useRealTimers();
  cleanup();
  clearNuiMocks();
});

describe('useDraftAutosave (debounce, fake timers)', () => {
  function setup() {
    vi.useFakeTimers();
    const save = vi.fn();
    const { result, unmount } = renderHook(() => useDraftAutosave(save));
    return { save, a: () => result.current, unmount };
  }

  it('saves once, 10 s after the last keystroke, while focused and dirty', () => {
    const { save, a } = setup();
    a().onFocus();
    a().onInput();
    vi.advanceTimersByTime(6_000);
    a().onInput(); // resets the debounce
    vi.advanceTimersByTime(AUTOSAVE_DELAY_MS - 1);
    expect(save).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(save).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(60_000); // idle: nothing more, no interval
    expect(save).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('no save when the editor lost focus before the delay ran out', () => {
    const { save, a } = setup();
    a().onFocus();
    a().onInput();
    a().onBlur();
    vi.advanceTimersByTime(AUTOSAVE_DELAY_MS * 3);
    expect(save).not.toHaveBeenCalled();
  });

  it('no save when clean: focus alone, or saved explicitly (markClean) before the delay', () => {
    const { save, a } = setup();
    a().onFocus();
    vi.advanceTimersByTime(AUTOSAVE_DELAY_MS * 3);
    expect(vi.getTimerCount()).toBe(0);
    a().onInput();
    a().markClean();
    vi.advanceTimersByTime(AUTOSAVE_DELAY_MS * 3);
    expect(save).not.toHaveBeenCalled();
  });

  it('a failed save leaves it dirty; unmount cancels the pending timeout', async () => {
    vi.useFakeTimers();
    const save = vi.fn().mockRejectedValueOnce(new Error('rate_limited')).mockResolvedValue(undefined);
    const { result, unmount } = renderHook(() => useDraftAutosave(save));
    result.current.onFocus();
    result.current.onInput();
    await vi.advanceTimersByTimeAsync(AUTOSAVE_DELAY_MS);
    expect(save).toHaveBeenCalledTimes(1);
    result.current.onInput();
    unmount();
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe('markdown toolbar (pure)', () => {
  it('bold wraps the selection; heading and list prefix (and toggle) the selected lines', () => {
    expect(applyBold({ text: 'a stor b', start: 2, end: 6 })).toEqual({ text: 'a **stor** b', start: 4, end: 8 });
    expect(applyBold({ text: 'ab', start: 1, end: 1 })).toEqual({ text: 'a****b', start: 3, end: 3 });
    expect(applyHeading({ text: 'x\nRubrik\ny', start: 3, end: 3 }).text).toBe('x\n# Rubrik\ny');
    expect(applyHeading({ text: '# Rubrik', start: 2, end: 2 }).text).toBe('Rubrik');
    expect(applyList({ text: 'ett\ntvå', start: 0, end: 7 }).text).toBe('- ett\n- två');
    expect(applyList({ text: '- ett\n- två', start: 0, end: 11 }).text).toBe('ett\ntvå');
  });
});

describe('charge lines (pure)', () => {
  const catalogue: Charge[] = [
    { code: 'OB-1', category: 'traffic', title: 'Olovlig parkering', lawRef: 'TrF 3 kap.', class: 'ordningsbot', fine: 1000, jailMinutes: 0 },
    { code: 'OB-2', category: 'traffic', title: 'Rött ljus', lawRef: 'TrF 3 kap. 11 §', class: 'ordningsbot', fine: 3000, jailMinutes: 0 },
    { code: 'BRB-005', category: 'penal', title: 'Misshandel', lawRef: 'BrB 3 kap. 5 §', class: 'fängelse', fine: 5000, jailMinutes: 10 },
  ];
  const byCode = new Map(catalogue.map((c) => [c.code, c]));

  it('sums fine and jail by quantity; quantities clamp to 1–20', () => {
    let lines = addLine([], 'OB-1');
    lines = addLine(lines, 'BRB-005');
    lines = addLine(lines, 'BRB-005');
    expect(sumLines(lines, byCode)).toEqual({ fine: 1000 + 2 * 5000, jailMinutes: 20 });
    lines = setQuantity(lines, 'OB-1', 99);
    expect(lines[0]?.quantity).toBe(20);
    expect(clampQuantity(0)).toBe(1);
    expect(sumLines(removeLine(lines, 'BRB-005'), byCode)).toEqual({ fine: 20_000, jailMinutes: 0 });
  });

  it('ordningsbot only when every line is class ordningsbot', () => {
    expect(canIssueFine([], byCode)).toBe(false);
    expect(canIssueFine([{ code: 'OB-1', quantity: 1 }, { code: 'OB-2', quantity: 2 }], byCode)).toBe(true);
    expect(canIssueFine([{ code: 'OB-1', quantity: 1 }, { code: 'BRB-005', quantity: 1 }], byCode)).toBe(false);
  });

  it('filters on code, title and lagrum (every word), and by class', () => {
    expect(filterCharges(catalogue, 'trf rött').map((c) => c.code)).toEqual(['OB-2']);
    expect(filterCharges(catalogue, 'brb-005').map((c) => c.code)).toEqual(['BRB-005']);
    expect(filterCharges(catalogue, '', 'ordningsbot')).toHaveLength(2);
  });
});

describe('report page', () => {
  it('a read-only report renders its text through MarkdownLite; markup is shown as text, never as HTML', async () => {
    const { db } = installMockRegister();
    const c = db.cases.find((x) => x.id === 1042)!;
    c.status = 'closed'; // not editable
    renderAt('/rapport/811');
    expect(await screen.findByRole('heading', { level: 1, name: /K-1042-26-R01/ })).toBeTruthy();
    expect(screen.getByRole('heading', { level: 3, name: 'Händelse' })).toBeTruthy();
    expect(screen.getByText('två maskerade personer').tagName).toBe('STRONG');
    expect(screen.queryByRole('textbox', { name: 'Rapporttext' })).toBeNull();
  });

  it('the preview renders markdown-lite as text only (a <script> or <img> stays literal)', async () => {
    installMockRegister();
    renderAt('/rapport/820');
    const body = (await screen.findByRole('textbox', { name: 'Rapporttext' })) as HTMLTextAreaElement;
    fireEvent.change(body, { target: { value: '# Rubrik\n<img src=x onerror=alert(1)> **fet** <script>alert(1)</script>\n- punkt' } });
    const preview = document.querySelector('[data-report-preview]') as HTMLElement;
    expect(within(preview).getByRole('heading', { name: 'Rubrik' })).toBeTruthy();
    expect(preview.querySelector('img, script')).toBeNull();
    expect(preview.textContent).toContain('<img src=x onerror=alert(1)>');
    expect(within(preview).getByText('fet').tagName).toBe('STRONG');
    expect(within(preview).getByRole('listitem').textContent).toBe('punkt');
  });

  it('no dangerouslySetInnerHTML anywhere in the NUI or packages/ui sources', () => {
    const walk = (dir: string): string[] =>
      readdirSync(dir).flatMap((f) => {
        const p = join(dir, f);
        return statSync(p).isDirectory() ? walk(p) : /\.(tsx?|jsx?)$/.test(f) ? [p] : [];
      });
    const files = [...walk(join(__dirname, '../src')), ...walk(join(__dirname, '../../../packages/ui/src'))];
    expect(files.length).toBeGreaterThan(20);
    // Used as a prop (JSX `dangerouslySetInnerHTML={…}` or createElement's `dangerouslySetInnerHTML: …`); comments may name it.
    expect(files.filter((f) => /dangerouslySetInnerHTML\s*[=:]/.test(readFileSync(f, 'utf8')))).toEqual([]);
  });

  it('autosave on the page: one saveReportDraft 10 s after typing while focused; none after blur', async () => {
    const { calls } = installMockRegister();
    renderAt('/rapport/820');
    const body = (await screen.findByRole('textbox', { name: 'Rapporttext' })) as HTMLTextAreaElement;
    vi.useFakeTimers();
    const drafts = () => calls.mock.calls.filter(([a]) => a === 'saveReportDraft');

    fireEvent.focus(body);
    fireEvent.change(body, { target: { value: `${body.value}\nMer text.` } });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTOSAVE_DELAY_MS - 100);
    });
    expect(drafts()).toHaveLength(0);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(100);
    });
    expect(drafts()).toHaveLength(1);
    expect(drafts()[0]?.[1]).toEqual({ reportId: 820, title: 'Anmälan: misshandel', body: expect.stringContaining('Mer text.') });
    expect(RECORDS_ACTIONS.saveReportDraft.input.safeParse(drafts()[0]?.[1]).success).toBe(true);

    fireEvent.change(body, { target: { value: `${body.value} Ännu mer.` } });
    fireEvent.blur(body);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(AUTOSAVE_DELAY_MS * 2);
    });
    expect(drafts()).toHaveLength(1);
    vi.useRealTimers();
    await waitFor(() => expect(document.querySelector('[data-draft-status]')?.textContent).toMatch(/^Utkast sparat kl\. \d\d:\d\d$/));
  });

  it('Spara sends saveReport with title, body and level', async () => {
    const { calls } = installMockRegister();
    renderAt('/rapport/820');
    const body = (await screen.findByRole('textbox', { name: 'Rapporttext' })) as HTMLTextAreaElement;
    fireEvent.change(body, { target: { value: 'Ny text' } });
    fireEvent.click(screen.getByRole('button', { name: 'Spara' }));
    await waitFor(() => expect(calls.mock.calls.some(([a]) => a === 'saveReport')).toBe(true));
    expect(calls.mock.calls.find(([a]) => a === 'saveReport')?.[1]).toEqual({ id: 820, title: 'Anmälan: misshandel', body: 'Ny text', level: 0 });
  });

  it('charge picker: type-ahead, live sums, ordningsbot gating, applyCharges and issueFine inputs', async () => {
    const { calls } = installMockRegister();
    renderAt('/rapport/820', ['mdt_page:*', 'perm:charges.apply', 'perm:charges.fine']);
    await screen.findByRole('textbox', { name: 'Rapporttext' });
    const picker = document.querySelector('[data-charge-picker]') as HTMLElement;
    // Person from the case's subjects (getCase).
    const person = within(picker).getByRole('combobox', { name: 'Person' });
    await waitFor(() => within(person).getByRole('option', { name: 'Maria Karlsson' }));
    fireEvent.change(person, { target: { value: 'FPD00002' } });

    const search = within(picker).getByRole('searchbox', { name: 'Sök brott eller lagrum' });
    fireEvent.change(search, { target: { value: 'misshandel' } });
    await waitFor(() => within(picker).getByRole('button', { name: /^BRB-005/ }));
    fireEvent.click(within(picker).getByRole('button', { name: /^BRB-005/ }));
    fireEvent.click(within(picker).getByRole('button', { name: /^BRB-005/ }));
    const totals = picker.querySelector('[data-charge-totals]') as HTMLElement;
    expect(totals.querySelector('[data-total-fine]')?.textContent).toBe(`Totalt bötesbelopp: ${fmtCurrency(10_000)}`);
    expect(totals.querySelector('[data-total-jail]')?.textContent).toBe('Total fängelsetid: 20 min');
    const fineButton = within(picker).getByRole('button', { name: 'Utfärda ordningsbot' }) as HTMLButtonElement;
    expect(fineButton.disabled).toBe(true);

    fireEvent.click(within(picker).getByRole('button', { name: 'Registrera brott' }));
    await waitFor(() => expect(within(picker).getByText('Brotten är registrerade på rapporten.')).toBeTruthy());
    const applied = calls.mock.calls.find(([a]) => a === 'applyCharges')?.[1];
    expect(applied).toEqual({ reportId: 820, citizenid: 'FPD00002', lines: [{ code: 'BRB-005', quantity: 2 }] });
    expect(RECORDS_ACTIONS.applyCharges.input.safeParse(applied).success).toBe(true);
    await waitFor(() => expect(document.querySelector('[data-applied-charges]')?.textContent).toContain('Misshandel × 2'));

    // Only ordningsbot lines → the button is enabled; it confirms and sends issueFine with the case id.
    fireEvent.change(search, { target: { value: 'rött ljus' } });
    fireEvent.click(await within(picker).findByRole('button', { name: /^TRF-018/ }));
    expect((within(picker).getByRole('button', { name: 'Utfärda ordningsbot' }) as HTMLButtonElement).disabled).toBe(false);
    fireEvent.click(within(picker).getByRole('button', { name: 'Utfärda ordningsbot' }));
    const dialog = screen.getByRole('dialog');
    expect(dialog.textContent).toContain('Maria Karlsson');
    fireEvent.click(within(dialog).getByRole('button', { name: 'Bekräfta' }));
    await waitFor(() => expect(calls.mock.calls.some(([a]) => a === 'issueFine')).toBe(true));
    const fine = calls.mock.calls.find(([a]) => a === 'issueFine')?.[1];
    expect(fine).toEqual({ citizenid: 'FPD00002', caseId: 1101, lines: [{ code: 'TRF-018', quantity: 1 }] });
    expect(RECORDS_ACTIONS.issueFine.input.safeParse(fine).success).toBe(true);
    await waitFor(() => expect(within(picker).getByText(/^Ordningsbot på .* utfärdad till Maria Karlsson\.$/)).toBeTruthy());
  });

  it('without charges perms the picker offers no apply/fine buttons', async () => {
    installMockRegister();
    renderAt('/rapport/820');
    await screen.findByRole('textbox', { name: 'Rapporttext' });
    const picker = document.querySelector('[data-charge-picker]') as HTMLElement;
    expect(within(picker).queryByRole('button', { name: 'Registrera brott' })).toBeNull();
    expect(within(picker).queryByRole('button', { name: 'Utfärda ordningsbot' })).toBeNull();
  });

  it('draft read-back: a draft newer than the report is offered; "Återställ utkast" loads it into the editor', async () => {
    const { handlers, calls } = installMockRegister();
    const saved = handlers.saveReportDraft({ reportId: 820, title: 'Anmälan: misshandel (utkast)', body: 'Utkasttext från förra passet' }) as { savedAt: string };
    expect(saved.savedAt).toMatch(/Z$/);
    renderAt('/rapport/820');
    const offer = await waitFor(() => {
      const el = document.querySelector('[data-draft-offer]');
      expect(el).toBeTruthy();
      return el as HTMLElement;
    });
    expect(offer.textContent).toContain('Det finns ett osparat utkast');
    const body = screen.getByRole('textbox', { name: 'Rapporttext' }) as HTMLTextAreaElement;
    expect(body.value).not.toContain('Utkasttext'); // nothing replaced until the officer chooses
    fireEvent.click(within(offer).getByRole('button', { name: 'Återställ utkast' }));
    expect(body.value).toBe('Utkasttext från förra passet');
    expect((screen.getByRole('textbox', { name: 'Rubrik' }) as HTMLInputElement).value).toBe('Anmälan: misshandel (utkast)');
    expect(document.querySelector('[data-draft-offer]')).toBeNull();
    expect(document.querySelector('[data-draft-restored]')?.textContent).toBe('Ett sparat utkast har återställts.');
    // Spara stores it; the mock (like fredpd_records) deletes the draft, so a reload offers nothing
    fireEvent.click(screen.getByRole('button', { name: 'Spara' }));
    await waitFor(() => expect(calls.mock.calls.some(([a]) => a === 'saveReport')).toBe(true));
    expect(calls.mock.calls.find(([a]) => a === 'saveReport')?.[1]).toMatchObject({ id: 820, body: 'Utkasttext från förra passet' });
    const after = handlers.getReport({ id: 820 }) as { draft: unknown };
    expect(after.draft).toBeNull();
  });

  it('"Släng utkastet" hides the offer and keeps the saved report text', async () => {
    const { handlers } = installMockRegister();
    handlers.saveReportDraft({ reportId: 820, body: 'Gammalt utkast' });
    renderAt('/rapport/820');
    const body = (await screen.findByRole('textbox', { name: 'Rapporttext' })) as HTMLTextAreaElement;
    const before = body.value;
    const offer = document.querySelector('[data-draft-offer]') as HTMLElement;
    fireEvent.click(within(offer).getByRole('button', { name: 'Släng utkastet' }));
    expect(document.querySelector('[data-draft-offer]')).toBeNull();
    expect(body.value).toBe(before);
  });

  it('no offer without a draft, for a draft older than the report, or on a read-only report', async () => {
    const draft = { title: null, body: 'x', savedAt: '2026-09-29T09:00:00Z' };
    expect(newerDraft({ draft: null, updatedAt: '2026-09-29T09:00:00Z' })).toBeNull();
    expect(newerDraft({ draft, updatedAt: '2026-09-29T09:00:00Z' })).toBeNull(); // same second: not newer
    expect(newerDraft({ draft, updatedAt: '2026-09-29T09:30:00Z' })).toBeNull();
    expect(newerDraft({ draft, updatedAt: '2026-09-29T08:59:59Z' })).toBe(draft);
    expect(newerDraft({ draft: { ...draft, savedAt: 'nonsense' }, updatedAt: '2026-09-29T08:00:00Z' })).toBeNull();

    // the contract: draft is required-nullable, title nullable
    const base = { id: 1, reportNumber: 'K-1-26/1', caseId: 1, caseNumber: 'K-1-26', title: 'Rapport', body: '', level: 0, author: null,
      createdAt: '2026-09-29T08:00:00Z', updatedAt: '2026-09-29T08:00:00Z', charges: [], editable: true };
    expect(ReportDetailSchema.safeParse({ ...base, draft: null }).success).toBe(true);
    expect(ReportDetailSchema.safeParse({ ...base, draft }).success).toBe(true);
    expect(ReportDetailSchema.safeParse(base).success).toBe(false);
    expect(ReportDetailSchema.safeParse({ ...base, draft: { body: 'x', savedAt: 'igår' } }).success).toBe(false);

    const { handlers, db } = installMockRegister();
    handlers.saveReportDraft({ reportId: 820, body: 'Utkast' });
    db.cases.find((x) => x.id === 1101)!.status = 'closed';
    renderAt('/rapport/820');
    expect(await screen.findByRole('heading', { level: 1, name: /Anmälan: misshandel/ })).toBeTruthy();
    expect(document.querySelector('[data-draft-offer]')).toBeNull();
    expect((handlers.getReport({ id: 820 }) as { draft: unknown }).draft).toBeNull();
  });
});
