import { useState } from 'react'
import { errorMessage, useDashboardQuery, type PartyView } from '../../app/api'
import { formatCents } from '../../app/money'
import { BalanceChart } from './BalanceChart'
import { monthLabel, shiftMonth } from './format'

/**
 * The overview: total balance, how it moved over the last 90 days, and this
 * month's money in and out (transfers between your own accounts don't count:
 * the money never left).
 */
export function DashboardPage() {
  // undefined = "this month", as the API decides it.
  const [month, setMonth] = useState<string | undefined>(undefined)
  const { data, error, isFetching, refetch } = useDashboardQuery(month)
  const shown = data?.month ?? month

  if (error)
    return (
      <section className="card stack" role="alert">
        <p className="error">{errorMessage(error)}</p>
        <button type="button" onClick={() => refetch()} disabled={isFetching}>
          {isFetching ? 'Trying…' : 'Try again'}
        </button>
      </section>
    )
  if (!data || !shown) return <p className="muted">Loading…</p>

  return (
    <div className="dashboard">
      <section className="card hero-card">
        <div>
          <p className="muted">Total balance</p>
          <p className="hero-figure">{formatCents(data.totalBalanceCents)}</p>
        </div>
        <h2 className="chart-title">Balance, last {data.series.length} days</h2>
        <BalanceChart points={data.series} />
      </section>

      <div className="month-switcher" aria-busy={isFetching}>
        <button
          type="button"
          className="secondary icon"
          aria-label="Previous month"
          onClick={() => setMonth(shiftMonth(shown, -1))}
        >
          ‹
        </button>
        <h2>{monthLabel(shown)}</h2>
        <button
          type="button"
          className="secondary icon"
          aria-label="Next month"
          onClick={() => setMonth(shiftMonth(shown, 1))}
        >
          ›
        </button>
      </div>

      <div className="grid">
        <MoneyCard
          title="Money in"
          totalCents={data.moneyInCents}
          sign="in"
          listTitle="Top sources"
          parties={data.topSources}
        />
        <MoneyCard
          title="Money out"
          totalCents={data.moneyOutCents}
          sign="out"
          listTitle="Top spending"
          parties={data.topSpending}
        />
      </div>
    </div>
  )
}

function MoneyCard({
  title,
  totalCents,
  sign,
  listTitle,
  parties,
}: Readonly<{
  title: string
  totalCents: number
  sign: 'in' | 'out'
  listTitle: string
  parties: PartyView[]
}>) {
  const prefix = sign === 'in' ? '+' : '-'
  return (
    <section className="card">
      <p className="muted">{title}</p>
      <p className={`stat ${sign === 'in' ? 'positive' : 'negative'}`}>
        {totalCents === 0 ? formatCents(0) : `${prefix}${formatCents(totalCents)}`}
      </p>
      <h3>{listTitle}</h3>
      {parties.length === 0 ? (
        <p className="muted">Nothing this month.</p>
      ) : (
        <ul className="party-list">
          {parties.map((p) => (
            <li key={p.account}>
              <span>{p.name}</span>
              <span className="amount">{formatCents(p.amountCents)}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
