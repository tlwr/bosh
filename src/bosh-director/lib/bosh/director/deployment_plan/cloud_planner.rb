module Bosh::Director
  module DeploymentPlan
    class CloudPlanner
      attr_accessor :compilation

      def initialize(options)
        @networks = self.class.index_by_name(options.fetch(:networks))
        @vm_types = self.class.index_by_name(options.fetch(:vm_types, {}))
        @vm_extensions = self.class.index_by_name(options.fetch(:vm_extensions, {}))
        @disk_types = self.class.index_by_name(options.fetch(:disk_types))
        @availability_zones = options.fetch(:availability_zones_list)
        @compilation = options.fetch(:compilation)
        @logger = options.fetch(:logger)
      end

      def ip_provider
        @ip_provider ||= IpProvider.new(IpRepo.new(@logger), @networks, @logger)
      end

      def availability_zone(name)
        @availability_zones[name]
      end

      def availability_zones
        @availability_zones.values
      end

      def vm_types
        @vm_types.values
      end

      def vm_type(name)
        @vm_types[name]
      end

      def vm_extensions
        @vm_extensions.values
      end

      def vm_extension(name)
        unless @vm_extensions.has_key?(name)
          raise "The vm_extension '#{name}' has not been configured in cloud-config."
        end

        @vm_extensions[name]
      end

      def networks
        @networks.values
      end

      def network(name)
        @networks[name]
      end

      def disk_types
        @disk_types.values
      end

      def disk_type(name)
        @disk_types[name]
      end

      def self.index_by_name(collection)
        collection.inject({}) do |index, item|
          index.merge(item.name => item)
        end
      end
    end
  end
end
