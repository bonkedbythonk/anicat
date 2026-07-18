import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { FocusScope } from "./FocusScope";
import { useFocusable } from "./useFocusable";

function Item({ label }: { label: string }) {
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>();
  return <button ref={ref} tabIndex={tabIndex}>{label}</button>;
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
});
