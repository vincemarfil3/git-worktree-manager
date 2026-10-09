'use client'
// Standard. A feature form is just <Form> + shared fields. No useForm wiring, error rendering,
// or submit-state logic here.
import { useRouter } from 'next/navigation'
import {
  CheckboxField, Form, FormError, FormGrid, FormSection, MoneyField, SelectField, SubmitButton, TextareaField, TextField, useAppForm,
} from '@/components/shared/form'
import { toCreateOrderPayload } from '../mappers'
import { useCreateOrder } from '../mutations'
import { createOrderDefaults, createOrderSchema } from '../schemas'

const currencyOptions = [
  { value: 'PHP', label: 'PHP – Philippine peso' },
  { value: 'USD', label: 'USD – US dollar' },
] as const

export function CreateOrderForm() {
  const router = useRouter()
  const createOrder = useCreateOrder()
  const form = useAppForm(createOrderSchema, createOrderDefaults)
  const currency = form.watch('currency')

  return (
    <Form
      form={form}
      onSubmit={async (values) => {
        // await so the submit button stays disabled for the whole request
        const order = await createOrder.mutateAsync(toCreateOrderPayload(values))
        router.push(`/orders/${order.id}`)
      }}
      // API field names differ from form names: route server errors to the right field
      serverErrors={{ fieldMap: { customer_name: 'customerName', send_receipt: 'sendReceipt' } }}
    >
      <FormError />
      <FormSection title="Order details">
        <FormGrid>
          <TextField control={form.control} name="customerName" label="Customer name" required autoComplete="off" className="sm:col-span-2" />
          <SelectField control={form.control} name="currency" label="Currency" options={currencyOptions} required />
          <MoneyField control={form.control} name="amount" label="Amount" currency={currency} required />
          <TextareaField control={form.control} name="note" label="Note" description="Visible to the customer on the receipt." maxLength={500} className="sm:col-span-2" />
          <CheckboxField control={form.control} name="sendReceipt" label="Email a receipt to the customer" className="sm:col-span-2" />
        </FormGrid>
      </FormSection>
      <SubmitButton pendingText="Creating…">Create order</SubmitButton>
    </Form>
  )
}
