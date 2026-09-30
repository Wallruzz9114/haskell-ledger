import { fireEvent, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { dashboardFor, fakeApi } from '../../test/fakeApi'
import { renderWithStore } from '../../test/render'
import { DashboardPage } from './DashboardPage'

describe('DashboardPage', () => {
  it('leads with the total balance, then money in and out with names', async () => {
    fakeApi({ 'GET /api/dashboard': () => ({ status: 200, body: dashboardFor() }) })
    renderWithStore(<DashboardPage />)
    expect(await screen.findByText('$39,913.00', { selector: '.hero-figure' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'September 2026' })).toBeInTheDocument()
    expect(screen.getByText('+$33,250.00')).toBeInTheDocument()
    expect(screen.getByText('-$24,829.00')).toBeInTheDocument()
    expect(screen.getByText('Globex Operating')).toBeInTheDocument()
  })

  it('asks for the previous month', async () => {
    const seen = fakeApi({
      'GET /api/dashboard': (req) => ({
        status: 200,
        body: dashboardFor(req.query.get('month') ?? '2026-09'),
      }),
    })
    renderWithStore(<DashboardPage />)
    await screen.findByRole('heading', { name: 'September 2026' })
    await userEvent.click(screen.getByRole('button', { name: 'Previous month' }))
    expect(await screen.findByRole('heading', { name: 'August 2026' })).toBeInTheDocument()
    expect(seen.at(-1)?.query.get('month')).toBe('2026-08')
    // A quiet month says so instead of showing empty lists.
    expect(screen.getAllByText('Nothing this month.')).toHaveLength(2)
  })

  it('reads the chart with the keyboard, and has a table of every day', async () => {
    fakeApi({ 'GET /api/dashboard': () => ({ status: 200, body: dashboardFor() }) })
    renderWithStore(<DashboardPage />)
    const chart = await screen.findByRole('img', { name: /Balance over the last 3 days/ })
    // Focusing the chart shows the latest day; the left arrow steps back.
    fireEvent.focus(chart)
    expect(screen.getByRole('status')).toHaveTextContent('Sep 30$39,913.00')
    fireEvent.keyDown(chart, { key: 'ArrowLeft' })
    expect(screen.getByRole('status')).toHaveTextContent('Sep 29$39,500.00')
    // The table view lists every day, for anyone who can't use the chart.
    expect(screen.getByText('Show as table')).toBeInTheDocument()
    expect(screen.getAllByRole('row')).toHaveLength(4) // header + 3 days
  })
})
