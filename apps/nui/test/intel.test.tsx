// SPDX-License-Identifier: GPL-3.0-only
// Tasks 5b.2–5b.3: Underrättelser. Sources (handler view vs masked vs notice), the list-first entity page (hidden
// links only counted, kontaktnotiser), the 3-click add-link flow, missions/reports notices, and the graph: Cytoscape
// (mocked here) is created once, `cose` runs once and is stopped, expanding a node adds elements without a new layout.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { INTEL_ACTIONS } from '@fredpd/types/intel';
import { mergeGraph } from '../src/intel';
import { clearNuiMocks } from '../src/utils/fetchNui';
import { installMockRegister, renderAt } from './helpers';

const cy = vi.hoisted(() => {
  const layout = { run: vi.fn(), stop: vi.fn() };
  const handlers: { event: string; selector: unknown; fn: (evt: unknown) => void }[] = [];
  const instance = {
    layout: vi.fn(() => layout),
    on: vi.fn((event: string, a: unknown, b?: unknown) => {
      handlers.push(typeof a === 'function' ? { event, selector: null, fn: a as (evt: unknown) => void } : { event, selector: a, fn: b as (evt: unknown) => void });
    }),
    add: vi.fn(),
    destroy: vi.fn(),
    getElementById: vi.fn(() => ({ position: () => ({ x: 10, y: 20 }) })),
  };
  const factory = vi.fn((_options: { elements: { group: string; data: { id: string } }[] }) => instance);
  return { layout, handlers, instance, factory };
});
vi.mock('cytoscape', () => ({ default: cy.factory }));

const INTEL = ['mdt_page:*', 'perm:intel.read'];

beforeEach(() => {
  vi.clearAllMocks();
  cy.handlers.length = 0;
});
afterEach(() => {
  cleanup();
  clearNuiMocks();
});

describe('mergeGraph (pure)', () => {
  it('adds only new nodes (never as root) and edges between known nodes', () => {
    const base = { nodes: [{ id: 1, type: 'person' as const, ref: null, label: 'A', root: true }], edges: [], truncated: false };
    const more = {
      nodes: [
        { id: 2, type: 'group' as const, ref: null, label: 'B', root: true },
        { id: 1, type: 'person' as const, ref: null, label: 'A', root: false },
      ],
      edges: [{ id: 9, from: 1, to: 2, type: 'member_of', confidence: 50 }, { id: 10, from: 2, to: 3, type: 'x', confidence: 1 }],
      truncated: true,
    };
    const { graph, addedNodes, addedEdges } = mergeGraph(base, more);
    expect(addedNodes.map((n) => [n.id, n.root])).toEqual([[2, false]]);
    expect(addedEdges.map((e) => e.id)).toEqual([9]);
    expect(graph.nodes[0]?.root).toBe(true);
    expect(graph.truncated).toBe(true);
  });

  it('never grows past the node cap: adds what fits, drops edges to the rest and marks the graph truncated', () => {
    const node = (id: number) => ({ id, type: 'person' as const, ref: null, label: `N${id}`, root: id === 1 });
    const base = { nodes: [1, 2, 3].map(node), edges: [], truncated: false };
    const more = {
      nodes: [2, 4, 5, 6].map(node),
      edges: [
        { id: 1, from: 2, to: 4, type: 'associate', confidence: 50 },
        { id: 2, from: 2, to: 6, type: 'associate', confidence: 50 },
      ],
      truncated: false,
    };
    const { graph, addedNodes, addedEdges } = mergeGraph(base, more, 4);
    expect(addedNodes.map((n) => n.id)).toEqual([4]);
    expect(addedEdges.map((e) => e.id)).toEqual([1]);
    expect(graph.nodes).toHaveLength(4);
    expect(graph.truncated).toBe(true);
    // Already at the cap: nothing more is added.
    expect(mergeGraph(graph, { nodes: [node(7)], edges: [], truncated: false }, 4).addedNodes).toEqual([]);
    // Everything fits: not truncated.
    expect(mergeGraph(base, { nodes: [node(4)], edges: [], truncated: false }, 4).graph.truncated).toBe(false);
  });
});

