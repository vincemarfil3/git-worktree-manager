// Starter (Mode A). Browser endpoint calls via same-origin /api. Mirrors api.server.ts paths.
// Mode B: point at Route Handlers under app/api/orders.
import { apiClient } from '@/lib/api-client'
import type { OrdersListParams } from './keys'
import type { CreateOrderRequest, Order, Page } from './types'

export const ordersApi = {
  list: async (p: OrdersListParams, signal?: AbortSignal) =>
    (
      await apiClient.get<Page<Order>>('/orders', {
        params: { page: p.page, page_size: p.pageSize, sort: p.sort, search: p.search || undefined },
        signal,
      })
    ).data,
  detail: async (id: string, signal?: AbortSignal) => (await apiClient.get<Order>(`/orders/${id}`, { signal })).data,
  create: async (body: CreateOrderRequest) => (await apiClient.post<Order>('/orders', body)).data,
  remove: async (id: string) => {
    await apiClient.delete(`/orders/${id}`)
  },
}
