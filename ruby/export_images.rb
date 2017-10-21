require_relative 'db'
require 'mysql2'

public_path = File.expand_path('../public/images', __dir__)
FileUtils.mkdir_p(public_path) unless File.exist?(public_path)

db.prepare('SELECT * FROM image').execute.each do |image|
  path = File.join(public_path, image["name"])
  File.write(path, image["data"])
end
