'use client'
import { createStore } from 'zustand/vanilla'
import { createStoreContext } from '@/lib/create-store-context'

// Client-only state shared across pages: which orders the user pinned.
// Stores IDs only. Order data still comes from TanStack Query.
type PinnedOrdersState = {
  pinned: string[]
  toggle: (id: string) => void
  clear: () => void
}

export const createPinnedOrdersStore = (init: { pinned: string[] }) =>
  createStore<PinnedOrdersState>()((set) => ({
    pinned: init.pinned,
    toggle: (id) => set((s) => ({ pinned: s.pinned.includes(id) ? s.pinned.filter((p) => p !== id) : [...s.pinned, id] })),
    clear: () => set({ pinned: [] }),
  }))

export const [PinnedOrdersProvider, usePinnedOrders] = createStoreContext(createPinnedOrdersStore, 'usePinnedOrders')
