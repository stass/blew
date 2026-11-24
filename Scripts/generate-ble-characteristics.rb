#!/usr/bin/env ruby
# frozen_string_literal: true

# generate-ble-characteristics.rb <sig-dir> <output-file>
#
# Reads assigned_numbers/uuids/characteristic_uuids.yaml and gss/*.yaml from
# <sig-dir>, resolves struct-typed fields recursively via \autoref annotations,
# and writes a Swift source file containing the full GATT characteristic database.

require "yaml"

abort "Usage: generate-ble-characteristics.rb <sig-dir> <output-file>" unless ARGV.length == 2

SIG_DIR     = ARGV[0]
OUTPUT_FILE = ARGV[1]

# ---------------------------------------------------------------------------
# Type mapping
# ---------------------------------------------------------------------------

SWIFT_TYPES = {
  "uint8"       => ".uint8",
  "uint16"      => ".uint16",
  "uint24"      => ".uint24",
  "uint32"      => ".uint32",
  "uint48"      => ".uint48",
  "uint64"      => ".uint64",
  "sint8"       => ".sint8",
  "sint16"      => ".sint16",
  "sint32"      => ".sint32",
  "boolean[8]"  => ".boolean8",
  "boolean[16]" => ".boolean16",
  "boolean[24]" => ".boolean24",
  "boolean[32]" => ".boolean32",
  "medfloat16"  => ".medfloat16",
  "medfloat32"  => ".medfloat32",
  "utf8s"       => ".utf8s",
}.freeze

# ---------------------------------------------------------------------------
# Field attribute helpers
# ---------------------------------------------------------------------------

# Returns byte count of the field when present.
#   N > 0  fixed N bytes
#  -1      variable length (rest of data)
#  -2      variable-length array (rest of data, typed elements)
def parse_size(size_str)
  s = size_str.to_s.strip
  case s
  when /\A(\d+)\z/         then $1.to_i
  when "variable"          then -1
  when /\A0 or (\d+)\z/    then $1.to_i
  when /\A0 or n\*/        then -2
  when /\A\d+ or (\d+)\z/  then $1.to_i  # "1 or 2" etc. — use the larger
  else                          -1
  end
end

def conditional?(size_str)
  size_str.to_s.strip.start_with?("0 or ")
end

# Types whose value a presence condition can test: the decoder reads them as
# a little-endian unsigned integer.
CONTROL_TYPES = %w[uint8 uint16 uint24 uint32 boolean[8] boolean[16] boolean[24] boolean[32]].freeze

def generation_error(message)
  abort "generate-ble-characteristics.rb: #{message}"
end

# Parses one "Present if ..." sentence into conditions. Each condition is a
# hash with :kind (:bit, :equals, :not_equals or :external), and :field (the
# name of the field the condition reads) for every kind but :external.
# Returns nil when the sentence is in none of the phrasings the GSS uses.
def parse_presence(sentence)
  case sentence
  when /\APresent if bit (\d+) of (?:the )?(.+?) field is set to ([01])\z/
    [{ kind: :bit, field: $2, bit: $1.to_i, set: $3 == "1" }]
  when /\APresent if bits (\d+) and (\d+) of (?:the )?(.+?) field are set to ([01])\z/
    field, set = $3, $4 == "1"
    [$1, $2].map { |bit| { kind: :bit, field: field, bit: bit.to_i, set: set } }
  when /\APresent if value of (?:the )?(.+?) field is (\d+)\z/
    [{ kind: :equals, field: $1, value: $2.to_i }]
  when /\APresent if (?:the )?(.+?) field is not (\d+)(?: \([^()]*\))?\z/
    [{ kind: :not_equals, field: $1, value: $2.to_i }]
  when /\APresent if (.+ in .+ characteristic is set to [01])\z/
    [{ kind: :external, text: $1 }]
  when /\AThe presence of this field is defined by (.+)\z/
    [{ kind: :external, text: "#{$1} defines it" }]
  end
end

# Returns the presence conditions of a field from its GSS description; all
# of them must hold for the field to be present. Every "Present if" sentence
# must parse, every condition must read an earlier field of an integer type
# and fit in it, and a field sized "0 or N" must have a condition. Anything
# else stops the generation, so no conditional field is decoded as always
# present. (Where an :external field may be is checked on the flattened
# field list, by check_external_last.)
def presence_conditions(field, parent_id, earlier)
  name = field["field"]
  where = "#{parent_id}: field '#{name}'"
  # The build runs the system Ruby, which can be 2.6: no filter_map.
  sentences = field["description"].to_s.lines.map(&:strip).map do |line|
    i = line =~ /present if|presence of this field is defined by/i
    i && line[i..-1].sub(/\.\z/, "").sub(/\Apresence/, "The presence")
  end.compact
  conditions = sentences.flat_map do |sentence|
    parse_presence(sentence) or
      generation_error("#{where}: unrecognised presence condition \"#{sentence}\"")
  end
  if conditions.empty? && conditional?(field["size"])
    generation_error("#{where} is sized \"#{field['size']}\" but states no presence condition")
  end
  conditions.each do |c|
    next if c[:kind] == :external
    control = earlier.reverse.find { |f| f["field"] == c[:field] } or
      generation_error("#{where}: condition reads '#{c[:field]}', which is not an earlier field")
    CONTROL_TYPES.include?(control["type"].to_s) or
      generation_error("#{where}: condition reads '#{c[:field]}' of type #{control['type']}, not an integer")
    bits = 8 * parse_size(control["size"])
    if c[:kind] == :bit && c[:bit] >= bits
      generation_error("#{where}: bit #{c[:bit]} is outside the #{bits}-bit field '#{c[:field]}'")
    end
    if c[:kind] != :bit && c[:value] >= 2**bits
      generation_error("#{where}: value #{c[:value]} does not fit the #{bits}-bit field '#{c[:field]}'")
    end
  end
  conditions
