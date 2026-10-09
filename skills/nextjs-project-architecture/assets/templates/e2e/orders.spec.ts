import { expect, test } from '@playwright/test'
import { signIn, uniqueName } from './helpers'

test.beforeEach(async ({ page }) => {
  await signIn(page)
})

test('creates an order, opens it, and finds it in the list', async ({ page }) => {
  const customer = uniqueName('Playwright')
  await page.goto('/orders/new')
  await page.getByLabel('Customer name').fill(customer)
  await page.getByRole('combobox', { name: 'Currency' }).click()
  await page.getByRole('option', { name: /USD/ }).click()
  await page.getByLabel('Amount').fill('1,099.95')
  await page.getByRole('button', { name: 'Create order' }).click()

  await expect(page).toHaveURL(/\/orders\/ORD-\d+$/)
  await expect(page.getByText(customer)).toBeVisible()
  await expect(page.getByText(/1,099\.95/)).toBeVisible()

  await page.getByRole('link', { name: '← Orders' }).click()
  await page.getByRole('searchbox').fill(customer)
  await expect(page).toHaveURL(/search=/)
  await expect(page.getByRole('row')).toHaveCount(2) // header + the new order
})

test('shows the API validation error on the form field', async ({ page }) => {
  await page.goto('/orders/new')
  await page.getByLabel('Customer name').fill('error') // the mock API rejects this name with a 422
  await page.getByLabel('Amount').fill('10')
  await page.getByRole('button', { name: 'Create order' }).click()

  await expect(page.getByLabel('Customer name')).toHaveAttribute('aria-invalid', 'true')
  await expect(page.getByText('Customer is blocked')).toBeVisible()
  await expect(page).toHaveURL('/orders/new')
})
