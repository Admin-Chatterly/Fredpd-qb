// SPDX-License-Identifier: GPL-3.0-only
// Nätverk tab of an entity (task 5b.3; docs/contracts.md §C15, IMPLEMENTATION.md §4.7 "Graph"). This module is
// React.lazy-loaded by the entity page, and Cytoscape (MIT) is imported dynamically inside it, so neither is part of
// the main bundle. The graph is built server-side (getGraph, BFS over visible links, capped at 150 nodes). Rendering:
// one Cytoscape instance, layout `cose` run ONCE (animate: false) and then stop()ped; nothing animates or ticks
// afterwards. "Visa kopplingar" on a node fetches getGraph for that node (depth 1) and adds only the new elements,
// placed around it without re-running the layout. A truncated answer shows the cap message.
import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router';
import { useQueryClient } from '@tanstack/react-query';
import type { Core, ElementDefinition } from 'cytoscape';
import { GRAPH_NODE_CAP } from '@fredpd/types/intel';
import type { Graph } from '@fredpd/types/intel';
import { Button, Card, useI18n } from '@fredpd/ui';
import { mdtQueryOptions, useMdtQuery, useTransport } from '../../api/hooks';
import { useErrorText } from '../../api/errors';
import { Callout, PageSpinner, QueryView } from '../../components/Common';
import { ENTITY_TYPE_KEYS, entityPath, linkTypeLabel, mergeGraph } from '../../intel';
import type { GraphEdge, GraphNode } from '../../intel';

export const GRAPH_LAYOUT = { name: 'cose', animate: false, randomize: false, fit: true, padding: 24 } as const;

const nodeElement = (n: GraphNode, position?: { x: number; y: number }): ElementDefinition => ({
  group: 'nodes',
  data: { id: String(n.id), label: n.label, type: n.type, root: n.root ? 1 : 0 },
  ...(position ? { position } : {}),
});
const edgeElement = (e: GraphEdge, label: string): ElementDefinition => ({
  group: 'edges',
  data: { id: `e${e.id}`, source: String(e.from), target: String(e.to), label },
});

/** Theme colours from the CSS tokens (canvas drawing cannot use CSS variables directly). */
function themeColors(el: HTMLElement) {
  const css = getComputedStyle(el);
  const v = (name: string, fallback: string) => css.getPropertyValue(name).trim() || fallback;
  return { fg: v('--color-fg', '#e6e6e6'), muted: v('--color-muted', '#9a9a9a'), line: v('--color-line-strong', '#444'), accent: v('--color-accent', '#3b82f6'), danger: v('--color-danger', '#ef4444') };
}

export interface GraphCanvasProps {
  graph: Graph;
  onSelect: (id: number | null) => void;
  /** Receives the Cytoscape instance (expansions add elements through it). */
  onReady: (cy: Core) => void;
}

/** Creates the Cytoscape instance once for the first graph; later changes go through the instance, not re-renders. */
export function GraphCanvas({ graph, onSelect, onReady }: GraphCanvasProps) {
  const i18n = useI18n();
  const container = useRef<HTMLDivElement>(null);
  const [failed, setFailed] = useState(false);
  // First graph only: the instance is built once; later graphs are merged in by the parent through `onReady`'s cy.
  const initial = useRef(graph);
  const callbacks = useRef({ onSelect, onReady });
  useEffect(() => {
    callbacks.current = { onSelect, onReady };
  });

  useEffect(() => {
    let cy: Core | null = null;
    let cancelled = false;
    void import('cytoscape')
      .then(({ default: cytoscape }) => {
        const el = container.current;
        if (cancelled || !el) return;
        const colors = themeColors(el);
        const g = initial.current;
        cy = cytoscape({
          container: el,
          elements: [...g.nodes.map((n) => nodeElement(n)), ...g.edges.map((e) => edgeElement(e, linkTypeLabel(i18n, e.type)))],
          style: [
            { selector: 'node', style: { label: 'data(label)', color: colors.fg, 'font-size': 10, 'background-color': colors.muted, width: 18, height: 18, 'text-valign': 'bottom', 'text-margin-y': 4 } },
            { selector: 'node[root = 1]', style: { 'background-color': colors.accent, width: 26, height: 26 } },
            { selector: 'node:selected', style: { 'border-width': 3, 'border-color': colors.danger } },
            { selector: 'edge', style: { width: 1.5, 'line-color': colors.line, 'curve-style': 'bezier', label: 'data(label)', 'font-size': 8, color: colors.muted } },
          ],
          minZoom: 0.2,
          maxZoom: 3,
          wheelSensitivity: 0.3,
        });
        // Render once: run the layout synchronously (no animation), then stop it so nothing keeps ticking.
        const layout = cy.layout(GRAPH_LAYOUT);
        layout.run();
        layout.stop();
        cy.on('tap', 'node', (evt) => callbacks.current.onSelect(Number(evt.target.id())));
        cy.on('tap', (evt) => {
          if (evt.target === cy) callbacks.current.onSelect(null);
        });
        callbacks.current.onReady(cy);
      })
      .catch((err: unknown) => {
        console.error('[fredpd] graph failed to load', err);
        if (!cancelled) setFailed(true);
      });
    return () => {
      cancelled = true;
      cy?.destroy();
    };
  }, [i18n]);

  if (failed) return <Callout tone="danger">{i18n.t('errors.unknown')}</Callout>;
  return <div ref={container} data-graph-canvas className="h-[60vh] w-full rounded-md border border-line bg-canvas" />;
}

