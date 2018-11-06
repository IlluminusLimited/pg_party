# frozen_string_literal: true

require "pg_party/cache"
require "pg_party/schema_helper"

module PgParty
  class ModelDecorator < SimpleDelegator
    def partition_primary_key
      if self != base_class
        base_class.primary_key
      elsif partition_name = partitions.first
        in_partition(partition_name).get_primary_key(base_class.name)
      else
        get_primary_key(base_class.name)
      end
    end

    def partition_table_exists?
      target_table = partitions.first || table_name

      PgParty::SchemaHelper.table_exists?(target_table)
    end

    def in_partition(child_table_name)
      PgParty::Cache.fetch_model(cache_key, child_table_name) do
        Class.new(__getobj__) do
          self.table_name = child_table_name

          # to avoid argument errors when calling model_name
          def self.name
            superclass.name
          end

          # when returning records from a query, Rails
          # allocates objects first, then initializes
          def self.allocate
            superclass.allocate
          end

          # creating and persisting new records from a child partition
          # will ultimately insert into the parent partition table
          def self.new(*args, &blk)
            superclass.new(*args, &blk)
          end
        end
      end
    end

    def partition_key_eq(value)
      if complex_partition_key
        complex_partition_key_eq(value)
      else
        simple_partition_key_eq(value)
      end
    end

    def range_partition_key_in(start_range, end_range)
      if complex_partition_key
        complex_range_partition_key_in(start_range, end_range)
      else
        simple_range_partition_key_in(start_range, end_range)
      end
    end

    def list_partition_key_in(*values)
      if complex_partition_key
        complex_list_partition_key_in(values)
      else
        simple_list_partition_key_in(values)
      end
    end

    def partitions
      PgParty::Cache.fetch_partitions(cache_key) do
        connection.select_values(<<-SQL)
          SELECT pg_inherits.inhrelid::regclass::text
          FROM pg_tables
          INNER JOIN pg_inherits
            ON pg_tables.tablename::regclass = pg_inherits.inhparent::regclass
          WHERE pg_tables.tablename = #{connection.quote(table_name)}
        SQL
      end
    end

    def create_range_partition(start_range:, end_range:, **options)
      modified_options = options.merge(
        start_range: start_range,
        end_range: end_range,
        primary_key: primary_key,
      )

      create_partition(:create_range_partition_of, table_name, **modified_options)
    end

    def create_list_partition(values:, **options)
      modified_options = options.merge(
        values: values,
        primary_key: primary_key,
      )

      create_partition(:create_list_partition_of, table_name, **modified_options)
    end

    private

    def simple_partition_key_eq(value)
      where(partition_key => value)
    end

    def complex_partition_key_eq(value)
      subquery = base_class
        .unscoped
        .where("(#{partition_key}) = (?)", value)
        .select(primary_key)
        .to_sql

      where(arel_table[primary_key].in(Arel.sql(subquery)))
    end

    def simple_range_partition_key_in(start_range, end_range)
      node = partition_key_as_arel

      where(node.gteq(start_range).and(node.lt(end_range)))
    end

    def complex_range_partition_key_in(start_range, end_range)
      subquery = base_class
        .unscoped
        .where("(#{partition_key}) >= (?) AND (#{partition_key}) < (?)", start_range, end_range)
        .select(primary_key)
        .to_sql

      where(arel_table[primary_key].in(Arel.sql(subquery)))
    end

    def simple_list_partition_key_in(values)
      where(partition_key_as_arel.in(values.flatten))
    end

    def complex_list_partition_key_in(values)
      subquery = base_class
        .unscoped
        .where("(#{partition_key}) IN (?)", values.flatten)
        .select(primary_key)
        .to_sql

      where(arel_table[primary_key].in(Arel.sql(subquery)))
    end

    def create_partition(migration_method, table_name, **options)
      transaction { connection.send(migration_method, table_name, **options) }
    end

    def cache_key
      __getobj__.object_id
    end

    def partition_key_as_arel
      arel_table[partition_key]
    end
  end
end
