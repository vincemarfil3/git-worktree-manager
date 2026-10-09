// Standard. TanStack Table v9 registers features explicitly. Every shared table uses this one registry,
// so feature columns are typed against it:  const helper = createColumnHelper<DataTableFeatures, Order>()
import { metaHelper, rowPaginationFeature, rowSelectionFeature, rowSortingFeature, tableFeatures } from '@tanstack/react-table'

export type DataTableColumnMeta = {
  /** Human label used by toolbars and column menus */
  label?: string
  /** Right-align numbers and money */
  align?: 'start' | 'end'
  /** Fixed width class, e.g. "w-32" */
  width?: string
}

// Server mode: no client row models registered. Sorting and pagination are done by the backend (manual*).
// Client mode (small, fully loaded lists): add sortedRowModel/paginatedRowModel slots in a separate registry.
export const dataTableFeatures = tableFeatures({
  rowSortingFeature,
  rowPaginationFeature,
  rowSelectionFeature,
  columnMeta: metaHelper<DataTableColumnMeta>(),
})

export type DataTableFeatures = typeof dataTableFeatures
