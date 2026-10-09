import { z } from 'zod'
import { requiredText } from '@/lib/validation'

export const signInSchema = z.object({
  email: z.email('Enter a valid email'),
  password: requiredText('Enter your password'),
})

export const signInDefaults = { email: '', password: '' }
