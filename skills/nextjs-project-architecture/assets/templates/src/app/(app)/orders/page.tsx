// Starter. List page: prefetch on the server, hydrate the client leaf.
// USE THIS PATTERN ONLY IF the client keeps using the cache (pagination, mutations, refetch).
// Otherwise fetch directly in the Server Component and render (references/decisions.md section 1).
import { dehydrate, HydrationBoundary } from '@tanstack/react-query'
import type { SearchParams } from 'nuqs/server'
import { getQueryClient } from '@/lib/query-client'
import { ordersApiServer } from '@/features/orders/api.server'
import { ordersKeys } from '@/features/orders/keys'
import { loadOrdersSearchParams } from '@/features/orders/search-params'
import { OrdersTable } from '@/features/orders/components/orders-table'

export default async function OrdersPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  // Same parsers as the client leaf -> identical query key -> cache hit on first paint
  const params = await loadOrdersSearchParams(searchParams)
  const queryClient = getQueryClient()

  // Several prefetches: Promise.all to avoid waterfalls. One client, one dehydrate, one boundary.
  await queryClient.prefetchQuery({
    queryKey: ordersKeys.list(params),
    queryFn: () => ordersApiServer.list(params),
  })

  return (
    <main className="space-y-6 p-6">
      <h1 className="text-2xl font-semibold">Orders</h1>
      <HydrationBoundary state={dehydrate(queryClient)}>
        <OrdersTable />
      </HydrationBoundary>
    </main>
  )
}
