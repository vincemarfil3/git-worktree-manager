import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ThemeProvider } from 'next-themes'
import { beforeEach, describe, expect, it } from 'vitest'
import { ThemeToggle } from './theme-toggle'

function renderToggle() {
  render(
    <ThemeProvider attribute="class" defaultTheme="system" enableSystem>
      <ThemeToggle />
    </ThemeProvider>,
  )
  return userEvent.setup()
}

async function choose(user: ReturnType<typeof userEvent.setup>, name: string) {
  await user.click(screen.getByRole('button', { name: 'Change theme' }))
  await user.click(await screen.findByRole('menuitemradio', { name }))
}

describe('ThemeToggle', () => {
  beforeEach(() => {
    localStorage.clear()
    document.documentElement.className = ''
  })

  it('switches to dark and remembers the choice', async () => {
    const user = renderToggle()
    await choose(user, 'Dark')

    expect(document.documentElement).toHaveClass('dark')
    expect(localStorage.getItem('theme')).toBe('dark')
  })

  it('switches back to light', async () => {
    const user = renderToggle()
    await choose(user, 'Dark')
    await choose(user, 'Light')

    expect(document.documentElement).not.toHaveClass('dark')
    expect(localStorage.getItem('theme')).toBe('light')
  })

  it('marks the saved choice in the menu', async () => {
    localStorage.setItem('theme', 'dark')
    const user = renderToggle()
    await user.click(screen.getByRole('button', { name: 'Change theme' }))

    expect(await screen.findByRole('menuitemradio', { name: 'Dark' })).toHaveAttribute('aria-checked', 'true')
    expect(screen.getByRole('menuitemradio', { name: 'Light' })).toHaveAttribute('aria-checked', 'false')
  })
})
