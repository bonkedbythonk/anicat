import click
from rich import print as rprint
from pathlib import Path
import os
import shutil

from ...core.config import AppConfig
from ...core.constants import USER_CONFIG
from ..config.loader import ConfigLoader

@click.command(help="Login to your AniList account")
@click.pass_obj
def login(config: AppConfig):
    """
    Login to AniList by opening the token URL and config file.
    """
    from ...core.constants import ANILIST_AUTH
    
    rprint("[bold cyan]AniList Login[/]")
    rprint(f"Opening your browser for authentication: [link={ANILIST_AUTH}]{ANILIST_AUTH}[/link]")
    click.launch(ANILIST_AUTH)
    
    rprint("\n[bold yellow]Opening your config file in your default text editor...[/]")
    click.launch(str(USER_CONFIG))
    
    rprint("\n[bold green]Instructions:[/]")
    rprint("1. Copy the 'access_token' from the URL after authorizing.")
    rprint(f"2. Paste it in the file behind [bold white]token = [/] (located under the [bold white][[anilist]][/] section).")
    rprint("3. Save ([bold white]Cmd+S[/]) and close the editor.")
    
    input("\nPress Enter here once you have saved and closed the file...")
    
    # Reload config to verify
    try:
        loader = ConfigLoader(config_path=USER_CONFIG)
        new_config = loader.load()
        
        if new_config.anilist.token:
            rprint("\n[bold green]Login successful! Enjoy Anicat.[/bold green]")
        else:
            rprint("\n[bold red]Error: Token not found in config. Please try again.[/bold red]")
            
    except Exception as e:
        rprint(f"\n[bold red]Failed to reload config: {e}[/bold red]")
