from typing import TYPE_CHECKING, Optional

from InquirerPy import inquirer
from InquirerPy.prompts import FuzzyPrompt  # pyright: ignore[reportPrivateImportUsage]
from rich.console import Console

from ..base import BaseSelector

if TYPE_CHECKING:
    from ....core.config import AppConfig

console = Console()

from ..base import BaseSelector


class InquirerSelector(BaseSelector):
    def __init__(self, config: Optional["AppConfig"] = None):
        self.config = config

    def _get_header_text(self, header: Optional[str] = None) -> str:
        """Constructs the header text including logo and update notification."""
        lines = []
        if self.config and self.config.fzf.show_header_ascii_art:
            header_color = self.config.fzf.header_color.split(",")
            color_str = f"rgb({header_color[0]},{header_color[1]},{header_color[2]})"
            lines.append(f"[{color_str}]{self.config.fzf.header_ascii_art}[/]")
            lines.append("") # Spacing

        if header:
            lines.append(f"[bold cyan]{header}[/bold cyan]")
            
        return "\n".join(lines)

    def _render_header(self, header: Optional[str] = None):
        """Prints the header to the console."""
        header_text = self._get_header_text(header)
        if header_text:
            console.print(header_text)

    def choose(self, prompt, choices, *, preview=None, header=None):
        self._render_header(header)
        
        return FuzzyPrompt(
            message=prompt,
            choices=choices,
            border=False,
            validate=lambda result: result in choices,
            wrap_around=True,
            keybindings={
                "answer": [{"key": "enter"}, {"key": "right"}],
            },
        ).execute()

    def confirm(self, prompt, *, default=False):
        self._render_header()
        return inquirer.confirm(
            message=prompt,
            default=default,
            keybindings={
                "answer": [{"key": "enter"}, {"key": "right"}],
            },
        ).execute()

    def ask(self, prompt, *, default=None):
        self._render_header()
        return inquirer.text(
            message=prompt,
            default=default or "",
            validate=lambda result: len(result.strip()) > 0 or "Input cannot be empty. Please try again.",
            keybindings={
                "answer": [{"key": "enter"}, {"key": "right"}],
            },
        ).execute()

    def choose_multiple(
        self, prompt: str, choices: list[str], preview: str | None = None
    ) -> list[str]:
        self._render_header()
        return FuzzyPrompt(
            message=prompt,
            choices=choices,
            multiselect=True,
            border=False,
            wrap_around=True,
            keybindings={
                "answer": [{"key": "enter"}, {"key": "right"}],
            },
        ).execute()

    def search(
        self,
        prompt: str,
        search_command: str,
        *,
        preview: str | None = None,
        header: str | None = None,
        initial_query: str | None = None,
        initial_results: list[str] | None = None,
    ) -> str | None:
        self._render_header(header)
        
        return FuzzyPrompt(
            message=prompt,
            choices=initial_results or [],
            border=False,
            wrap_around=True,
            keybindings={
                "answer": [{"key": "enter"}, {"key": "right"}],
            },
        ).execute()


if __name__ == "__main__":
    import sys
    try:
        selector = InquirerSelector()
        choice = selector.choose("Test", ["a", "b"])
        print(choice)
    finally:
        # Ensure terminal is reset on exit
        sys.exit(0)
