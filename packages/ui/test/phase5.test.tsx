// SPDX-License-Identifier: GPL-3.0-only
// Shared components added for the Phase 3–5b pages: Tabs (tablist, arrows), Drawer (labelled side panel, backdrop
// and close button, focus back) and MarkdownLite (parser + text-only rendering: no HTML ever reaches the DOM).
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { Drawer, MarkdownLite, Tabs, parseInline, parseMarkdownLite } from '../src';

afterEach(cleanup);

describe('Tabs', () => {
  it('renders a tablist, marks the selected tab, moves with the arrow keys and skips disabled tabs', () => {
    const onChange = vi.fn();
    render(
      <Tabs
        label="Filter"
        value="b"
        onChange={onChange}
        items={[
          { id: 'a', label: 'A' },
          { id: 'b', label: 'B', count: 3 },
          { id: 'c', label: 'C', disabled: true },
        ]}
      />,
    );
    const list = screen.getByRole('tablist', { name: 'Filter' });
    expect(screen.getByRole('tab', { name: 'B3' }).getAttribute('aria-selected')).toBe('true');
    fireEvent.click(screen.getByRole('tab', { name: 'A' }));
    expect(onChange).toHaveBeenLastCalledWith('a');
    fireEvent.keyDown(list, { key: 'ArrowRight' });
    expect(onChange).toHaveBeenLastCalledWith('a'); // wraps past the disabled C
    fireEvent.keyDown(list, { key: 'ArrowLeft' });
    expect(onChange).toHaveBeenLastCalledWith('a');
  });
});

describe('Drawer', () => {
  it('is a labelled dialog; backdrop and close button call onClose; closed renders nothing', () => {
    const onClose = vi.fn();
    const { rerender } = render(
      <div className="relative">
        <button type="button">outside</button>
        <Drawer open title="Beviskedja" onClose={onClose}>
          <p>innehåll</p>
        </Drawer>
      </div>,
    );
    const dialog = screen.getByRole('dialog', { name: 'Beviskedja' });
    expect(document.activeElement).toBe(dialog);
    fireEvent.click(screen.getByRole('button', { name: 'common.close' }));
    fireEvent.mouseDown(dialog.parentElement!);
    expect(onClose).toHaveBeenCalledTimes(2);
    fireEvent.mouseDown(dialog);
    expect(onClose).toHaveBeenCalledTimes(2);
    rerender(
      <div className="relative">
        <Drawer open={false} title="Beviskedja" onClose={onClose}>
          <p>innehåll</p>
        </Drawer>
      </div>,
    );
    expect(screen.queryByRole('dialog')).toBeNull();
  });
});

describe('MarkdownLite', () => {
  it('parses headings, lists, paragraphs and **bold**', () => {
    expect(parseInline('a **b** c')).toEqual([
      { bold: false, text: 'a ' },
      { bold: true, text: 'b' },
      { bold: false, text: ' c' },
    ]);
    expect(parseInline('**öppen')).toEqual([{ bold: false, text: '**öppen' }]);
    expect(parseMarkdownLite('# H1\n### H3\n- a\n* b\n\ntext\nrad två').map((b) => b.type)).toEqual(['heading', 'heading', 'list', 'paragraph']);
    expect(parseMarkdownLite('#### fyra')[0]).toMatchObject({ type: 'paragraph' });
    expect(parseMarkdownLite('   \n\n')).toEqual([]);
  });

  it('renders text nodes only: HTML, links and images stay literal text', () => {
    const evil = '# <img src=x onerror=alert(1)>\n<script>alert(1)</script> [länk](http://x) ![bild](http://x/y.png)\n- **<b>fet</b>**';
    const { container } = render(<MarkdownLite text={evil} />);
    expect(container.querySelector('img, script, a, b')).toBeNull();
    expect(container.textContent).toContain('<script>alert(1)</script>');
    expect(container.textContent).toContain('[länk](http://x)');
    expect(screen.getByRole('heading').textContent).toBe('<img src=x onerror=alert(1)>');
    expect(container.querySelector('li strong')?.textContent).toBe('<b>fet</b>');
  });

  it('shows the empty text for an empty body', () => {
    render(<MarkdownLite text="" empty="Rapporten är tom." />);
    expect(screen.getByText('Rapporten är tom.')).toBeTruthy();
  });
});
