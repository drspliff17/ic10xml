# IC10XML

## Simple CLI solution to writing Stationeers IC10, from an external editor

Encodes plain-text ``.ic10`` files into valid ``instruction.xml`` file via
simple CLI interface:

```txt
Usage: ic10xml <file.ic10> [opts]
Opts:
-n | --name         -> Set output name (default to file name, w/o suffix)
-t | --title        -> Set script title (default to file name, w/o suffix)
-d | --description  -> Set script description tag
-a | --author       -> Set script author tag
-v | --version      -> Set version tag
```

## Config File

If present, file will be loaded on execution. Expected path:

```bash
$HOME/.config/ic10xml/config
```

Config file may set the following values:

```txt
script_directory -> Stationeers Scripts Directory. If set, generated xml will be
                    moved here automatically

game_version     -> Provides default value for version tag

default_author   -> Provides default value for author tag
```

### Format

Config uses simple Key/Value format:

```txt
default_author = Dr Spliff
```

## Download Release

Only Supports Linux, other OS must build from src

[Download the latest release](https://github.com/drspliff17/ic10xml/releases/latest)

Add to ``$PATH``

## Build Instructions

- Requires [Odin Compiler](https://github.com/odin-lang/Odin)

Clone repo, cd into dir and run:

```bash
odin build src -out:ic10xml
```

Add to ``$PATH``

## Notes

- If using Neovim, recommend to pair with [this plugin](https://github.com/Pesterenan/ic10.nvim)
