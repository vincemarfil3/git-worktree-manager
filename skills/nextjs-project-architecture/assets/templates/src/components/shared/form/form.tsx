'use client'
// Starter. <Form> = FormProvider + <form> + submit handling + server error mapping.
// onSubmit should `await mutation.mutateAsync(...)` so isSubmitting covers the whole request.
import type { FieldValues, UseFormReturn } from 'react-hook-form'
import { FormProvider } from 'react-hook-form'
import { cn } from '@/lib/utils'
import { mapServerErrors, type ServerErrorOptions } from './map-server-errors'

type FormProps<TIn extends FieldValues, TOut> = {
  form: UseFormReturn<TIn, unknown, TOut>
  onSubmit: (values: TOut) => Promise<unknown> | unknown
  /** Forwarded to mapServerErrors: fieldMap (API name -> form name), codeToField, fallbackMessage */
  serverErrors?: ServerErrorOptions<TIn>
  className?: string
  children: React.ReactNode
}

export function Form<TIn extends FieldValues, TOut>({ form, onSubmit, serverErrors, className, children }: FormProps<TIn, TOut>) {
  const handleSubmit = form.handleSubmit(async (values) => {
    form.clearErrors('root')
    try {
      await onSubmit(values)
    } catch (error) {
      mapServerErrors(form, error, serverErrors)
    }
  })

  return (
    <FormProvider {...form}>
      <form noValidate onSubmit={handleSubmit} className={cn('space-y-6', className)}>
        {children}
      </form>
    </FormProvider>
  )
}
