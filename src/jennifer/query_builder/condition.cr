require "./criteria"

module Jennifer
  module QueryBuilder
    class Condition
      RAW_OPERATORS = [:is, :is_not]

      getter rhs : Criteria::Rightable, lhs : Criteria, operator : Symbol = :bool

      @rhs = nil
      @negative = false

      def initialize(field : String, table : String, relation = nil)
        @lhs = Criteria.new(field, table, relation)
      end

      def initialize(criteria)
        @lhs = criteria
      end

      def initialize(@lhs, @operator, @rhs)
      end

      def_clone

      protected def initialize_copy(other)
        @rhs = other.@rhs.dup
        @lhs = other.@lhs.clone
        @operator = other.operator
        @negative = other.@negative
      end

      def set_relation(table, name)
        @lhs.set_relation(table, name)
        @rhs.as(Criteria).set_relation(table, name) if @rhs.is_a?(Criteria)
      end

      def alias_tables(aliases)
        @lhs.alias_tables(aliases)
        @rhs.as(Criteria).alias_tables(aliases) if @rhs.is_a?(Criteria)
      end

      def change_table(old_name, new_name)
        @lhs.change_table(old_name, new_name)
        @rhs.as(Criteria).change_table(old_name, new_name) if @rhs.is_a?(Criteria)
      end

      def not
        @negative = !@negative
        self
      end

      def &(other : Condition | LogicOperator)
        op = And.new
        op.add(self)
        op.add(other)
        op
      end

      def &(other : Criteria)
        self & Condition.new(other)
      end

      def |(other : Condition | LogicOperator)
        op = Or.new
        op.add(self)
        op.add(other)
        op
      end

      def |(other : Criteria)
        self | Condition.new(other)
      end

      def to_s
        to_sql
      end

      def filter_out(arg)
        if arg.is_a?(Criteria)
          arg.to_sql
        else
          ::Jennifer::Adapter.escape_string(1)
        end
      end

      def to_sql
        _lhs = @lhs.to_sql
        str =
          case @operator
          when :bool
            _lhs
          when :in
            "#{_lhs} IN(#{::Jennifer::Adapter::SqlGenerator.escape_string(@rhs.as(Array).size)})"
          else
            "#{_lhs} #{::Jennifer::Adapter::SqlGenerator.operator_to_sql(@operator)} " +
              if filterable?
                filter_out(@rhs)
              elsif @rhs.is_a?(Criteria)
                @rhs.as(Criteria).to_sql
              else
                @rhs.to_s
              end
          end
        str = "NOT (#{str})" if @negative
        str
      end

      def sql_args : Array(DB::Any)
        res = [] of DB::Any
        if filterable?
          if @operator == :in
            @rhs.as(Array).each do |e|
              unless e.is_a?(Criteria)
                res << e.as(DB::Any)
              else
                res += e.sql_args
              end
            end
          elsif !@rhs.is_a?(Criteria)
            res << @rhs.as(DB::Any)
          end
        end
        res
      end

      def sql_args_count
        if filterable?
          count = 0
          if @operator == :in
            @rhs.as(Array).each do |e|
              count += e.is_a?(Criteria) ? e.sql_args_count : 1
            end
          elsif !@rhs.is_a?(Criteria)
            count += 1
          end
          count
        else
          0
        end
      end

      private def filterable?
        !(
          @rhs.is_a?(Criteria) ||
            @operator == :bool ||
            RAW_OPERATORS.includes?(@operator)
        )
      end
    end
  end
end
