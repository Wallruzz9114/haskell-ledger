import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { Provider } from 'react-redux'
import { setupListeners } from '@reduxjs/toolkit/query'
import App from './App'
import { ErrorBoundary } from './app/ErrorBoundary'
import { store } from './app/store'
import './index.css'

// Let RTK Query hear the browser's focus and online/offline events, which
// refetchOnFocus and refetchOnReconnect in api.ts rely on.
setupListeners(store.dispatch)

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ErrorBoundary>
      <Provider store={store}>
        <App />
      </Provider>
    </ErrorBoundary>
  </StrictMode>,
)
