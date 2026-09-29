// SPDX-License-Identifier: GPL-3.0-only
import { afterEach, beforeAll, afterAll, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import type { ReactNode } from 'react';
import { useState } from 'react';
import { I18nProvider, createI18n } from '../src/i18n';
import { Notice, VisibilityGate } from '../src/components/Notice';
import { VirtualList } from '../src/components/VirtualList';
import { Badge } from '../src/components/Badge';
import { SearchInput } from '../src/components/SearchInput';
import { NavItem } from '../src/components/Layout';
import { Button } from '../src/components/Button';
import { IconButton } from '../src/components/IconButton';
import sv from '../../../locales/sv.json';
import en from '../../../locales/en.json';

const i18n = createI18n({ sv, en });
const wrap = (ui: ReactNode) => render(<I18nProvider i18n={i18n}>{ui}</I18nProvider>);

afterEach(cleanup);

describe('Notice (kontaktnotis)', () => {
  it('renders only the notice title and text', () => {
    const { container } = wrap(<Notice subject="Anna Berg" owner="IGV-07 · Karl L." />);
    expect(screen.getByRole('note').textContent).toBe(
      'KontaktnotisDet finns uppgifter som rör Anna Berg. Kontakta IGV-07 · Karl L..',
    );
    expect(container.textContent).toBe(screen.getByRole('note').textContent);
  });

  it('points at command when there is no owner', () => {
    wrap(<Notice subject="ABC 12D" owner={null} />);
    expect(screen.getByRole('note').textContent).toContain('Det finns uppgifter som rör ABC 12D. Kontakta ledningen.');
  });

  it('VisibilityGate shows the notice instead of the record for `notice`', () => {
    const { container } = wrap(
      <VisibilityGate result="notice" subject="Anna Berg" owner="Utredning">
        <p>Hemlig sammanfattning</p>
      </VisibilityGate>,
    );
    expect(container.textContent).not.toContain('Hemlig sammanfattning');
    expect(container.textContent).toBe('KontaktnotisDet finns uppgifter som rör Anna Berg. Kontakta Utredning.');
  });

  it('VisibilityGate renders nothing for `none`, the content for `full`, a banner plus content for `masked`', () => {
    const none = wrap(<VisibilityGate result="none" subject="x"><p>body</p></VisibilityGate>);
    expect(none.container.textContent).toBe('');
    cleanup();
    const full = wrap(<VisibilityGate result="full" subject="x"><p>body</p></VisibilityGate>);
    expect(full.container.textContent).toBe('body');
    cleanup();
    const masked = wrap(<VisibilityGate result="masked" subject="x"><p>body</p></VisibilityGate>);
    expect(masked.container.textContent).toBe('Delar av innehållet är maskerade.body');
  });
});

describe('VirtualList', () => {
  // jsdom has no layout; TanStack Virtual reads the viewport size from offsetHeight/offsetWidth.
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

  const items = Array.from({ length: 5000 }, (_, i) => ({ id: `p${i}`, name: `Person ${i}` }));

  it('renders a window of rows, not all of them', () => {
    const renderItem = vi.fn((item: (typeof items)[number], _index: number) => <span>{item.name}</span>);
    wrap(<VirtualList items={items} estimateSize={40} overscan={5} getKey={(i) => i.id} renderItem={renderItem} label="Träffar" />);
    const rows = screen.getAllByRole('listitem');
    // 400 px / 40 px = 10 visible rows + 5 overscan below (none above at the top).
    expect(rows.length).toBeGreaterThanOrEqual(10);
    expect(rows.length).toBeLessThanOrEqual(20);
    expect(screen.getByText('Person 0')).toBeTruthy();
    expect(screen.queryByText('Person 4999')).toBeNull();
    expect(rows[0]?.getAttribute('aria-setsize')).toBe('5000');
    // The spacer keeps the full scroll height.
    expect(screen.getByRole('list').style.height).toBe(`${5000 * 40}px`);
    expect(renderItem.mock.calls.every(([, index]) => index < 20)).toBe(true);
  });

  it('moves the window when scrolled', () => {
    const { container } = wrap(<VirtualList items={items} estimateSize={40} overscan={2} renderItem={(item) => <span>{item.name}</span>} />);
    const scroller = container.firstElementChild as HTMLDivElement;
    scroller.scrollTop = 40 * 2000;
    fireEvent.scroll(scroller);
    expect(screen.getByText('Person 2000')).toBeTruthy();
    expect(screen.queryByText('Person 0')).toBeNull();
    expect(screen.getAllByRole('listitem').length).toBeLessThanOrEqual(16);
  });

  it('does not rebuild every row key on a scroll-driven re-render', () => {
    const getKey = vi.fn((item: (typeof items)[number]) => item.id);
    const { container } = wrap(<VirtualList items={items} estimateSize={40} overscan={2} getKey={getKey} renderItem={(item) => <span>{item.name}</span>} />);
    getKey.mockClear();
    const scroller = container.firstElementChild as HTMLDivElement;
    scroller.scrollTop = 40 * 1000;
    fireEvent.scroll(scroller);
    expect(screen.getByText('Person 1000')).toBeTruthy();
    // Only the new window's keys (about 16), not all 5 000.
    expect(getKey.mock.calls.length).toBeLessThan(100);
  });
});

describe('IconButton', () => {
  // Tailwind orders utilities in the stylesheet, not by class order, so a text button's px-* would beat any px-0
  // override and squeeze the icon. Icon buttons must be square with no horizontal padding at all.
  it.each([
    ['sm', 'size-7'],
    ['md', 'size-9'],
  ] as const)('is a %s square without horizontal padding', (size, sizeClass) => {
    wrap(<IconButton label="Stäng" size={size} icon={<svg />} />);
    const classes = screen.getByRole('button', { name: 'Stäng' }).className.split(/\s+/);
    expect(classes).toContain(sizeClass);
    expect(classes.filter((c) => /^(px|pl|pr|w)-/.test(c))).toEqual([]);
  });

  it('keeps padding on text buttons', () => {
    wrap(<Button size="sm">Spara</Button>);
    expect(screen.getByRole('button', { name: 'Spara' }).className.split(/\s+/)).toContain('px-2.5');
  });
});

describe('Badge', () => {
  it('labels the classification level', () => {
    wrap(
      <>
        <Badge level={0} />
        <Badge level={1} />
        <Badge level={2} />
      </>,
    );
    expect(screen.getByText('Standard').dataset.tone).toBe('neutral');
    expect(screen.getByText('Begränsad').dataset.tone).toBe('warning');
    expect(screen.getByText('Hemlig').dataset.tone).toBe('danger');
  });
});

describe('SearchInput', () => {
  function Harness({ onSubmit }: { onSubmit: (v: string) => void }) {
    const [value, setValue] = useState('');
    return <SearchInput value={value} onValueChange={setValue} onSubmit={onSubmit} placeholder="Sök" />;
  }

  it('submits the trimmed value on Enter and clears with the clear button', () => {
    const onSubmit = vi.fn();
    wrap(<Harness onSubmit={onSubmit} />);
    const input = screen.getByPlaceholderText('Sök') as HTMLInputElement;
    fireEvent.keyDown(input, { key: 'Enter' });
    expect(onSubmit).not.toHaveBeenCalled();
    fireEvent.change(input, { target: { value: '  ABC 12D ' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    expect(onSubmit).toHaveBeenCalledWith('ABC 12D');
    fireEvent.click(screen.getByRole('button', { name: 'Rensa' }));
    expect(input.value).toBe('');
  });
});

describe('NavItem', () => {
  it('routes plain clicks through onNavigate and marks the active item', () => {
    const onNavigate = vi.fn();
    wrap(<NavItem href="/larm" label="Larm" active onNavigate={onNavigate} />);
    const link = screen.getByRole('link', { name: 'Larm' });
    expect(link.getAttribute('aria-current')).toBe('page');
    fireEvent.click(link);
    expect(onNavigate).toHaveBeenCalledTimes(1);
    // A modified click is left to the browser (new tab); stop jsdom from "navigating" afterwards.
    const stop = (e: Event) => e.preventDefault();
    document.addEventListener('click', stop);
    fireEvent.click(link, { ctrlKey: true });
    document.removeEventListener('click', stop);
    expect(onNavigate).toHaveBeenCalledTimes(1);
  });
});
