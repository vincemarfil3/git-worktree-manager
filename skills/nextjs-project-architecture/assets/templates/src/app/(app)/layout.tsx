import Link from 'next/link'
import { ThemeToggle } from '@/components/shared/theme-toggle'
import { SignOutButton } from '@/features/auth'

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <header className="flex items-center justify-between border-b px-6 py-3">
        <nav className="flex gap-4 text-sm font-medium">
          <Link href="/orders">Orders</Link>
        </nav>
        <div className="flex items-center gap-1">
          <ThemeToggle />
          <SignOutButton />
        </div>
      </header>
      {children}
    </>
  )
}
