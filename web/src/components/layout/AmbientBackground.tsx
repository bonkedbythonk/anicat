import { useEffect, useState, memo } from "react";

const SKIN_CONFIGS: Record<string, string> = {
  "neon-abyss":   "radial-gradient(ellipse at 50% 0%, rgba(94,92,230,0.12) 0%, var(--background) 60%)",
  "sakura-zen":   "radial-gradient(ellipse at 50% 0%, rgba(220,100,150,0.10) 0%, var(--background) 60%)",
  "retro-manga":  "var(--background)",
};

export const AmbientBackground = memo(function AmbientBackground() {
  const [base, setBase] = useState(SKIN_CONFIGS["neon-abyss"]);

  useEffect(() => {
    const update = () => {
      const style = document.documentElement.getAttribute("data-style") || "neon-abyss";
      setBase(SKIN_CONFIGS[style] || SKIN_CONFIGS["neon-abyss"]);
    };
    update();
    const observer = new MutationObserver(update);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-style"],
    });
    return () => observer.disconnect();
  }, []);

  return (
    <div
      className="fixed inset-0 pointer-events-none z-0"
      style={{ background: base }}
    />
  );
});
