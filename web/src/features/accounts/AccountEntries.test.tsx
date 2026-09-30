import { screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { selectAccount } from '../../app/store'
import { fakeApi } from '../../test/fakeApi'
import { renderWithStore } from '../../test/render'
import { AccountEntries } from './AccountEntries'

const entries = [
  {
    transfer: 38,
    account: 'acme-ops',
    amount: -2500,
    counterparty: 'globex-ops',
    memo: 'Invoice GX-1080',
    createdAt: '2026-09-29T18:05:12Z',
  },
  {
    transfer: 1,
    account: 'acme-ops',
    amount: 1850000,
    counterparty: 'external',
    memo: '',
    createdAt: '2026-07-01T09:00:00Z',
  },
]

describe('AccountEntries', () => {
  it('asks you to pick an account first', () => {
    fakeApi({})
    renderWithStore(<AccountEntries />)
    expect(screen.getByText(/Select an account/)).toBeInTheDocument()
  })

  it('shows who was on the other side, the memo and the date', async () => {
    fakeApi({ 'GET /api/accounts/acme-ops/entries': () => ({ status: 200, body: entries }) })
    const { store } = renderWithStore(<AccountEntries />)
    store.dispatch(selectAccount('acme-ops'))

    // Money out: "To globex-ops", with its memo, in red.
    expect(await screen.findByText('globex-ops')).toBeInTheDocument()
    expect(screen.getByText('Invoice GX-1080')).toBeInTheDocument()
    expect(screen.getByText('-$25.00')).toHaveClass('negative')
    // Money in: "From external", in green, with no memo line.
    expect(screen.getByText('external').parentElement).toHaveTextContent('From external')
    expect(screen.getByText('+$18,500.00')).toHaveClass('positive')
    // The date, as a machine-readable <time> too.
    expect(
      screen.getByText(/2026/, { selector: 'time[datetime="2026-07-01T09:00:00Z"]' }),
    ).toBeInTheDocument()
  })
})
