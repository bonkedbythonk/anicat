"use client";

import { useState, useCallback } from "react";
import { useUpdateProgress } from "./useUpdateProgress";

export interface UseProgressEditorReturn {
  isEditing: boolean;
  editValue: string;
  setEditValue: (value: string) => void;
  startEditing: (currentProgress: number) => void;
  cancelEditing: () => void;
  commitProgress: (mediaId: number, newProgress: number) => void;
}

/**
 * Manages the inline progress-editing UI state for media items.
 */
export function useProgressEditor(): UseProgressEditorReturn {
  const [isEditing, setIsEditing] = useState(false);
  const [editValue, setEditValue] = useState("");
  const updateProgress = useUpdateProgress();

  const startEditing = useCallback((currentProgress: number) => {
    setEditValue(String(currentProgress));
    setIsEditing(true);
  }, []);

  const cancelEditing = useCallback(() => {
    setIsEditing(false);
    setEditValue("");
  }, []);

  const commitProgress = useCallback(
    (mediaId: number, newProgress: number) => {
      // Close the editing UI immediately — don't block on the network call
      setIsEditing(false);
      updateProgress.mutate({ mediaId, progress: newProgress });
    },
    [updateProgress]
  );

  return {
    isEditing,
    editValue,
    setEditValue,
    startEditing,
    cancelEditing,
    commitProgress,
  };
}
