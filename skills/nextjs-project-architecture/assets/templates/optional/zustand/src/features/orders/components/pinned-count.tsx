'use client'
import { usePinnedOrders } from '../pinned-orders-store'

export function PinnedCount() {
  const count = usePinnedOrders((s) => s.pinned.length)
  if (count === 0) return null
  return <span className="text-sm text-muted-foreground">{count} pinned</span>
}
