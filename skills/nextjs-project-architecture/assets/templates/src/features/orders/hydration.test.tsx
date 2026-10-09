// The full cycle in one place: server prefetch -> dehydrate -> send as JSON -> hydrate in the browser.
import { dehydrate, HydrationBoundary } from '@tanstack/react-query'
import { screen } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import { makeQueryClient } from '@/lib/query-client'
import { server, TEST_ORIGIN } from '@/test/msw-server'
import { renderWithProviders } from '@/test/render'
import { OrdersTable } from './components/orders-table'
import { ordersKeys } from './keys'
import { loadOrdersSearchParams } from './search-params'
import type { Order, Page } from './types'

const serverPage: Page<Order> = {
  items: [{ id: 'SRV-1', customer_name: 'From the server', status: 'paid', total: '10.00', currency: 'PHP', created_at: '2026-10-01T00:00:00Z' }],
  total: 200, // enough pages that ?page=2 is valid (out-of-range pages are clamped and refetched)
  page: 1,
  page_size: 20,
}

/** What page.tsx does, then a JSON round trip like the real HTML payload. */
async function prefetchOnServer(url: string) {
  const client = makeQueryClient()
  const params = loadOrdersSearchParams(new URLSearchParams(url))
  await client.prefetchQuery({ queryKey: ordersKeys.list(params), queryFn: () => serverPage })
  return JSON.parse(JSON.stringify(dehydrate(client)))
}

/** Counts browser requests to the list endpoint. */
function countBrowserFetches() {
  const calls: string[] = []
  server.use(
    http.get(`${TEST_ORIGIN}/api/orders`, ({ request }) => {
      calls.push(request.url)
      return HttpResponse.json({ ...serverPage, items: [] })
    }),
  )
  return calls
}

const settle = () => new Promise((r) => setTimeout(r, 100))

describe('prefetch -> dehydrate -> hydrate', () => {
  it('shows server data on the first render, with no loading state and no browser fetch', async () => {
    const state = await prefetchOnServer('')
    const calls = countBrowserFetches()

    renderWithProviders(
      <HydrationBoundary state={state}>
        <OrdersTable />
      </HydrationBoundary>,
    )

    expect(screen.getByRole('link', { name: 'SRV-1' })).toBeInTheDocument() // getBy, not findBy: already there
    await settle()
    expect(calls).toHaveLength(0)
  })

  it('works with URL params: server and browser build the same query key', async () => {
    const url = '?page=2&pageSize=50&sort=total:asc&search=ana'
    const state = await prefetchOnServer(url)
    const calls = countBrowserFetches()

    renderWithProviders(
      <HydrationBoundary state={state}>
        <OrdersTable />
      </HydrationBoundary>,
      { searchParams: url },
    )

    expect(screen.getByRole('link', { name: 'SRV-1' })).toBeInTheDocument()
    await settle()
    expect(calls).toHaveLength(0)
  })

  it('falls back to a browser fetch when the keys do not match (the prefetch is wasted)', async () => {
    const state = await prefetchOnServer('?page=1')
    const calls = countBrowserFetches()

    renderWithProviders(
      <HydrationBoundary state={state}>
        <OrdersTable />
      </HydrationBoundary>,
      { searchParams: '?page=2' },
    )

    expect(screen.queryByRole('link', { name: 'SRV-1' })).not.toBeInTheDocument()
    await settle()
    expect(calls).toHaveLength(1)
  })
})
