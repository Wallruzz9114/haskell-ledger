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
    // Each test file gets a fresh environment, so mocked fetches and Redux
    // stores can't leak between files.
    restoreMocks: true,
  },
})
