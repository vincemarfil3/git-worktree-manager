// Starter (Mode A). Server-only endpoint calls, used by page.tsx prefetch. Never imported by client files.
// Mode B: replace serverApi with a call into src/server/services.
import 'server-only'
import { serverApi } from '@/lib/server-api'
import type { OrdersListParams } from './keys'
import type { Order, Page } from './types'

export const ordersApiServer = {
  list: (p: OrdersListParams) =>
    serverApi.get<Page<Order>>('/orders', {
      query: { page: p.page, page_size: p.pageSize, sort: p.sort, search: p.search || undefined },
    }),
  detail: (id: string) => serverApi.get<Order>(`/orders/${id}`),
}
