import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { apiError, fakeApi } from '../../test/fakeApi'
import { renderWithStore } from '../../test/render'
import { DepositForm } from './DepositForm'

const visible = [
  { id: 'acme-ops', name: 'Acme Operating', kind: 'Customer', owner: 'alice', balanceCents: 0 },
  { id: 'external', name: 'External', kind: 'External', owner: null, balanceCents: 0 },
]

async function chooseAccount() {
  const into = await screen.findByLabelText('Into account')
  await within(into).findByRole('option', { name: 'Acme Operating' })
  await userEvent.selectOptions(into, 'acme-ops')
}

describe('DepositForm', () => {
  it('only offers customer accounts, never "external"', async () => {
    fakeApi({ 'GET /api/accounts': () => ({ status: 200, body: visible }) })
    renderWithStore(<DepositForm />)
    await chooseAccount()
    const names = within(screen.getByLabelText('Into account'))
      .getAllByRole('option')
      .map((o) => o.textContent)
    expect(names).not.toContain('External')
  })

  it('sends an Idempotency-Key and reuses it when the same deposit is retried', async () => {
    let calls = 0
    const seen = fakeApi({
      'GET /api/accounts': () => ({ status: 200, body: visible }),
      'POST /api/deposits': () => {
        calls += 1
        return calls === 1
          ? {
              status: 500,
              body: apiError(
                'internal_error',
                'Something went wrong on our side. Please try again.',
              ),
            }
          : {
              status: 201,
              body: { id: 50, from: 'external', to: 'acme-ops', amount: 10000, memo: 'Deposit' },
            }
      },
    })
    renderWithStore(<DepositForm />)
    await chooseAccount()
    await userEvent.type(screen.getByLabelText('Amount'), '100')
    await userEvent.click(screen.getByRole('button', { name: 'Deposit' }))
    expect(await screen.findByText(/Something went wrong/)).toBeInTheDocument()
    // Retry without changing anything: the same key, so it can't count twice.
    await userEvent.click(screen.getByRole('button', { name: 'Deposit' }))
    expect(await screen.findByText('Deposited $100.00 into acme-ops.')).toBeInTheDocument()

    const deposits = seen.filter((r) => r.path === '/api/deposits')
    expect(deposits[0].body).toEqual({ to: 'acme-ops', amountCents: 10000 })
    expect(deposits[0].headers.get('Idempotency-Key')).toBeTruthy()
    expect(deposits[1].headers.get('Idempotency-Key')).toBe(
      deposits[0].headers.get('Idempotency-Key'),
    )
  })

  it('uses a new key once the amount changes', async () => {
    const seen = fakeApi({
      'GET /api/accounts': () => ({ status: 200, body: visible }),
      'POST /api/deposits': () => ({ status: 500, body: apiError('internal_error', 'Try again.') }),
    })
    renderWithStore(<DepositForm />)
    await chooseAccount()
    const amount = screen.getByLabelText('Amount')
    await userEvent.type(amount, '100')
    await userEvent.click(screen.getByRole('button', { name: 'Deposit' }))
    await screen.findByText('Try again.')
    await userEvent.clear(amount)
    await userEvent.type(amount, '200')
    await userEvent.click(screen.getByRole('button', { name: 'Deposit' }))
    await screen.findByText('Try again.')

    const keys = seen
      .filter((r) => r.path === '/api/deposits')
      .map((r) => r.headers.get('Idempotency-Key'))
    expect(keys).toHaveLength(2)
    expect(keys[1]).not.toBe(keys[0])
  })
})
