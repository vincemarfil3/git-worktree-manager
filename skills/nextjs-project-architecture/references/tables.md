# Tables — TanStack Table v9 + nuqs URL state

Implemented in `assets/templates/src/components/shared/table/`; usage in `GUIDE.md` section 6. TanStack Table **v9**: `useTable({ features, columns, data })`, features registered in `features.ts` (`rowSortingFeature`, `rowPaginationFeature`, `rowSelectionFeature`, `columnMeta`), columns built with `createColumnHelper<DataTableFeatures, T>().columns([...])`, cells rendered with `<table.FlexRender>`. v8 APIs (`useReactTable`, `getCoreRowModel`, `flexRender` imports, global `ColumnMeta` module augmentation) do not apply.

## Files — `components/shared/table/`

`features.ts`, `data-table.tsx`, `table-search-params.ts`, `use-table-url-state.ts`, `table-toolbar.tsx`, `table-pagination.tsx`, `column-header.tsx`, `row-actions.tsx`, `confirm-dialog.tsx`, `table-states.tsx`, `index.ts`.

## data-table contract

The table never fetches. A feature leaf (`orders-table.tsx`) calls its query hook and passes results in.

Props:
- `columns`, `data`, `rowCount` (server total)
- pagination + sorting state and change handlers (from `use-table-url-state`)
- `isLoading` (first load → skeleton rows = page size), `isFetching` (refetch → keep rows, subtle indicator)
- `error`, `onRetry`
- `emptyState` (message + optional action)
- `getRowId` — stable domain id, never the index
- slots: `toolbar`, `bulkActions(selected, clear)` (enables the checkbox column)
- Server mode only. For small fully-loaded lists, create a second registry with `sortedRowModel`/`paginatedRowModel` slots.

## Server mode

- Manual pagination/sorting/filtering; page count from `rowCount`.
- Standard pagination envelope for every list endpoint (e.g. FastAPI generic `Page[T]`): `{ items, total, page, page_size }`. In Mode B, the service returns the same shape.
- One sort format across URL and API, e.g. `sort=created_at:desc`. Single-column sort by default.
- Clamp out-of-range pages to the last valid page.
- Optional: prefetch the next page.

Client mode: small fully-loaded lists using TanStack's built-in row models. Virtualize (TanStack Virtual) only if thousands of rows.

## Columns (in the feature)

- `features/<name>/components/<name>-columns.tsx`, typed with generated types.
- Column `meta`: label, align, width. Numbers/money right-aligned with `tabular-nums`.
- Cells use shared formatters (`lib/format`) and the feature's status map (`features/<n>/status.ts`) with `Badge`. No inline formatting.
- Row actions column last, not hideable. Destructive actions confirm with `AlertDialog`; successful mutations invalidate list keys.
- Column visibility (not in the templates yet): register `columnVisibilityFeature` and persist to localStorage per table (user preference, not URL).
- Detail navigation via a real link in a cell (keyboard + middle-click), not only row click.

## States

Initial skeleton; refetch keeps rows with opacity/progress bar; error + retry; distinguish "no data yet" (create action) from "no results for filters" (clear filters).

## Selection

Reset selection on page, filter, or sort change. Show selected count in the bulk bar.

## Responsive / a11y

Horizontal scroll container with sticky first column; consider card-list variant for mobile-heavy tables. Real table semantics, sort buttons in headers, `aria-sort`.

## URL state with nuqs

- Adapter in `providers.tsx`.
- Parsers once per feature in `features/<n>/search-params.ts` via `createTableSearchParams({ sortable, defaultSort })`: page (int >= 1), pageSize (allowed sizes only), sort (`col:asc|desc` for whitelisted columns only), search. Extra filters live in a separate `useQueryStates` in the feature and go into the query key params.
- Same parsers on the server (`page.tsx` via `createLoader`) and client (`useTableUrlState`) → identical query key → hydrated cache hit on first paint. Parsers are imported from `nuqs/server` so the module is safe on both sides.
- Invalid values fall back to defaults (hand-edited URLs never reach the backend unsanitized).
- `clearOnDefault` keeps URLs clean.
- Shallow updates (default) — TanStack Query fetches client-side, no server re-render.
- History: `push` for page changes, `replace` for filters/search.
- Debounce search in the input (`TableToolbar`, 300ms) before writing the URL. nuqs updates hook state immediately even when URL writes are throttled, so throttling alone would still fire a request per keystroke.
- Reset page to 1 when filters, search, or sort change.
- `use-table-url-state.ts` maps nuqs values ↔ TanStack Table pagination/sorting state.
- Never put sensitive data in the URL (customer details, emails, card fragments, tokens).
