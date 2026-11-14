package kvp

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"

// Represents valid types, which values may be converted into, when parsed
VALUE_TYPES :: enum {
	STRING,
	INT,
	I32,
	F32,
	BOOL,
	I64,
	F64,
	U8,
	U32,
	U64,
	ENUMV,
	ENUMS,
}

// Represents all parser-related errors that may occur
PARSER_ERROR :: enum {
	FILE_NOT_EXIST,
	FAILED_TO_READ,
	FAILED_TO_SPLIT_LINES,
	FAILED_TO_SPLIT_TOKEN,
	INVALID_DELIMETER_USAGE,
}

// Represents all errors that may occur in the tokenization process
TOKENIZER_ERROR :: enum {
	INVALID_KEY,
	INVALID_VALUE,
	MISSING_KEY,
	MISSING_VALUE,
	MISSING_KEY_AND_VALUE,
	MISSING_DELIMETER,
	VALUE_OUT_OF_BOUNDS,
	FAILED_TO_COPY_TOKENS_TO_PARSER,
}

// Represents all errors that may occur specifically in the unmarshal process
UNMARSHAL_ERROR :: enum {
	INVALID_UNMARSHAL_TARGET,
	INVALID_FIELD_TYPE,
	DUPLICATE_KEY,
}

KVP_ERROR :: union {
	PARSER_ERROR,
	TOKENIZER_ERROR,
	UNMARSHAL_ERROR,
}

Error :: struct {
	line:        int,
	token_index: int,
	type:        KVP_ERROR,
}

// Represents a valid key, and an assigned value type
@(private = "file")
Key_Definition :: struct {
	key:  string,
	type: VALUE_TYPES,
}

// Represents a valid Token, parsed from bytes
@(private = "file")
Token :: struct {
	key:   string,
	value: string,
	line:  int,
}

@(private = "file")
Parser_Internal :: struct {
	// Authorative definition of keys, used to validate Tokens, parsed from bytes
	keys:         [dynamic]Key_Definition,

	// Appended from internal procs
	errors:       [dynamic]Error,

	// Set via read_bytes_into_parser()
	bytes:        []byte,

	// Parsed from bytes, raw-tokens which are not validated against keys
	tokens:       []Token,

	// Character used to split key / value
	kv_delimiter: string,
}

// Core Parser
Parser :: struct {
	data: ^Parser_Internal,
}

@(private = "file")
// Frees the allocated key string, owned by Key_Definition
free_key_definition :: proc(k: ^Key_Definition, alloc: mem.Allocator = context.allocator) {if len(k.key) > 0 do delete_string(k.key, alloc)}

@(private = "file")
/*
Maps a reflective primitive type to its corresponding VALUE_TYPES entry
Returns false if the type is not supported
*/
value_type_from_info :: proc(i: ^reflect.Type_Info) -> (type: VALUE_TYPES, ok: bool) {
	switch i.id {
	case typeid_of(string):
		return .STRING, true
	case typeid_of(int):
		return .INT, true
	case typeid_of(i32):
		return .I32, true
	case typeid_of(f32):
		return .F32, true
	case typeid_of(bool):
		return .BOOL, true
	case typeid_of(i64):
		return .I64, true
	case typeid_of(f64):
		return .F64, true
	case typeid_of(u8):
		return .U8, true
	case typeid_of(u32):
		return .U32, true
	case typeid_of(u64):
		return .U64, true
	}

	return nil, false
}

@(private = "file")
/*
Reads the enum mode from a struct field tag, defaults to ENUMS, when no tag is present
Returns false if the tag contains an unsupported mode
*/
enum_mode_from_tag :: proc(tag: string) -> (mode: VALUE_TYPES, ok: bool) {
	value, found := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), "kvp")
	if !found do return .ENUMS, true
	switch value {
	case "ENUMS":
		return .ENUMS, true
	case "ENUMV":
		return .ENUMV, true
	}
	return .ENUMS, false
}

@(private = "file")
/*
Retrieves the VALUE_TYPES entry corresponding to an enums backing type
Returns false if the type is not an enum, or its backing type is unsupported
*/
enum_value_type_from_info :: proc(i: ^reflect.Type_Info) -> (type: VALUE_TYPES, ok: bool) {
	if i == nil do return nil, false

	base := reflect.type_info_base(i)
	if reflect.underlying_type_kind(base.id) != .Enum do return nil, false

	enum_info := base.variant.(reflect.Type_Info_Enum)
	backing_type := reflect.type_info_base(enum_info.base)

	return value_type_from_info(backing_type)
}

