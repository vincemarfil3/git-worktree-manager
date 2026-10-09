import { expect, test } from '@playwright/test'
import { signIn } from './helpers'

test('pinned orders stay shared across pages until reload', async ({ page }) => {
  await signIn(page, { from: '/orders/ORD-1001' })
  await page.getByRole('button', { name: 'Pin ORD-1001' }).click()
  await expect(page.getByRole('banner').getByText('1 pinned')).toBeVisible()

  await page.getByRole('link', { name: '← Orders' }).click() // client-side navigation keeps the store
  await expect(page.getByRole('banner').getByText('1 pinned')).toBeVisible()

  await page.reload() // in-memory only: a reload starts fresh (add persist if it should survive)
  await expect(page.getByRole('banner').getByText(/pinned/)).toBeHidden()
})
