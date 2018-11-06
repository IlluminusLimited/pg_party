# frozen_string_literal: true

module PgParty
  module TypeCaster
    # https://github.com/rails/rails/pull/26992
    def type_cast_for_database(attr_name, value)
      return value if value.is_a?(Arel::Nodes::SqlLiteral)
      super
    end
  end
end
