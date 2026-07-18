import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useState } from "react";
import { FocusScope } from "./FocusScope";
import { useFocusable } from "./useFocusable";

function Item({ label, disabled }: { label: string; disabled?: boolean }) {
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>({ disabled });
  return <button ref={ref} tabIndex={tabIndex} disabled={disabled}>{label}</button>;
}

describe("FocusScope", () => {
  it("registers focusable children and roves tabindex", async () => {
    render(
      <FocusScope name="test" orientation="horizontal">
        <Item label="a" />
        <Item label="b" />
        <Item label="c" />
      </FocusScope>
    );
    const buttons = screen.getAllByRole("button");
    expect(buttons[0]).toHaveAttribute("tabindex", "0");
    expect(buttons[1]).toHaveAttribute("tabindex", "-1");
    expect(buttons[2]).toHaveAttribute("tabindex", "-1");
  });

  it("updates indices when an item unmounts", async () => {
    function App() {
      const [showB, setShowB] = useState(true);
      return (
        <>
          <FocusScope name="unmount-test" orientation="horizontal">
            <Item label="a" />
            {showB && <Item label="b" />}
            <Item label="c" />
          </FocusScope>
          <button onClick={() => setShowB(false)}>hide b</button>
        </>
      );
    }
    const user = userEvent.setup();
    render(<App />);
    const buttons = screen.getAllByRole("button");
    expect(buttons[0]).toHaveAttribute("tabindex", "0");
    expect(buttons[1]).toHaveAttribute("tabindex", "-1");
    expect(buttons[2]).toHaveAttribute("tabindex", "-1");
    await user.click(buttons[3]);
    const after = screen.getAllByRole("button");
    expect(after[0]).toHaveAttribute("tabindex", "0");
    expect(after[1]).toHaveAttribute("tabindex", "-1");
  });

  it("skips disabled items when roving focus", async () => {
    render(
      <FocusScope name="disabled-test" orientation="horizontal">
        <Item label="a" />
        <Item label="b" disabled />
        <Item label="c" />
      </FocusScope>
    );
    const buttons = screen.getAllByRole("button");
    expect(buttons[0]).toHaveAttribute("tabindex", "0");
    expect(buttons[1]).toHaveAttribute("tabindex", "-1");
    expect(buttons[2]).toHaveAttribute("tabindex", "-1");
  });
});