describe('sources', () => {
  it('list: full and masked rows by codename, a notice only as the Notice; lists never show an identity', async () => {
    installMockRegister();
    renderAt('/intel/kallor', INTEL);
    await screen.findByText('KORPEN');
    expect(screen.getByText('FALKEN')).toBeTruthy();
    expect(document.querySelector('[data-source-visibility="masked"]')?.textContent).toContain('Delvis maskerat');
    const notice = document.querySelector('[data-source-visibility="notice"]') as HTMLElement;
    expect(notice.textContent).toBe('KontaktnotisDet finns uppgifter som rör en källa. Kontakta Bo Carlsson (Spaning).');
    expect(document.body.textContent).not.toContain('UGGLAN');
    expect(document.body.textContent).not.toContain('Mohammed Hassan');
  });

  it('handler view: the real identity from getSource, notes, edit', async () => {
    const { calls } = installMockRegister();
    renderAt('/intel/kallor/11', [...INTEL, 'perm:intel.handler']);
    expect(await screen.findByText('Mohammed Hassan')).toBeTruthy();
    expect(screen.getByText(/Rör sig i Vagos kretsar/, { selector: 'p' })).toBeTruthy();
    const editor = screen.getByRole('region', { name: 'Redigera' });
    fireEvent.change(within(editor).getByRole('combobox', { name: 'Tillförlitlighet' }), { target: { value: 'A' } });
    fireEvent.click(within(editor).getByRole('button', { name: 'Spara' }));
    await waitFor(() => expect(calls.mock.calls.some(([a]) => a === 'updateSource')).toBe(true));
    const input = calls.mock.calls.find(([a]) => a === 'updateSource')?.[1];
    expect(input).toMatchObject({ id: 11, reliability: 'A' });
    expect(INTEL_ACTIONS.updateSource.input.safeParse(input).success).toBe(true);
  });

  it('masked view: codename and reliability only; no handler, identity or notes', async () => {
    installMockRegister();
    renderAt('/intel/kallor/12', INTEL);
    await screen.findByText('FALKEN');
    expect(screen.getByText('Identiteten är skyddad.')).toBeTruthy();
    expect(document.body.textContent).not.toContain('Johan Andersson');
    expect(document.body.textContent).not.toContain('Bo Carlsson');
    expect(document.body.textContent).not.toContain('Källhanterare');
    expect(screen.queryByRole('region', { name: 'Redigera' })).toBeNull();
  });

  it('without perm intel.read: Källor/Rapporter are hidden and refuse without calling anything', async () => {
    const { calls } = installMockRegister();
    renderAt('/intel/kallor');
    expect(await screen.findByText('Du har inte behörighet att göra det här.')).toBeTruthy();
    expect(screen.queryByRole('tab', { name: 'Källor' })).toBeNull();
    expect(screen.getByRole('tab', { name: 'Insatser' })).toBeTruthy();
    expect(calls.mock.calls.filter(([a]) => a === 'listSources')).toEqual([]);
  });
});