@(private = "file")
/*
Determines the VALUE_TYPES entry used when registering a reflected type, supports
primitive types and enums, applying the requested enum mode
*/
serialization_type_from_info :: proc(
	i: ^reflect.Type_Info,
	enum_mode: VALUE_TYPES = .ENUMS,
) -> (
	type: VALUE_TYPES,
	ok: bool,
) {
	if i == nil do return nil, false

	base := reflect.type_info_base(i)
	if reflect.underlying_type_kind(base.id) == .Enum {
		if enum_mode == .ENUMS do return .ENUMS, true

		if enum_mode == .ENUMV {
			_, valid := enum_value_type_from_info(base)
			if !valid do return nil, false
			return .ENUMV, true
		}

		return nil, false
	}

	return value_type_from_info(base)
}

@(private = "file")
/*
Checks whether a reflected type is supported, recursively checks:
Struct fields, Arrays && Slices -> including enum field tags
*/
is_supported_type :: proc(info: ^reflect.Type_Info, enum_mode: VALUE_TYPES = .ENUMS) -> bool {
	if info == nil do return false

	base := reflect.type_info_base(info)

	#partial switch reflect.underlying_type_kind(base.id) {
	case .Struct:
		for i in 0 ..< reflect.struct_field_count(base.id) {
			field := reflect.struct_field_at(base.id, i)
			field_mode, valid_tag := enum_mode_from_tag(string(field.tag))
			if !valid_tag do return false
			if !is_supported_type(field.type, field_mode) do return false
		}
		return true

	case .Array:
		elem := base.variant.(reflect.Type_Info_Array).elem
		return is_supported_type(elem, enum_mode)

	case .Slice:
		elem := base.variant.(reflect.Type_Info_Slice).elem
		return is_supported_type(elem, enum_mode)

	case .Dynamic_Array:
		return false

	case:
		_, ok := serialization_type_from_info(base, enum_mode)
		return ok
	}

	return false
}

/*
Constructs an Error, and appends it to Parser.data.errors
Line and token index default to 0, when not applicable
*/
append_error :: proc(p: ^Parser, t: KVP_ERROR, line: int = 0, token_index: int = 0) {
	e := Error {
		line        = line,
		token_index = token_index,
		type        = t,
	}
	if _, err := append(&p.data.errors, e); err != nil do fmt.panicf("Failed to allocate Error into Parser")
}

@(private = "file")
// Frees the allocated key && value strings, owned by Token
free_token :: proc(t: ^Token, alloc: mem.Allocator = context.allocator) {
	if len(t.key) > 0 do delete_string(t.key, alloc)
	if len(t.value) > 0 do delete_string(t.value, alloc)
}

/*
Create and initialize a Parser
'kv_delimiter' must be a single character, else, '=' is used
The supplied allocator is used for parser-owned allocations
*/
init_parser :: proc(
	kv_delimiter: string = "=",
	alloc: mem.Allocator = context.allocator,
) -> Parser {
	kvd := len(strings.trim_space(kv_delimiter)) == 1 ? kv_delimiter : "="

	p := Parser{}
	p.data = new(Parser_Internal, alloc)
	p.data.keys = make([dynamic]Key_Definition, alloc)
	p.data.errors = make([dynamic]Error, alloc)
	p.data.kv_delimiter = kvd

	return p
}

/*
Frees all memory owned by the Parser, including:
Registered keys, errors, tokens, and input bytes. Resets Parser data pointer to nil
*/
free_parser :: proc(p: ^Parser, alloc: mem.Allocator = context.allocator) {
	for &k in p.data.keys do free_key_definition(&k, alloc)
	delete(p.data.keys)
	delete(p.data.errors)

	for &t in p.data.tokens do free_token(&t, alloc)
	if len(p.data.tokens) > 0 do delete(p.data.tokens, alloc)

	if len(p.data.bytes) > 0 do delete(p.data.bytes, alloc)
	free(p.data, alloc)
	p.data = nil
}

