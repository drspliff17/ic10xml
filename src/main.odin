package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import cli "shared:cli_helpers"

DOTNET_EPOCH_OFFSET :: i64(621355968000000000)

print_help :: proc(cfg_path: string) {
	h := `------------------------------------------------
Convert plain-text .ic10 file -> instruction.xml
------------------------------------------------
Usage: ic10xml <file.ic10> [opts]
Opts:
-h | --help
-n | --name         -> Set output name (default to file name, w/o suffix)
-t | --title        -> Set script title (default to file name, w/o suffix)
-d | --description  -> Set script description tag
-a | --author       -> Set script author tag
-v | --version      -> Set version tag [May have unintended consequences]

Config file will be loaded if created at:
%s

Valid Config Keys:
script_directory    -> Stationeers scripts directory, if set, output dir
                       will be moved here automatically
`
	fmt.printf(h, cfg_path)
}

main :: proc() {
	h, he := os.user_home_dir(context.allocator)
	if he != nil {
		fmt.eprintfln("Failed to allocate user home directory: %v", he)
		return
	}
	defer delete_string(h)

	cfg_path, ce := os.join_path({h, ".config", "ic10xml", "config"}, context.allocator)
	if ce != nil {
		fmt.eprintfln("Failed to allocate config path %v", ce)
		return
	}
	defer delete_string(cfg_path)

	config := new(Config)
	if os.exists(os.dir(cfg_path)) {
		if os.exists(cfg_path) {
			load_config(config, cfg_path)
		} else {
			fmt.eprintfln(
				"[ERROR] Config directory exists, but config file does not. Expected: %s\nAborting",
				cfg_path,
			)
			return
		}
	}
	defer if config != nil do free_config(config)

	args := os.args[1:]
	if len(args) < 1 {
		print_help(cfg_path)
		return
	} else {
		switch args[0] {
		case "-h", "--help":
			print_help(cfg_path)
			return
		}
	}

	input_path := string(args[0])
	args = args[1:]

	game_version := len(config.game_version) > 0 ? config.game_version : "0.2.6428.27798"
	author := len(config.default_author) > 0 ? config.default_author : "Recruit"

	title := strings.trim_suffix(os.base(input_path), ".ic10")
	ts := DOTNET_EPOCH_OFFSET + time.time_to_unix(time.now()) / 100
	desc := ""

	output_name := strings.trim_suffix(os.base(input_path), ".ic10")

	for len(args) > 0 {
		switch args[0] {
		case "-h", "--help":
			print_help(cfg_path)
			return

		case "-n", "--name":
			if len(args) < 2 {
				fmt.eprintln("Expected value to assign to File Name")
				return
			}
			if len(args[1]) > 0 do output_name = args[1]
			args = args[2:]

		case "-t", "--title":
			if len(args) < 2 {
				fmt.eprintln("Expected value to assign to Title")
				return
			}
			title = args[1]
			args = args[2:]

		case "-d", "--description":
			if len(args) < 2 {
				fmt.eprintln("Expected value to assign to Description")
				return
			}
			desc = args[1]
			args = args[2:]

		case "-a", "--author":
			if len(args) < 2 {
				fmt.eprintln("Expected value to assign to Author")
				return
			}
			author = args[1]
			args = args[2:]

		case "-v", "--version":
			if len(args) < 2 {
				fmt.eprintln("Expected value to assign to Game Version")
				return
			}
			fmt.printfln(
				"[WARN] Untested as to whether version may invalidate file, if mismatch occurs.",
			)
			game_version = args[1]
			args = args[2:]

		case:
			fmt.eprintfln("Unknown argument: %s", args[0])
			return
		}
	}

	output_dir, e := os.join_path({os.dir(input_path), output_name}, context.allocator)
	if e != nil do fmt.panicf("Failed to allocate output directory path: %v", e)
	defer delete_string(output_dir)

	data, err := os.read_entire_file(input_path, context.allocator)
	if err != nil {
		fmt.eprintfln("Failed to read input file: %s -> %v", input_path, err)
		return
	}
	defer delete(data, context.allocator)

	xml := fmt.aprintf(
		"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
		"<InstructionData xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n" +
		"  <DateTime>%d</DateTime>\n" +
		"  <GameVersion>%s</GameVersion>\n" +
		"  <Title>%s</Title>\n" +
		"  <Description>%s</Description>\n" +
		"  <Author>%s</Author>\n" +
		"  <WorkshopFileHandle>0</WorkshopFileHandle>\n" +
		"  <Instructions>%s</Instructions>\n" +
		"</InstructionData>\n",
		ts,
		game_version,
		title,
		desc,
		author,
		string(data),
	)
	defer delete(xml)

	if os.exists(output_dir) {
		fmt.eprintfln("File already exists, aborting: %s", output_dir)
		return
	}

	if e := os.make_directory_all(output_dir); e != nil {
		fmt.eprintfln("Failed to create output directory: %s -> %v", output_dir, e)
		return
	}

	output_path, oe := os.join_path({output_dir, "instruction.xml"}, context.allocator)
	if oe != nil {
		fmt.eprintfln("Failed to allocate output path: %v", oe)
		return
	}
	defer delete_string(output_path)

	err = os.write_entire_file(output_path, transmute([]byte)xml)
	if err != nil {
		fmt.eprintln("Failed to write output file")
		return
	}

	fmt.printfln("Created %s", output_path)
	if config != nil {
		new_path, e := os.join_path({config.script_directory, output_name}, context.allocator)
		if e != nil {
			fmt.eprintfln("Failed to allocate new path: %v", e)
			return
		}
		defer delete_string(new_path)

		if os.exists(new_path) {
			fmt.printfln("[WARN] File already exists: %s", new_path)
			p := cli.confirmationPrompt("Overwrite file? [y/N]", true)
			if p != .Positive {
				fmt.println("[ABORTED]")
				return
			}

			if e := os.remove_all(new_path); e != nil {
				fmt.eprintfln("Failed to remove existing directory: %s -> %v", new_path, e)
				return
			}
		}

		abs_out, err := os.get_absolute_path(os.dir(output_path), context.allocator)
		if err != nil {
			fmt.eprintfln("Failed to resolve output path: %v", err)
			return
		}
		defer delete_string(abs_out)

		if e := os.rename(abs_out, new_path); e != nil {
			fmt.eprintfln("Failed to move to %s: %v", config.script_directory, e)
			return
		}

		fmt.printfln("Moved -> %s/%s", config.script_directory, output_path)
	}
}
