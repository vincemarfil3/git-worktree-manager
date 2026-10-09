'use client'
// Standard. Server-mode data table (TanStack Table v9). It NEVER fetches: the feature leaf calls its
// query hook and passes the results in. Pagination and sorting are done by the backend (manual*).
import { useEffect, useState } from 'react'
import { useTable, type ColumnDef, type OnChangeFn, type PaginationState, type RowData, type RowSelectionState, type SortingState } from '@tanstack/react-table'
import { Checkbox } from '@/components/ui/checkbox'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { cn } from '@/lib/utils'
import { ColumnHeader } from './column-header'
import { dataTableFeatures, type DataTableFeatures } from './features'
import { TablePagination } from './table-pagination'
import { EmptyRow, ErrorRow, SkeletonRows, type EmptyState } from './table-states'

const EMPTY: never[] = [] // stable fallback: a new [] each render would rebuild row models

export type DataTableProps<TData extends RowData> = {
  /** Build with createColumnHelper<DataTableFeatures, TData>().columns([...]) */
  columns: ColumnDef<DataTableFeatures, TData, unknown>[]
  data: TData[] | undefined
  /** Server total (e.g. page.total). Drives page count. */
  rowCount: number | undefined
  /** Stable domain id, never the index */
  getRowId: (row: TData) => string

  pagination: PaginationState
  onPaginationChange: OnChangeFn<PaginationState>
  sorting: SortingState
  onSortingChange: OnChangeFn<SortingState>

  /** First load: skeleton rows */
  isLoading?: boolean
  /** Background refetch: rows stay, subtle indicator */
  isFetching?: boolean
  isError?: boolean
  onRetry?: () => void
  /** "No orders yet" + create button, or "No results" + clear filters */
  empty: EmptyState

  toolbar?: React.ReactNode
  /** Enables the checkbox column. Receives selected rows and a clear function. */
  bulkActions?: (selected: TData[], clear: () => void) => React.ReactNode
}

export function DataTable<TData extends RowData>({
  columns, data, rowCount, getRowId, pagination, onPaginationChange, sorting, onSortingChange,
  isLoading, isFetching, isError, onRetry, empty, toolbar, bulkActions,
}: DataTableProps<TData>) {
  const [rowSelection, setRowSelection] = useState<RowSelectionState>({})
  const selectable = !!bulkActions
  const rows = data ?? (EMPTY as TData[])

  const table = useTable({
    features: dataTableFeatures,
    columns,
    data: rows,
    rowCount: rowCount ?? 0,
    getRowId: (row) => getRowId(row),
    manualPagination: true,
    manualSorting: true,
    enableRowSelection: selectable,
    state: { pagination, sorting, rowSelection },
    onPaginationChange,
    onSortingChange,
    onRowSelectionChange: setRowSelection,
  })

  // Reset selection when the page, sort, or filters change (new data arrives)
  useEffect(() => setRowSelection({}), [data])

  // Clamp out-of-range pages (e.g. last item on the last page was deleted, or ?page=999)
  useEffect(() => {
    if (isLoading || rowCount === undefined) return
    const pageCount = Math.max(1, Math.ceil(rowCount / pagination.pageSize))
    if (pagination.pageIndex >= pageCount) onPaginationChange({ ...pagination, pageIndex: pageCount - 1 })
  }, [isLoading, rowCount, pagination, onPaginationChange])

  const selectedRows = table.getSelectedRowModel().rows.map((r) => r.original)
  const columnCount = columns.length + (selectable ? 1 : 0)
  const bodyRows = table.getRowModel().rows

  return (
    <div className="space-y-3">
      {toolbar}
      {selectable && selectedRows.length > 0 && (
        <div className="flex items-center gap-2 rounded-md border bg-muted/50 px-3 py-2 text-sm">
          <span className="tabular-nums">{selectedRows.length} selected</span>
          {bulkActions(selectedRows, () => setRowSelection({}))}
        </div>
      )}

      <div className={cn('relative overflow-x-auto rounded-md border', isFetching && !isLoading && 'opacity-70 transition-opacity')} aria-busy={isLoading || isFetching}>
        <Table>
          <TableHeader>
            {table.getHeaderGroups().map((group) => (
              <TableRow key={group.id}>
                {selectable && (
                  <TableHead className="w-10">
                    <Checkbox
                      aria-label="Select all rows on this page"
                      checked={table.getIsAllPageRowsSelected() ? true : table.getIsSomePageRowsSelected() ? 'indeterminate' : false}
                      onCheckedChange={(v) => table.toggleAllPageRowsSelected(v === true)}
                    />
                  </TableHead>
                )}
                {group.headers.map((header) => {
                  const meta = header.column.columnDef.meta
                  const sorted = header.column.getIsSorted()
                  const title = header.column.columnDef.header
                  return (
                    <TableHead
                      key={header.id}
                      className={cn(meta?.width, meta?.align === 'end' && 'text-right')}
                      aria-sort={sorted === 'asc' ? 'ascending' : sorted === 'desc' ? 'descending' : undefined}
                    >
                      {header.isPlaceholder ? null : typeof title === 'string' ? (
                        // String headers get sorting UI automatically. Set enableSorting: false on columns the backend cannot sort.
                        <ColumnHeader
                          title={title}
                          sorted={sorted}
                          canSort={header.column.getCanSort()}
                          onToggle={header.column.getToggleSortingHandler()}
                          align={meta?.align}
                        />
                      ) : (
                        <table.FlexRender header={header} />
                      )}
                    </TableHead>
                  )
                })}
              </TableRow>
            ))}
          </TableHeader>
          <TableBody>
            {isLoading ? (
              <SkeletonRows rows={Math.min(pagination.pageSize, 10)} columns={columnCount} />
            ) : isError && !data ? (
              <ErrorRow columns={columnCount} onRetry={onRetry} />
            ) : bodyRows.length === 0 ? (
              <EmptyRow columns={columnCount} empty={empty} />
            ) : (
              bodyRows.map((row) => (
                <TableRow key={row.id} data-state={row.getIsSelected() ? 'selected' : undefined}>
                  {selectable && (
                    <TableCell>
                      <Checkbox aria-label="Select row" checked={row.getIsSelected()} onCheckedChange={(v) => row.toggleSelected(v === true)} />
                    </TableCell>
                  )}
                  {row.getAllCells().map((cell) => (
                    <TableCell key={cell.id} className={cn(cell.column.columnDef.meta?.align === 'end' && 'text-right tabular-nums')}>
                      <table.FlexRender cell={cell} />
                    </TableCell>
                  ))}
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </div>

      <TablePagination
        pageIndex={pagination.pageIndex}
        pageSize={pagination.pageSize}
        rowCount={rowCount ?? 0}
        selectedCount={selectable ? selectedRows.length : undefined}
        onPageChange={(pageIndex) => onPaginationChange({ ...pagination, pageIndex })}
        onPageSizeChange={(pageSize) => onPaginationChange({ pageIndex: 0, pageSize })}
      />
    </div>
  )
}
