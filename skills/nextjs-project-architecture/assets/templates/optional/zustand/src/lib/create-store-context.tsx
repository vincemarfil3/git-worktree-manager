'use client'
import { createContext, useContext, useState } from 'react'
import { useStore, type StoreApi } from 'zustand'

/**
 * Makes a Zustand store safe for Next.js: one store per <Provider>, never one shared module-level store.
 * On the server each request renders its own Provider, so users never see each other's state.
 */
export function createStoreContext<TState, TInit>(createStore: (init: TInit) => StoreApi<TState>, name: string) {
  const StoreContext = createContext<StoreApi<TState> | null>(null)

  function Provider({ initialState, children }: { initialState: TInit; children: React.ReactNode }) {
    const [store] = useState(() => createStore(initialState))
    return <StoreContext value={store}>{children}</StoreContext>
  }

  function useSelector<T>(selector: (state: TState) => T): T {
    const store = useContext(StoreContext)
    if (!store) throw new Error(`${name} is missing its Provider`)
    return useStore(store, selector)
  }

  return [Provider, useSelector] as const
}
