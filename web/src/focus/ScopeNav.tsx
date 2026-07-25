import { useSpatialNavigation } from "./useSpatialNavigation";

/**
 * Binds arrow-key spatial navigation to the *nearest* FocusScope. Render it as
 * a child of a `<FocusScope>` so `useSpatialNavigation`'s `useContext` resolves
 * to that scope. Calling `useSpatialNavigation()` in the component that renders
 * the scope (rather than inside it) resolves the parent scope instead, which
 * silently breaks navigation — this helper makes the correct placement the easy
 * default. Renders nothing.
 */
export function ScopeNav() {
  useSpatialNavigation();
  return null;
}
