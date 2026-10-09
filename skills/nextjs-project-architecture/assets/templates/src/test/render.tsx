// Render a component with the app's providers: a FRESH QueryClient per test (no cache leaking between tests)
// and an in-memory URL for nuqs. Returns userEvent and the URL update spy.
import { QueryClientProvider } from '@tanstack/react-query'
import { render, type RenderOptions } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { NuqsTestingAdapter, type OnUrlUpdateFunction } from 'nuqs/adapters/testing'
import { vi } from 'vitest'
import { makeQueryClient } from '@/lib/query-client'

type Options = Omit<RenderOptions, 'wrapper'> & {
  /** Initial URL query, e.g. '?page=2&sort=total:asc' */
  searchParams?: string
}

export function renderWithProviders(ui: React.ReactElement, { searchParams = '', ...options }: Options = {}) {
  // The app's real settings (staleTime etc.), only without retries so errors show immediately
  const queryClient = makeQueryClient()
  const defaults = queryClient.getDefaultOptions()
  queryClient.setDefaultOptions({ ...defaults, queries: { ...defaults.queries, retry: false }, mutations: { retry: false } })
  const onUrlUpdate = vi.fn<OnUrlUpdateFunction>()

  const Wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={queryClient}>
      <NuqsTestingAdapter searchParams={searchParams} onUrlUpdate={onUrlUpdate} hasMemory>
        {children}
      </NuqsTestingAdapter>
    </QueryClientProvider>
  )

  return {
    user: userEvent.setup(),
    queryClient,
    /** Last URL query string the component wrote, e.g. '?page=2&sort=total:asc' */
    lastUrl: () => onUrlUpdate.mock.lastCall?.[0].queryString ?? '',
    onUrlUpdate,
    ...render(ui, { wrapper: Wrapper, ...options }),
  }
}
