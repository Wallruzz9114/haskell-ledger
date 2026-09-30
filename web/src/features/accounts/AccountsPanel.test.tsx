import { act, screen } from '@testing-library/react'
import { setupListeners } from '@reduxjs/toolkit/query'
import { describe, expect, it } from 'vitest'
import { admin, alice, fakeApi } from '../../test/fakeApi'
import { renderWithStore } from '../../test/render'
import { AccountsPanel } from './AccountsPanel'

const all = [
  {
    id: 'acme-ops',
    name: 'Acme Operating',
    kind: 'Customer',
    owner: 'alice',
    balanceCents: 2825300,
  },
  {
    id: 'external',
    name: 'External (outside the ledger)',
    kind: 'External',
    owner: null,
    balanceCents: -7501300,
  },
  { id: 'legacy', name: 'Legacy', kind: 'Customer', owner: null, balanceCents: 0 },
]

describe('AccountsPanel', () => {
  it('shows a customer their accounts, without an owner field', async () => {
    fakeApi({ 'GET /api/accounts': () => ({ status: 200, body: all.slice(0, 1) }) })
    renderWithStore(<AccountsPanel user={alice} />)
    expect(await screen.findByText('Your accounts')).toBeInTheDocument()
    expect(await screen.findByText('$28,253.00')).toBeInTheDocument()
    expect(screen.queryByLabelText('Owner')).not.toBeInTheDocument()
  })

  it('shows an admin every account with its owner, and negative balances in red', async () => {
    fakeApi({ 'GET /api/accounts': () => ({ status: 200, body: all }) })
    renderWithStore(<AccountsPanel user={admin} />)
    expect(await screen.findByText('All accounts')).toBeInTheDocument()
    expect(await screen.findByText(/no owner/)).toBeInTheDocument()
    expect(screen.getByText('-$75,013.00')).toHaveClass('negative')
    expect(screen.getByLabelText('Owner')).toBeInTheDocument()
  })

  it('refreshes balances when the tab gets focus again', async () => {
    let balance = 2825300
    fakeApi({
      'GET /api/accounts': () => ({ status: 200, body: [{ ...all[0], balanceCents: balance }] }),
    })
    const { store } = renderWithStore(<AccountsPanel user={alice} />)
    // What main.tsx does for the real app: listen for focus events.
    const stopListening = setupListeners(store.dispatch)
    expect(await screen.findByText('$28,253.00')).toBeInTheDocument()

    // Someone pays alice while she's in another tab...
    balance = 2835300
    // ...and she comes back to this one.
    act(() => {
      window.dispatchEvent(new Event('focus'))
    })
    expect(await screen.findByText('$28,353.00')).toBeInTheDocument()
    stopListening()
  })
})
