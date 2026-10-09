// Component test: URL state (nuqs) -> query hook -> DataTable, against the MSW orders mock (57 orders).
import { screen, waitFor, within } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'
import { server, TEST_ORIGIN } from '@/test/msw-server'
import { renderWithProviders } from '@/test/render'
import { OrdersTable } from './orders-table'

const firstOrderId = () => within(screen.getAllByRole('row')[1]!).getAllByRole('link')[0]!.textContent

describe('OrdersTable', () => {
  it('loads the first page sorted by newest', async () => {
    renderWithProviders(<OrdersTable />)

    expect(await screen.findByRole('link', { name: 'ORD-1056' })).toBeInTheDocument()
    expect(firstOrderId()).toBe('ORD-1056')
    expect(screen.getByText(/1–20 of 57/)).toBeInTheDocument()
  })

  it('reads page, size, and sort from the URL', async () => {
    renderWithProviders(<OrdersTable />, { searchParams: '?page=2&pageSize=10&sort=total:asc' })

    await screen.findByRole('link', { name: 'ORD-1010' })
    expect(firstOrderId()).toBe('ORD-1010')
    expect(screen.getByText(/11–20 of 57/)).toBeInTheDocument()
    expect(screen.getByText('Page 2 of 6')).toBeInTheDocument()
  })

  it('writes the next page to the URL', async () => {
    const { user, lastUrl } = renderWithProviders(<OrdersTable />)
    await screen.findByRole('link', { name: 'ORD-1056' })

    await user.click(screen.getByRole('button', { name: /next page/i }))

    await waitFor(() => expect(lastUrl()).toContain('page=2'))
    expect(await screen.findByText('Page 2 of 3')).toBeInTheDocument()
  })

  it('debounces search, resets to page 1, and shows the no-results state', async () => {
    const { user, lastUrl } = renderWithProviders(<OrdersTable />, { searchParams: '?page=3' })
    await screen.findByText('Page 3 of 3')

    await user.type(screen.getByRole('searchbox'), 'zzz')

    expect(await screen.findByText('No orders match your search.')).toBeInTheDocument()
    expect(lastUrl()).toBe('?search=zzz') // page reset (default values are cleared from the URL)
  })

  it('sorts when a sortable header is clicked', async () => {
    const { user, lastUrl } = renderWithProviders(<OrdersTable />)
    await screen.findByRole('link', { name: 'ORD-1056' })

    await user.click(screen.getByRole('button', { name: /total/i }))

    await waitFor(() => expect(lastUrl()).toMatch(/sort=total/))
    expect(screen.queryByRole('button', { name: /^status/i })).not.toBeInTheDocument() // not sortable: plain text header
  })

  it('shows the error state and recovers on retry', async () => {
    server.use(http.get(`${TEST_ORIGIN}/api/orders`, () => HttpResponse.json({ detail: 'down' }, { status: 503 }), { once: true }))
    const { user } = renderWithProviders(<OrdersTable />)

    await user.click(await screen.findByRole('button', { name: /try again/i }))

    expect(await screen.findByRole('link', { name: 'ORD-1056' })).toBeInTheDocument()
  })
})
