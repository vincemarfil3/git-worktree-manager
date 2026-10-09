import { SignInForm, safeRedirect } from '@/features/auth'

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ from?: string | string[] }> }) {
  const { from } = await searchParams

  return (
    <main className="mx-auto max-w-sm space-y-6 p-6 pt-24">
      <h1 className="text-2xl font-semibold">Sign in</h1>
      <SignInForm redirectTo={safeRedirect(from)} />
    </main>
  )
}
