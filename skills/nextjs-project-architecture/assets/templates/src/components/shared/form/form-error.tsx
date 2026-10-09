'use client'
// Starter. Shows the form-level (root) error: 5xx, unknown, or errors not tied to a field.
import { useFormState } from 'react-hook-form'
import { Alert, AlertDescription } from '@/components/ui/alert'

export function FormError() {
  const { errors } = useFormState()
  const message = (errors.root?.serverError as { message?: string } | undefined)?.message
  if (!message) return null
  return (
    <Alert variant="destructive">
      <AlertDescription>{message}</AlertDescription>
    </Alert>
  )
}
