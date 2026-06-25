import { useEffect, useState, memo } from "react";
import { isWindows } from "@/lib/platform";

const SKIN_CONFIGS: Record<string, string> = {
  "neon-abyss":   "radial-gradient(ellipse at 50% 0%, rgba(94,92,230,0.12) 0%, var(--background) 60%)",
  "sakura-zen":   "radial-gradient(ellipse at 50% 0%, rgba(220,100,150,0.10) 0%, var(--background) 60%)",
  "retro-manga":  "var(--background)",
};

// On Windows with Mica the root background is already transparent, so the
// ambient gradient must also fade to transparent or it blocks the Mica tint.
const MICA_SKIN_CONFIGS: Record<string, string> = {
  "neon-abyss":  "radial-gradient(ellipse at 50% 0%, rgba(94,92,230,0.10) 0%, transparent 60%)",
  "sakura-zen":  "radial-gradient(ellipse at 50% 0%, rgba(220,100,150,0.08) 0%, transparent 60%)",
  "retro-manga": "transparent",
};

export const AmbientBackground = memo(function AmbientBackground() {
  const configs = isWindows ? MICA_SKIN_CONFIGS : SKIN_CONFIGS;
  const [base, setBase] = useState(configs["neon-abyss"]);

  useEffect(() => {
    const update = () => {
      const style = document.documentElement.getAttribute("data-style") || "neon-abyss";
      setBase(configs[style] || configs["neon-abyss"]);
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