function GraphPanel({ initial, rootId }: { initial: Graph; rootId: number }) {
  const i18n = useI18n();
  const { t, tx } = i18n;
  const errorText = useErrorText();
  const queryClient = useQueryClient();
  const transport = useTransport();
  const [graph, setGraph] = useState(initial);
  const [selected, setSelected] = useState<number | null>(null);
  const [expanded, setExpanded] = useState<ReadonlySet<number>>(() => new Set([rootId]));
  const [expanding, setExpanding] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const cyRef = useRef<Core | null>(null);
  const node = graph.nodes.find((n) => n.id === selected) ?? null;

  const expand = async (id: number) => {
    setExpanding(true);
    setError(null);
    try {
      const more = await queryClient.fetchQuery(mdtQueryOptions('getGraph', { entityId: id, depth: 1 }, transport));
      const merged = mergeGraph(graph, more);
      setGraph(merged.graph);
      setExpanded((s) => new Set([...s, id]));
      const cy = cyRef.current;
      if (cy && (merged.addedNodes.length > 0 || merged.addedEdges.length > 0)) {
        // New nodes on a circle around the expanded one; no second layout run.
        const center = cy.getElementById(String(id)).position();
        const r = 80 + 4 * merged.addedNodes.length;
        cy.add([
          ...merged.addedNodes.map((n, i) => {
            const a = (2 * Math.PI * i) / Math.max(1, merged.addedNodes.length);
            return nodeElement(n, { x: center.x + r * Math.cos(a), y: center.y + r * Math.sin(a) });
          }),
          ...merged.addedEdges.map((e) => edgeElement(e, linkTypeLabel(i18n, e.type))),
        ]);
      }
    } catch (err) {
      setError(err);
    } finally {
      setExpanding(false);
    }
  };

  return (
    <div className="flex flex-col gap-3" data-graph={graph.nodes.length}>
      {graph.truncated && <Callout tone="warning">{tx('intel.graph.truncated', { max: GRAPH_NODE_CAP })}</Callout>}
      <div className="grid gap-3 lg:grid-cols-[minmax(0,1fr)_16rem]">
        <GraphCanvas
          graph={initial}
          onSelect={setSelected}
          onReady={(cy) => {
            cyRef.current = cy;
          }}
        />
        <Card title={node ? node.label : t('intel.section.graph')}>
          {node ? (
            <div className="flex flex-col gap-2 text-sm">
              <p className="text-muted">{t(ENTITY_TYPE_KEYS[node.type])}</p>
              <Link to={entityPath(node.id)} className="text-accent-text hover:underline">
                {t('common.open')}
              </Link>
              <Button size="sm" loading={expanding} disabled={expanded.has(node.id)} onClick={() => void expand(node.id)}>
                {t('intel.graph.expand')}
              </Button>
            </div>
          ) : (
            <p className="text-sm text-muted">{tx('intel.graph.hint', { nodes: graph.nodes.length, edges: graph.edges.length })}</p>
          )}
          {error !== null && <p className="mt-2 text-sm text-danger">{errorText(error)}</p>}
        </Card>
      </div>
    </div>
  );
}

export function GraphView({ entityId }: { entityId: number }) {
  const { t } = useI18n();
  const query = useMdtQuery('getGraph', { entityId, depth: 1 });
  return (
    <QueryView query={query} loading={<PageSpinner />} notFound={t('errors.notFound')}>
      {(graph) => <GraphPanel key={entityId} initial={graph} rootId={entityId} />}
    </QueryView>
  );
}

export default GraphView;
