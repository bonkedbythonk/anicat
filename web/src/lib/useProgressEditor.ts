import { useState } from "react";

export function useProgressEditor() {
  const [isEditing, setIsEditing] = useState(false);
  const [editValue, setEditValue] = useState("");

  const startEditing = (currentValue: number) => {
    setEditValue(currentValue.toString());
    setIsEditing(true);
  };

  const cancelEditing = () => {
    setIsEditing(false);
    setEditValue("");
  };

  return {
    isEditing,
    editValue,
    setEditValue,
    startEditing,
    cancelEditing,
  };
}
