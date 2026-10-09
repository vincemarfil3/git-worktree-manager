// Starter. Types for the feature. With OpenAPI, alias generated types here instead:
//   import type { components } from '@/lib/api-types'
//   export type Order = components['schemas']['OrderRead']
// Nothing else should import api-types.ts directly.
export type OrderStatus = 'paid' | 'pending' | 'failed' | 'refunded'

export type Order = {
  id: string
  customer_name: string
  status: OrderStatus
  total: string // decimal string, never a float
  currency: string
  created_at: string // ISO 8601 UTC
}

export type Page<T> = { items: T[]; total: number; page: number; page_size: number }

/** Request body for POST /orders (the API shape, not the form shape) */
export type CreateOrderRequest = {
  customer_name: string
  currency: string
  amount: string
  note?: string
  send_receipt: boolean
}
