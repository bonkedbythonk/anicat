export function useProgressEditor(
  _entry: { score?: number; progress?: number; status?: string; notes?: string },
  _onUpdate: (updates: Record<string, unknown>) => void,
) {
  return {
    score: null,
    progress: null,
    status: null,
    notes: null,
    setScore: () => {},
    setProgress: () => {},
    setStatus: () => {},
    setNotes: () => {},
    save: () => {},
    isDirty: false,
  };
}
