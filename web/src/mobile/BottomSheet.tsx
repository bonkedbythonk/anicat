import { type ReactNode } from "react";
import { createPortal } from "react-dom";
import { motion, AnimatePresence } from "framer-motion";

interface BottomSheetProps {
  open: boolean;
  onClose: () => void;
  title?: string;
  children: ReactNode;
}

/** Native-style slide-up sheet — the standard iOS pattern for choices that
 * would otherwise be a desktop `<select>` or centered modal (status picker,
 * episode actions, character detail). No desktop equivalent to preserve;
 * this is new, mobile-only surface.
 *
 * Portaled to document.body: this renders from inside MobileMediaDetail,
 * which itself renders inside a Framer Motion `motion.div` — and a
 * `transform` on any ancestor (which Framer Motion applies for its
 * animations) creates a new containing block for `position: fixed`
 * descendants *and* a new stacking context for z-index. Without the portal,
 * this sheet would be confined and painted inside that animated wrapper's
 * box instead of the real viewport, and the bottom tab bar (rendered outside
 * that tree) would show through on top of it regardless of z-index. */
export function BottomSheet({ open, onClose, title, children }: BottomSheetProps) {
  return createPortal(
    <AnimatePresence>
      {open && (
        <div className="fixed inset-0 z-[300]">
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="absolute inset-0 bg-black/60"
            onClick={onClose}
          />
          <motion.div
            initial={{ y: "100%" }}
            animate={{ y: 0 }}
            exit={{ y: "100%" }}
            transition={{ type: "spring", damping: 32, stiffness: 320 }}
            className="absolute bottom-0 left-0 right-0 rounded-t-2xl bg-surface border-t border-border max-h-[80vh] overflow-y-auto"
            style={{ paddingBottom: "env(safe-area-inset-bottom)" }}
          >
            <div className="mx-auto mt-2.5 h-1 w-9 rounded-full bg-foreground/20" />
            {title && <h3 className="px-5 pt-3 pb-1 font-mono text-[11px] uppercase tracking-[0.08em] text-muted-foreground">{title}</h3>}
            <div className="px-2 pb-2 pt-1">{children}</div>
          </motion.div>
        </div>
      )}
    </AnimatePresence>,
    document.body,
  );
}

export function SheetRow({ onClick, active, destructive, children }: { onClick: () => void; active?: boolean; destructive?: boolean; children: ReactNode }) {
  return (
    <button
      onClick={onClick}
      className={`flex w-full items-center gap-3 rounded-md px-4 py-3.5 text-left text-[15px] font-medium active:bg-foreground/[0.06] ${
        destructive ? "text-danger-light" : active ? "text-accent" : "text-foreground"
      }`}
    >
      {children}
    </button>
  );
}