end

# Nothing in the value says whether a field with an :external condition is
# there, so it can only be the last field of the flattened list: present
# when bytes remain.
def check_external_last(identifier, fields)
  fields[0...-1].each do |f|
    next unless f[:conditions].any? { |c| c[:kind] == :external }
    generation_error("#{identifier}: field '#{f[:name]}' has a condition outside the value but is not last")
  end
end

# Extracts a GSS identifier from the first \autoref that has no /field/ suffix.
# Returns nil when absent or when the reference is a self-reference.
def autoref_id(desc)
  m = desc.to_s.match(/\\autoref\{sec:(org\.bluetooth\.characteristic\.[^\/}]+)\}/)
  m && m[1]
end

def make_field(name:, type:, size:, conditions:)
  { name: name, type: type, size: size, conditions: conditions }
end

# ---------------------------------------------------------------------------
# Recursive struct resolution
# ---------------------------------------------------------------------------

# Resolves a single struct field, either by inlining the referenced
# characteristic's fields (prefixed with field_name) or falling back to opaque.
# Inlined fields keep their own conditions, with the field names they read
# prefixed the same way, and also get the struct field's conditions.
def resolve_struct_field(field_name, desc, size, conditions,
                         parent_id, gss_by_id, visiting)
  ref_id        = autoref_id(desc)
  full_visiting = visiting + [parent_id]
  opaque        = [make_field(name: field_name, type: ".opaque", size: size, conditions: conditions)]

  if ref_id.nil?
    $stderr.puts "warning: #{parent_id}: '#{field_name}' struct has no resolvable \\autoref"
    opaque
  elsif full_visiting.include?(ref_id)
    $stderr.puts "warning: #{parent_id}: '#{field_name}' struct → circular ref to #{ref_id}"
    opaque
  elsif !gss_by_id.key?(ref_id)
    $stderr.puts "warning: #{parent_id}: '#{field_name}' struct → #{ref_id} not in GSS index"
    opaque
  else
    resolve_fields(ref_id, gss_by_id, full_visiting).map do |f|
      inner = f[:conditions].map do |c|
        c[:kind] == :external ? c : c.merge(field: "#{field_name}.#{c[:field]}")
      end
      make_field(name: "#{field_name}.#{f[:name]}", type: f[:type], size: f[:size],
                 conditions: conditions + inner)
    end
  end
end

# Resolves one raw YAML field entry into an array of flat field hashes.
def resolve_one_field(field, parent_id, earlier, gss_by_id, visiting)
  name       = field["field"]
  type_str   = field["type"].to_s
  desc       = field["description"].to_s
  size       = parse_size(field["size"])
  conditions = presence_conditions(field, parent_id, earlier)

  if type_str == "struct"
    resolve_struct_field(name, desc, size, conditions, parent_id, gss_by_id, visiting)
  elsif SWIFT_TYPES.key?(type_str)
    [make_field(name: name, type: SWIFT_TYPES[type_str], size: size, conditions: conditions)]
  else
    # Arrays (uint16[n] etc.), gatt_uuid, bit-field types (uint2), unknown
    [make_field(name: name, type: ".opaque", size: size, conditions: conditions)]
  end
end

# Returns an array of fully-resolved flat field hashes for a characteristic.
def resolve_fields(identifier, gss_by_id, visiting = [])
  char = gss_by_id[identifier]
  if char.nil?
    $stderr.puts "warning: #{identifier} not found in GSS index"
    [make_field(name: identifier, type: ".opaque", size: -1, conditions: [])]
  elsif char["size_in_bits"]
    # Bit-packed structure — cannot decode at byte granularity
    [make_field(name: char["name"] || identifier, type: ".opaque", size: -1, conditions: [])]
  else
    structure = char["structure"] || []
    structure.each_with_index.flat_map do |field, i|
      resolve_one_field(field, identifier, structure[0...i], gss_by_id, visiting)
    end
  end
end

# ---------------------------------------------------------------------------
# Swift code generation helpers
# ---------------------------------------------------------------------------

def esc_swift(str)
  str.to_s.gsub("\\", "\\\\").gsub('"', '\\"')
end

