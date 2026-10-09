'use client'
// Starter. Client hooks. Same key factory as the server prefetch, so the hydrated cache is hit on first paint.
import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { ordersApi } from './api.client'
import { ordersKeys, type OrdersListParams } from './keys'

export function useOrders(params: OrdersListParams) {
  return useQuery({
    queryKey: ordersKeys.list(params),
    queryFn: ({ signal }) => ordersApi.list(params, signal),
    placeholderData: keepPreviousData, // no flicker between pages
  })
}

export function useOrder(id: string) {
  return useQuery({
    queryKey: ordersKeys.detail(id),
    queryFn: ({ signal }) => ordersApi.detail(id, signal),
  })
}
