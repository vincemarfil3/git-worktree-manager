import { defaultShouldDehydrateQuery, dehydrate } from '@tanstack/react-query'
import { describe, expect, it, vi } from 'vitest'
import { getQueryClient, makeQueryClient } from './query-client'

describe('query client settings that make hydration work', () => {
  it('has a staleTime above 0, so the browser does not refetch right after hydration', () => {
    const staleTime = makeQueryClient().getDefaultOptions().queries?.staleTime
    expect(staleTime).toBeGreaterThan(0)
  })

  it('dehydrates pending queries too, so un-awaited prefetches can stream', () => {
    const client = makeQueryClient()
    void client.prefetchQuery({ queryKey: ['slow'], queryFn: () => new Promise(() => {}) })

    const state = dehydrate(client)
    expect(state.queries.map((q) => q.state.status)).toEqual(['pending'])
    expect(defaultShouldDehydrateQuery(client.getQueryCache().getAll()[0]!)).toBe(false) // TanStack's default would drop it
  })

  it('reuses one client in the browser', () => {
    expect(getQueryClient()).toBe(getQueryClient())
  })
})

describe('on the server', () => {
  it('creates a new client per request, never a shared one (no data leaking between users)', async () => {
    vi.resetModules()
    vi.doMock('@tanstack/react-query', async (original) => ({ ...(await original<object>()), isServer: true }))
    const { getQueryClient: getServerClient } = await import('./query-client')

    expect(getServerClient()).not.toBe(getServerClient())
    vi.doUnmock('@tanstack/react-query')
  })
})
