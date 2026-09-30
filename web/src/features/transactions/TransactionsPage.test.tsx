import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { alice, fakeApi, type SeenRequest } from '../../test/fakeApi'
import { renderWithStore } from '../../test/render'
import { TransactionsPage } from './TransactionsPage'

const row = (n: number, overrides = {}) => ({
  transfer: n,
  account: 'acme-ops',
  accountName: 'Acme Operating',
  counterparty: 'globex-ops',
  counterpartyName: 'Globex Operating',
  amountCents: -1000 * n,
  memo: `Invoice ${n}`,
  createdAt: `2026-09-${String(n).padStart(2, '0')}T15:00:00Z`,
  ...overrides,
})

const myAccounts = [
  { id: 'acme-ops', name: 'Acme Operating', kind: 'Customer', owner: 'alice', balanceCents: 1 },
  { id: 'globex-ops', name: 'Globex Operating', kind: 'Customer', owner: 'bob', balanceCents: 1 },
]

function transactionsApi(handle: (req: SeenRequest) => unknown) {
  return fakeApi({
    'GET /api/accounts': () => ({ status: 200, body: myAccounts }),
    'GET /api/transactions': (req) => ({ status: 200, body: handle(req) }),
  })
}

describe('TransactionsPage', () => {
  it('shows names on both sides, and loads the next page with the cursor', async () => {
    const seen = transactionsApi((req) =>
      req.query.get('before') === 'next-page'
        ? { items: [row(1)], nextCursor: null }
        : { items: [row(3), row(2)], nextCursor: 'next-page' },
    )
    renderWithStore(<TransactionsPage user={alice} />)
    expect(await screen.findByText('Invoice 3')).toBeInTheDocument()
    expect(screen.getAllByText('Globex Operating').length).toBeGreaterThan(0)
    expect(screen.getByText('-$30.00')).toHaveClass('negative')

    await userEvent.click(screen.getByRole('button', { name: 'Load more' }))
    expect(await screen.findByText('Invoice 1')).toBeInTheDocument()
    // The last page: no more "Load more".
    expect(screen.queryByRole('button', { name: 'Load more' })).not.toBeInTheDocument()
    expect(
      seen
        .filter((r) => r.path === '/api/transactions')
        .at(-1)
        ?.query.get('before'),
    ).toBe('next-page')
  })

  it('searches once typing pauses', async () => {
    const seen = transactionsApi((req) => ({
      items: req.query.get('q') === 'payroll' ? [] : [row(1)],
      nextCursor: null,
    }))
    renderWithStore(<TransactionsPage user={alice} />)
    await screen.findByText('Invoice 1')
    await userEvent.type(screen.getByLabelText('Search transactions'), 'payroll')
    expect(await screen.findByText('No transactions match “payroll”.')).toBeInTheDocument()
    // One request for the finished word, not one per keystroke.
    const searches = seen.filter((r) => r.query.get('q'))
    expect(searches.map((r) => r.query.get('q'))).toEqual(['payroll'])
  })

  it('offers only her own accounts to filter by', async () => {
    transactionsApi(() => ({ items: [], nextCursor: null }))
    renderWithStore(<TransactionsPage user={alice} />)
    const picker = await screen.findByLabelText('Account')
    await screen.findByRole('option', { name: 'Acme Operating' })
    expect(picker).not.toHaveTextContent('Globex Operating')
  })

  it('offers a retry when loading fails', async () => {
    let up = false
    // The first answer is a 503; after "Try again", the API is back.
    const seen = fakeApi({
      'GET /api/accounts': () => ({ status: 200, body: myAccounts }),
      'GET /api/transactions': () =>
        up
          ? { status: 200, body: { items: [row(1)], nextCursor: null } }
          : {
              status: 503,
              body: { error: 'service_unavailable', message: 'Temporarily unavailable.' },
            },
    })
    renderWithStore(<TransactionsPage user={alice} />)
    expect(await screen.findByText('Temporarily unavailable.')).toBeInTheDocument()
    up = true
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('Invoice 1')).toBeInTheDocument()
    expect(seen.filter((r) => r.path === '/api/transactions').length).toBeGreaterThanOrEqual(2)
  })
})
