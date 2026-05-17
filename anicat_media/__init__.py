import sys

if sys.version_info < (3, 11):
    raise ImportError(
        "You are using an unsupported version of Python. Only Python 3.11 or newer is supported by Anicat"
    )


def Cli():
    from .cli import run_cli

    run_cli()
