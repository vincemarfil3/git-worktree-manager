import { expect, test, type Page } from '@playwright/test'
import { createOrder, signIn, uniqueName } from './helpers'

test.beforeEach(async ({ page }) => {
  await signIn(page)
})

/** Records every browser request to the orders API. */
function trackOrderFetches(page: Page) {
  const calls: string[] = []
  page.on('request', (r) => r.url().includes('/api/orders') && calls.push(r.url()))
  return calls
}

test('the list is in the server HTML and the browser does not fetch it again', async ({ page }) => {
  const calls = trackOrderFetches(page)

  const response = await page.goto('/orders')
  expect(await response!.text()).toContain('ORD-1056') // prefetched on the server
  await expect(page.getByRole('link', { name: 'ORD-1056' })).toBeVisible()
  await page.waitForLoadState('networkidle')
  expect(calls).toHaveLength(0) // hydrated from the HTML, no refetch
})

test('URL params prefetch exactly the page the browser shows', async ({ page }) => {
  const calls = trackOrderFetches(page)

  const response = await page.goto('/orders?page=2&pageSize=10&sort=total:asc')
  expect(await response!.text()).toContain('ORD-1010')
  await expect(page.getByText('Page 2 of 6')).toBeVisible()
  await page.waitForLoadState('networkidle')
  expect(calls).toHaveLength(0) // same query key on server and browser
})

test('rows render even before JavaScript loads', async ({ page }) => {
  await page.route('**/_next/static/chunks/**', (route) => route.abort())
  await page.goto('/orders')
  await expect(page.getByRole('link', { name: 'ORD-1056' })).toBeVisible()
})

test('after hydration the browser takes over: new pages are fetched client-side', async ({ page }) => {
  const calls = trackOrderFetches(page)
  await page.goto('/orders')
  await page.waitForLoadState('networkidle')

  await page.getByRole('button', { name: 'Next page' }).click()
  await expect(page.getByText('Page 2 of 3')).toBeVisible()
  expect(calls).toHaveLength(1)

  await page.getByRole('button', { name: 'Previous page' }).click()
  await expect(page.getByText('Page 1 of 3')).toBeVisible()
  expect(calls).toHaveLength(1) // page 1 still fresh in the cache: no second fetch
})

test('a mutation on the same page refreshes the cached list (invalidation)', async ({ page }) => {
  const customer = uniqueName('Delete Me')
  await createOrder(page, customer)
  await page.goto(`/orders?search=${encodeURIComponent(customer)}`)
  const row = page.getByRole('row', { name: new RegExp(customer) })
  await expect(row).toBeVisible()

  await row.getByRole('button', { name: 'Row actions' }).click()
  await page.getByRole('menuitem', { name: 'Delete' }).click()
  await page.getByRole('alertdialog').getByRole('button', { name: 'Delete' }).click()

  // No navigation happened, so only invalidateQueries can remove the row
  await expect(row).toBeHidden()
  await expect(page.getByText('No orders match your search.')).toBeVisible()
})
