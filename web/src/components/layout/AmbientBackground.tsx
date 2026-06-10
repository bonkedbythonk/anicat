export function AmbientBackground() {
  return (
    <div
      className="fixed inset-0 pointer-events-none z-0 transition-all duration-1000"
      style={{
        background: `
          radial-gradient(ellipse 80% 50% at 20% 20%, var(--ambient-color), transparent),
          radial-gradient(ellipse 60% 40% at 80% 80%, rgba(139, 92, 246, 0.05), transparent)
        `,
      }}
    />
  );
}
