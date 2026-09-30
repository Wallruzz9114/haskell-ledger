import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { alice, apiError, fakeApi } from '../../test/fakeApi'
import { renderWithStore } from '../../test/render'
import { TransferForm } from './TransferForm'

const visible = [
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
  // An admin's list could include other people's accounts; the "From"
  // dropdown must still only offer alice's own.
  { id: 'globex-ops', name: 'Globex Operating', kind: 'Customer', owner: 'bob', balanceCents: 1 },
]

async function fillAndSend(amount: string) {
  const from = await screen.findByLabelText('From')
  await within(from).findByRole('option', { name: /Acme Operating/ })
  await userEvent.selectOptions(from, 'acme-ops')
  await userEvent.type(screen.getByLabelText('To (any account id)'), 'globex-ops')
  await userEvent.type(screen.getByLabelText('Amount (USD)'), amount)
  await userEvent.click(screen.getByRole('button', { name: 'Send' }))
}

describe('TransferForm', () => {
  it('offers only your own accounts to send from', async () => {
    fakeApi({ 'GET /api/accounts': () => ({ status: 200, body: visible }) })
    renderWithStore(<TransferForm user={alice} />)
    const from = await screen.findByLabelText('From')
    await within(from).findByRole('option', { name: /Acme Operating/ })
    const names = within(from)
      .getAllByRole('option')
      .map((o) => o.textContent)
    expect(names.some((n) => n?.includes('Globex'))).toBe(false)
  })

  it('sends cents and an Idempotency-Key, and reuses the key when a send fails', async () => {
    let calls = 0
    const seen = fakeApi({
      'GET /api/accounts': () => ({ status: 200, body: visible }),
      'POST /api/transfers': () => {
        calls += 1
        return calls === 1
          ? {
              status: 503,
              body: apiError(
                'internal_error',
                'Something went wrong on our side. Please try again.',
              ),
            }
          : {
              status: 201,
              body: { id: 40, from: 'acme-ops', to: 'globex-ops', amount: 125050, memo: '' },
            }
      },
    })
    renderWithStore(<TransferForm user={alice} />)

    await fillAndSend('1,250.50')
    expect(await screen.findByText(/Something went wrong/)).toBeInTheDocument()
    // Retry the same draft: same key, so the server can't apply it twice.
    await userEvent.click(screen.getByRole('button', { name: 'Send' }))
    expect(await screen.findByText('Sent $1,250.50 as transfer #40.')).toBeInTheDocument()

    const sends = seen.filter((r) => r.path === '/api/transfers')
    expect(sends).toHaveLength(2)
    expect(sends[0].body).toMatchObject({ from: 'acme-ops', to: 'globex-ops', amountCents: 125050 })
    const firstKey = sends[0].headers.get('Idempotency-Key')
    expect(firstKey).toBeTruthy()
    expect(sends[1].headers.get('Idempotency-Key')).toBe(firstKey)
  })

  it('uses a new key after the details change, so an edited retry is not a 409', async () => {
    // Behaves like the real API: it remembers every key with the request it
    // came with, and refuses the same key with a different request.
    const remembered = new Map<string, string>()
    const seen = fakeApi({
      'GET /api/accounts': () => ({ status: 200, body: visible }),
      'POST /api/transfers': (req) => {
        const key = req.headers.get('Idempotency-Key') ?? ''
        const request = JSON.stringify(req.body)
        if (remembered.has(key) && remembered.get(key) !== request) {
          return {
            status: 409,
            body: apiError(
              'idempotency_key_reused',
              'This Idempotency-Key was already used with a different request.',
            ),
          }
        }
        remembered.set(key, request)
        const cents = (req.body as { amountCents: number }).amountCents
        return cents > 150000
          ? { status: 422, body: apiError('insufficient_funds', 'Insufficient funds.') }
          : {
              status: 201,
              body: { id: 41, from: 'acme-ops', to: 'globex-ops', amount: cents, memo: '' },
            }
      },
    })
    renderWithStore(<TransferForm user={alice} />)

    // Too much: refused.
    await fillAndSend('999999.99')
    expect(await screen.findByText('Insufficient funds.')).toBeInTheDocument()
    // Lower the amount and send again: accepted, not "key already used".
    const amount = screen.getByLabelText('Amount (USD)')
    await userEvent.clear(amount)
    await userEvent.type(amount, '25')
    await userEvent.click(screen.getByRole('button', { name: 'Send' }))
    expect(await screen.findByText('Sent $25.00 as transfer #41.')).toBeInTheDocument()

    const keys = seen
      .filter((r) => r.path === '/api/transfers')
      .map((r) => r.headers.get('Idempotency-Key'))
    expect(keys).toHaveLength(2)
    expect(keys[1]).not.toBe(keys[0])
  })

  it('checks the amount before sending anything', async () => {
    const seen = fakeApi({ 'GET /api/accounts': () => ({ status: 200, body: visible }) })
    renderWithStore(<TransferForm user={alice} />)
    await fillAndSend('abc')
    expect(await screen.findByText(/Enter a positive amount/)).toBeInTheDocument()
    expect(seen.some((r) => r.path === '/api/transfers')).toBe(false)
  })

  it("shows the API's reason when a transfer is refused", async () => {
    fakeApi({
      'GET /api/accounts': () => ({ status: 200, body: visible }),
      'POST /api/transfers': () => ({
        status: 422,
        body: apiError(
          'insufficient_funds',
          'Insufficient funds: $1,500.00 available, $999,999.99 requested.',
        ),
      }),
    })
    renderWithStore(<TransferForm user={alice} />)
    await fillAndSend('999999.99')
    expect(await screen.findByText(/Insufficient funds/)).toBeInTheDocument()
  })
})
