'use client'
// Standard. Client leaf: URL state -> query hook -> shared DataTable. No fetching logic in the table itself.
import Link from 'next/link'
import { useMemo } from 'react'
import { Button } from '@/components/ui/button'
import { DataTable, TableToolbar, useTableUrlState } from '@/components/shared/table'
import { useDeleteOrder } from '../mutations'
import { useOrders } from '../queries'
import { ordersSearchParams } from '../search-params'
import { getOrdersColumns } from './orders-columns'

export function OrdersTable() {
  const url = useTableUrlState(ordersSearchParams)
  const query = useOrders(url.params) // same params as the server prefetch -> hydrated on first paint
  const deleteOrder = useDeleteOrder()

  // Stable columns: rebuilding them every render resets table internals
  const columns = useMemo(() => getOrdersColumns({ onDelete: (id) => deleteOrder.mutateAsync(id) }), [deleteOrder.mutateAsync])

  const hasFilters = url.params.search !== ''

  return (
    <DataTable
      columns={columns}
      data={query.data?.items}
      rowCount={query.data?.total}
      getRowId={(o) => o.id}
      pagination={url.pagination}
      onPaginationChange={url.onPaginationChange}
      sorting={url.sorting}
      onSortingChange={url.onSortingChange}
      isLoading={query.isPending}
      isFetching={query.isFetching}
      isError={query.isError}
      onRetry={() => void query.refetch()}
      empty={
        hasFilters
          ? { message: 'No orders match your search.', action: <Button variant="outline" size="sm" onClick={() => url.setSearch('')}>Clear search</Button> }
          : { message: 'No orders yet.', action: <Button asChild size="sm"><Link href="/orders/new">Create order</Link></Button> }
      }
      toolbar={
        <TableToolbar
          search={url.params.search}
          onSearchChange={url.setSearch}
          searchPlaceholder="Search customer or order ID…"
          actions={<Button asChild><Link href="/orders/new">New order</Link></Button>}
        />
      }
    />
  )
}