/*
Adds a Key_Definition to Parser.data.keys
The key string is cloned - panics if allocation, or append, fails
*/
append_key_definition :: proc(
	p: ^Parser,
	key: string,
	type: VALUE_TYPES,
	alloc: mem.Allocator = context.allocator,
) {
	k := Key_Definition {
		key  = strings.clone(key, alloc),
		type = type,
	}
	if _, e := append(&p.data.keys, k); e != nil do fmt.panicf("Failed to append key definition to Parser")
}

@(private = "file")
/*
Recursively traverses a reflected type and registers supported primitive, or enum, fields
Nested structs, arrays, && slices are represented by dot, and index path segments
Appends an error if a field type, or enum tag, is invalid - or if a key is duplicated
*/
register_type_keys :: proc(
	p: ^Parser,
	info: ^reflect.Type_Info,
	prefix: string,
	alloc: mem.Allocator,
	enum_mode: VALUE_TYPES = .ENUMS,
) -> (
	any_errors_encountered: bool,
) {
	if info == nil do return true

	base := reflect.type_info_base(info)

	#partial switch reflect.underlying_type_kind(base.id) {
	case .Struct:
		for i in 0 ..< reflect.struct_field_count(base.id) {
			field := reflect.struct_field_at(base.id, i)

			field_mode, valid_tag := enum_mode_from_tag(string(field.tag))
			if !valid_tag {
				append_error(p, .INVALID_FIELD_TYPE)
				return true
			}

			path := fmt.aprintf("%s%s%s", prefix, len(prefix) > 0 ? "." : "", field.name)
			defer delete_string(path, alloc)

			if register_type_keys(p, field.type, path, alloc, field_mode) do return true
		}

	case .Array:
		elem := base.variant.(reflect.Type_Info_Array).elem
		path := fmt.aprintf("%s[]", prefix)
		defer delete_string(path, alloc)

		return register_type_keys(p, elem, path, alloc, enum_mode)

	case .Slice:
		elem := base.variant.(reflect.Type_Info_Slice).elem
		path := fmt.aprintf("%s[]", prefix)
		defer delete_string(path, alloc)

		return register_type_keys(p, elem, path, alloc, enum_mode)

	case .Dynamic_Array:
		append_error(p, .INVALID_FIELD_TYPE)
		return true

	case:
		value_type, ok := serialization_type_from_info(base, enum_mode)
		if !ok {
			append_error(p, .INVALID_FIELD_TYPE)
			return true
		}

		for existing in p.data.keys {
			if existing.key == prefix {
				append_error(p, .DUPLICATE_KEY)
				return true
			}
		}

		append_key_definition(p, prefix, value_type, alloc)
	}

	return false
}

@(private = "file")
/*
Parses an array or slice index from the beginning of a path. Returns the parsed index,
number of consumed characters && whether parsing succeeded
*/
parse_path_index :: proc(path: string) -> (index, consumed: int, ok: bool) {
	if len(path) < 3 || path[0] != '[' do return

	end := strings.index_byte(path, ']')
	if end < 0 do return

	digits := path[1:end]
	if len(digits) == 0 do return

	value, valid := strconv.parse_int(digits, 10)
	if !valid || value < 0 do return

	return value, end + 1, true
}

