// Starter. Create page: no prefetch needed, the form is a client leaf.
import { CreateOrderForm } from '@/features/orders/components/create-order-form'

export default function NewOrderPage() {
  return (
    <main className="mx-auto max-w-2xl space-y-6 p-6">
      <h1 className="text-2xl font-semibold">New order</h1>
      <CreateOrderForm />
    </main>
  )
}
