// Standard. Form values -> API payload. Typed against the request type, so API changes break compilation here.
import type { CreateOrderFormValues } from './schemas'
import type { CreateOrderRequest } from './types'

export function toCreateOrderPayload(v: CreateOrderFormValues): CreateOrderRequest {
  return {
    customer_name: v.customerName,
    currency: v.currency,
    amount: v.amount, // already a normalized decimal string
    note: v.note,
    send_receipt: v.sendReceipt,
  }
}
