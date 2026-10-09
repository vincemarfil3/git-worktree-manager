// Starter. Layout-only helpers. Fields never do their own layout.
import { cn } from '@/lib/utils'

export function FormSection({ title, description, children, className }: { title: string; description?: string; children: React.ReactNode; className?: string }) {
  return (
    <section className={cn('space-y-4', className)}>
      <div className="space-y-1">
        <h2 className="text-base font-semibold">{title}</h2>
        {description && <p className="text-sm text-muted-foreground">{description}</p>}
      </div>
      {children}
    </section>
  )
}

export function FormGrid({ children, columns = 2, className }: { children: React.ReactNode; columns?: 1 | 2 | 3; className?: string }) {
  const cols = { 1: '', 2: 'sm:grid-cols-2', 3: 'sm:grid-cols-2 lg:grid-cols-3' }[columns]
  return <div className={cn('grid gap-4', cols, className)}>{children}</div>
}