@(private = "file")
validate_scalar :: proc(
	p: ^Parser,
	value: string,
	info: ^reflect.Type_Info,
	token_index: int,
	enum_mode: VALUE_TYPES = .ENUMS,
) -> (
	any_errors_encountered: bool,
) {
	if info == nil {
		append_error(p, .INVALID_FIELD_TYPE, token_index = token_index)
		return true
	}

	base := reflect.type_info_base(info)

	if reflect.underlying_type_kind(base.id) == .Enum {
		enum_info := base.variant.(reflect.Type_Info_Enum)

		#partial switch enum_mode {
		case .ENUMS:
			_, valid := reflect.enum_from_name_any(base.id, value)
			if !valid {
				append_error(p, .INVALID_VALUE, token_index = token_index)
				return true
			}
			return false

		case .ENUMV:
			backing_type := reflect.type_info_base(enum_info.base)
			_, supported := value_type_from_info(backing_type)

			if !supported {
				append_error(p, .INVALID_FIELD_TYPE, token_index = token_index)
				return true
			}

			return validate_scalar(p, value, backing_type, token_index)

		case:
			append_error(p, .INVALID_FIELD_TYPE, token_index = token_index)
			return true
		}
	}

	value_type, ok := value_type_from_info(base)
	if !ok {
		append_error(p, .INVALID_FIELD_TYPE, token_index = token_index)
		return true
	}

	#partial switch value_type {
	case .STRING:
		return false

	case .INT:
		_, valid := strconv.parse_int(value, 10)
		if !valid {
			append_error(p, .INVALID_VALUE, token_index = token_index)
			return true
		}

	case .I32:
		v, valid := strconv.parse_int(value, 10)
		if !valid {
			append_error(p, .INVALID_VALUE, token_index = token_index)
			return true
		}
		if v < int(math.min(i32)) || v > int(math.max(i32)) {
			append_error(p, .VALUE_OUT_OF_BOUNDS, token_index = token_index)
			return true
		}

	case .F32:
		_, valid := strconv.parse_f32(value)
		if !valid {
			append_error(p, .INVALID_VALUE, token_index = token_index)
			return true
		}

	case .BOOL:
		_, valid := strconv.parse_bool(value)
		if !valid {
			append_error(p, .INVALID_VALUE, token_index = token_index)
			return true
		}

	case .I64:
		_, valid := strconv.parse_i64(value)
		if !valid {
			append_error(p, .INVALID_VALUE, token_index = token_index)
			return true
		}

	case .F64:
		_, valid := strconv.parse_f64(value)
		if !valid {
			append_error(p, .INVALID_VALUE, token_index = token_index)
			return true
		}

	case .U8:
		v, valid := strconv.parse_uint(value, 10)
		if !valid {
			append_error(p, .INVALID_VALUE, token_index = token_index)
			return true
		}
		if v > uint(math.max(u8)) {
			append_error(p, .VALUE_OUT_OF_BOUNDS, token_index = token_index)
			return true
		}

	case .U32:
		v, valid := strconv.parse_u64(value)
		if !valid {
			append_error(p, .INVALID_VALUE, token_index = token_index)
			return true
		}
		if v > u64(math.max(u32)) {
			append_error(p, .VALUE_OUT_OF_BOUNDS, token_index = token_index)
			return true
		}

	case .U64:
		_, valid := strconv.parse_u64(value)
		if !valid {
			append_error(p, .INVALID_VALUE, token_index = token_index)
			return true
		}
	}

	return false
}

@(private = "file")
/*
Determines the number of slice elements required by the tokens matching the given path prefix.
Result is based on the highest referenced index
*/
slice_required_len :: proc(p: ^Parser, prefix: string) -> int {
	required_len := 0

	for token in p.data.tokens {
		if len(token.key) <= len(prefix) do continue
		if token.key[:len(prefix)] != prefix do continue

		suffix := token.key[len(prefix):]
		index, _, ok := parse_path_index(suffix)
		if !ok do continue

		required_len = max(required_len, index + 1)
	}

	return required_len
}

@(private = "file")
/*
Allocates and zero-initializes storage for a raw slice, updates the destination Raw_Slice,
and returns whether or not the allocation failed
*/
allocate_slice :: proc(
	dst: rawptr,
	elem_size: int,
	elem_align: int,
	count: int,
	alloc: mem.Allocator,
) -> bool {
	if dst == nil do return true

	if count == 0 {
		((^mem.Raw_Slice)(dst))^ = mem.Raw_Slice{}
		return false
	}

	bytes, err := mem.alloc_bytes(count * elem_size, elem_align, alloc)
	if err != nil || bytes == nil do return true

	mem.zero(raw_data(bytes), len(bytes))
	((^mem.Raw_Slice)(dst))^ = mem.Raw_Slice {
		data = raw_data(bytes),
		len  = count,
	}

	return false
}

