# IC10XML

## Simple CLI solution to writing Stationeers IC10, from an external editor

Encodes plain-text ``.ic10`` files into valid ``instruction.xml`` file
Simple CLI interface:

```txt
Usage: ic10xml <file.ic10> [opts]
Opts:
-n | --name         -> Set output name (default to file name, w/o suffix)
-t | --title        -> Set script title (default to file name, w/o suffix)
-d | --description  -> Set script description tag
-a | --author       -> Set script author tag
-v | --version      -> Set version tag [May have unintended consequences]
```

## Config File

If present, file will be loaded on initialisation. Expected path:

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
