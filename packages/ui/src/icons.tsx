// SPDX-License-Identifier: GPL-3.0-only
// Small stroke icon set (24×24, currentColor), drawn for FredPD. Icons are decorative: the control that holds one
// carries the accessible name (IconButton label, NavItem label).
import type { ReactNode, SVGProps } from 'react';

export type IconProps = Omit<SVGProps<SVGSVGElement>, 'children'> & { size?: number };

function Icon({ size = 18, children, ...rest }: IconProps & { children: ReactNode }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...rest}
    >
      {children}
    </svg>
  );
}

export const IconHome = (p: IconProps) => (
  <Icon {...p}><path d="M3 11 12 4l9 7" /><path d="M5 10v10h14V10" /><path d="M10 20v-6h4v6" /></Icon>
);
export const IconSearch = (p: IconProps) => (
  <Icon {...p}><circle cx="11" cy="11" r="7" /><path d="m20 20-4-4" /></Icon>
);
export const IconBell = (p: IconProps) => (
  <Icon {...p}><path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4z" /><path d="M10 21h4" /></Icon>
);
export const IconFlag = (p: IconProps) => (
  <Icon {...p}><path d="M5 21V4" /><path d="M5 4h11l-2 4 2 4H5" /></Icon>
);
export const IconFolder = (p: IconProps) => (
  <Icon {...p}><path d="M3 6h7l2 2h9v11H3z" /></Icon>
);
export const IconBox = (p: IconProps) => (
  <Icon {...p}><path d="M3 7 12 3l9 4v10l-9 4-9-4z" /><path d="m3 7 9 4 9-4" /><path d="M12 11v10" /></Icon>
);
export const IconEye = (p: IconProps) => (
  <Icon {...p}><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z" /><circle cx="12" cy="12" r="3" /></Icon>
);
export const IconBook = (p: IconProps) => (
  <Icon {...p}><path d="M4 4h10a4 4 0 0 1 4 4v12H8a4 4 0 0 1-4-4z" /><path d="M4 16a4 4 0 0 1 4-4h10" /></Icon>
);
export const IconUsers = (p: IconProps) => (
  <Icon {...p}><circle cx="9" cy="8" r="3.5" /><path d="M2.5 20a6.5 6.5 0 0 1 13 0" /><path d="M16 4.5a3.5 3.5 0 0 1 0 7" /><path d="M18 14a6.5 6.5 0 0 1 3.5 6" /></Icon>
);
export const IconShield = (p: IconProps) => (
  <Icon {...p}><path d="M12 3 4 6v6c0 5 3.5 8 8 9 4.5-1 8-4 8-9V6z" /></Icon>
);
export const IconKey = (p: IconProps) => (
  <Icon {...p}><circle cx="8" cy="15" r="4" /><path d="m11 12 9-9" /><path d="m17 6 3 3" /></Icon>
);
export const IconMenu = (p: IconProps) => (
  <Icon {...p}><path d="M4 6h16M4 12h16M4 18h16" /></Icon>
);
export const IconClose = (p: IconProps) => (
  <Icon {...p}><path d="M6 6l12 12M18 6 6 18" /></Icon>
);
export const IconLogout = (p: IconProps) => (
  <Icon {...p}><path d="M14 4h5v16h-5" /><path d="M10 8l-4 4 4 4" /><path d="M6 12h10" /></Icon>
);
export const IconCheck = (p: IconProps) => (
  <Icon {...p}><path d="m5 12 5 5L19 7" /></Icon>
);
export const IconMinus = (p: IconProps) => (
  <Icon {...p}><path d="M5 12h14" /></Icon>
);
export const IconPlus = (p: IconProps) => (
  <Icon {...p}><path d="M12 5v14M5 12h14" /></Icon>
);
export const IconBan = (p: IconProps) => (
  <Icon {...p}><circle cx="12" cy="12" r="8" /><path d="m6.5 6.5 11 11" /></Icon>
);