@(private = "file")
/*
Recursively allocates and prepares slices within the target structure, Slice lengths are
inferred from the indices referenced by parsed tokens
*/
prepare_slices :: proc(
	p: ^Parser,
	info: ^reflect.Type_Info,
	dst: rawptr,
	prefix: string,
	alloc: mem.Allocator,
) -> bool {
	if info == nil do return true

	base := reflect.type_info_base(info)

	#partial switch reflect.underlying_type_kind(base.id) {
	case .Struct:
		for i in 0 ..< reflect.struct_field_count(base.id) {
			field := reflect.struct_field_at(base.id, i)

			field_prefix := fmt.aprintf("%s%s%s", prefix, len(prefix) > 0 ? "." : "", field.name)
			defer delete_string(field_prefix, alloc)

			field_dst: rawptr
			if dst != nil {
				field_dst = rawptr(uintptr(dst) + uintptr(field.offset))
			}

			if prepare_slices(p, field.type, field_dst, field_prefix, alloc) do return true
		}

	case .Array:
		array_info := base.variant.(reflect.Type_Info_Array)

		for i in 0 ..< array_info.count {
			elem_dst: rawptr
			if dst != nil do elem_dst = rawptr(uintptr(dst) + uintptr(i * array_info.elem_size))

			elem_prefix := fmt.aprintf("%s[%d]", prefix, i)
			defer delete_string(elem_prefix, alloc)

			if prepare_slices(p, array_info.elem, elem_dst, elem_prefix, alloc) do return true
		}

	case .Slice:
		slice_info := base.variant.(reflect.Type_Info_Slice)
		count := slice_required_len(p, prefix)

		if allocate_slice(dst, slice_info.elem_size, slice_info.elem.align, count, alloc) {
			append_error(p, .INVALID_FIELD_TYPE)
			return true
		}

		if count == 0 do return false

		slice := ((^mem.Raw_Slice)(dst))^

		for i in 0 ..< count {
			elem_dst := rawptr(uintptr(slice.data) + uintptr(i * slice_info.elem_size))

			elem_prefix := fmt.aprintf("%s[%d]", prefix, i)
			defer delete_string(elem_prefix, alloc)

			if prepare_slices(p, slice_info.elem, elem_dst, elem_prefix, alloc) do return true
		}

	case .Dynamic_Array:
		append_error(p, .INVALID_FIELD_TYPE)
		return true

	case:
		return false
	}

	return false
}

@(private = "file")
/*
Resolves a token key against the reflected target type. Validates the token value,
and (optionally) assigns it to the destination. Traverses nested structs, arrays && slices,
respecting enum field tags
*/
resolve_token :: proc(
	p: ^Parser,
	info: ^reflect.Type_Info,
	dst: rawptr,
	path: string,
	prefix: string,
	token: Token,
	token_index: int,
	assign: bool,
	alloc: mem.Allocator,
	enum_mode: VALUE_TYPES = .ENUMS,
) -> bool {
	if info == nil {
		append_error(p, .INVALID_KEY, token_index = token_index)
		return true
	}

	base := reflect.type_info_base(info)
	kind := reflect.underlying_type_kind(base.id)

	#partial switch kind {
	case .Struct:
		if len(path) == 0 {
			append_error(p, .INVALID_KEY, token_index = token_index)
			return true
		}

		path := path
		for len(path) > 0 && path[0] == '.' do path = path[1:]
		if len(path) == 0 {
			append_error(p, .INVALID_KEY, token_index = token_index)
			return true
		}

		end := len(path)
		for c, i in path {
			if c == '.' || c == '[' {
				end = i
				break
			}
		}

		field_name := path[:end]
		if len(field_name) == 0 {
			append_error(p, .INVALID_KEY, token_index = token_index)
			return true
		}

		field_found := false
		for i in 0 ..< reflect.struct_field_count(base.id) {
			field := reflect.struct_field_at(base.id, i)
			if field.name != field_name do continue

			field_found = true

			field_mode, valid_tag := enum_mode_from_tag(string(field.tag))
			if !valid_tag {
				append_error(p, .INVALID_FIELD_TYPE, token_index = token_index)
				return true
			}

			next_prefix := fmt.aprintf("%s%s%s", prefix, len(prefix) > 0 ? "." : "", field.name)
			defer delete_string(next_prefix, alloc)

			next_path := path[end:]
			if len(next_path) > 0 && next_path[0] == '.' do next_path = next_path[1:]

			field_dst: rawptr
			if dst != nil do field_dst = rawptr(uintptr(dst) + uintptr(field.offset))

			return resolve_token(
				p,
				field.type,
				field_dst,
				next_path,
				next_prefix,
				token,
				token_index,
				assign,
				alloc,
				field_mode,
			)
		}

		if !field_found {
			append_error(p, .INVALID_KEY, token_index = token_index)
			return true
		}

	case .Array:
		index, consumed, ok := parse_path_index(path)
		if !ok {
			append_error(p, .INVALID_KEY, token_index = token_index)
			return true
		}

		array_info := base.variant.(reflect.Type_Info_Array)
		if index >= array_info.count {
			append_error(p, .INVALID_KEY, token_index = token_index)
			return true
		}

		elem_dst: rawptr
		if dst != nil {
			elem_dst = rawptr(uintptr(dst) + uintptr(index * array_info.elem_size))
		}

		next_prefix := fmt.aprintf("%s[%d]", prefix, index)
		defer delete_string(next_prefix, alloc)

		return resolve_token(
			p,
			array_info.elem,
			elem_dst,
			path[consumed:],
			next_prefix,
			token,
			token_index,
			assign,
			alloc,
			enum_mode,
		)

	case .Slice:
		index, consumed, ok := parse_path_index(path)
		if !ok {
			append_error(p, .INVALID_KEY, token_index = token_index)
			return true
		}

		slice_info := base.variant.(reflect.Type_Info_Slice)
		elem_dst: rawptr

		if dst != nil {
			slice := ((^mem.Raw_Slice)(dst))^

			if index >= slice.len {
				append_error(p, .INVALID_KEY, token_index = token_index)
				return true
			}

			elem_dst = rawptr(uintptr(slice.data) + uintptr(index * slice_info.elem_size))
		}

		next_prefix := fmt.aprintf("%s[%d]", prefix, index)
		defer delete_string(next_prefix, alloc)

		return resolve_token(
			p,
			slice_info.elem,
			elem_dst,
			path[consumed:],
			next_prefix,
			token,
			token_index,
			assign,
			alloc,
			enum_mode,
		)

	case .Dynamic_Array:
		append_error(p, .INVALID_FIELD_TYPE, token_index = token_index)
		return true

	case:
		if len(path) != 0 {
			append_error(p, .INVALID_KEY, token_index = token_index)
			return true
		}

		if validate_scalar(p, token.value, base, token_index, enum_mode) do return true

		if assign {
			assign_scalar(dst, base, token.value, alloc, enum_mode)
		}

		return false
	}

	return true
}

