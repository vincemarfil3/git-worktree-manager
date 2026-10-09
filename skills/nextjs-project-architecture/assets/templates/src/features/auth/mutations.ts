'use client'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { apiClient } from '@/lib/api-client'

export function useSignIn() {
  return useMutation({
    mutationFn: (body: { email: string; password: string }) => apiClient.post('/auth/login', body),
  })
}

export function useSignOut() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: () => apiClient.post('/auth/logout'),
    onSettled: () => queryClient.clear(), // never show the previous user's data
  })
}
