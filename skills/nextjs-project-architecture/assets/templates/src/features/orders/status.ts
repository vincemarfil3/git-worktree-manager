// Standard. Per-feature status map (lives in the feature so lib/ never imports features/). One map: status -> label, badge variant, icon. Used by table cells, detail pages, and filters.
// Keyed by the status union type: a new backend status is a compile error until it is mapped here.
import { CheckCircle2, Clock, RotateCcw, XCircle, type LucideIcon } from 'lucide-react'
import type { OrderStatus } from './types'

type StatusDisplay = { label: string; badge: 'default' | 'secondary' | 'destructive' | 'outline'; icon: LucideIcon }

export const orderStatus: Record<OrderStatus, StatusDisplay> = {
  paid: { label: 'Paid', badge: 'default', icon: CheckCircle2 },
  pending: { label: 'Pending', badge: 'secondary', icon: Clock },
  failed: { label: 'Failed', badge: 'destructive', icon: XCircle },
  refunded: { label: 'Refunded', badge: 'outline', icon: RotateCcw },
}

export const orderStatusOptions = Object.entries(orderStatus).map(([value, s]) => ({ value, label: s.label }))
