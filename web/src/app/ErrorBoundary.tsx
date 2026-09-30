import { Component, type ErrorInfo, type ReactNode } from 'react'

interface State {
  crashed: boolean
}

/**
 * Catches a crash while rendering anything inside it, and shows a message
 * with a way back instead of a blank page.
 *
 * React only offers this as a class component: getDerivedStateFromError
 * and componentDidCatch have no hook equivalents.
 */
export class ErrorBoundary extends Component<Readonly<{ children: ReactNode }>, State> {
  state: State = { crashed: false }

  static getDerivedStateFromError(): State {
    return { crashed: true }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Keep the details for whoever opens the browser console.
    console.error('The app crashed while rendering:', error, info.componentStack)
  }

  render() {
    if (!this.state.crashed) return this.props.children
    return (
      <div className="page narrow">
        <h1>Ledger</h1>
        <section className="card stack" role="alert">
          <p className="error">Something went wrong on this page. Reloading usually fixes it.</p>
          <button type="button" onClick={() => window.location.reload()}>
            Reload
          </button>
        </section>
      </div>
    )
  }
}