@(private = "file")
/*
Converts a validated string into its corresponding primitive, or enum value && writes
it to the destination memory
*/
assign_scalar :: proc(
	dst: rawptr,
	info: ^reflect.Type_Info,
	value: string,
	alloc: mem.Allocator,
	enum_mode: VALUE_TYPES = .ENUMS,
) {
	if dst == nil || info == nil do return

	base := reflect.type_info_base(info)

	if reflect.underlying_type_kind(base.id) == .Enum {
		enum_info := base.variant.(reflect.Type_Info_Enum)

		#partial switch enum_mode {
		case .ENUMV:
			assign_scalar(dst, enum_info.base, value, alloc)

		case .ENUMS:
			enum_value, valid := reflect.enum_from_name_any(base.id, value)
			if !valid do return

			numeric_value := fmt.aprintf("%d", i64(enum_value))
			defer delete_string(numeric_value, alloc)

			assign_scalar(dst, enum_info.base, numeric_value, alloc)

		case:
			return
		}

		return
	}

	switch base.id {
	case typeid_of(string):
		((^string)(dst))^ = strings.clone(value, alloc)

	case typeid_of(int):
		v, _ := strconv.parse_int(value, 10)
		((^int)(dst))^ = v

	case typeid_of(i32):
		v, _ := strconv.parse_int(value, 10)
		((^i32)(dst))^ = i32(v)

	case typeid_of(f32):
		v, _ := strconv.parse_f32(value)
		((^f32)(dst))^ = v

	case typeid_of(bool):
		v, _ := strconv.parse_bool(value)
		((^bool)(dst))^ = v

	case typeid_of(i64):
		v, _ := strconv.parse_i64(value)
		((^i64)(dst))^ = v

	case typeid_of(f64):
		v, _ := strconv.parse_f64(value)
		((^f64)(dst))^ = v

	case typeid_of(u8):
		v, _ := strconv.parse_uint(value, 10)
		((^u8)(dst))^ = u8(v)

	case typeid_of(u32):
		v, _ := strconv.parse_u64(value)
		((^u32)(dst))^ = u32(v)

	case typeid_of(u64):
		v, _ := strconv.parse_u64(value)
		((^u64)(dst))^ = v
	}
}

/*
Registers Key_Definition for every supported field in the given Struct type
Appends an error if: target != Struct, or contains unsupported fields
Returns true if any errors were encountered
*/
register_struct_keys :: proc(
	p: ^Parser,
	$T: typeid,
	alloc: mem.Allocator = context.allocator,
) -> (
	any_errors_encountered: bool,
) {
	if reflect.underlying_type_kind(T) != .Struct {
		append_error(p, .INVALID_UNMARSHAL_TARGET)
		return true
	}

	info := reflect.type_info_base(type_info_of(T))
	if !is_supported_type(info) {
		append_error(p, .INVALID_FIELD_TYPE)
		return true
	}

	return register_type_keys(p, info, "", alloc)
}

