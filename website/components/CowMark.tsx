/** The menu bar cow (same shapes as CowArt.swift, y-axis flipped for SVG). */
export function CowMark({ className, title }: { className?: string; title?: string }) {
  const id = "cowmask";
  return (
    <svg viewBox="2 5 96 80" className={className} role={title ? "img" : undefined} aria-label={title} aria-hidden={title ? undefined : true}>
      <defs>
        <mask id={id}>
          <g fill="white">
            <path d="M24 25 C19 20 16 13 18 7 C26 8 32 14 36 21 Z" />
            <path d="M76 25 C81 20 84 13 82 7 C74 8 68 14 64 21 Z" />
            <ellipse cx="17" cy="37" rx="14" ry="7.5" transform="rotate(22 17 37)" />
            <ellipse cx="83" cy="37" rx="14" ry="7.5" transform="rotate(-22 83 37)" />
            <rect x="21" y="18" width="58" height="52" rx="27" ry="25" />
            <ellipse cx="50" cy="68" rx="27" ry="15.5" />
          </g>
          <g fill="black">
            <ellipse cx="37" cy="42" rx="5.5" ry="6" />
            <ellipse cx="63" cy="42" rx="5.5" ry="6" />
            <ellipse cx="41" cy="68" rx="4" ry="5.5" />
            <ellipse cx="59" cy="68" rx="4" ry="5.5" />
          </g>
          <path d="M23 66 A27 15.5 0 0 1 77 66" fill="none" stroke="black" strokeWidth="5" />
        </mask>
      </defs>
      <rect x="0" y="0" width="100" height="100" fill="currentColor" mask={`url(#${id})`} />
    </svg>
  );
}
