'use client'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { useSignOut } from '../mutations'

export function SignOutButton() {
  const router = useRouter()
  const signOut = useSignOut()

  return (
    <Button variant="ghost" size="sm" disabled={signOut.isPending} onClick={() => signOut.mutate(undefined, { onSettled: () => router.replace('/login') })}>
      Sign out
    </Button>
  )
}
