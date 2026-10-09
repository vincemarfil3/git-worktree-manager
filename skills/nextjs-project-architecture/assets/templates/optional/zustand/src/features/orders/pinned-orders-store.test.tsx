import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { PinOrderButton } from './components/pin-order-button'
import { PinnedCount } from './components/pinned-count'
import { PinnedOrdersProvider } from './pinned-orders-store'

const app = (testId: string, pinned: string[] = []) => (
  <div data-testid={testId}>
    <PinnedOrdersProvider initialState={{ pinned }}>
      <PinOrderButton id="ORD-1" />
      <PinnedCount />
    </PinnedOrdersProvider>
  </div>
)

describe('pinned orders store', () => {
  it('updates every component that reads it', async () => {
    const user = userEvent.setup()
    render(app('a'))

    await user.click(screen.getByRole('button', { name: 'Pin ORD-1' }))
    expect(screen.getByText('1 pinned')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Unpin ORD-1' })).toHaveAttribute('aria-pressed', 'true')

    await user.click(screen.getByRole('button', { name: 'Unpin ORD-1' }))
    expect(screen.queryByText(/pinned/)).not.toBeInTheDocument()
  })

  it('starts from the initial state given to the Provider', () => {
    render(app('a', ['ORD-1', 'ORD-2']))
    expect(screen.getByText('2 pinned')).toBeInTheDocument()
  })

  it('gives each Provider its own store (no state shared between requests or users)', async () => {
    const user = userEvent.setup()
    render(
      <>
        {app('first')}
        {app('second')}
      </>,
    )
    const [first, second] = [screen.getByTestId('first'), screen.getByTestId('second')]

    await user.click(first.querySelector('button')!)
    expect(first).toHaveTextContent('1 pinned')
    expect(second).not.toHaveTextContent('pinned')
  })

  it('fails loudly when the Provider is missing', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(() => render(<PinnedCount />)).toThrow('usePinnedOrders is missing its Provider')
  })
})
