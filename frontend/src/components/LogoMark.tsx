/**
 * Canonical STRATUM logo mark (three strata bars). Geometry matches /logo-mark.svg and the favicon.
 * `variant="dark"` = bars for dark nav backgrounds (white with stepped opacity).
 * `variant="light"` = bars for light backgrounds (ink + gray, same as favicon).
 */

type Props = {
  variant?: "dark" | "light";
  className?: string;
  size?: number;
};

export default function LogoMark({ variant = "light", className, size = 18 }: Props) {
  const height = Math.round((size * 32) / 24);

  if (variant === "dark") {
    return (
      <svg
        className={className}
        width={size}
        height={height}
        viewBox="0 0 24 14"
        fill="none"
        aria-hidden
      >
        <rect x="0" y="0" width="18" height="4" rx="2" fill="#ffffff" />
        <rect x="0" y="5" width="18" height="4" rx="2" fill="#ffffff" opacity="0.66" />
        <rect x="0" y="10" width="11" height="4" rx="2" fill="#ffffff" opacity="0.4" />
      </svg>
    );
  }

  return (
    <svg
      className={className}
      width={size}
      height={height}
      viewBox="0 0 32 32"
      fill="none"
      aria-hidden
    >
      <rect x="4" y="5" width="24" height="6" rx="2" fill="#1d1d1f" />
      <rect x="4" y="13" width="24" height="6" rx="2" fill="#6e6e73" />
      <rect x="4" y="21" width="16" height="6" rx="2" fill="#aeaeb2" />
    </svg>
  );
}
