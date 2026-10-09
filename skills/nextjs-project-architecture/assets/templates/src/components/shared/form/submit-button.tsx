'use client'
// Starter. Disabled + spinner while submitting (prevents double submits / double charges).
import { Loader2 } from 'lucide-react'
import { useFormState } from 'react-hook-form'
import { Button } from '@/components/ui/button'

type SubmitButtonProps = { children: React.ReactNode; pendingText?: string; className?: string; disabled?: boolean }

export function SubmitButton({ children, pendingText, className, disabled }: SubmitButtonProps) {
  const { isSubmitting } = useFormState()
  return (
    <Button type="submit" disabled={disabled || isSubmitting} aria-busy={isSubmitting} className={className}>
      {isSubmitting && <Loader2 className="size-4 animate-spin" aria-hidden="true" />}
      {isSubmitting && pendingText ? pendingText : children}
    </Button>
  )
}
