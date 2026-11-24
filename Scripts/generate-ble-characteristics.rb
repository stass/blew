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
  "sint24"      => ".sint24",
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

# ---------------------------------------------------------------------------
# Scale and unit
# ---------------------------------------------------------------------------

# Integer types the decoder can scale, with their width in bits and whether
# they are signed.
INTEGER_TYPES = {
  "uint8" => [8, false], "uint16" => [16, false], "uint24" => [24, false],
  "uint32" => [32, false], "uint48" => [48, false], "uint64" => [64, false],
  "sint8" => [8, true], "sint16" => [16, true], "sint24" => [24, true],
  "sint32" => [32, true],
}.freeze
FLOAT_TYPES = %w[medfloat16 medfloat32].freeze

# The GSS states the scale of a numeric field as "Represented values: M = 1,
# d = -2, b = 0": the value is raw * M * 10^d * 2^b. The vendored files
# write it with or without the "Represented values:" prefix, with "and"
# before b (Blood Pressure Measurement), with a space after a minus sign
# ("d = - 7") or none after an equals sign ("b =0"), and with a trailing
# period. A line that mentions M or "Represented values" in any other way
# stops the generation.
SCALE_MENTION = /Represented values|\bM\s*=/.freeze
SCALE_PATTERN = /\A(?:Represented values:\s*)?M\s*=\s*(-?\s*\d+),\s*d\s*=\s*(-?\s*\d+),\s*(?:and\s+)?b\s*=\s*(-?\s*\d+)\s*\.?\z/.freeze

# Returns the scale a field's description states, as { m:, d:, b: }, or nil
# when it states none. A field may state one scale.
def stated_scale(field, where)
  lines = field["description"].to_s.lines.map(&:strip).select { |l| l =~ SCALE_MENTION }
  generation_error("#{where} states #{lines.size} scales") if lines.size > 1
  return nil if lines.empty?
  m = SCALE_PATTERN.match(lines[0]) or
    generation_error("#{where}: unrecognised scale \"#{lines[0]}\"")
  m_value, d, b = m.captures.map { |s| s.delete(" ").to_i }
  # The GSS states no M below 1; one would need a decision on rounding
  # and sign that nothing here has made.
  generation_error("#{where}: scale with M = #{m_value}") if m_value < 1
  { m: m_value, d: d, b: b }
end

# Returns the org.bluetooth.unit identifiers a field's description names,
# in order and without repeats. The GSS writes them after "Unit:" or
# "Base Unit:", sometimes on the next line, sometimes with a space after
# "org.bluetooth.unit." and a trailing period or semicolon.
def stated_units(field)
  field["description"].to_s
       .scan(/org\.bluetooth\.unit\.\s*([A-Za-z0-9_.]*[A-Za-z0-9_])/)
       .map { |(id)| "org.bluetooth.unit.#{id}" }
       .uniq
end

UNITLESS = "org.bluetooth.unit.unitless"

# Fields whose stated scale contradicts their own description. Neither can
# be chosen from the GSS, so these are shown raw, with no unit. The
# generation stops when an entry's scale changes or its field is gone, so an
# entry is removed once the GSS is corrected.
CONTRADICTED_SCALES = {
  # "Unit is volt with a resolution of 1/64V", which is b = -6.
  "org.bluetooth.characteristic.high_voltage: field 'High Voltage'" => { m: 1, d: 0, b: 6 },
  # "Unit is meter with a resolution of 1 m", which is d = 0.
  "org.bluetooth.characteristic.activity_goal: field 'Distance'" => { m: 1, d: 1, b: 0 },
  # A uint8 with "Minimum: -12.8", which only a sint8 can hold.
  "org.bluetooth.characteristic.recipe_parameters: field 'Temperature Gradient'" => { m: 1, d: -1, b: 0 },
}.freeze
CONTRADICTED_SCALES_SEEN = []

# The GSS states a special value of an integer field as "A value of 0x8000
# represents "value is not known"", with straight, curly or no quotes,
# "A raw value of", a decimal value ("A value of 255 means drift is
# unknown"), "represents:", "indicates" or "means", and a trailing period.
SPECIAL_MENTION = /\bvalue of (?:0x\h+|-?\d+)\b.*\b(?:represents|indicates|means)\b/i.freeze
SPECIAL_PATTERN = /\A(?:A|The|The special) (?:raw )?value of (0x\h+|-?\d+)(?: for [^:]+?)?:? (?:represents|indicates|means):?\s*(.+?)\.?\z/.freeze
QUOTES = "\"'\u2018\u2019\u201C\u201D"

