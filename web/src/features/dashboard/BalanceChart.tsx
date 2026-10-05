import { useCallback, useState, type KeyboardEvent, type PointerEvent } from 'react'
import type { BalancePointView } from '../../app/api'
import { formatCents } from '../../app/money'
import { formatCompact, formatDay, niceTicks } from './format'

// Drawn in CSS pixels at the container's real width, so the labels stay
// their real size on a phone instead of shrinking with the drawing.
const DEFAULT_WIDTH = 640
const HEIGHT = 220
const PAD = { top: 12, right: 16, bottom: 28, left: 64 }
const PLOT_H = HEIGHT - PAD.top - PAD.bottom

/**
 * The width of an element, kept up to date as it resizes. Returns a ref
 * callback to put on the element. Where ResizeObserver doesn't exist (the
 * test environment), it stays at the fallback.
 */
function useElementWidth(fallback: number) {
  const [width, setWidth] = useState(fallback)
  // React 19 runs the function a ref callback returns when the element goes away.
  const ref = useCallback((el: HTMLElement | null) => {
    if (!el || typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(([entry]) => {
      const w = Math.round(entry.contentRect.width)
      if (w > 0) setWidth(w)
    })
    observer.observe(el)
    return () => observer.disconnect()
  }, [])
  return [width, ref] as const
}

/**
 * The total balance over time: one series, so no legend (the card's title
 * names it). A crosshair snaps to the nearest day on hover, and the arrow
 * keys do the same for keyboard users. "Show as table" has every value.
 */
export function BalanceChart({ points }: Readonly<{ points: BalancePointView[] }>) {
  const [active, setActive] = useState<number | null>(null)
  const [width, measure] = useElementWidth(DEFAULT_WIDTH)

  if (points.length === 0) return <p className="muted">No balance history yet.</p>

  const values = points.map((p) => p.balanceCents)
  const ticks = niceTicks(Math.min(0, ...values), Math.max(...values))
  const lo = ticks[0]
  const hi = ticks.at(-1) ?? lo
  const plotW = width - PAD.left - PAD.right
  const x = (i: number) =>
    PAD.left + (points.length === 1 ? plotW : (i / (points.length - 1)) * plotW)
  const y = (v: number) => PAD.top + PLOT_H - ((v - lo) / (hi - lo || 1)) * PLOT_H
  const baseline = y(Math.max(lo, 0))

  const line = points.map((p, i) => `${i === 0 ? 'M' : 'L'}${x(i)},${y(p.balanceCents)}`).join(' ')
  const area = `${line} L${x(points.length - 1)},${baseline} L${x(0)},${baseline} Z`
  // Up to five date labels along the bottom (fewer when narrow: about one
  // per 90px), always including the last day.
  const labelCount = Math.max(2, Math.min(5, Math.floor(plotW / 90)))
  const labelEvery = Math.max(1, Math.ceil(points.length / labelCount))
  const labelled = points.map((_, i) => i).filter((i) => (points.length - 1 - i) % labelEvery === 0)

  // Pointer position -> nearest day.
  function onPointerMove(e: PointerEvent<SVGSVGElement>) {
    const rect = e.currentTarget.getBoundingClientRect()
    const svgX = ((e.clientX - rect.left) / rect.width) * width
    const i = Math.round(((svgX - PAD.left) / plotW) * (points.length - 1))
    setActive(Math.min(points.length - 1, Math.max(0, i)))
  }

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    const last = points.length - 1
    const step: Record<string, (i: number) => number> = {
      ArrowLeft: (i) => Math.max(0, i - 1),
      ArrowRight: (i) => Math.min(last, i + 1),
      Home: () => 0,
      End: () => last,
    }
    if (step[e.key]) {
      e.preventDefault()
      setActive((i) => step[e.key](i ?? last))
    }
  }

  const point = active === null ? null : points[active]
  // The day read out to screen readers: the hovered or selected one, or the latest.
  const shown = point ?? points.at(-1)
  const valueText = shown
    ? `${formatDay(shown.date)}: ${formatCents(shown.balanceCents)}`
    : undefined

  return (
    <div className="chart">
      {/* To keyboards and screen readers the chart is a slider over the days:
          the arrow keys move the selected day, and aria-valuetext reads it
          out ("Sep 12: $64,613.00"). */}
      <div
        ref={measure}
        className="chart-plot"
        tabIndex={0}
        role="slider"
        aria-label={`Balance by day, last ${points.length} days`}
        aria-valuemin={0}
        aria-valuemax={points.length - 1}
        aria-valuenow={active ?? points.length - 1}
        aria-valuetext={valueText}
        onKeyDown={onKeyDown}
        onFocus={() => setActive(points.length - 1)}
        onBlur={() => setActive(null)}
      >
        <svg
          viewBox={`0 0 ${width} ${HEIGHT}`}
          onPointerMove={onPointerMove}
          onPointerLeave={() => setActive(null)}
        >
          {ticks.map((t) => (
            <g key={t}>
              <line className="grid" x1={PAD.left} x2={width - PAD.right} y1={y(t)} y2={y(t)} />
              <text
                className="tick"
                x={PAD.left - 8}
                y={y(t)}
                textAnchor="end"
                dominantBaseline="middle"
              >
                {formatCompact(t)}
              </text>
            </g>
          ))}
          {labelled.map((i) => (
            <text
              key={i}
              className="tick"
              x={x(i)}
              y={HEIGHT - 8}
              textAnchor={i === points.length - 1 ? 'end' : 'middle'}
            >
              {formatDay(points[i].date)}
            </text>
          ))}
          <path className="area" d={area} />
          <path className="line" d={line} />
          {point && active !== null && (
            <g>
              <line
                className="crosshair"
                x1={x(active)}
                x2={x(active)}
                y1={PAD.top}
                y2={PAD.top + PLOT_H}
              />
              <circle className="dot" cx={x(active)} cy={y(point.balanceCents)} r={4} />
            </g>
          )}
        </svg>
        {point && active !== null && (
          <output className="chart-tooltip" style={{ left: `${(x(active) / width) * 100}%` }}>
            <span className="muted">{formatDay(point.date)}</span>
            <strong>{formatCents(point.balanceCents)}</strong>
          </output>
        )}
      </div>
      <details className="chart-table">
        <summary>Show as table</summary>
        <table>
          <thead>
            <tr>
              <th>Day</th>
              <th className="right">Balance</th>
            </tr>
          </thead>
          <tbody>
            {points.map((p) => (
              <tr key={p.date}>
                <td>{formatDay(p.date)}</td>
                <td className="right amount">{formatCents(p.balanceCents)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </details>
    </div>
  )
}
