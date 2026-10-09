// Standard. Form schema (the FORM shape). The API shape is in types.ts; mappers.ts converts between them.
import { z } from 'zod'
import { moneyString, optionalText, requiredText } from '@/lib/validation'

export const createOrderSchema = z.object({
  customerName: requiredText('Enter the customer name'),
  currency: z.enum(['PHP', 'USD']),
  amount: moneyString({ maxDecimals: 2, min: 1 }),
  note: optionalText(),
  sendReceipt: z.boolean(),
})

export type CreateOrderFormInput = z.input<typeof createOrderSchema>
export type CreateOrderFormValues = z.output<typeof createOrderSchema>

export const createOrderDefaults: CreateOrderFormInput = {
  customerName: '',
  currency: 'PHP',
  amount: '',
  note: '',
  sendReceipt: true,
}
