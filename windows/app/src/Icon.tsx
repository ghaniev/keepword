import type {CSSProperties} from 'react';

const paths = {
  home: 'm3 10 9-7 9 7v10a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1Z',
  chat: 'M21 11a8 8 0 0 1-8 8H6l-4 3 1-6a8 8 0 0 1-1-5 8 8 0 0 1 8-8h3a8 8 0 0 1 8 8ZM7 9h9M7 13h6',
  calendar: 'M5 5h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2ZM7 3v4M17 3v4M3 10h18M7 14h2M13 14h2M7 18h2',
  check: 'M22 11v1a10 10 0 1 1-6-9M8 11l4 4L22 5',
  people: 'M15 21v-2a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v2M13 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0ZM17 4a4 4 0 0 1 0 8M21 21v-2a4 4 0 0 0-3-4',
  tag: 'm20 13-7 7a2 2 0 0 1-3 0l-8-8V3h9l9 8a2 2 0 0 1 0 2ZM7 7h.01',
  repeat: 'm17 2 4 4-4 4M3 11V9a3 3 0 0 1 3-3h15M7 22l-4-4 4-4M21 13v2a3 3 0 0 1-3 3H3',
  folder: 'M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z',
  tray: 'M3 13h5l2 3h4l2-3h5M3 13l3-9h12l3 9v7H3Z',
  document: 'M14 2H5v20h14V7ZM14 2v6h5M8 12h8M8 16h8',
  trash: 'M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7',
  settings: 'm9 3-1 3-3 1-2 3 2 2v3l3 2 1 4h6l1-4 3-2v-3l2-2-2-3-3-1-1-3ZM16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z',
  search: 'M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0ZM15 15l6 6',
  record: 'M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0ZM16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z',
  stop: 'M6 6h12v12H6Z',
  import: 'M4 4h5M15 4h5v17H4V4M12 2v12m-4-4 4 4 4-4',
  plus: 'M12 5v14M5 12h14',
  back: 'm14 5-7 7 7 7',
  clock: 'M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0ZM12 6v6l4 2',
  sparkles: 'm12 3 3 6 6 3-6 3-3 6-3-6-6-3 6-3ZM20 2v4M18 4h4',
  waveform: 'M3 10v4M7 6v12M12 3v18M17 6v12M21 10v4',
  bookmark: 'M5 3h14v19l-7-5-7 5Z',
  play: 'm7 3 15 9-15 9Z',
  pause: 'M7 4v16M17 4v16',
  mic: 'M9 5a3 3 0 0 1 6 0v7a3 3 0 0 1-6 0ZM5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8',
  expand: 'M14 3h7v7M21 3l-9 9M10 3H3v18h18v-7',
  close: 'm6 6 12 12M6 18 18 6',
} as const;

export type IconName = keyof typeof paths;
export default function Icon({name,size=16,style}:{name:IconName;size?:number;style?:CSSProperties}) {
  return <svg className="icon" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style={style}><path d={paths[name]}/></svg>;
}
