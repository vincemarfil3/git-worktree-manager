import { expect, test } from '@playwright/test'
import { signIn } from './helpers'

test('follows the device setting by default', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'dark' })
  await page.goto('/login')
  await expect(page.locator('html')).toHaveClass(/dark/)
})

test('keeps a manual choice after reload, with no flash of the wrong theme', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'light' })
  await signIn(page)

  await page.getByRole('button', { name: 'Change theme' }).click()
  await page.getByRole('menuitemradio', { name: 'Dark' }).click()
  await expect(page.locator('html')).toHaveClass(/dark/)

  // Block the app's JavaScript: if the page is still dark, the theme is applied before React loads (no flash)
  await page.route('**/_next/static/chunks/**', (route) => route.abort())
  await page.reload()
  await expect(page.locator('html')).toHaveClass(/dark/)
})
