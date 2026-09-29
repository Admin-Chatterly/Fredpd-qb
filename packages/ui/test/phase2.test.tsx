// SPDX-License-Identifier: GPL-3.0-only
// Shared components added for the Phase 2 tablet pages: Dialog, Pagination, Textarea, VirtualListbox.
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import type { ReactNode } from 'react';
import { useState } from 'react';
import { I18nProvider, createI18n } from '../src/i18n';
import { Dialog } from '../src/components/Dialog';
import { Pagination, pageCount } from '../src/components/Pagination';
import { Textarea } from '../src/components/Textarea';
import { VirtualListbox } from '../src/components/VirtualListbox';
import sv from '../../../locales/sv.json';
import en from '../../../locales/en.json';

const i18n = createI18n({ sv, en });
const wrap = (ui: ReactNode) => render(<I18nProvider i18n={i18n}>{ui}</I18nProvider>);

afterEach(cleanup);

describe('Dialog', () => {
  it('renders nothing while closed', () => {
    const { container } = wrap(<Dialog open={false} title="Titel" onClose={() => {}}>body</Dialog>);
    expect(container.textContent).toBe('');
  });

  it('is a labelled modal dialog over the nearest positioned ancestor, focusing its first field', () => {
    wrap(
      <Dialog open title="Ny efterlysning" onClose={() => {}} footer={<button type="button">Spara</button>}>
        <input aria-label="Anledning" />
      </Dialog>,
    );
    const dialog = screen.getByRole('dialog', { name: 'Ny efterlysning' });
    expect(dialog.getAttribute('aria-modal')).toBe('true');
    expect(dialog.parentElement?.className).toContain('absolute');
    expect(document.activeElement).toBe(screen.getByRole('textbox', { name: 'Anledning' }));
  });

  it('closes from the close button and the backdrop, not from a click inside', () => {
    const onClose = vi.fn();
    wrap(
      <Dialog open title="T" onClose={onClose} position="fixed">
        <p>inne</p>
      </Dialog>,
    );
    fireEvent.mouseDown(screen.getByText('inne'));
    expect(onClose).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Stäng' }));
    const backdrop = screen.getByRole('dialog').parentElement as HTMLElement;
    expect(backdrop.className).toContain('fixed');
    fireEvent.mouseDown(backdrop);
    expect(onClose).toHaveBeenCalledTimes(2);
  });

  it('gives the focus back when it closes', () => {
    function Harness() {
      const [open, setOpen] = useState(false);
      return (
        <>
          <button type="button" onClick={() => setOpen(true)}>
            Öppna
          </button>
          <Dialog open={open} title="T" onClose={() => setOpen(false)}>
            <input aria-label="f" />
          </Dialog>
        </>
      );
    }
    wrap(<Harness />);
    const opener = screen.getByRole('button', { name: 'Öppna' });
    opener.focus();
    fireEvent.click(opener);
    expect(document.activeElement).toBe(screen.getByRole('textbox', { name: 'f' }));
    fireEvent.click(screen.getByRole('button', { name: 'Stäng' }));
    expect(document.activeElement).toBe(opener);
  });
});

describe('Pagination', () => {
  it('counts pages', () => {
    expect(pageCount(0, 50)).toBe(1);
    expect(pageCount(50, 50)).toBe(1);
    expect(pageCount(51, 50)).toBe(2);
  });

  it('is hidden for one page; moves with previous/next, disabled at the ends', () => {
    const { container } = wrap(<Pagination page={1} total={20} pageSize={50} onPageChange={() => {}} />);
    expect(container.textContent).toBe('');
    cleanup();
    const onPageChange = vi.fn();
    wrap(<Pagination page={1} total={120} pageSize={50} onPageChange={onPageChange} />);
    expect(screen.getByRole('navigation', { name: 'Sida 1 av 3' })).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Föregående' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole('button', { name: 'Nästa' }));
    expect(onPageChange).toHaveBeenCalledWith(2);
  });
});

