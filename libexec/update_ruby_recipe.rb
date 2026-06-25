#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

class UpdateRubyRecipeError < StandardError; end

class UpdateRubyRecipe
  ROOT = File.expand_path("..", __dir__)
  RECIPE_PATH = File.join(ROOT, "recipes", "rubies.yml")

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
    doc["rubies"] = rubies.keys.sort_by { |version| version_sort_key(version) }.each_with_object({}) do |version, sorted|
      sorted[version] = rubies.fetch(version)
    end
    File.write(RECIPE_PATH, YAML.dump(doc))
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

  def version_sort_key(version)
    release, pre = version.split("-", 2)
    numeric = release.split(".").map(&:to_i)
    pre_key = if pre
      name, number = pre.match(/\A([a-z]+)(\d+)?\z/i)&.captures
      [0, name.downcase, number.to_i]
    else
      [1]
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
