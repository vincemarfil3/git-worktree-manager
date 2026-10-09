// Component test: real form, real mutation hook, real axios client; only the network is faked (MSW).
import { screen, waitFor } from '@testing-library/react'
import { delay, http, HttpResponse } from 'msw'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { server, TEST_ORIGIN } from '@/test/msw-server'
import { renderWithProviders } from '@/test/render'
import { CreateOrderForm } from './create-order-form'

const push = vi.hoisted(() => vi.fn())
vi.mock('next/navigation', () => ({ useRouter: () => ({ push }) }))

const ORDERS_URL = `${TEST_ORIGIN}/api/orders`
const customerInput = () => screen.getByLabelText(/customer name/i)
const amountInput = () => screen.getByLabelText(/^amount/i)
const submitButton = () => screen.getByRole('button', { name: /create order/i })

describe('CreateOrderForm', () => {
  beforeEach(() => push.mockReset())

  it('shows validation errors and focuses the first invalid field without calling the API', async () => {
    let called = false
    server.use(http.post(ORDERS_URL, () => ((called = true), HttpResponse.json({}))))
    const { user } = renderWithProviders(<CreateOrderForm />)

    await user.click(submitButton())

    expect(await screen.findByText('Enter the customer name')).toBeInTheDocument()
    expect(customerInput()).toHaveAttribute('aria-invalid', 'true')
    expect(customerInput()).toHaveAccessibleDescription('Enter the customer name')
    expect(customerInput()).toHaveFocus()
    expect(called).toBe(false)
  })

  it('sends the mapped API payload and navigates to the new order', async () => {
    let body: unknown
    server.use(
      http.post(ORDERS_URL, async ({ request }) => {
        body = await request.json()
        return HttpResponse.json({ id: 'ORD-9', customer_name: 'Ana', status: 'pending', total: '1250.50', currency: 'PHP', created_at: '2026-10-08T00:00:00Z' }, { status: 201 })
      }),
    )
    const { user } = renderWithProviders(<CreateOrderForm />)

    await user.type(customerInput(), 'Ana')
    await user.type(amountInput(), '1,250.50')
    await user.click(submitButton())

    await waitFor(() => expect(push).toHaveBeenCalledWith('/orders/ORD-9'))
    // Form shape (customerName, "1,250.50") -> API shape (customer_name, "1250.50"); blank note is omitted
    expect(body).toEqual({ customer_name: 'Ana', currency: 'PHP', amount: '1250.50', send_receipt: true })
  })

  it('puts a 422 from the API on the right field (customer_name -> customerName)', async () => {
    const { user } = renderWithProviders(<CreateOrderForm />)

    await user.type(customerInput(), 'error') // the default mock answers 422 for this name
    await user.type(amountInput(), '10')
    await user.click(submitButton())

    expect(await screen.findByText('Customer is blocked')).toBeInTheDocument()
    expect(customerInput()).toHaveAttribute('aria-invalid', 'true')
    expect(customerInput()).toHaveFocus()
    expect(push).not.toHaveBeenCalled()
  })

  it('shows a generic form error for 5xx without leaking details', async () => {
    server.use(http.post(ORDERS_URL, () => HttpResponse.json({ detail: 'Traceback: db exploded' }, { status: 500 })))
    const { user } = renderWithProviders(<CreateOrderForm />)

    await user.type(customerInput(), 'Ana')
    await user.type(amountInput(), '10')
    await user.click(submitButton())

    expect(await screen.findByRole('alert')).toHaveTextContent('Something went wrong. Please try again.')
    expect(screen.queryByText(/traceback/i)).not.toBeInTheDocument()
  })

  it('disables submit while the request is in flight (no double orders)', async () => {
    server.use(
      http.post(ORDERS_URL, async () => {
        await delay(200)
        return HttpResponse.json({ id: 'ORD-10', customer_name: 'Ana', status: 'pending', total: '10', currency: 'PHP', created_at: '2026-10-08T00:00:00Z' }, { status: 201 })
      }),
    )
    const { user } = renderWithProviders(<CreateOrderForm />)

    await user.type(customerInput(), 'Ana')
    await user.type(amountInput(), '10')
    await user.click(submitButton())

    const pending = await screen.findByRole('button', { name: /creating/i })
    expect(pending).toBeDisabled()
    await waitFor(() => expect(push).toHaveBeenCalledTimes(1))
  })
})
