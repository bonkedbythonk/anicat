import { describe, it, expect } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { FocusScope } from "./FocusScope";
import { useFocusable } from "./useFocusable";
import { useSpatialNavigation } from "./useSpatialNavigation";
import { useAppStore } from "@/stores/app";

function GridItem({ label }: { label: string }) {
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>();
  return <button ref={ref} tabIndex={tabIndex}>{label}</button>;
}

function GridItems() {
  useSpatialNavigation();
  return (
    <>
      {Array.from({ length: 9 }).map((_, i) => (
        <GridItem key={i} label={`item ${i}`} />
      ))}
    </>
  );
}

function Grid() {
  return (
    <FocusScope name="grid" orientation="grid" columns={3}>
      <GridItems />
    </FocusScope>
  );
}

describe("useSpatialNavigation", () => {
  it("moves down by columns", () => {
    render(<Grid />);
    const buttons = screen.getAllByRole("button");
    act(() => buttons[0].focus());
    fireEvent.keyDown(window, { key: "ArrowDown" });
    expect(document.activeElement).toBe(buttons[3]);
  });

  it("moves up by columns", () => {
    render(<Grid />);
    const buttons = screen.getAllByRole("button");
    act(() => buttons[3].focus());
    fireEvent.keyDown(window, { key: "ArrowUp" });
    expect(document.activeElement).toBe(buttons[0]);
  });

  it("moves right to the next item", () => {
    render(<Grid />);
    const buttons = screen.getAllByRole("button");
    act(() => buttons[0].focus());
    fireEvent.keyDown(window, { key: "ArrowRight" });
    expect(document.activeElement).toBe(buttons[1]);
  });

  it("moves left to the previous item", () => {
    render(<Grid />);
    const buttons = screen.getAllByRole("button");
    act(() => buttons[1].focus());
    fireEvent.keyDown(window, { key: "ArrowLeft" });
    expect(document.activeElement).toBe(buttons[0]);
  });

  it("jumps to the first item on Home", () => {
    render(<Grid />);
    const buttons = screen.getAllByRole("button");
    act(() => buttons[8].focus());
    fireEvent.keyDown(window, { key: "Home" });
    expect(document.activeElement).toBe(buttons[0]);
  });

  it("jumps to the last item on End", () => {
    render(<Grid />);
    const buttons = screen.getAllByRole("button");
    act(() => buttons[0].focus());
    fireEvent.keyDown(window, { key: "End" });
    expect(document.activeElement).toBe(buttons[8]);
  });

  it("ignores arrow keys when another scope is active", () => {
    render(<Grid />);
    const buttons = screen.getAllByRole("button");
    // Focusing the grid auto-activates it (FocusScope.onFocus). Simulate a
    // different scope then taking over the active slot; arrows must be ignored
    // here even though a grid item still holds DOM focus.
    act(() => buttons[0].focus());
    act(() => useAppStore.getState().setActiveFocusScope("other"));
    fireEvent.keyDown(window, { key: "ArrowRight" });
    expect(document.activeElement).toBe(buttons[0]);
  });
});
