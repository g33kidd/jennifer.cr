require "./mapping"
require "./validation"
require "./callback"
require "./relation_definition"

module Jennifer
  module Model
    abstract class Base
      extend Ifrit
      include Mapping
      include Validation
      include Callback
      include RelationDefinition

      alias Supportable = DBAny | Base

      @@table_name : String?
      @@singular_table_name : String?

      def self.table_name(value : String | Symbol)
        @@table_name = value.to_s
      end

      def self.singular_table_name(value : String | Symbol)
        @@singular_table_name = value.to_s
      end

      def self.c(name)
        ::Jennifer::QueryBuilder::Criteria.new(name, table_name)
      end

      def self.c(name, relation)
        ::Jennifer::QueryBuilder::Criteria.new(name, table_name, relation)
      end

      def self.build(pull : DB::ResultSet)
        o = new(pull)
        o.__after_initialize_callback
        o
      end

      def self.build(values : Hash(Symbol, ::Jennifer::DBAny) | NamedTuple)
        o = new(values)
        o.__after_initialize_callback
        o
      end

      def self.build(values : Hash(String, ::Jennifer::DBAny))
        o = new(values)
        o.__after_initialize_callback
        o
      end

      def self.build(values : Hash | NamedTuple, new_record : Bool)
        o = new(values, new_record)
        o.__after_initialize_callback
        o
      end

      def self.build(**values)
        o = new(values)
        o.__after_initialize_callback
        o
      end

      def self.build
        o = new
        o.__after_initialize_callback
        o
      end

      def new_record?
        @new_record
      end

      def destroyed?
        @destroyed
      end

      def self.create(values : Hash | NamedTuple)
        o = new(values)
        o.save
        o
      end

      def self.create
        a = {} of Symbol => Supportable
        o = new(a)
        o.save
        o
      end

      def self.create(**values)
        o = new(values.to_h)
        o.save
        o
      end

      def self.create!(values : Hash | NamedTuple)
        o = new(values)
        o.save!
        o
      end

      def self.create!
        o = new({} of Symbol => Supportable)
        o.save!
        o
      end

      def self.create!(**values)
        o = new(values.to_h)
        o.save!
        o
      end

      def save!(skip_validation = false)
        raise Jennifer::BaseException.new("Record was not save") unless save(skip_validation)
        true
      end

      def append_relation(name, hash)
        raise Jennifer::UnknownRelation.new(self.class, name)
      end

      abstract def primary
      abstract def attribute(name)
      abstract def set_attribute(name, value)

      macro scope(name, &block)
        class Jennifer::QueryBuilder::ModelQuery(T)
          def {{name.id}}({{ block.args.join(", ").id }})
            T.{{name.id}}(self, {{block.args.join(", ").id}})
          end
        end

        def self.{{name.id}}({{ block.args.map(&.stringify).map { |e| "__" + e }.join(", ").id }})
          {% if !block.args.empty? %}
            {{ block.args.map(&.stringify).join(", ").id }} = {{block.args.map(&.stringify).map { |e| "__" + e }.join(", ").id}}
          {% end %}
          all.exec { {{block.body}} }
        end

        def self.{{name.id}}(_query : ::Jennifer::QueryBuilder::ModelQuery({{@type}}){% if !block.args.empty? %}, {{ block.args.map(&.stringify).map { |e| "__" + e }.join(", ").id }} {% end %})
          {% if !block.args.empty? %}
            {{ block.args.map(&.stringify).join(", ").id }} = {{block.args.map(&.stringify).map { |e| "__" + e }.join(", ").id}}
          {% end %}
          _query.exec { {{block.body}} }
        end
      end

      macro def self.models
        {% begin %}
          [
            {% for model in @type.all_subclasses %}
              {{model.id}},
            {% end %}
          ]
        {% end %}
      end

      macro inherited
        ::Jennifer::Model::Validation.inherited_hook
        ::Jennifer::Model::Callback.inherited_hook
        ::Jennifer::Model::RelationDefinition.inherited_hook

        @@relations = {} of String => ::Jennifer::Relation::IRelation

        after_save :__refresh_changes

        def self.table_name : String
          @@table_name ||= {{@type}}.to_s.underscore.pluralize
        end

        def self.singular_table_name
          @@singular_table_name ||= {{@type}}.to_s.underscore
        end

        def self.relations
          @@relations
        end

        def self.superclass
          {{@type.superclass}}
        end

        macro finished
          ::Jennifer::Model::Validation.finished_hook
          ::Jennifer::Model::Callback.finished_hook
          ::Jennifer::Model::RelationDefinition.finished_hook

          def self.relation(name : String)
            @@relations[name]
          rescue e : KeyError
            raise Jennifer::UnknownRelation.new(self, /"(?<r>.*)"$/.match(e.message.to_s).try &.["r"])
          end
        end
      end

      def update_attributes(hash : Hash)
        hash.each { |k, v| set_attribute(k, v) }
      end

      # Deletes object from db and calls callbacks
      def destroy
        return false if new_record? || !__before_destroy_callback
        @destroyed = true if delete
        __after_destroy_callback if @destroyed
        @destroyed
      end

      # Deletes object from DB without calling callbacks
      def delete
        return if new_record? || errors.any?
        this = self
        self.class.where { this.class.primary == this.primary }.delete
      end

      # Lock current object in DB
      def lock!(type : String | Bool = true)
        this = self
        self.class.where { this.class.primary == this.primary }.lock(type).to_a
      end

      # Starts transaction and locks current object
      def with_lock(type : String | Bool = true)
        self.class.transaction do |t|
          self.lock!(type)
          yield(t)
        end
      end

      # Starts transaction
      def self.transaction
        Adapter.adapter.transaction do |t|
          yield(t)
        end
      end

      def self.where(&block)
        ac = all
        tree = with ac.expression_builder yield
        ac.set_tree(tree)
        ac
      end

      def self.find(id)
        _id = id
        this = self
        where { this.primary == _id }.first
      end

      def self.find!(id)
        _id = id
        this = self
        where { this.primary == _id }.first!
      end

      def self.all
        QueryBuilder::ModelQuery(self).build(table_name)
      end

      def self.destroy(*ids)
        destroy(ids.to_a)
      end

      def self.destroy(ids : Array)
        _ids = ids
        where do
          if _ids.size == 1
            c(primary_field_name) == _ids[0]
          else
            c(primary_field_name).in(_ids)
          end
        end.destroy
      end

      def self.delete(*ids)
        delete(ids.to_a)
      end

      def self.delete(ids : Array)
        _ids = ids
        where do
          if _ids.size == 1
            c(primary_field_name) == _ids[0]
          else
            c(primary_field_name).in(_ids)
          end
        end.delete
      end

      def self.search_by_sql(query : String, args = [] of Supportable)
        result = [] of self
        ::Jennifer::Adapter.adapter.query(query, args) do |rs|
          rs.each do
            result << build(rs)
          end
        end
        result
      end
    end
  end
end
