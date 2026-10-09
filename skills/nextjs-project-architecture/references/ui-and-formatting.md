# UI, formatting, and route states

Profiles: Starter uses shadcn primitives, tokens/dark mode, and route-state files. Standard adds the status map and formatters. Hardened enforces the strict money and date rules below.

## shadcn layering

- `components/ui/`: shadcn-generated primitives. Minimal edits; brand via CSS variable tokens in `globals.css`.
- `components/shared/`: composes primitives with RHF / TanStack Table.
- `features/`: uses `shared/`, and `ui/` directly only for simple one-offs.
- Global UI: Sonner toasts (wired to QueryClient `onError`), Dialog / AlertDialog for confirmations.

Table primitive mapping: data-table → Table; column-header → Button + DropdownMenu; row-actions → DropdownMenu; toolbar → Input, Select/Combobox, DropdownMenu (column visibility); pagination → Button + Select; states → Skeleton; status cells → Badge.

## Tokens and dark mode (next-themes)

- `ThemeProvider` in providers: class attribute, `defaultTheme="system"`, `enableSystem`, `disableTransitionOnChange`, pass the CSP nonce.
- `suppressHydrationWarning` on `<html>`.
- Theme toggle: shipped as `components/shared/theme-toggle.tsx` (Light / Dark / System radio menu, in the `(app)` header). Both icons render and swap with `dark:` classes, so there is no mounted check and no hydration mismatch. Tested in `theme-toggle.test.tsx` and `e2e/theme.spec.ts` (follows the OS setting; saved choice applied before React loads, so no flash).
- A new custom color gets a variable in BOTH `:root` and `.dark` in `globals.css`.
- Components use semantic classes only (`bg-background`, `text-foreground`, `text-muted-foreground`, `border-border`) — never raw `bg-white`/`text-gray-900`.
- Status tokens for payment states (paid, pending, failed, refunded) mapped to Badge variants; check WCAG AA contrast in both themes.
- Charts use shadcn chart tokens. Rich text: `prose dark:prose-invert`. Logos may need dark variants.

## Icons (Lucide)

- Size with Tailwind (`size-4`); shadcn buttons auto-size icons.
- Decorative icons hidden from screen readers; icon-only buttons need `aria-label` + Tooltip.
- Brand/payment logos (Visa, Mastercard, GCash…) as official SVGs in `components/icons/`, following brand guidelines.

## Status map — `features/<n>/status.ts`

Lives in the feature (so `lib/` never imports `features/`). One map: status → `{ label, badgeVariant, icon }`, keys typed against the generated status enum (new backend status = compile error until mapped). Used by table cells, detail pages, and filters.

## Formatters — `lib/format/`

Shipped: `money.ts` (`formatMoney`, `parseMoney`), `date.ts` (`formatDate`, `formatDateTime`, `formatDateOnly`, `DISPLAY_TIME_ZONE`). Add on demand: `number.ts` (`formatNumber`, `formatPercent`), `formatRelative`, `toUtcRange`. No inline `toFixed` or date formatting anywhere else.

Money:
- Amounts arrive as decimal strings (e.g. Pydantic `Decimal`) + currency code. Never convert to JS float.
- Backend computes totals/fees. If the UI must calculate, use `big.js`.
- Currency always explicit from data. Decimal places vary (PHP/USD 2, JPY 0, some 3) — never hardcode `/100`; let `Intl.NumberFormat` decide.
- `Intl.NumberFormat` (locale e.g. `en-PH`) formats decimal strings precisely in modern engines. Cache formatter instances per locale+currency.
- Symbol on single-currency screens, code where multiple currencies appear. Consistent negative/refund style. Compact format only for dashboard summaries.
- `parseMoney` accepts `1,234.50`, strips grouping, validates max decimals.

Dates:
- The backend sends timezone-aware ISO 8601 UTC. Use date-fns v4 (with tz support) or `Intl.DateTimeFormat`.
- **Hydration trap:** server timezone (often UTC) ≠ browser timezone → mismatched text. Always format with an explicit timezone (merchant setting or default e.g. `Asia/Manila`) on both sides.
- Relative times: client-only, or absolute on server then switch after mount. Use `<time dateTime>` with full timestamp tooltip.
- Date-only values stay `YYYY-MM-DD` strings; never timezone-convert them.
- Range filters: user's days in display timezone → UTC boundaries (start of first day to end of last day).

## Route groups and route-state files

- `(auth)`: login, minimal layout. `(app)`: protected shell. Put `loading.tsx` and `error.tsx` inside `(app)` so the shell persists.
- `loading.tsx`: skeleton matching the real layout; route-specific only where layout differs.
- `error.tsx`: client component; catches its segment's page and below, not its own layout. `global-error.tsx` renders its own `html`/`body`. Wire "Try again" to both Next's `reset` and TanStack's query error reset boundary. Show friendly message + error digest as support reference; report to Sentry. Boundaries retry reads only — never re-run mutations.
- Expected errors (validation, empty, failed refetch) stay inline; unexpected render failures go to `error.tsx`.
- Backend errors during render: 404 → `notFound()`; 401 → redirect to login; 403 → shared forbidden state; 5xx → throw.
- `not-found.tsx`: root (unknown URLs) and resource-level (e.g. "Order not found" with link back to list).
