'use client'
// Starter. Mutations invalidate the feature's keys on success (see the key tree in keys.ts).
// One mutation style per feature: if this feature uses Server Actions instead (Mode B), replace with actions.ts.
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ordersApi } from './api.client'
import { ordersKeys } from './keys'
import type { CreateOrderRequest } from './types'

export function useCreateOrder() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (body: CreateOrderRequest) => ordersApi.create(body),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ordersKeys.lists() }),
  })
}

export function useDeleteOrder() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => ordersApi.remove(id),
    onSuccess: (_data, id) => {
      queryClient.removeQueries({ queryKey: ordersKeys.detail(id) })
      return queryClient.invalidateQueries({ queryKey: ordersKeys.lists() })
    },
  })
}
