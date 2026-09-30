import { configureStore, createSlice, type PayloadAction } from '@reduxjs/toolkit'
import { ledgerApi } from './api'

/** Client-only UI state lives in a plain slice; server state lives in RTK Query. */
interface UiState {
  selectedAccountId: string | null
}

const initialState: UiState = { selectedAccountId: null }

export const uiSlice = createSlice({
  name: 'ui',
  initialState,
  reducers: {
    selectAccount(state, action: PayloadAction<string | null>) {
      state.selectedAccountId = action.payload
    },
  },
  // Logging out clears the selection too, so the next user starts fresh.
  extraReducers: (builder) => {
    builder.addMatcher(ledgerApi.endpoints.logout.matchFulfilled, () => initialState)
  },
})

export const { selectAccount } = uiSlice.actions

/** A new store. A function, so each test can have its own. */
export function makeStore() {
  return configureStore({
    reducer: {
      ui: uiSlice.reducer,
      [ledgerApi.reducerPath]: ledgerApi.reducer,
    },
    middleware: (getDefault) => getDefault().concat(ledgerApi.middleware),
  })
}

export const store = makeStore()

export type AppStore = ReturnType<typeof makeStore>
export type RootState = ReturnType<AppStore['getState']>
export type AppDispatch = AppStore['dispatch']
