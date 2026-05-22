import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import commonjs from "@rollup/plugin-commonjs";
import path from "node:path";

export default defineConfig(({ mode }) => {
  const isDev = mode === "development";

  return {
    // Base URL for assets - all processed assets will be prefixed with /assets/
    base: "/assets/",

    plugins: [
      react(),
      tailwindcss(),
      // Handle CommonJS modules (@swc/helpers, vendor files)
      commonjs({
        include: [/vendor/, /@swc\/helpers/],
      }),
    ],

    // Test configuration for Vitest
    test: {
      globals: true,
      environment: "jsdom",
      include: ["js/**/*.{test,spec}.{js,jsx}"],
      setupFiles: ["./js/test/setup.js"],
      coverage: {
        provider: "v8",
        reporter: ["text", "html"],
        reportsDirectory: "./coverage",
        exclude: ["**/__mocks__/**"],
        thresholds: {
          lines: 90,
          functions: 90,
          branches: 90,
          statements: 90,
        },
      },
    },

    // Optimize dependencies - include React ESM exports
    optimizeDeps: {
      include: [
        "react",
        "react-dom",
        "react/jsx-runtime",
        "react/jsx-dev-runtime",
      ],
      exclude: ["topbar", "@swc/helpers"],
    },

    // Build configuration
    build: {
      // Output to priv/static/assets
      outDir: path.resolve(__dirname, "../priv/static/assets"),
      // Empty the output directory before building (only in production)
      emptyOutDir: !isDev,
      // Generate sourcemaps in dev
      sourcemap: isDev,
      // Configure rollup
      rollupOptions: {
        // JS entry point (imports CSS)
        input: path.resolve(__dirname, "js/app.js"),
        output: {
          // Keep the same output structure as before
          entryFileNames: "js/[name].js",
          chunkFileNames: "js/[name]-[hash].js",
          assetFileNames: (assetInfo) => {
            const info = assetInfo.name || "";
            if (info.endsWith(".css")) {
              return "css/app.css";
            }
            if (/\.(jpg|jpeg|png|gif|svg|webp|avif)$/.test(info)) {
              return "images/[name]-[hash][extname]";
            }
            if (/\.(woff|woff2|ttf|otf|eot)$/.test(info)) {
              return "fonts/[name]-[hash][extname]";
            }
            return "assets/[name]-[hash][extname]";
          },
        },
      },
      // Don't minify in dev for faster builds
      minify: !isDev,
      // Watch mode configuration (only used when --watch flag is passed)
      watch: isDev
        ? {
            // Don't build on startup, wait for changes
            buildDelay: 100,
            // Clear screen on rebuild
            clearScreen: false,
          }
        : null,
      // CommonJS options for mixed ESM/CJS modules
      commonjsOptions: {
        transformMixedEsModules: true,
      },
    },

    // Resolve paths
    resolve: {
      alias: {
        "@": path.resolve(__dirname, "js"),
        "@css": path.resolve(__dirname, "css"),
        // Use mock phoenix in tests, real phoenix in dev/build
        ...(mode === "test"
          ? {
              phoenix: path.resolve(__dirname, "js/__mocks__/phoenix.js"),
            }
          : {
              // Phoenix deps from Elixir deps directory
              phoenix: path.resolve(
                __dirname,
                "../deps/phoenix/priv/static/phoenix.mjs",
              ),
            }),
        phoenix_html: path.resolve(
          __dirname,
          "../deps/phoenix_html/priv/static/phoenix_html.js",
        ),
        phoenix_live_view: path.resolve(
          __dirname,
          "../deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js",
        ),
        // Vendor files - use raw imports
        topbar: path.resolve(__dirname, "vendor/topbar.js"),
      },
      // Auto-resolve these extensions when importing without extension
      extensions: [".js", ".jsx", ".ts", ".tsx"],
    },

    // CSS configuration
    css: {
      // Enable sourcemaps in dev
      devSourcemap: isDev,
    },

    // Development server configuration (not used in --watch mode, but configured)
    server: {
      port: 5173,
      strictPort: true, // Fail if port is in use
      host: "127.0.0.1",
    },
  };
});