# Returns the special values an integer field of `bits` bits states, as
# { raw unsigned bit pattern => text }. A line that pairs a hex value with
# "represents" or "indicates" in any other form stops the generation.
def special_values(field, bits, where)
  # One sentence at a time: some lines hold several (date_time.yaml's Year).
  field["description"].to_s.lines.flat_map { |l| l.strip.split(/(?<=\.)\s+/) }
       .select { |l| l =~ SPECIAL_MENTION }
       .each_with_object({}) do |line, acc|
    m = SPECIAL_PATTERN.match(line) or
      generation_error("#{where}: unrecognised special value \"#{line}\"")
    raw = m[1].start_with?("0x") ? m[1].to_i(16) : m[1].to_i
    raw += 2**bits if raw < 0 # a signed value, as its bit pattern
    text = m[2].sub(/\A[#{QUOTES}]+/, "").sub(/[#{QUOTES}]+\z/, "")
    if raw < 0 || raw >= 2**bits
      generation_error("#{where}: special value #{m[1]} does not fit #{bits} bits")
    end
    generation_error("#{where}: special value #{m[1]} stated twice") if acc.key?(raw)
    acc[raw] = text
  end
end

# The assigned units, by identifier, with the name blew prints: the text in
# the outer parentheses of units.yaml's name ("thermodynamic temperature
# (degree Celsius)" is "degree Celsius"), the name without its parentheses
# when they hold the rest of the unit ("step (per minute)" is "step per
# minute"), or the whole name ("percentage").
def load_unit_names(path)
  YAML.safe_load(File.read(path, encoding: "utf-8")).fetch("uuids").each_with_object({}) do |u, acc|
    name = u["name"]
    m = /\A([^(]*)\((.*)\)\z/.match(name)
    acc[u["id"]] = if m.nil? then name
                   elsif m[2].start_with?("per ") then "#{m[1]}#{m[2]}"
                   else m[2]
                   end
  end
end

# Returns { scale:, unit:, specials: } for a field of GSS type type_str: the
# scale the decoder applies (nil for none), the unit it names after the
# value ({ id:, name: } or nil) and the special values it shows as text.
# Every field's scale statement is checked, whatever its type.
#
# - Only numeric fields get any of these. Arrays, structs and other opaque
#   types are shown as hex.
# - A unit must be in assigned_numbers/uuids/units.yaml. The GSS also names
#   identifiers that are not, some with the wrong dimension (Luminous Energy
#   names lumen_per_hour for lumen hours); those fields get no unit.
# - A field that names two units (mmHg or kPa, kilograms or litres) has
#   its unit chosen by a flag, so it gets no unit; an integer field that
#   also states a scale stops the generation, as the scale may hold for
#   one unit only.
# - "unitless" is no unit.
# - An integer field gets its unit only with a scale: without one the GSS
#   gives the raw-to-value mapping in prose, if at all (Time Exponential 8
#   is 1.1^(N-64) seconds), so the raw number is shown alone.
# - A float (SFLOAT, FLOAT) carries its own exponent. The GSS gives one a
#   scale only to say it counts a multiple of the base unit (kPa of the
#   base unit pascal); blew shows the float as sent, so such a field gets
#   neither the scale nor the base unit. A float with the identity scale
#   keeps its unit. Its special values are the IEEE 11073 ones.
# - The scale of an integer field must not overflow the decoder's 64-bit
#   arithmetic for any raw value of its type, and a scaled unsigned field
#   must not state a negative minimum.
def scale_and_unit(field, type_str, where)
  scale = stated_scale(field, where)
  integer = INTEGER_TYPES[type_str]
  specials = integer ? special_values(field, integer[0], where) : {}
  none = { scale: nil, unit: nil, specials: specials }
  if CONTRADICTED_SCALES.key?(where)
    stated = CONTRADICTED_SCALES[where]
    if scale != stated
      generation_error("#{where}: scale is #{scale.inspect}, not #{stated.inspect}; " \
                       "update CONTRADICTED_SCALES")
    end
    CONTRADICTED_SCALES_SEEN << where
    return none
  end
  units = stated_units(field)
  return none unless integer || FLOAT_TYPES.include?(type_str)

  if units.size > 1 && integer && scale
    generation_error("#{where} states a scale and the units #{units.join(', ')}")
  end
  id = units.size == 1 && units[0] != UNITLESS ? units[0] : nil
  unit = id && UNIT_NAMES.key?(id) ? { id: id, name: UNIT_NAMES[id] } : nil
  if integer.nil?
    identity = scale.nil? || scale == { m: 1, d: 0, b: 0 }
    return { scale: nil, unit: identity ? unit : nil, specials: {} }
  end
  return none if scale.nil?
  bits, signed = integer
  max_raw = signed ? 2**(bits - 1) : 2**bits - 1
  factor = scale[:b] < 0 ? 5**-scale[:b] : 2**scale[:b]
  if max_raw * scale[:m] * factor > 2**64 - 1
    generation_error("#{where}: scale #{scale} overflows 64 bits for #{type_str}")
  end
  if !signed && field["description"].to_s =~ /Minimum:\s*-/
    generation_error("#{where}: #{type_str} states a negative minimum; list it in CONTRADICTED_SCALES")
  end
  { scale: scale, unit: unit, specials: specials }
end

# Extracts a GSS identifier from the first \autoref that has no /field/ suffix.
# Returns nil when absent or when the reference is a self-reference.
def autoref_id(desc)
  m = desc.to_s.match(/\\autoref\{sec:(org\.bluetooth\.characteristic\.[^\/}]+)\}/)
  m && m[1]
end

def make_field(name:, type:, size:, conditions:, scale: nil, unit: nil, specials: {})
  { name: name, type: type, size: size, conditions: conditions, scale: scale, unit: unit,
    specials: specials }
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
                 conditions: conditions + inner, scale: f[:scale], unit: f[:unit],
                 specials: f[:specials])
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
  numeric = scale_and_unit(field, type_str, "#{parent_id}: field '#{name}'")

  if type_str == "struct"
    resolve_struct_field(name, desc, size, conditions, parent_id, gss_by_id, visiting)
  elsif SWIFT_TYPES.key?(type_str)
    [make_field(name: name, type: SWIFT_TYPES[type_str], size: size, conditions: conditions,
                scale: numeric[:scale], unit: numeric[:unit], specials: numeric[:specials])]
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
  args = ["name: \"#{esc_swift(f[:name])}\"", "type: #{f[:type]}", "size: #{f[:size]}"]
  unless f[:conditions].empty?
    args << "conditions: [#{f[:conditions].map { |c| condition_swift(c) }.join(', ')}]"
  end
  if (s = f[:scale])
    args << "scale: .init(multiplier: #{s[:m]}, decimalExponent: #{s[:d]}, binaryExponent: #{s[:b]})"
  end
  if (u = f[:unit])
    args << "unit: .init(id: \"#{esc_swift(u[:id])}\", name: \"#{esc_swift(u[:name])}\")"
  end
  unless f[:specials].empty?
    pairs = f[:specials].sort.map { |raw, text| format("0x%X: \"%s\"", raw, esc_swift(text)) }
    args << "specialValues: [#{pairs.join(', ')}]"
  end
  ".init(#{args.join(', ')})"
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
UNITS_FILE = File.join(SIG_DIR, "assigned_numbers", "uuids", "units.yaml")
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

UNIT_NAMES = load_unit_names(UNITS_FILE)

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
(CONTRADICTED_SCALES.keys - CONTRADICTED_SCALES_SEEN).each do |where|
  generation_error("CONTRADICTED_SCALES lists #{where}, which no characteristic has")
end

output = <<~SWIFT
  // BLECharacteristics.generated.swift
  // Auto-generated by Scripts/generate-ble-characteristics.rb from the Bluetooth SIG GSS.
  // Source: https://bitbucket.org/bluetooth-SIG/public.git
  // Do not edit manually -- rebuild to regenerate.

  enum GATTCharacteristicDB {
      enum FieldType {
          case uint8, uint16, uint24, uint32, uint48, uint64
          case sint8, sint16, sint24, sint32
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

      /// The GSS "Represented values" of an integer field: the value is
      /// raw * multiplier * 10^decimalExponent * 2^binaryExponent. The
      /// generator checks that this fits 64 bits for every raw value.
      /// Codable as the `scale` object of `gatt info` JSON; its property
      /// names are the keys.
      struct Scale: Equatable, Codable {
          let multiplier: Int64
          let decimalExponent: Int
          let binaryExponent: Int
      }

      /// An assigned unit: its org.bluetooth.unit identifier and the name
      /// from units.yaml.
      struct Unit: Equatable {
          let id: String
          let name: String
      }

      struct Field {
          let name: String
          let type: FieldType
          let size: Int
          /// All must hold for the field to be present; empty means always.
          let conditions: [Condition]
          /// Set only on integer fields; nil shows the raw value.
          let scale: Scale?
          /// The unit of a numeric field's value, after scaling; nil when
          /// the GSS names none, more than one, or one not in units.yaml.
          let unit: Unit?
          /// Raw values (the unsigned bit pattern) of an integer field that
          /// the GSS gives a meaning instead of a number.
          let specialValues: [UInt64: String]

          init(name: String, type: FieldType, size: Int, conditions: [Condition] = [],
               scale: Scale? = nil, unit: Unit? = nil, specialValues: [UInt64: String] = [:]) {
              self.name = name
              self.type = type
              self.size = size
              self.conditions = conditions
              self.scale = scale
              self.unit = unit
              self.specialValues = specialValues
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