/*
Reads the contents of a file into Parser.data.bytes, replacing any previously loaded bytes
Appends an error if the file does not exist, or cannot be read. Returns true on success
*/
read_bytes_into_parser :: proc(
	p: ^Parser,
	filepath: string,
	alloc: mem.Allocator = context.allocator,
) -> (
	any_errors_encountered: bool,
) {
	if len(p.data.bytes) > 0 do delete(p.data.bytes, alloc)

	if !os.exists(filepath) {
		append_error(p, .FILE_NOT_EXIST, 0)
		return true
	}

	b, e := os.read_entire_file_from_path(filepath, alloc)
	if e != nil {
		append_error(p, .FAILED_TO_READ, 0)
		return true
	}
	defer delete(b, alloc)
	if len(b) == 0 do return false

	p.data.bytes = make([]byte, len(b), alloc)
	l := copy(p.data.bytes, b[:])
	assert(l == len(p.data.bytes))

	return false
}

/*
Splits Parser.data.bytes into individual key/value tokens, using the configured delimeter
Appends errors for malformed lines, missing keys/values && tokenization failures
Replaces any previously generated tokens, and returns true if any errors were encountered
*/
tokenize_bytes :: proc(
	p: ^Parser,
	alloc: mem.Allocator = context.allocator,
) -> (
	any_errors_encountered: bool,
) {
	if len(p.data.tokens) > 0 {
		for &t in p.data.tokens do free_token(&t, alloc)
		delete(p.data.tokens)
	}
	if len(p.data.bytes) < 3 do return false

	found_err := false
	lines, l_err := strings.split(string(p.data.bytes), "\n", alloc)
	if l_err != nil {
		append_error(p, .FAILED_TO_SPLIT_LINES, line = 0)
		found_err = true
		return
	}
	defer delete(lines)

	tk := make([dynamic]Token, alloc)
	defer delete(tk)

	for line, i in lines {
		if len(strings.trim_space(line)) == 0 do continue

		if !strings.contains(line, p.data.kv_delimiter) {
			append_error(p, .MISSING_DELIMETER, line = i + 1)
			found_err = true
			continue
		}

		if strings.count(line, p.data.kv_delimiter) > 1 {
			append_error(p, .INVALID_DELIMETER_USAGE, line = i + 1)
			found_err = true
			continue
		}

		t, t_err := strings.split(line, p.data.kv_delimiter, alloc)
		if t_err != nil {
			append_error(p, .FAILED_TO_SPLIT_TOKEN, line = i + 1)
			found_err = true
			continue
		}
		defer delete(t)

		if len(strings.trim_space(t[0])) == 0 && len(strings.trim_space(t[1])) == 0 {
			append_error(p, .MISSING_KEY_AND_VALUE, line = i + 1)
			found_err = true
			continue
		} else {
			if len(strings.trim_space(t[0])) == 0 {
				append_error(p, .MISSING_KEY, line = i + 1)
				found_err = true
				continue
			}

			if len(strings.trim_space(t[1])) == 0 {
				append_error(p, .MISSING_VALUE, line = i + 1)
				found_err = true
				continue
			}
		}

		append(
			&tk,
			Token {
				key = strings.clone(strings.trim_space(t[0])),
				value = strings.clone(strings.trim_space(t[1])),
				line = i + 1,
			},
		)
	}

	p.data.tokens = make([]Token, len(tk), alloc)
	tc := copy(p.data.tokens, tk[:])
	if tc != len(tk) {
		append_error(p, .FAILED_TO_COPY_TOKENS_TO_PARSER)
		found_err = true
	}

	return found_err
}

