// SPDX-License-Identifier: GPL-3.0-only
// Underrättelser helpers (docs/contracts.md §C15): labels, paths, graph merging. Everything is canView-shaped by
// fredpd_intel; the pages only render what arrives (notice → Notice only, masked source → codename/reliability only).
import type { LocaleKey } from '@fredpd/types/locale-keys';
import type { Entity, Graph } from '@fredpd/types/intel';
import { GRAPH_NODE_CAP } from '@fredpd/types/intel';
import type { I18n } from '@fredpd/ui';

export const ENTITY_TYPES = ['person', 'vehicle', 'location', 'group', 'case'] as const satisfies readonly Entity['type'][];
export const ENTITY_TYPE_KEYS: Readonly<Record<Entity['type'], LocaleKey>> = {
  person: 'intel.entity.type.person',
  vehicle: 'intel.entity.type.vehicle',
  location: 'intel.entity.type.location',
  group: 'intel.entity.type.group',
  case: 'intel.entity.type.case',
};

export const LINK_TYPES = ['associate', 'member_of', 'owns', 'uses', 'seen_at', 'related'] as const;
export const linkTypeLabel = (i18n: Pick<I18n, 'tx'>, type: string) => i18n.tx(`intel.linkType.${type}`, undefined, type);

export type Reliability = 'A' | 'B' | 'C' | 'D';
export const RELIABILITY_KEYS: Readonly<Record<Reliability, LocaleKey>> = {
  A: 'intel.reliability.a',
  B: 'intel.reliability.b',
  C: 'intel.reliability.c',
  D: 'intel.reliability.d',
};

export const INTEL_BASE = '/intel';
export const entityPath = (id: number) => `${INTEL_BASE}/objekt/${id}`;
export const sourcePath = (id: number) => `${INTEL_BASE}/kallor/${id}`;
export const intelReportPath = (id: number) => `${INTEL_BASE}/rapporter/${id}`;
export const missionPath = (id: number) => `${INTEL_BASE}/insatser/${id}`;

export type GraphNode = Graph['nodes'][number];
export type GraphEdge = Graph['edges'][number];

/**
 * Merges an expansion into the graph shown: new nodes and edges only (existing ones keep their data and `root`).
 * The shown graph never exceeds `cap` nodes (GRAPH_NODE_CAP, docs/contracts.md §C15): expansions past it add only
 * what fits and mark the graph truncated, so repeated "Visa kopplingar" cannot grow the canvas without bound.
 */
export function mergeGraph(base: Graph, more: Graph, cap: number = GRAPH_NODE_CAP): { graph: Graph; addedNodes: GraphNode[]; addedEdges: GraphEdge[] } {
  const nodeIds = new Set(base.nodes.map((n) => n.id));
  const edgeIds = new Set(base.edges.map((e) => e.id));
  const fresh = more.nodes.filter((n) => !nodeIds.has(n.id));
  const room = Math.max(0, cap - base.nodes.length);
  const addedNodes = fresh.slice(0, room).map((n) => ({ ...n, root: false }));
  const known = new Set([...nodeIds, ...addedNodes.map((n) => n.id)]);
  const addedEdges = more.edges.filter((e) => !edgeIds.has(e.id) && known.has(e.from) && known.has(e.to));
  return {
    graph: {
      nodes: [...base.nodes, ...addedNodes],
      edges: [...base.edges, ...addedEdges],
      truncated: base.truncated || more.truncated || fresh.length > addedNodes.length,
    },
    addedNodes,
    addedEdges,
  };
}
