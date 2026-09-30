import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  plugins: [react()],
  server: {
    // In development, API calls go to the Haskell server on :8080. The
    // browser only ever talks to Vite (same origin), so the session cookie
    // just works and there's no CORS to set up.
    proxy: { '/api': 'http://localhost:8080' },
  },
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    // Undo mocks and stubbed globals (like the fake fetch) after every test,
    // so a test that forgets to set up its own fake API fails loudly instead
    // of silently reusing the previous test's. restoreMocks alone doesn't
    // undo vi.stubGlobal; unstubGlobals does.
    restoreMocks: true,
    unstubGlobals: true,
  },
})