/*
Validates parsed tokens against the reflected fields of the given Struct type
Checks token paths, duplicate keys, value types, enum types && numeric bounds
Appends error to the Parser, and returns true if any validation errors occur
*/
validate_tokens :: proc(
	p: ^Parser,
	$T: typeid,
	alloc: mem.Allocator = context.allocator,
) -> (
	any_errors_encountered: bool,
) {
	if reflect.underlying_type_kind(T) != .Struct {
		append_error(p, .INVALID_UNMARSHAL_TARGET)
		return true
	}

	info := reflect.type_info_base(type_info_of(T))
	if !is_supported_type(info) {
		append_error(p, .INVALID_FIELD_TYPE)
		return true
	}

	found_err := false
	for token, i in p.data.tokens {
		for previous in 0 ..< i {
			if p.data.tokens[previous].key == token.key {
				append_error(p, .DUPLICATE_KEY, token_index = i)
				found_err = true
				break
			}
		}

		if resolve_token(p, info, nil, token.key, "", token, i, false, alloc) do found_err = true
	}

	return found_err
}

/*
Unmarshals parsed tokens into the supplied Struct instance
Optionally, validates token paths && values before assignment
Automatically prepares slives using the indices referenced by tokens
Appends errors to the Parser, and returns true if any errors occur
*/
unmarshal :: proc(
	p: ^Parser,
	out: ^$T,
	validate_keys: bool = true,
	alloc: mem.Allocator = context.allocator,
) -> (
	any_errors_encountered: bool,
) {
	if reflect.underlying_type_kind(T) != .Struct {
		append_error(p, .INVALID_UNMARSHAL_TARGET)
		return true
	}

	info := reflect.type_info_base(type_info_of(T))
	if !is_supported_type(info) {
		append_error(p, .INVALID_FIELD_TYPE)
		return true
	}

	if validate_keys do if validate_tokens(p, T, alloc) do return true

	if prepare_slices(p, info, rawptr(out), "", alloc) do return true

	found_err := false
	for token, i in p.data.tokens do if resolve_token(p, info, rawptr(out), token.key, "", token, i, true, alloc) do found_err = true
	return found_err
}

get_key_count :: proc(p: ^Parser) -> int {return len(p.data.keys)}

get_byte_count :: proc(p: ^Parser) -> int {return len(p.data.bytes)}

get_token_count :: proc(p: ^Parser) -> int {return len(p.data.tokens)}

get_error_count :: proc(p: ^Parser) -> int {return len(p.data.errors)}

/*
Returns shallow copy of Parser.data.tokens, or nil if no tokens exist
Must free by calling delete() on the returned Slice
*/
get_cloned_token_array :: proc(p: ^Parser, alloc: mem.Allocator = context.allocator) -> []Token {
	if len(p.data.tokens) == 0 do return nil
	t := make([]Token, len(p.data.tokens[:]), alloc)
	i := copy_slice(t, p.data.tokens[:])
	if i != len(p.data.tokens) do fmt.panicf("Failed to copy all Parser tokens, missing: %d", len(p.data.tokens) - i)
	return t
}

/*
Returns shallow copy of Parser.data.errors, or nil if no tokens exist
Must free by calling delete() on the returned Slice
*/
get_cloned_error_array :: proc(p: ^Parser, alloc: mem.Allocator = context.allocator) -> []Error {
	if len(p.data.errors) == 0 do return nil
	e := make([]Error, len(p.data.errors), alloc)
	i := copy_slice(e, p.data.errors[:])
	if i != len(p.data.errors) do fmt.panicf("Failed to copy all Parser errors, missing: %d", len(p.data.errors) - i)
	return e
}

/*
Writes Parser.data.errors to specified path
Creates missing parent directory, when possible
Panics if directory creation || or file write fails
*/
dump_parser_errors_to_file :: proc(p: ^Parser, filepath: string) {
	if !os.exists(os.dir(filepath)) do if e := os.make_directory_all(os.dir(filepath)); e != nil do fmt.panicf("Failed to create parent directory for output file: %s", filepath)

	t := make([dynamic]string)
	defer {
		for s in t do delete_string(s)
		delete(t)
	}

	for e in p.data.errors {
		s: string
		if e.line == 0 && e.token_index == 0 {
			s = fmt.aprintf("%v", e.type)
		} else {
			v :=
				e.line == 0 ? fmt.aprintf("[Token Index: %d]", e.token_index) : fmt.aprintf("[Line Number: %d]", e.line)
			s = fmt.aprintf("%v %s", e.type, v)
			delete_string(v)
		}
		append(&t, s)
	}

	str := strings.join(t[:], "\n")
	defer delete(str)

	e := os.write_entire_file_from_string(filepath, str)
	if e != nil do fmt.panicf("Failed to write errors to %s", filepath)
}
