'use client'
import { Pin, PinOff } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { usePinnedOrders } from '../pinned-orders-store'

export function PinOrderButton({ id }: { id: string }) {
  const isPinned = usePinnedOrders((s) => s.pinned.includes(id))
  const toggle = usePinnedOrders((s) => s.toggle)

  return (
    <Button variant="ghost" size="icon" aria-pressed={isPinned} aria-label={isPinned ? `Unpin ${id}` : `Pin ${id}`} onClick={() => toggle(id)}>
      {isPinned ? <PinOff className="size-4" aria-hidden="true" /> : <Pin className="size-4" aria-hidden="true" />}
    </Button>
  )
}
