require_relative './db'
require 'pry'
require 'active_record'

ActiveRecord::Base.establish_connection db_config.merge(adapter: :mysql2)
ActiveRecord::Base.logger = Logger.new(STDOUT)

class Haveread < ActiveRecord::Base
  self.table_name = :haveread
  belongs_to :user
  belongs_to :channel
  belongs_to :message
end

class Channel < ActiveRecord::Base
  self.table_name = :channel
  has_many :messages
  has_many :havereads
end

class Image < ActiveRecord::Base
  self.table_name = :image
end

class User < ActiveRecord::Base
  self.table_name = :user
  has_many :messages
  has_many :havereads
end

class Message < ActiveRecord::Base
  self.table_name = :message
  belongs_to :channel
  belongs_to :user
  has_many :havereads
end

Pry.start