# Strips LaTeX markup and the boilerplate "structure is defined below" sentence,
# then returns the first meaningful line as a single clean description string.
def clean_description(raw)
  raw.to_s
     .split("\n")
     .map(&:strip)
     .reject { |l| l.empty? || l.match?(/The structure of this characteristic is defined/) }
     .first
     .to_s
     .gsub(/\\[A-Za-z]+(\{[^}]*\})?/, "")
     .strip
end

def condition_swift(c)
  case c[:kind]
  when :bit        then ".bit(field: \"#{esc_swift(c[:field])}\", bit: #{c[:bit]}, set: #{c[:set]})"
  when :equals     then ".equals(field: \"#{esc_swift(c[:field])}\", value: #{c[:value]})"
  when :not_equals then ".notEquals(field: \"#{esc_swift(c[:field])}\", value: #{c[:value]})"
  when :external   then ".external(\"#{esc_swift(c[:text])}\")"
  end
end

def field_swift(f)
  base = ".init(name: \"#{esc_swift(f[:name])}\", type: #{f[:type]}, size: #{f[:size]}"
  if f[:conditions].empty?
    "#{base})"
  else
    "#{base}, conditions: [#{f[:conditions].map { |c| condition_swift(c) }.join(', ')}])"
  end
end

def char_swift(uuid, char, fields)
  name = esc_swift(char["name"].to_s)
  desc = esc_swift(clean_description(char["description"]))
  inner = fields.map { |f| "                #{field_swift(f)}" }.join(",\n")
  fields_literal = inner.empty? ? "[]" : "[\n#{inner}\n            ]"
  [
    "        \"#{uuid}\": .init(",
    "            name: \"#{name}\",",
    "            description: \"#{desc}\",",
    "            fields: #{fields_literal}",
    "        )"
  ].join("\n")
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

UUIDS_FILE = File.join(SIG_DIR, "assigned_numbers", "uuids", "characteristic_uuids.yaml")
GSS_FILES  = Dir.glob(File.join(SIG_DIR, "gss", "*.yaml"))

if !File.file?(UUIDS_FILE) || GSS_FILES.empty?
  generation_error("no Bluetooth SIG data in #{SIG_DIR} (#{UUIDS_FILE} and gss/*.yaml). " \
                   "It is a git submodule: run `git submodule update --init` in the blew checkout.")
end

gss_by_id = GSS_FILES.each_with_object({}) do |path, idx|
  char = YAML.safe_load(File.read(path, encoding: "utf-8"))["characteristic"] or
    generation_error("#{path} has no top-level 'characteristic'")
  idx[char["identifier"]] = char
end

uuid_map = YAML.safe_load(File.read(UUIDS_FILE, encoding: "utf-8")).fetch("uuids")
              .each_with_object({}) do |entry, acc|
                acc[format("%04X", entry["uuid"])] = entry["id"]
              end

db_entries = uuid_map
  .select { |_uuid, identifier| gss_by_id.key?(identifier) }
  .map do |uuid, identifier|
    fields = resolve_fields(identifier, gss_by_id)
    check_external_last(identifier, fields)
    [uuid, gss_by_id[identifier], fields]
  end
  .sort_by { |uuid, _| uuid }
  .map { |uuid, char, fields| char_swift(uuid, char, fields) }
  .join(",\n")

generation_error("no characteristic in #{UUIDS_FILE} has a GSS definition") if db_entries.empty?

output = <<~SWIFT
  // BLECharacteristics.generated.swift
  // Auto-generated by Scripts/generate-ble-characteristics.rb from the Bluetooth SIG GSS.
  // Source: https://bitbucket.org/bluetooth-SIG/public.git
  // Do not edit manually -- rebuild to regenerate.

  enum GATTCharacteristicDB {
      enum FieldType {
          case uint8, uint16, uint24, uint32, uint48, uint64
          case sint8, sint16, sint32
          case boolean8, boolean16, boolean24, boolean32
          case medfloat16, medfloat32
          case utf8s
          case opaque
      }

      /// When a conditional field is present. `field` names an earlier
      /// field of the same characteristic, read as an unsigned integer.
      enum Condition {
          /// Bit `bit` of `field` is 1 when `set`, 0 otherwise.
          case bit(field: String, bit: Int, set: Bool)
          case equals(field: String, value: UInt64)
          case notEquals(field: String, value: UInt64)
          /// Decided outside this value (the text says by what); the field
          /// is the last one and is present when its bytes are.
          case external(String)
      }

      struct Field {
          let name: String
          let type: FieldType
          let size: Int
          /// All must hold for the field to be present; empty means always.
          let conditions: [Condition]

          init(name: String, type: FieldType, size: Int, conditions: [Condition] = []) {
              self.name = name
              self.type = type
              self.size = size
              self.conditions = conditions
          }
      }

      struct Characteristic {
          let name: String
          let description: String
          let fields: [Field]
      }

      static let db: [String: Characteristic] = [
  #{db_entries}
      ]
  }
SWIFT

File.write(OUTPUT_FILE, output)
n_chars = db_entries.scan(/^\s+"[0-9A-F]{4}"/).size
$stderr.puts "Generated #{OUTPUT_FILE} (#{n_chars} characteristics from #{uuid_map.size} UUIDs)"
