import { render } from '@testing-library/react'
import type { ReactElement } from 'react'
import { Provider } from 'react-redux'
import { makeStore } from '../app/store'

/** Render with a fresh Redux store, so tests never share cached data. */
export function renderWithStore(ui: ReactElement) {
  const store = makeStore()
  return { store, ...render(<Provider store={store}>{ui}</Provider>) }
}
