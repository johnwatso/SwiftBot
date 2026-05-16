import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'path';

// Vite builds into ../SwiftBotApp/Resources/admin so the existing
// AdminWebServer.swift can serve it without changing any paths.
// emptyOutDir is false so we don't wipe the games/ subfolder.
export default defineConfig({
  plugins: [react()],
  base: '/',
  build: {
    outDir: resolve(__dirname, '../SwiftBotApp/Resources/admin'),
    emptyOutDir: false,
    assetsDir: 'assets',
    sourcemap: false,
    rollupOptions: {
      output: {
        entryFileNames: 'assets/[name].js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: 'assets/[name][extname]',
      },
    },
  },
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://localhost:8090',
      '/v1': 'http://localhost:8090',
      '/auth': 'http://localhost:8090',
      '/health': 'http://localhost:8090',
    },
  },
});
