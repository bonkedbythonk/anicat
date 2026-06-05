import logging
import tomllib
from enum import Enum
from pathlib import Path
from typing import Dict
from pydantic import ValidationError

from anicat_media.core.config import AppConfig
from anicat_media.core.constants import USER_CONFIG
from anicat_media.core.exceptions import ConfigError

logger = logging.getLogger(__name__)


def generate_config_toml_from_app_model(config: AppConfig) -> str:
    """
    Generates a TOML string from an AppConfig object.
    """
    lines = [r"#/\_/\ ", r"#( o.o )", r"# > ^ <  [ a n i c a t ]", ""]

    for section_name, section_model in config:
        model_class = type(section_model)
        if not hasattr(model_class, "model_fields"):
            continue

        lines.append(f"[{section_name}]")

        for field_name in model_class.model_fields:
            field_value = getattr(section_model, field_name)

            # Special case for token in anilist section to ensure it's always written
            if (
                section_name == "anilist"
                and field_name == "token"
                and field_value is None
            ):
                field_value = ""

            if field_value is None:
                continue

            if isinstance(field_value, bool):
                value = str(field_value).lower()
            elif isinstance(field_value, (int, float)):
                value = str(field_value)
            elif isinstance(field_value, list):
                # Simple list formatting for TOML
                value = (
                    "["
                    + ", ".join(
                        f'"{v.value}"'
                        if isinstance(v, Enum)
                        else f'"{v}"'
                        if isinstance(v, str)
                        else str(v)
                        for v in field_value
                    )
                    + "]"
                )
            elif isinstance(field_value, Path):
                # Make path dynamic to user home if possible
                try:
                    home = Path.home()
                    if field_value.is_relative_to(home):
                        str_val = "~/" + str(field_value.relative_to(home))
                    else:
                        str_val = str(field_value)
                except (ValueError, RuntimeError):
                    str_val = str(field_value)

                str_val = str_val.replace("\\", "\\\\").replace('"', '\\"')
                value = f'"{str_val}"'
            elif isinstance(field_value, Enum):  # Enum
                value = f'"{field_value.value}"'
            else:
                str_val = str(field_value).replace("\\", "\\\\")
                if "\n" in str_val:
                    # Use multiline string for values with newlines
                    value = f'"""\n{str_val}"""'
                else:
                    str_val = str_val.replace('"', '\\"')
                    value = f'"{str_val}"'

            lines.append(f"{field_name} = {value}")
        lines.append("")

    return "\n".join(lines)


class ConfigLoader:
    """
    Handles loading the application configuration from a .toml file.
    """

    def __init__(self, config_path: Path = USER_CONFIG):
        self.config_path = config_path

    def _handle_first_run(self) -> AppConfig:
        """Handles the configuration process when no config.toml file is found."""
        app_config = AppConfig()
        config_toml_content = generate_config_toml_from_app_model(app_config)
        try:
            self.config_path.parent.mkdir(parents=True, exist_ok=True)
            self.config_path.write_text(config_toml_content, encoding="utf-8")
        except Exception as e:
            raise ConfigError(
                f"Could not create configuration file at {self.config_path!s}. "
                f"Please check permissions. Error: {e}",
            )
        return app_config

    def load(self, update: Dict = {}, allow_setup=True) -> AppConfig:
        if not self.config_path.exists():
            if allow_setup:
                return self._handle_first_run()
            return AppConfig()

        try:
            with self.config_path.open("rb") as f:
                config_dict = tomllib.load(f)
        except tomllib.TOMLDecodeError as e:
            raise ConfigError(
                f"Error parsing configuration file '{self.config_path}':\n{e}"
            )

        if update:
            for section, values in update.items():
                if section in config_dict:
                    config_dict[section].update(values)
                else:
                    config_dict[section] = values

        try:
            app_config = AppConfig.model_validate(config_dict)
            return app_config
        except ValidationError as e:
            error_message = (
                f"Configuration error in '{self.config_path}'!\n"
                f"Please correct the following issues:\n\n{e}"
            )
            raise ConfigError(error_message)
