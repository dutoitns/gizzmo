module Gizzard
  class ShardTemplate
    include Comparable

    ABSTRACT_HOST = "localhost"
    DEFAULT_WEIGHT = 1

    GIZZARD_SHARD_TYPES = [
      "com.twitter.gizzard.shards.ReplicatingShard",
      "com.twitter.gizzard.shards.ReadOnlyShard",
      "com.twitter.gizzard.shards.WriteOnlyShard",
      "com.twitter.gizzard.shards.BlockedShard",
      "ReplicatingShard",
      "ReadOnlyShard",
      "WriteOnlyShard",
      "BlockedShard",
    ]

    INVALID_COPY_TYPES = ["ReadOnlyShard", "WriteOnlyShard", "BlockedShard"]

    SHARD_SUFFIXES = {
      "ReplicatingShard" => 'replicating',
      "ReadOnlyShard" => 'read_only',
      "WriteOnlyShard" => 'write_only',
      "BlockedShard" => 'blocked'
    }

    attr_reader :type, :weight, :source_type, :dest_type

    def initialize(type, host, weight, source_type, dest_type, children)
      @type, @host, @weight, @source_type, @dest_type, @children =
        type, host, weight, source_type || '', dest_type || '', children
    end

    def concrete?
      !GIZZARD_SHARD_TYPES.include? type
    end

    def replicating?
      type =~ /ReplicatingShard/
    end

    def short_type
      type.split(".").last
    end

    def identifier
      replicating? ? short_type.to_s : "#{short_type}:#{host}"
    end

    def host
      if concrete?
        @host
      elsif !replicating?
        children.first.host
      else
        ABSTRACT_HOST
      end
    end

    def children
      @children.sort { |a, b| b <=> a }
    end

    def descendant_identifiers
      ids = children.map { |c| c.descendant_identifiers }.flatten
      ids << identifier if concrete?
      ids.uniq.sort
    end

    def copy_sources(multiplier = 1.0)
      return {} if INVALID_COPY_TYPES.include? short_type

      if concrete?
        { self => multiplier }
      else
        total_weight = children.map {|c| c.weight }.inject {|a,b| a+b }.to_f
        children.inject({}) do |sources, child|
          share = total_weight.zero? ? 0 : (child.weight / total_weight * multiplier)
          sources.merge child.copy_sources(share)
        end
      end
    end

    def copy_source
      copy_sources.to_a.sort {|a,b| a.last <=> b.last }.first.first
    end

    def inspect
      weight_inspect = weight.nil? ? "" : " #{weight}"
      child_inspect = children.empty? ? "" : " #{children.inspect}"
      "(#{identifier}#{weight_inspect}#{child_inspect})"
    end


    # Materialization

    def to_shard_id(table_name)
      name = [table_name, SHARD_SUFFIXES[short_type]].compact.join("_")
      Thrift::ShardId.new(host, name)
    end

    def to_shard_info(table_name)
      Thrift::ShardInfo.new(to_shard_id(table_name), type, source_type || '', dest_type || '', 0)
    end


    # Similarity/Equality

    include Comparable

    def similar?(other)
      return false unless other.is_a? ShardTemplate
      (self.descendant_identifiers & other.descendant_identifiers).length > 0
    end

    def <=>(other, deep = true, include_weight = true)
      raise ArgumentError, "other is not a ShardTemplate" unless other.is_a? ShardTemplate

      if (cmp = [host, type.to_s] <=> [other.host, other.type.to_s]) == 0
        if (cmp = include_weight ? weight <=> other.weight : 0) == 0
          # only sort children if necessary...
          deep ? children <=> other.children : 0
        else
          cmp
        end
      else
        cmp
      end
    end

    def eql?(other, deep = true, include_weight = true)
      return false unless other.is_a? ShardTemplate
      (self.<=>(other, deep, include_weight)).zero?
    end

    def hash
      weight.hash + host.hash + type.hash + children.hash
    end


    # Config

    def to_config
      weight_def = (weight  == DEFAULT_WEIGHT) ? nil : weight
      definition = [identifier, weight_def].compact.join(":")

      if children.empty?
        definition
      else
        child_defs = children.map {|c| c.to_config }
        child_defs = child_defs.first if child_defs.length == 1
        { definition => child_defs }
      end
    end


    # Class Methods

    module Introspection
      def from_shard_info(info, link_weight = nil, children = [])
        class_sym = SHARD_TYPES.index(info.class_name) or raise "unrecognized shard type #{info.class_name}"
        host = info.id.hostname

        new(class_sym, host, link_weight, info.source_type, info.destination_type, children)
      end

      def existing_template_map(manifest)
        # trees[template][graph_id][table_id]
        trees = Hash.new {|h,k| h[k] = Hash.new {|h,k| h[k] = [] } }

        manifest.forwardings.map{|f| [f.table_id, f.base_id, f.shard_id] }.each do |(table_id, base_id, shard_id)|
          tree = build_tree(shard_id, DEFAULT_WEIGHT, manifest)
          trees[tree][table_id] << shard_id.table_prefix
        end

        trees
      end

      private

      def build_tree(root_id, link_weight, manifest)
        children = manifest.links[root_id].map do |(child_id, child_weight)|
          build_tree(child_id, child_weight, manifest)
        end

        from_shard_info(manifest.shards[root_id], link_weight, children)
      end
    end

    extend Introspection


    module Configuration
      def from_config(config, conf_tree)
        shard, children = parse_link_struct(conf_tree)
        type, host, weight = parse_shard_definition(shard)
        new(type, host, weight, config.source_type, config.destination_type, Array(children).map { |child| from_config(config, child) })
      end

      private

      def parse_link_struct(obj)
        if obj.is_a? String
          [obj, nil]
        elsif obj.is_a? Hash and obj.length == 1
          [obj.keys.first, obj.values.first]
        else
          raise ArgumentError, "invalid shard tree: #{obj.inspect}"
        end
      end

      def parse_shard_definition(definition)
        type, arg1, arg2 = definition.split(":")

        host, weight =
          if GIZZARD_SHARD_TYPES.include? type
            if arg2 or YAML.load(arg1.to_s).is_a? String
              raise ArgumentError, "cannot specify a host for #{type} shard in: #{definition.inspect}"
            end
            [nil, (arg1 || DEFAULT_WEIGHT).to_i]
          else
            if arg1.nil? or YAML.load(arg1.to_s).is_a? Numeric
              raise ArgumentError, "must specify a host for #{type} shard in: #{definition.inspect}"
            end
            [arg1, (arg2 || DEFAULT_WEIGHT).to_i]
          end

        [type, host, weight]
      end
    end

    extend Configuration
  end
end
