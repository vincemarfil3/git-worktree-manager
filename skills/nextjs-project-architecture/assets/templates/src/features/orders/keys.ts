// Starter. THE query keys for this feature. Never write queryKey: [...] inline anywhere else (lint rule).
// Pure module (no hooks, no axios): page.tsx (server) and queries.ts (client) both import it.
//
// Key tree (invalidateQueries matches by PREFIX, so a parent invalidates everything under it):
//
//   ['orders']                              ordersKeys.all          -> everything about orders
//   ['orders', 'list']                      ordersKeys.lists()      -> every list page/sort/search
//   ['orders', 'list', { page, ... }]       ordersKeys.list(params) -> one specific page
//   ['orders', 'detail']                    ordersKeys.details()    -> every detail
//   ['orders', 'detail', id]                ordersKeys.detail(id)   -> one order
//
// Which to invalidate:
//   create order        -> ordersKeys.lists()
//   update order id     -> ordersKeys.detail(id) + ordersKeys.lists()
//   delete order id     -> ordersKeys.lists() (and removeQueries(ordersKeys.detail(id)))
//   not sure / bulk     -> ordersKeys.all
export type OrdersListParams = { page: number; pageSize: number; sort: string; search: string }

export const ordersKeys = {
  all: ['orders'] as const,
  lists: () => [...ordersKeys.all, 'list'] as const,
  list: (params: OrdersListParams) => [...ordersKeys.lists(), params] as const,
  details: () => [...ordersKeys.all, 'detail'] as const,
  detail: (id: string) => [...ordersKeys.details(), id] as const,
}