describe('entity page (list-first)', () => {
  it('lists the visible links newest first and the reports behind them', async () => {
    installMockRegister();
    renderAt('/intel/objekt/1', INTEL);
    expect(await screen.findByRole('heading', { level: 1, name: 'Erik Nilsson' })).toBeTruthy();
    const links = [...document.querySelectorAll('[data-link]')];
    expect(links.length).toBe(6);
    expect(document.querySelector('[data-hidden-links]')).toBeNull();
    expect(links.some((l) => l.textContent?.includes('Medlem i') && l.textContent.includes('Vagos'))).toBe(true);
    expect(screen.getByRole('region', { name: 'Rapporter' }).textContent).toContain('#31');
  });

  it('hidden links are only counted, never described; hidden insatser give a kontaktnotis', async () => {
    installMockRegister();
    renderAt('/intel/objekt/7', INTEL); // XYZ98A: both links are Hemlig (tier 1)
    expect(await screen.findByRole('heading', { level: 1, name: 'XYZ98A (sentinel)' })).toBeTruthy();
    expect(document.querySelector('[data-hidden-links]')?.textContent).toBe('Kopplingar som är dolda för dig: 2');
    expect(document.querySelectorAll('[data-link]')).toHaveLength(0);
    const notices = document.querySelector('[data-entity-notices]') as HTMLElement;
    expect(notices.textContent).toBe('KontaktnotisDet finns uppgifter som rör XYZ98A (sentinel). Kontakta Bo Carlsson (Spaning).');
    for (const hidden of ['Vagos', 'Mohammed Hassan', 'Vinterträd', 'Använder']) expect(document.body.textContent).not.toContain(hidden);
  });

  it('adds a link in three clicks: add → pick the other entity → pick the type', async () => {
    const { calls } = installMockRegister();
    renderAt('/intel/objekt/5', INTEL);
    await screen.findByRole('heading', { level: 1, name: 'Mohammed Hassan' });
    const click = vi.fn((el: HTMLElement) => fireEvent.click(el));
    click(screen.getByRole('button', { name: 'Lägg till koppling' })); // 1
    const flow = document.querySelector('[data-add-link]') as HTMLElement;
    const box = within(flow).getByRole('searchbox');
    fireEvent.change(box, { target: { value: 'Sandy' } });
    fireEvent.keyDown(box, { key: 'Enter' });
    click(await within(flow).findByRole('button', { name: /Sandy Shores motell/ })); // 2
    click(within(flow).getByRole('button', { name: 'Sedd vid' })); // 3
    expect(await screen.findByText('Kopplingen är sparad.')).toBeTruthy();
    expect(click).toHaveBeenCalledTimes(3);
    const input = calls.mock.calls.find(([a]) => a === 'addLink')?.[1];
    expect(input).toEqual({ fromId: 5, to: { id: 4 }, type: 'seen_at', confidence: 50, level: 1 });
    expect(INTEL_ACTIONS.addLink.input.safeParse(input).success).toBe(true);
    await waitFor(() => expect([...document.querySelectorAll('[data-link]')].some((l) => l.textContent?.includes('Sandy Shores motell'))).toBe(true));
  });

  it('a new entity can be created as the other end (group / location)', async () => {
    const { calls } = installMockRegister();
    renderAt('/intel/objekt/1', INTEL);
    await screen.findByRole('heading', { level: 1, name: 'Erik Nilsson' });
    fireEvent.click(screen.getByRole('button', { name: 'Lägg till koppling' }));
    const flow = document.querySelector('[data-add-link]') as HTMLElement;
    fireEvent.change(within(flow).getByLabelText('Namn'), { target: { value: 'Lost MC' } });
    fireEvent.click(within(flow).getByRole('button', { name: 'Skapa nytt objekt' }));
    fireEvent.click(within(flow).getByRole('button', { name: 'Medlem i' }));
    await screen.findByText('Kopplingen är sparad.');
    expect(calls.mock.calls.find(([a]) => a === 'addLink')?.[1]).toEqual({ fromId: 1, to: { type: 'group', label: 'Lost MC' }, type: 'member_of', confidence: 50, level: 1 });
  });
});

