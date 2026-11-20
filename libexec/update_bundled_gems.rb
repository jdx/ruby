#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "rubygems"
require "yaml"

# Bumps the gems staged into every portable Ruby (recipes/series.yml
# bundled_gems) to the newest stable release that is safe for the series:
#
# - same major version as the pinned one, so a breaking release is a manual bump
# - required_ruby_version satisfied by the oldest Ruby the entry applies to
# - platform "ruby" only (the source gem, never the java one)
#
# Prints one line per bump and rewrites recipes/series.yml in place.
class UpdateBundledGems
  ROOT = File.expand_path("..", __dir__)
  SERIES_PATH = File.join(ROOT, "recipes", "series.yml")

  Entry = Struct.new(:series, :name, :line, :version, :min_ruby, keyword_init: true)

  def self.run!
    new.run!
  end

  def run!
    text = File.read(SERIES_PATH)
    lines = text.lines
    changed = false

    entries(text, lines).each do |entry|
      latest = latest_for(entry)
      next if latest.nil? || latest.fetch("number") == entry.version

      url = "https://rubygems.org/downloads/#{entry.name}-#{latest.fetch("number")}.gem"
      sha256 = Digest::SHA256.hexdigest(fetch(url))
      unless sha256 == latest.fetch("sha")
        abort "error: #{url} sha256 #{sha256} does not match rubygems.org metadata #{latest.fetch("sha")}"
      end

      indent = lines[entry.line][/\A\s*/]
      lines[entry.line] = "#{indent}version: #{latest.fetch("number")}\n"
      lines[entry.line + 1] = "#{indent}url: #{url}\n"
      lines[entry.line + 2] = "#{indent}sha256: #{sha256}\n"
      changed = true
      puts "#{entry.name} #{entry.version} -> #{latest.fetch("number")} (#{entry.series})"
    end

    File.write(SERIES_PATH, lines.join) if changed
    puts "bundled gems are up to date" unless changed
  end

  private

  # Every `name:` block under a bundled_gems key, with the oldest Ruby it
  # applies to. Defaults apply to every series that does not override the gem.
  def entries(text, lines)
    doc = YAML.safe_load(text, permitted_classes: [], aliases: false)
    series_names = doc.fetch("series").keys.sort_by { |name| Gem::Version.new(name) }
    found = []
    section = nil

    lines.each_with_index do |line, index|
      section = "defaults" if line.match?(/\Adefaults:/)
      section = line[/\A  "?([\d.]+)"?:/, 1] if line.match?(/\A  "?\d+\.\d+"?:/)
      next unless line.match?(/\A\s+[\w-]+:\s*\z/) && lines[index + 1].to_s.match?(/\A\s+version: /)
      next unless lines[index + 2].to_s.include?("rubygems.org/downloads/")

      name = line[/([\w-]+):/, 1]
      found << Entry.new(
        series: section,
        name: name,
        line: index + 1,
        version: lines[index + 1][/version: (\S+)/, 1],
        min_ruby: min_ruby(doc, series_names, section, name)
      )
    end
    found
  end

  def min_ruby(doc, series_names, section, name)
    return Gem::Version.new("#{section}.0") unless section == "defaults"

    inheriting = series_names.reject do |series|
      doc.fetch("series").fetch(series)&.dig("bundled_gems", name)
    end
    abort "error: no series uses the default #{name}" if inheriting.empty?
    Gem::Version.new("#{inheriting.first}.0")
  end

  def latest_for(entry)
    current = Gem::Version.new(entry.version)
    candidates = JSON.parse(fetch("https://rubygems.org/api/v1/versions/#{entry.name}.json")).select do |release|
      next false unless release.fetch("platform") == "ruby" && !release.fetch("prerelease")

      version = Gem::Version.new(release.fetch("number"))
      version.segments.first == current.segments.first &&
        Gem::Requirement.new(release["ruby_version"] || ">= 0").satisfied_by?(entry.min_ruby)
    end
    candidates.max_by { |release| Gem::Version.new(release.fetch("number")) }
  end

  def fetch(url)
    response = Net::HTTP.get_response(URI(url))
    response = Net::HTTP.get_response(URI(response["location"])) while response.is_a?(Net::HTTPRedirection)
    abort "error: GET #{url} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    response.body
  end
end

UpdateBundledGems.run! if $PROGRAM_NAME == __FILE__
