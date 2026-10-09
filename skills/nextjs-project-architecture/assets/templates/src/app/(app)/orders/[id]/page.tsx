// Read-only page: fetch directly in the Server Component. No TanStack Query needed here.
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { Badge } from '@/components/ui/badge'
import { ordersApiServer } from '@/features/orders/api.server'
import { orderStatus } from '@/features/orders/status'
import { isApiError } from '@/lib/errors'
import { formatDateTime } from '@/lib/format/date'
import { formatMoney } from '@/lib/format/money'

export default async function OrderPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const order = await ordersApiServer.detail(id).catch((error: unknown) => {
    if (isApiError(error) && error.status === 404) notFound()
    throw error
  })
  const status = orderStatus[order.status]

  return (
    <main className="mx-auto max-w-2xl space-y-6 p-6">
      <Link href="/orders" className="text-sm text-muted-foreground hover:underline">
        ← Orders
      </Link>
      <div className="flex items-center gap-3">
        <h1 className="text-2xl font-semibold">{order.id}</h1>
        <Badge variant={status.badge}>{status.label}</Badge>
      </div>
      <dl className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-sm">
        <dt className="text-muted-foreground">Customer</dt>
        <dd>{order.customer_name}</dd>
        <dt className="text-muted-foreground">Total</dt>
        <dd className="tabular-nums">{formatMoney(order.total, order.currency)}</dd>
        <dt className="text-muted-foreground">Created</dt>
        <dd>{formatDateTime(order.created_at)}</dd>
      </dl>
    </main>
  )
}
