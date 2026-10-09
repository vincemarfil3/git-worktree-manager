'use client'
// Standard. Bridges nuqs URL state <-> TanStack Table state.
// - page/pageSize: history push (back button goes to previous page)
// - sort/search: history replace, and reset to page 1
// - shallow (default): TanStack Query fetches client-side, no server re-render
import { useQueryStates } from 'nuqs'
import type { OnChangeFn, PaginationState, SortingState } from '@tanstack/react-table'
import { sortToSorting, type TableSearchParams } from './table-search-params'

export function useTableUrlState(parsers: TableSearchParams) {
  const [params, setParams] = useQueryStates(parsers, { clearOnDefault: true })

  const pagination: PaginationState = { pageIndex: params.page - 1, pageSize: params.pageSize }
  const sorting: SortingState = sortToSorting(params.sort)

  const onPaginationChange: OnChangeFn<PaginationState> = (updater) => {
    const next = typeof updater === 'function' ? updater(pagination) : updater
    const sizeChanged = next.pageSize !== pagination.pageSize
    void setParams({ page: sizeChanged ? null : next.pageIndex + 1, pageSize: next.pageSize }, { history: 'push' })
  }

  const onSortingChange: OnChangeFn<SortingState> = (updater) => {
    const next = typeof updater === 'function' ? updater(sorting) : updater
    const first = next[0]
    // null resets to the default sort
    void setParams({ sort: first ? `${first.id}:${first.desc ? 'desc' : 'asc'}` : null, page: null }, { history: 'replace' })
  }

  /** Call with an already-debounced value (TableToolbar debounces for you). */
  const setSearch = (value: string) => void setParams({ search: value || null, page: null }, { history: 'replace' })

  /** For feature filters kept in a separate useQueryStates: call when a filter changes. */
  const resetPage = () => void setParams({ page: null }, { history: 'replace' })

  // `params` is what goes into the query key; it matches what createLoader returns on the server.
  return { params, pagination, sorting, onPaginationChange, onSortingChange, setSearch, resetPage }
}
