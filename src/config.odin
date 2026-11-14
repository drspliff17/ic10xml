package main

import "core:fmt"
import "core:os"
import "kvp"

Config :: struct {
	script_directory: string,
	game_version:     string,
	default_author:   string,
}

load_config :: proc(c: ^Config, filepath: string) -> ^Config {
	p := kvp.init_parser()
	defer kvp.free_parser(&p)

	kvp.register_struct_keys(&p, Config)
	kvp.read_bytes_into_parser(&p, filepath)
	kvp.tokenize_bytes(&p)
	kvp.unmarshal(&p, c)

	e := kvp.get_cloned_error_array(&p)
	defer delete(e)

	for x in e {
		if x.line == 0 {
			fmt.eprintfln("[ERROR] %v", x.type)
		} else {
			fmt.eprintfln("[ERROR] Line %d: %v", x.line, x.type)
		}
	}

	if !os.exists(c.script_directory) {
		fmt.eprintfln("[ERROR] Config.script_directory does not exist: %s", c.script_directory)
		return nil
	}

	f, err := os.stat(c.script_directory, context.allocator)
	if err != nil {
		fmt.eprintfln(
			"[ERROR] Failed to stat Config.script_directory: %s -> %v",
			c.script_directory,
			err,
		)
		return nil
	}
	defer os.file_info_delete(f, context.allocator)

	if f.type != .Directory {
		fmt.eprintfln(
			"[ERROR] Config.script_directory is an invalid file type: %s -> %v",
			c.script_directory,
			f.type,
		)
		return nil
	}

	return c
}

free_config :: proc(c: ^Config) {
	if len(c.script_directory) > 0 do delete_string(c.script_directory)
	if len(c.game_version) > 0 do delete_string(c.game_version)
	if len(c.default_author) > 0 do delete_string(c.default_author)
	free(c)
}
