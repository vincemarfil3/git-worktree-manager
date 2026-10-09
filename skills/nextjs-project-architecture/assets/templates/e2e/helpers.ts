import { expect, type Page } from '@playwright/test'

// The mock API accepts any email with the password "password".
export async function signIn(page: Page, { from = '/orders' } = {}) {
  await page.goto(`/login?from=${encodeURIComponent(from)}`)
  await page.getByLabel('Email').fill('qa@example.com')
  await page.getByLabel('Password').fill('password')
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page).toHaveURL(from)
}

/** Unique per run, so reruns against a still-running mock server do not collide. */
export const uniqueName = (prefix: string) => `${prefix} ${Date.now()}`

export async function createOrder(page: Page, customer: string, amount = '5') {
  await page.goto('/orders/new')
  await page.getByLabel('Customer name').fill(customer)
  await page.getByLabel('Amount').fill(amount)
  await page.getByRole('button', { name: 'Create order' }).click()
  await expect(page).toHaveURL(/\/orders\/ORD-\d+$/)
}
