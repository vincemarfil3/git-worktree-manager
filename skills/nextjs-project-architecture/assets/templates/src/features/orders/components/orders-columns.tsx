'use client'
// Standard. Column definitions for the orders table (TanStack Table v9 column helper).
// String headers get sort UI automatically; set enableSorting: false where the backend cannot sort.
import Link from 'next/link'
import { createColumnHelper } from '@tanstack/react-table'
import { Badge } from '@/components/ui/badge'
import { RowActions, type DataTableFeatures } from '@/components/shared/table'
import { formatDateTime } from '@/lib/format/date'
import { formatMoney } from '@/lib/format/money'
import { orderStatus } from '../status'
import type { Order } from '../types'

const helper = createColumnHelper<DataTableFeatures, Order>()

export function getOrdersColumns({ onDelete }: { onDelete: (id: string) => Promise<unknown> }) {
  return helper.columns([
    helper.accessor('id', {
      header: 'Order',
      enableSorting: false,
      // Real link: keyboard and middle-click work (not only row click)
      cell: (ctx) => (
        <Link href={`/orders/${ctx.getValue()}`} className="font-medium underline-offset-4 hover:underline">
          {ctx.getValue()}
        </Link>
      ),
    }),
    helper.accessor('customer_name', { header: 'Customer', meta: { label: 'Customer' } }),
    helper.accessor('status', {
      header: 'Status',
      enableSorting: false,
      cell: (ctx) => {
        const s = orderStatus[ctx.getValue()]
        const Icon = s.icon
        return (
          <Badge variant={s.badge}>
            <Icon className="size-3" aria-hidden="true" />
            {s.label}
          </Badge>
        )
      },
    }),
    helper.accessor('total', {
      header: 'Total',
      meta: { align: 'end' },
      cell: (ctx) => formatMoney(ctx.getValue(), ctx.row.original.currency),
    }),
    helper.accessor('created_at', {
      header: 'Created',
      cell: (ctx) => <time dateTime={ctx.getValue()}>{formatDateTime(ctx.getValue())}</time>,
    }),
    helper.display({
      id: 'actions',
      header: () => <span className="sr-only">Actions</span>,
      meta: { width: 'w-12' },
      cell: (ctx) => (
        <RowActions
          actions={[
            {
              label: 'Delete',
              destructive: true,
              confirm: { title: `Delete order ${ctx.row.original.id}?` },
              onSelect: () => onDelete(ctx.row.original.id),
            },
          ]}
        />
      ),
    }),
  ])
}