describe('Textarea', () => {
  it('marks itself invalid', () => {
    wrap(<Textarea aria-label="Anledning" invalid />);
    expect(screen.getByRole('textbox', { name: 'Anledning' }).getAttribute('aria-invalid')).toBe('true');
  });
});

describe('VirtualListbox', () => {
  const heightDesc = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetHeight');
  const widthDesc = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetWidth');
  beforeAll(() => {
    Object.defineProperty(HTMLElement.prototype, 'offsetHeight', { configurable: true, get: () => 400 });
    Object.defineProperty(HTMLElement.prototype, 'offsetWidth', { configurable: true, get: () => 600 });
  });
  afterAll(() => {
    if (heightDesc) Object.defineProperty(HTMLElement.prototype, 'offsetHeight', heightDesc);
    if (widthDesc) Object.defineProperty(HTMLElement.prototype, 'offsetWidth', widthDesc);
  });

  const items = Array.from({ length: 1000 }, (_, i) => ({ id: i, name: `Person ${i}`, locked: i === 2 }));

  function Harness({ onActivate }: { onActivate: (id: number) => void }) {
    const [active, setActive] = useState(0);
    return (
      <VirtualListbox
        items={items}
        rowHeight={40}
        label="Träffar"
        getKey={(item) => item.id}
        activeIndex={active}
        onActiveIndexChange={setActive}
        onActivate={(item) => onActivate(item.id)}
        isDisabled={(item) => item.locked}
        renderItem={(item, _i, isActive) => <span data-active={isActive || undefined}>{item.name}</span>}
        autoFocus
      />
    );
  }

  const activeText = () => {
    const box = screen.getByRole('listbox');
    return document.getElementById(box.getAttribute('aria-activedescendant') ?? '')?.textContent;
  };

  it('renders a window of options and focuses the listbox', () => {
    wrap(<Harness onActivate={() => {}} />);
    const box = screen.getByRole('listbox', { name: 'Träffar' });
    expect(document.activeElement).toBe(box);
    expect(screen.getAllByRole('option').length).toBeLessThan(25);
    expect(screen.getAllByRole('option')[0]?.getAttribute('aria-setsize')).toBe('1000');
    expect(activeText()).toBe('Person 0');
  });

  it('moves with the arrow keys, Home/End and PageDown; Enter activates; disabled rows are not activated', () => {
    const onActivate = vi.fn();
    wrap(<Harness onActivate={onActivate} />);
    const box = screen.getByRole('listbox');
    fireEvent.keyDown(box, { key: 'ArrowDown' });
    expect(activeText()).toBe('Person 1');
    fireEvent.keyDown(box, { key: 'Enter' });
    expect(onActivate).toHaveBeenLastCalledWith(1);
    fireEvent.keyDown(box, { key: 'ArrowDown' });
    expect(screen.getByRole('option', { selected: true }).getAttribute('aria-disabled')).toBe('true');
    fireEvent.keyDown(box, { key: 'Enter' });
    expect(onActivate).toHaveBeenCalledTimes(1);
    fireEvent.keyDown(box, { key: 'ArrowUp' });
    fireEvent.keyDown(box, { key: 'ArrowUp' });
    fireEvent.keyDown(box, { key: 'ArrowUp' });
    expect(activeText()).toBe('Person 0');
    fireEvent.keyDown(box, { key: 'End' });
    expect(box.getAttribute('aria-activedescendant')).toMatch(/-option-999$/);
    fireEvent.keyDown(box, { key: 'Home' });
    fireEvent.keyDown(box, { key: 'PageDown' });
    // 400 px / 40 px = 10 rows, one kept for context.
    expect(box.getAttribute('aria-activedescendant')).toMatch(/-option-9$/);
  });

  it('a click selects and activates the row', () => {
    const onActivate = vi.fn();
    wrap(<Harness onActivate={onActivate} />);
    fireEvent.click(screen.getByText('Person 4'));
    expect(onActivate).toHaveBeenCalledWith(4);
    expect(activeText()).toBe('Person 4');
  });
});
