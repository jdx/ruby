#!/usr/bin/env ruby
# frozen_string_literal: true

require "set"
require "uri"
require "yaml"

ROOT = File.expand_path("..", __dir__)

def load_yaml(path)
  YAML.safe_load(File.read(File.join(ROOT, path)), permitted_classes: [], aliases: false)
rescue Psych::Exception => e
  abort "#{path}: #{e.message}"
end

def assert(condition, message)
  abort message unless condition
end

def duplicate_ruby_versions
  in_rubies = false
  versions = []
  File.readlines(File.join(ROOT, "recipes/rubies.yml")).each do |line|
    if line.match?(/\Arubies:\s*(?:#.*)?\z/)
      in_rubies = true
      next
    end
    next unless in_rubies
    break if line.match?(/\A\S/)

    match = line.match(/\A  (?<version>[^:#][^:]*):\s*(?:#.*)?\z/)
    next unless match

    versions << match[:version].strip.delete_prefix("'").delete_suffix("'").delete_prefix('"').delete_suffix('"')
  end
  versions.group_by(&:itself).select { |_version, matches| matches.length > 1 }.keys
end

def valid_url?(value)
  uri = URI.parse(value.to_s)
  %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty?
rescue URI::InvalidURIError
  false
end

def valid_sha?(value)
  value.to_s.match?(/\A[0-9a-f]{64}\z/)
end

rubies = load_yaml("recipes/rubies.yml")
deps = load_yaml("recipes/dependencies.yml")
series = load_yaml("recipes/series.yml")
targets = load_yaml("recipes/targets.yml")

[["recipes/rubies.yml", rubies], ["recipes/dependencies.yml", deps],
 ["recipes/series.yml", series], ["recipes/targets.yml", targets]].each do |path, doc|
  assert doc.is_a?(Hash), "#{path}: top-level value must be a map"
  assert doc["schema"] == 1, "#{path}: schema must be 1"
end

duplicates = duplicate_ruby_versions
assert duplicates.empty?, "recipes/rubies.yml: duplicate versions #{duplicates.join(", ")}"

series_keys = Set.new(series.fetch("series").keys)
rubies.fetch("rubies").each do |version, recipe|
  assert recipe.is_a?(Hash), "recipes/rubies.yml: #{version} must be a map"
  assert recipe["series"], "recipes/rubies.yml: #{version} is missing series"
  assert series_keys.include?(recipe["series"]), "recipes/rubies.yml: #{version} uses unknown series #{recipe["series"]}"
  assert valid_url?(recipe["url"]), "recipes/rubies.yml: #{version} has invalid url"
  assert valid_sha?(recipe["sha256"]), "recipes/rubies.yml: #{version} has invalid sha256"
  if recipe["version"]
    assert recipe["version"] == version, "recipes/rubies.yml: #{version} version field must match key"
  end
end

deps.fetch("dependencies").each do |name, recipe|
  assert recipe.is_a?(Hash), "recipes/dependencies.yml: #{name} must be a map"
  assert recipe["version"], "recipes/dependencies.yml: #{name} is missing version"
  assert valid_url?(recipe["url"]), "recipes/dependencies.yml: #{name} has invalid url"
  assert valid_sha?(recipe["sha256"]), "recipes/dependencies.yml: #{name} has invalid sha256"
  assert valid_url?(recipe["mirror"]), "recipes/dependencies.yml: #{name} has invalid mirror" if recipe["mirror"]
end

required_targets = Set.new(%w[macos x86_64_linux arm64_linux])
actual_targets = Set.new(targets.fetch("targets").keys)
assert required_targets.subset?(actual_targets), "recipes/targets.yml: missing targets #{(required_targets - actual_targets).to_a.join(", ")}"

targets.fetch("targets").each do |name, recipe|
  assert recipe["artifact_platform"], "recipes/targets.yml: #{name} missing artifact_platform"
  assert %w[linux macos].include?(recipe["os"]), "recipes/targets.yml: #{name} has invalid os"
  if recipe["os"] == "linux"
    assert recipe["container"].to_s.include?("@sha256:"), "recipes/targets.yml: #{name} container must be digest-pinned"
    assert recipe["max_glibc"].to_s.match?(/\A\d+\.\d+\z/), "recipes/targets.yml: #{name} max_glibc is invalid"
  end
end

puts "Recipe validation passed"
