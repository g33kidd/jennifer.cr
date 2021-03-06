require "pg"
require "../adapter"
require "./request_methods"
require "./postgres/sql_notation"

module Jennifer
  alias DBAny = Array(Int32) | Array(Char) | Array(Float32) | Array(Float64) |
                Array(Int16) | Array(Int32) | Array(Int64) | Array(String) |
                Bool | Char | Float32 | Float64 | Int16 | Int32 | Int64 | JSON::Any | PG::Geo::Box |
                PG::Geo::Circle | PG::Geo::Line | PG::Geo::LineSegment | PG::Geo::Path | PG::Geo::Point |
                PG::Geo::Polygon | PG::Numeric | Slice(UInt8) | String | Time | UInt32 | Nil

  module Adapter
    alias EnumType = Bytes

    class Postgres < Base
      include RequestMethods

      TYPE_TRANSLATIONS = {
        :integer    => "int",
        :string     => "varchar",
        :char       => "char",
        :bool       => "boolean",
        :text       => "text",
        :float      => "real",
        :double     => "double precision",
        :short      => "SMALLINT",
        :timestamp  => "timestamp",
        :date_time  => "datetime",
        :blob       => "blob",
        :var_string => "varchar",
        :json       => "json",
      }

      DEFAULT_SIZES = {
        :string     => 254,
        :var_string => 254,
      }

      def prepare
        _query = <<-SQL
          SELECT e.enumtypid
          FROM pg_type t, pg_enum e
          WHERE t.oid = e.enumtypid
        SQL

        query(_query) do |rs|
          rs.each do
            PG::Decoders.register_decoder PG::Decoders::StringDecoder.new, rs.read(UInt32).to_i
          end
        end
      end

      def translate_type(name)
        TYPE_TRANSLATIONS[name]
      rescue e : KeyError
        raise BaseException.new("Unknown data alias #{name}")
      end

      def default_type_size(name)
        DEFAULT_SIZES[name]?
      end

      def table_exists?(table)
        Query["information_schema.tables"]
          .where { _table_name == table }
          .exists?
      end

      def column_exists?(table, name)
        Query["information_schema.columns"]
          .where { (_table_name == table) & (_column_name == name) }
          .exists?
      end

      def index_exists?(table, name)
        Query["pg_class"]
          .join("pg_namespace") { _oid == _pg_class__relnamespace }
          .where { (_pg_class__relname == name) & (_pg_namespace__nspname == Config.schema) }
          .exists?
      end

      def data_type_exists?(name)
        Query["pg_type"].where { _typname == name }.exists?
      end

      def enum_values(name)
        query_string_array("SELECT unnest(enum_range(NULL::#{name})::varchar[])")
      end

      def define_enum(name, values)
        exec <<-SQL
          CREATE TYPE #{name} AS ENUM(#{values.as(Array).map { |e| "'#{e}'" }.join(", ")})
        SQL
      end

      def drop_enum(name)
        exec "DROP TYPE #{name}"
      end

      def query_string_array(_query, field_count = 1)
        result = [] of Array(String)
        query(_query) do |rs|
          rs.each do
            temp = [] of String
            field_count.times do
              temp << rs.read(String)
            end
            result << temp
          end
        end
        result
      end

      # =========== overrides

      def add_index(table, name, options)
        query = String.build do |s|
          s << "CREATE "
          if options[:type]?
            s <<
              case options[:type]
              when :unique, :uniq
                "UNIQUE "
              else
                raise ArgumentError.new("Unknown index type: #{options[:type]}")
              end
          end
          s << "INDEX " << name << " ON " << table
          s << " USING " << options[:using] if options.has_key?(:using)
          s << " ("
          fields = options.as(Hash)[:_fields].as(Array)
          fields.each_with_index do |f, i|
            s << "," if i != 0
            s << f
            s << " " << options[:order].as(Hash)[f].to_s.upcase if options[:order]? && options[:order].as(Hash)[f]?
          end
          s << ")"
          s << " " << options[:partial] if options.has_key?(:partial)
        end
        exec query
      end

      def change_column(table, old_name, new_name, opts)
        column_name_part = " ALTER COLUMN #{old_name} "
        query = String.build do |s|
          s << "ALTER TABLE " << table
          if opts[:type]?
            s << column_name_part << " TYPE "
            column_type_definition(opts, s)
            s << ","
          end
          if opts[:null]?
            s << column_name_part
            if opts[:null]
              s << " DROP NOT NULL"
            else
              s << " SET NOT NULL"
            end
            s << ","
          end
          if opts[:default]?
            s << column_name_part
            if opts[:default].is_a?(Symbol) && opts[:default].as(Symbol) == :drop
              s << "DROP DEFAULT "
            else
              s << "SET DEFAULT " << self.class.t(opts[:default])
            end
            s << ","
          end
          if old_name.to_s != new_name.to_s
            s << " RENAME COLUMN " << old_name << " TO " << new_name
            s << ","
          end
        end

        exec query[0...-1]
      end

      def insert(obj : Model::Base)
        opts = obj.arguments_to_insert
        query = parse_query(SqlGenerator.insert(obj, obj.class.primary_auto_incrementable?), opts[:args])
        id = -1i64
        affected = 0i64
        if obj.class.primary_auto_incrementable?
          id = scalar(query, opts[:args]).as(Int32).to_i64
          affected += 1 if id > 0
        else
          affected = exec(query, opts[:args]).rows_affected
        end

        ExecResult.new(id, affected)
      end

      def exists?(query)
        args = query.select_args
        body = parse_query(SqlGenerator.exists(query), args)
        scalar(body, args)
      end

      private def column_definition(name, options, io)
        io << name
        column_type_definition(options, io)
        if options.has_key?(:null)
          if options[:null]
            io << " NULL"
          else
            io << " NOT NULL"
          end
        end
        io << " PRIMARY KEY" if options[:primary]?
        io << " DEFAULT #{self.class.t(options[:default])}" if options[:default]?
      end

      private def column_type_definition(options, io)
        type = if options[:serial]? || options[:auto_increment]?
                 "serial"
               else
                 options[:sql_type]? || translate_type(options[:type].as(Symbol))
               end
        size = options[:size]? || default_type_size(options[:type]?)
        io << " " << type
        io << "(#{size})" if size
        io << " ARRAY" if options[:array]?
      end

      def self.create_database
        opts = [Config.db, "-O", Config.user, "-h", Config.host, "-U", Config.user]
        Process.run("PGPASSWORD=#{Config.password} createdb \"${@}\"", opts, shell: true).inspect
      end

      def self.drop_database
        io = IO::Memory.new
        opts = [Config.db, "-h", Config.host, "-U", Config.user]
        s = Process.run("PGPASSWORD=#{Config.password} dropdb \"${@}\"", opts, shell: true, output: io, error: io)
        if s.exit_code != 0
          raise io.to_s
        end
      end

      def self.generate_schema
        io = IO::Memory.new
        opts = ["-U", Config.user, "-d", Config.db, "-h", Config.host, "-s"]
        s = Process.run("PGPASSWORD=#{Config.password} pg_dump \"${@}\"", opts, shell: true, output: io)
        File.write(Config.structure_path, io.to_s)
      end

      def self.load_schema
        io = IO::Memory.new
        opts = ["-U", Config.user, "-d", Config.db, "-h", Config.host, "-a", "-f", Config.structure_path]
        s = Process.run("PGPASSWORD=#{Config.password} psql \"${@}\"", opts, shell: true, output: io)
        raise "Cant load schema: exit code #{s.exit_code}" if s.exit_code != 0
      end
    end
  end

  macro after_load_hook
    require "./jennifer/adapter/postgres/criteria"
    require "./jennifer/adapter/postgres/numeric"
    require "./jennifer/adapter/postgres/migration/base"
    require "./jennifer/adapter/postgres/migration/table_builder/*"
  end
end

require "./postgres/result_set"
require "./postgres/field"
require "./postgres/exec_result"

::Jennifer::Adapter.register_adapter("postgres", ::Jennifer::Adapter::Postgres)
