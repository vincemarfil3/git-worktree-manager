// Standard. URL params for the orders list. Pure module: used by page.tsx (createLoader) and the table leaf.
import { createLoader } from 'nuqs/server'
import { createTableSearchParams } from '@/components/shared/table/table-search-params'

export const ordersSearchParams = createTableSearchParams({
  sortable: ['created_at', 'total', 'customer_name'], // only what the backend can sort
  defaultSort: 'created_at:desc',
})

export const loadOrdersSearchParams = createLoader(ordersSearchParams)
