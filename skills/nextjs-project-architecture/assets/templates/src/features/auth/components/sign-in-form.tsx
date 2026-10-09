'use client'
import { useRouter } from 'next/navigation'
import { Form, FormError, SubmitButton, TextField, useAppForm } from '@/components/shared/form'
import { useSignIn } from '../mutations'
import { signInDefaults, signInSchema } from '../schemas'

export function SignInForm({ redirectTo }: { redirectTo: string }) {
  const router = useRouter()
  const signIn = useSignIn()
  const form = useAppForm(signInSchema, signInDefaults)

  return (
    <Form
      form={form}
      onSubmit={async (values) => {
        await signIn.mutateAsync(values)
        router.replace(redirectTo)
      }}
    >
      <FormError />
      <TextField control={form.control} name="email" label="Email" type="email" autoComplete="email" />
      <TextField control={form.control} name="password" label="Password" type="password" autoComplete="current-password" />
      <SubmitButton pendingText="Signing in…" className="w-full">
        Sign in
      </SubmitButton>
    </Form>
  )
}
