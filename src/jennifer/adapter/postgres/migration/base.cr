module Jennifer
  module Migration
    abstract class Base
      extend Ifrit

      def create_enum(name, values)
        TableBuilder::CreateEnum.new(name, values).process
      end

      def drop_enum(name)
        TableBuilder::DropEnum.new(name).process
      end

      def change_enum(name, options)
        TableBuilder::ChangeEnum.new(name, options).process
      end

      def data_type_exists?(name)
        Adapter.adapter.as(Postgres).data_type_exists?(name)
      end
    end
  end
end
