import { expect, test } from '@playwright/test'
import { signIn } from './helpers'

test('sends signed-out users to sign in, then back to where they were going', async ({ page }) => {
  await page.goto('/orders?page=2')
  await expect(page).toHaveURL('/login?from=%2Forders%3Fpage%3D2')

  await page.getByLabel('Email').fill('qa@example.com')
  await page.getByLabel('Password').fill('password')
  await page.getByRole('button', { name: 'Sign in' }).click()

  await expect(page).toHaveURL('/orders?page=2')
  await expect(page.getByText('Page 2 of 3')).toBeVisible()
})

test('keeps tokens out of JavaScript (httpOnly cookies)', async ({ page, context }) => {
  await signIn(page)

  const cookies = await context.cookies()
  expect(cookies.filter((c) => c.name.includes('token'))).toHaveLength(2)
  expect(cookies.every((c) => !c.name.includes('token') || c.httpOnly)).toBe(true)
  expect(await page.evaluate(() => document.cookie)).not.toContain('token')
})

test('shows an error for a wrong password', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Email').fill('qa@example.com')
  await page.getByLabel('Password').fill('wrong')
  await page.getByRole('button', { name: 'Sign in' }).click()

  await expect(page.getByText('Invalid email or password')).toBeVisible()
  await expect(page).toHaveURL('/login')
})

test('signs out and blocks protected pages again', async ({ page }) => {
  await signIn(page)
  await page.getByRole('button', { name: 'Sign out' }).click()
  await expect(page).toHaveURL('/login')

  await page.goto('/orders')
  await expect(page).toHaveURL(/\/login\?from=/)
})
