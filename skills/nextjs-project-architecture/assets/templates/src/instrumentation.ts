// Starter. Runs once when the Next.js server starts.
// API_MOCKING=enabled -> the backend is replaced by MSW handlers (src/mocks). Build UI before the API exists,
// then remove the variable to use the real API. BACKEND_URL must still be a valid URL (e.g. http://api.mock).
// Verify on your Next.js version: if requests are not intercepted, run the handlers in a small standalone
// mock server instead (see GUIDE.md "Building before the API is ready").
// Standard+: Sentry's register() also goes here.
export async function register() {
  if (process.env.NEXT_RUNTIME === 'nodejs' && process.env.API_MOCKING === 'enabled') {
    const { server } = await import('./mocks/node')
    server.listen({ onUnhandledRequest: 'bypass' })
    console.info('[mocks] API mocking enabled')
  }
}
