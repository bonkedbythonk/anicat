import js from "@eslint/js";
import globals from "globals";
import tseslint from "typescript-eslint";
import reactHooks from "eslint-plugin-react-hooks";

export default tseslint.config(
  {
    ignores: [
      "dist/**",
      "src-tauri/**",
      "public/**",
      ".next/**",
      "out/**",
      "node_modules/**",
      "**/*.js",
      "**/*.cjs",
      "**/*.mjs",
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["src/**/*.{ts,tsx}"],
    languageOptions: {
      globals: { ...globals.browser },
    },
    plugins: {
      "react-hooks": reactHooks,
    },
    rules: {
      // The classic, high-value hook rules. rules-of-hooks catches the
      // hook-order violation that caused the React #310 crash, so it stays
      // an error. The newer React-Compiler rules (set-state-in-effect,
      // purity, immutability) are intentionally left off — this codebase
      // doesn't use the compiler and they flag normal patterns.
      "react-hooks/rules-of-hooks": "error",
      "react-hooks/exhaustive-deps": "warn",
      // The codebase leans on `any` at the API boundary and on dev logging;
      // keep these visible without failing the build.
      "@typescript-eslint/no-explicit-any": "warn",
      "@typescript-eslint/no-unused-vars": [
        "warn",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],
      "@typescript-eslint/no-unused-expressions": "warn",
      "no-empty": ["warn", { allowEmptyCatch: true }],
    },
  }
);
