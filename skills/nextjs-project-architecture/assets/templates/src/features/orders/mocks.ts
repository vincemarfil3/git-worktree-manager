// Standard. MSW handlers for the orders API. Used in two places:
//   - component tests: createOrdersHandlers('/api')            (browser calls /api/*)
//   - dev before the API exists: createOrdersHandlers(BACKEND_URL) via src/mocks/node.ts
// Responses follow the API contract (Page envelope, snake_case, 422 field errors) so swapping to the real API changes nothing.
import { http, HttpResponse } from 'msw'
import type { CreateOrderRequest, Order, Page } from './types'

const seed: Order[] = Array.from({ length: 57 }, (_, i) => ({
  id: `ORD-${String(1000 + i)}`,
  customer_name: ['Ana Cruz', 'Ben Reyes', 'Carla Santos', 'Dan Lim'][i % 4] ?? 'Guest',
  status: (['paid', 'pending', 'failed', 'refunded'] as const)[i % 4] ?? 'paid',
  total: (((i * 7919) % 500000) / 100 + 10).toFixed(2),
  currency: 'PHP',
  created_at: new Date(Date.UTC(2026, 8, 1) + i * 3_600_000 * 7).toISOString(),
}))

export function createOrdersHandlers(base: string) {
  let orders = [...seed]

  return [
    http.get(`${base}/orders`, ({ request }) => {
      const url = new URL(request.url)
      const page = Number(url.searchParams.get('page') ?? 1)
      const pageSize = Number(url.searchParams.get('page_size') ?? 20)
      const [sortBy = 'created_at', dir = 'desc'] = (url.searchParams.get('sort') ?? 'created_at:desc').split(':')
      const search = (url.searchParams.get('search') ?? '').toLowerCase()

      const filtered = orders
        .filter((o) => !search || o.customer_name.toLowerCase().includes(search) || o.id.toLowerCase().includes(search))
        .sort((a, b) => {
          const av = a[sortBy as keyof Order]
          const bv = b[sortBy as keyof Order]
          const cmp = sortBy === 'total' ? Number(av) - Number(bv) : String(av).localeCompare(String(bv))
          return dir === 'desc' ? -cmp : cmp
        })

      const body: Page<Order> = {
        items: filtered.slice((page - 1) * pageSize, page * pageSize),
        total: filtered.length,
        page,
        page_size: pageSize,
      }
      return HttpResponse.json(body)
    }),

    http.get(`${base}/orders/:id`, ({ params }) => {
      const order = orders.find((o) => o.id === params.id)
      return order ? HttpResponse.json(order) : HttpResponse.json({ detail: 'Order not found' }, { status: 404 })
    }),

    http.post(`${base}/orders`, async ({ request }) => {
      const body = (await request.json()) as CreateOrderRequest
      // FastAPI-style 422, to exercise server error mapping in the form
      if (body.customer_name.toLowerCase() === 'error') {
        return HttpResponse.json(
          { detail: [{ loc: ['body', 'customer_name'], msg: 'Customer is blocked', type: 'value_error' }] },
          { status: 422 },
        )
      }
      const order: Order = {
        id: `ORD-${Date.now()}`,
        customer_name: body.customer_name,
        status: 'pending',
        total: body.amount,
        currency: body.currency,
        created_at: new Date().toISOString(),
      }
      orders = [order, ...orders]
      return HttpResponse.json(order, { status: 201 })
    }),

    http.delete(`${base}/orders/:id`, ({ params }) => {
      orders = orders.filter((o) => o.id !== params.id)
      return new HttpResponse(null, { status: 204 })
    }),
  ]
}
