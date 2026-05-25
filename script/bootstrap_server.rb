#!/usr/bin/env ruby
# frozen_string_literal: true

trap("INT") do
  puts
  exit
end

require_relative "../config/environment"

ServerBootstrapper.start
