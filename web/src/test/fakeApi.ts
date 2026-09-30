import { vi } from 'vitest'

/** One request the app made, as the fake API saw it. */
export interface SeenRequest {
  method: string
  path: string
  /** The query string, e.g. query.get('month') for ?month=2026-08. */
  query: URLSearchParams
  headers: Headers
  body: unknown
}

type Handler = (req: SeenRequest) => { status: number; body?: unknown }

/**
 * Replace fetch with a fake Haskell API. Handlers are keyed by
 * "METHOD /path", e.g. "GET /api/me". Unknown routes answer 404.
 * Returns the list of requests made, so tests can inspect them.
 */
export function fakeApi(routes: Record<string, Handler>): SeenRequest[] {
  const seen: SeenRequest[] = []
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: Request) => {
      const text = await input.text()
      const req: SeenRequest = {
        method: input.method,
        path: new URL(input.url).pathname,
        query: new URL(input.url).searchParams,
        headers: input.headers,
        body: text ? JSON.parse(text) : undefined,
      }
      seen.push(req)
      const handler = routes[`${req.method} ${req.path}`]
      const { status, body } = handler
        ? handler(req)
        : { status: 404, body: { error: 'not_found', message: 'No such endpoint.' } }
      return new Response(body === undefined ? null : JSON.stringify(body), {
        status,
        headers: { 'Content-Type': 'application/json' },
      })
    }),
  )
  return seen
}

/** A JSON error body, shaped like the real API's. */
export const apiError = (error: string, message: string) => ({ error, message })

export const alice = { username: 'alice', role: 'customer' as const }
export const admin = { username: 'admin', role: 'admin' as const }

export const accounts = [
  {
    id: 'acme-ops',
    name: 'Acme Operating',
    kind: 'Customer',
    owner: 'alice',
    balanceCents: 2825300,
  },
  {
    id: 'acme-payroll',
    name: 'Acme Payroll',
    kind: 'Customer',
    owner: 'alice',
    balanceCents: 150000,
  },
]

/** A small dashboard response for alice. */
export const dashboardFor = (month = '2026-09') => ({
  totalBalanceCents: 3991300,
  month,
  series: [
    { date: '2026-09-28', balanceCents: 3900000 },
    { date: '2026-09-29', balanceCents: 3950000 },
    { date: '2026-09-30', balanceCents: 3991300 },
  ],
  moneyInCents: month === '2026-09' ? 3325000 : 0,
  moneyOutCents: month === '2026-09' ? 2482900 : 0,
  topSources:
    month === '2026-09'
      ? [{ account: 'external', name: 'External (outside the ledger)', amountCents: 3325000 }]
      : [],
  topSpending:
    month === '2026-09'
      ? [{ account: 'globex-ops', name: 'Globex Operating', amountCents: 320000 }]
      : [],
})
