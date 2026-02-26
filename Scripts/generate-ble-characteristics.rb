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

# Returns [flagBit, flagSet] from description text.
# flagSet == true  means "field is present when the bit is 1".
# Returns [-1, true] when no Flags condition is found.
def flag_condition(desc)
  m = desc.to_s.match(/Present if bit (\d+) of Flags field is set to ([01])/)
  m ? [m[1].to_i, m[2] == "1"] : [-1, true]
end

# Extracts a GSS identifier from the first \autoref that has no /field/ suffix.
# Returns nil when absent or when the reference is a self-reference.
def autoref_id(desc)
  m = desc.to_s.match(/\\autoref\{sec:(org\.bluetooth\.characteristic\.[^\/}]+)\}/)
  m && m[1]
end

def make_field(name:, type:, size:, flag_bit:, flag_set:)
  { name: name, type: type, size: size, flag_bit: flag_bit, flag_set: flag_set }
end

# ---------------------------------------------------------------------------
# Recursive struct resolution
# ---------------------------------------------------------------------------

# Resolves a single struct field, either by inlining the referenced
# characteristic's fields (prefixed with field_name) or falling back to opaque.
def resolve_struct_field(field_name, desc, size, flag_bit, flag_set,
                         parent_id, gss_by_id, visiting)
  ref_id        = autoref_id(desc)
  full_visiting = visiting + [parent_id]

  if ref_id.nil?
    $stderr.puts "warning: #{parent_id}: '#{field_name}' struct has no resolvable \\autoref"
    [make_field(name: field_name, type: ".opaque", size: size,
                flag_bit: flag_bit, flag_set: flag_set)]
  elsif full_visiting.include?(ref_id)
    $stderr.puts "warning: #{parent_id}: '#{field_name}' struct → circular ref to #{ref_id}"
    [make_field(name: field_name, type: ".opaque", size: size,
                flag_bit: flag_bit, flag_set: flag_set)]
  elsif !gss_by_id.key?(ref_id)
    $stderr.puts "warning: #{parent_id}: '#{field_name}' struct → #{ref_id} not in GSS index"
    [make_field(name: field_name, type: ".opaque", size: size,
                flag_bit: flag_bit, flag_set: flag_set)]
  else
    resolve_fields(ref_id, gss_by_id, full_visiting).map do |f|
      make_field(
        name:     "#{field_name}.#{f[:name]}",
        type:     f[:type],
        size:     f[:size],
        # Propagate outer flag condition to inner unconditional fields only
        flag_bit: flag_bit != -1 && f[:flag_bit] == -1 ? flag_bit : f[:flag_bit],
        flag_set: flag_bit != -1 && f[:flag_bit] == -1 ? flag_set : f[:flag_set]
      )
    end
  end
end

# Resolves one raw YAML field entry into an array of flat field hashes.
def resolve_one_field(field, parent_id, gss_by_id, visiting)
  name     = field["field"]
  type_str = field["type"].to_s
  desc     = field["description"].to_s
  size_str = field["size"].to_s
  size     = parse_size(size_str)
  cond     = conditional?(size_str)
  flag_bit, flag_set = cond ? flag_condition(desc) : [-1, true]

  if type_str == "struct"
    resolve_struct_field(name, desc, size, flag_bit, flag_set,
                         parent_id, gss_by_id, visiting)
  elsif SWIFT_TYPES.key?(type_str)
    [make_field(name: name, type: SWIFT_TYPES[type_str], size: size,
                flag_bit: flag_bit, flag_set: flag_set)]
  else
    # Arrays (uint16[n] etc.), gatt_uuid, bit-field types (uint2), unknown
    [make_field(name: name, type: ".opaque", size: size,
                flag_bit: flag_bit, flag_set: flag_set)]
  end
end

# Returns an array of fully-resolved flat field hashes for a characteristic.
def resolve_fields(identifier, gss_by_id, visiting = [])
  char = gss_by_id[identifier]
  if char.nil?
    $stderr.puts "warning: #{identifier} not found in GSS index"
    [make_field(name: identifier, type: ".opaque", size: -1, flag_bit: -1, flag_set: true)]
  elsif char["size_in_bits"]
    # Bit-packed structure — cannot decode at byte granularity
    [make_field(name: char["name"] || identifier, type: ".opaque", size: -1,
                flag_bit: -1, flag_set: true)]
  else
    (char["structure"] || []).flat_map do |field|
      resolve_one_field(field, identifier, gss_by_id, visiting)
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

def field_swift(f)
  base = ".init(name: \"#{esc_swift(f[:name])}\", type: #{f[:type]}, size: #{f[:size]}"
  if f[:flag_bit] == -1
    "#{base})"
  else
    "#{base}, flagBit: #{f[:flag_bit]}, flagSet: #{f[:flag_set]})"
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

gss_by_id = Dir.glob(File.join(SIG_DIR, "gss", "*.yaml"))
               .each_with_object({}) do |path, idx|
                 char = YAML.safe_load(File.read(path))["characteristic"]
                 idx[char["identifier"]] = char
               end

uuid_map = YAML.safe_load(
  File.read(File.join(SIG_DIR, "assigned_numbers", "uuids", "characteristic_uuids.yaml"))
).fetch("uuids")
              .each_with_object({}) do |entry, acc|
                acc[format("%04X", entry["uuid"])] = entry["id"]
              end

db_entries = uuid_map
  .select { |_uuid, identifier| gss_by_id.key?(identifier) }
  .map do |uuid, identifier|
    [uuid, gss_by_id[identifier], resolve_fields(identifier, gss_by_id)]
  end
  .sort_by { |uuid, _| uuid }
  .map { |uuid, char, fields| char_swift(uuid, char, fields) }
  .join(",\n")

output = <<~SWIFT
  // BLECharacteristics.generated.swift
  // Auto-generated by Scripts/generate-ble-characteristics.rb from the Bluetooth SIG GSS.
  // Source: https://bitbucket.org/bluetooth-SIG/public.git
  // Do not edit manually -- rebuild to regenerate.

  enum GATTCharacteristicDB {
      enum FieldType {
          case uint8, uint16, uint24, uint32, uint48, uint64
          case sint8, sint16, sint32
          case boolean8, boolean16, boolean32
          case medfloat16, medfloat32
          case utf8s
          case opaque
      }

      struct Field {
          let name: String
          let type: FieldType
          let size: Int
          let flagBit: Int
          let flagSet: Bool

          init(name: String, type: FieldType, size: Int, flagBit: Int = -1, flagSet: Bool = true) {
              self.name = name
              self.type = type
              self.size = size
              self.flagBit = flagBit
              self.flagSet = flagSet
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