describe('missions and intel reports', () => {
  it('a notice insats renders only the Notice', async () => {
    installMockRegister();
    renderAt('/intel/insatser/22', INTEL);
    const note = await screen.findByRole('note');
    expect(note.textContent).toBe('KontaktnotisDet finns uppgifter som rör en insats. Kontakta Bo Carlsson (Spaning).');
    expect(document.body.textContent).not.toContain('Vinterträd');
  });

  it('a full insats shows lead, members, its reports; the lead can add members and close it', async () => {
    const { calls } = installMockRegister();
    renderAt('/intel/insatser/21', INTEL);
    expect(await screen.findByRole('heading', { level: 1, name: 'Insats Nattfjäril' })).toBeTruthy();
    expect(screen.getByRole('region', { name: 'Deltagare' }).textContent).toContain('SPAN-02 · Bo Carlsson');
    await screen.findByText(/KORPEN uppger/);
    fireEvent.click(screen.getByRole('button', { name: 'Avsluta insatsen' }));
    await waitFor(() => expect(calls.mock.calls.find(([a]) => a === 'closeMission')?.[1]).toEqual({ id: 21 }));
    await waitFor(() => expect(screen.getByText('Avslutad')).toBeTruthy());
  });

  it('without perm intel.read an insats opens but never lists or offers intel reports', async () => {
    const { calls } = installMockRegister();
    renderAt('/intel/insatser/21', ['mdt_page:*']);
    expect(await screen.findByRole('heading', { level: 1, name: 'Insats Nattfjäril' })).toBeTruthy();
    expect(screen.getByRole('region', { name: 'Deltagare' })).toBeTruthy();
    expect(calls.mock.calls.some(([a]) => a === 'listIntelReports')).toBe(false);
    expect(document.body.textContent).not.toContain('KORPEN uppger');
    expect(screen.queryByRole('button', { name: 'Ny rapport' })).toBeNull();
  });

  it('a Hemlig report says the read is logged; a notice report is only the Notice', async () => {
    installMockRegister();
    renderAt('/intel/rapporter/33', INTEL);
    const note = await screen.findByRole('note');
    expect(note.textContent).toContain('en underrättelserapport');
    expect(document.body.textContent).not.toContain('Källuppgifter');
  });
});

describe('graph tab (Cytoscape mocked)', () => {
  const tapNode = (id: number) => {
    const handler = cy.handlers.find((h) => h.event === 'tap' && h.selector === 'node');
    act(() => handler?.fn({ target: { id: () => String(id) } }));
  };

  it('lazy-loads, builds once, runs cose once and stops it; expanding adds elements without a new layout', async () => {
    const { calls } = installMockRegister();
    const { unmount } = renderAt('/intel/objekt/1', INTEL);
    await screen.findByRole('heading', { level: 1, name: 'Erik Nilsson' });
    expect(cy.factory).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('tab', { name: 'Nätverk' }));
    await waitFor(() => expect(cy.factory).toHaveBeenCalledTimes(1));
    expect(cy.instance.layout).toHaveBeenCalledTimes(1);
    expect(cy.instance.layout).toHaveBeenCalledWith(expect.objectContaining({ name: 'cose', animate: false }));
    expect(cy.layout.run).toHaveBeenCalledTimes(1);
    expect(cy.layout.stop).toHaveBeenCalledTimes(1);
    const elements = cy.factory.mock.calls[0]![0].elements;
    expect(elements.filter((e) => e.group === 'nodes').map((e) => e.data.id).sort()).toEqual(['1', '2', '3', '4', '5', '6', '8']);
    expect(calls.mock.calls.filter(([a]) => a === 'getGraph')).toEqual([['getGraph', { entityId: 1, depth: 1 }]]);

    tapNode(8);
    fireEvent.click(await screen.findByRole('button', { name: 'Visa kopplingar' }));
    await waitFor(() => expect(cy.instance.add).toHaveBeenCalledTimes(1));
    expect(calls.mock.calls.filter(([a]) => a === 'getGraph').at(-1)).toEqual(['getGraph', { entityId: 8, depth: 1 }]);
    const added = cy.instance.add.mock.calls[0]![0] as { group: string; data: { id: string } }[];
    expect(added.some((e) => e.group === 'nodes')).toBe(true);
    expect(added.map((e) => e.data.id)).not.toContain('1'); // already shown
    expect(cy.instance.layout).toHaveBeenCalledTimes(1); // no second layout
    // Ballas has more members than the cap: the answer is truncated → cap message.
    expect(await screen.findByText(/Nätverket visar högst 150 objekt/)).toBeTruthy();
    expect(cy.factory).toHaveBeenCalledTimes(1);
    unmount();
    expect(cy.instance.destroy).toHaveBeenCalledTimes(1);
  });

  it('without perm intel.read the graph tab is not offered', async () => {
    installMockRegister();
    renderAt('/intel/objekt/1');
    await screen.findByRole('heading', { level: 1, name: 'Erik Nilsson' });
    expect(screen.queryByRole('tab', { name: 'Nätverk' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Lägg till koppling' })).toBeNull();
  });
});
