// Starter (Mode A). Browser HTTP client: same-origin /api only. No Authorization header, no refresh queue.
// (Optional) add `import 'client-only'` at the top.
import axios from 'axios'
import { getQueryClient } from '@/lib/query-client'
import { toApiError } from '@/lib/errors'

export const apiClient = axios.create({
  baseURL: '/api',
  timeout: 15_000,
  headers: { 'X-Requested-With': 'XMLHttpRequest' }, // required by the CSRF check (Hardened)
})

apiClient.interceptors.response.use(
  (res) => res,
  (error: unknown) => {
    if (axios.isAxiosError(error)) {
      const status = error.response?.status ?? 0
      const isAuthCall = error.config?.url?.startsWith('/auth/') ?? false
      const onLogin = typeof window !== 'undefined' && window.location.pathname.startsWith('/login')

      // Dead session: clear cached data and go to login, except for auth calls (keep login error messages) and when already on /login (avoid loops)
      if (status === 401 && !isAuthCall && !onLogin && typeof window !== 'undefined') {
        getQueryClient().clear()
        const from = encodeURIComponent(window.location.pathname + window.location.search)
        window.location.href = `/login?from=${from}`
      }
      return Promise.reject(toApiError(status, error.response?.data, error.message))
    }
    return Promise.reject(error)
  },
)
