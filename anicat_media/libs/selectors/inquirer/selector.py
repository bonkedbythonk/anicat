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
            
            from ....core.updater import is_update_available
            if is_update_available():
                lines.append("\n✨ [bold yellow]A new update is available![/]\n[dim]Run 'anicat update' to get the latest features.[/]")
            
            lines.append("") # Spacing

        if header:
            lines.append(f"[bold cyan]{header}[/bold cyan]")
            
        return "\n".join(lines)

    def choose(self, prompt, choices, *, preview=None, header=None):
        header_text = self._get_header_text(header)
        full_message = f"{header_text}\n{prompt}" if header_text else prompt
        
        return FuzzyPrompt(
            message=full_message,
            choices=choices,
            height="100%",
            border=False,
            validate=lambda result: result in choices,
            wrap_around=True,
            keybindings={
                "answer": [{"key": "enter"}, {"key": "right"}],
            },
        ).execute()

    def confirm(self, prompt, *, default=False):
        header_text = self._get_header_text()
        full_message = f"{header_text}\n{prompt}" if header_text else prompt
        return inquirer.confirm(
            message=full_message,
            default=default,
            keybindings={
                "answer": [{"key": "enter"}, {"key": "right"}],
            },
        ).execute()

    def ask(self, prompt, *, default=None):
        header_text = self._get_header_text()
        full_message = f"{header_text}\n{prompt}" if header_text else prompt
        return inquirer.text(
            message=full_message,
            default=default or "",
            keybindings={
                "answer": [{"key": "enter"}, {"key": "right"}],
            },
        ).execute()

    def choose_multiple(
        self, prompt: str, choices: list[str], preview: str | None = None
    ) -> list[str]:
        header_text = self._get_header_text()
        full_message = f"{header_text}\n{prompt}" if header_text else prompt
        return FuzzyPrompt(
            message=full_message,
            choices=choices,
            height="100%",
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
        header_text = self._get_header_text(header)
        full_message = f"{header_text}\n{prompt}" if header_text else prompt
        
        return FuzzyPrompt(
            message=full_message,
            choices=initial_results or [],
            height="100%",
            border=False,
            wrap_around=True,
            keybindings={
                "answer": [{"key": "enter"}, {"key": "right"}],
            },
        ).execute()


if __name__ == "__main__":
    selector = InquirerSelector()
    choice = selector.ask("Hello dev :)")
    print(choice)
    choice = selector.confirm("Hello dev :)")
    print(choice)
    choice = selector.choose_multiple("What comes first", ["a", "b"])
    print(choice)
    choice = selector.choose("What comes first", ["a", "b"])
    print(choice)
