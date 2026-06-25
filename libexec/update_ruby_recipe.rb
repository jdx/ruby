#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

class UpdateRubyRecipeError < StandardError; end

class UpdateRubyRecipe
  ROOT = File.expand_path("..", __dir__)
  RECIPE_PATH = File.join(ROOT, "recipes", "rubies.yml")
  PRE_RELEASE_RANK = {
    "preview" => 0,
    "rc" => 1
  }.freeze

  def self.run!(argv)
    version, url, sha256 = argv
    raise UpdateRubyRecipeError, "Usage: bin/update-ruby-recipe VERSION URL SHA256" unless version && url && sha256
    raise UpdateRubyRecipeError, "invalid version: #{version}" unless version.match?(/\A\d+\.\d+\.\d+(?:-(?:preview|rc)\d+)?\z/i)
    raise UpdateRubyRecipeError, "invalid URL: #{url}" unless url.match?(%r{\Ahttps://})
    raise UpdateRubyRecipeError, "invalid SHA256: #{sha256}" unless sha256.match?(/\A[0-9a-f]{64}\z/i)

    new(version, url, sha256.downcase).run!
  end

  def initialize(version, url, sha256)
    @version = version
    @url = url
    @sha256 = sha256
  end

  def run!
    doc = YAML.safe_load(File.read(RECIPE_PATH), permitted_classes: [], aliases: false)
    rubies = doc.fetch("rubies")
    old = rubies[@version]
    entry = recipe_entry
    if old == entry
      puts "Ruby #{@version} already exists in recipes/rubies.yml"
      return
    end

    rubies[@version] = entry
    File.write(RECIPE_PATH, updated_recipe_text(File.read(RECIPE_PATH), rubies))
    puts "#{old ? "Updated" : "Added"} Ruby #{@version} in recipes/rubies.yml"
  end

  private

  def recipe_entry
    entry = {
      "series" => @version[/\A\d+\.\d+/],
      "url" => @url,
      "sha256" => @sha256
    }
    entry["version"] = @version if @version.include?("-")
    entry
  end

  def updated_recipe_text(text, rubies)
    lines = text.lines
    blocks = ruby_blocks(lines)
    block_lines = recipe_entry_lines(@version, rubies.fetch(@version))
    existing = blocks.find { |block| block.fetch(:version) == @version }

    if existing
      lines[existing.fetch(:start)...existing.fetch(:finish)] = block_lines
    else
      insert_at = blocks.find { |block| version_sort_key(block.fetch(:version)) > version_sort_key(@version) }&.fetch(:start)
      lines.insert(insert_at || lines.length, *block_lines)
    end

    lines.join
  end

  def ruby_blocks(lines)
    rubies_start = lines.index("rubies:\n")
    raise UpdateRubyRecipeError, "recipes/rubies.yml is missing rubies map" unless rubies_start

    starts = lines.each_with_index.filter_map do |line, index|
      next if index <= rubies_start
      match = line.match(/\A  ([^:\s]+):\s*\z/)
      {version: match[1], start: index} if match
    end

    starts.each_with_index.map do |block, index|
      block.merge(finish: starts.fetch(index + 1, {start: lines.length}).fetch(:start))
    end
  end

  def recipe_entry_lines(version, entry)
    lines = [
      "  #{version}:\n",
      "    series: '#{entry.fetch("series")}'\n",
      "    url: #{entry.fetch("url")}\n",
      "    sha256: #{entry.fetch("sha256")}\n"
    ]
    lines << "    version: #{entry.fetch("version")}\n" if entry["version"]
    lines
  end

  def version_sort_key(version)
    release, pre = version.split("-", 2)
    numeric = release.split(".").map(&:to_i)
    pre_key =
      if pre && (match = pre.match(/\A([a-z]+)(\d+)?\z/i))
        name = match[1].downcase
        [0, PRE_RELEASE_RANK.fetch(name, 99), match[2].to_i, name]
      elsif pre
        [0, 99, 0, pre.downcase]
      else
        [1, 0, 0, ""]
      end
    [numeric, pre_key]
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    UpdateRubyRecipe.run!(ARGV)
  rescue UpdateRubyRecipeError => e
    warn "error: #{e.message}"
    exit 1
  end
end
