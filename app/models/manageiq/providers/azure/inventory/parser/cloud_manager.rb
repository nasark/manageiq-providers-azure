# TODO: Separate collection from parsing (perhaps collecting in parallel a la RHEVM)

class ManageIQ::Providers::Azure::Inventory::Parser::CloudManager < ManageIQ::Providers::Azure::Inventory::Parser
  include ManageIQ::Providers::Azure::RefreshHelperMethods

  def parse
    log_header = "Collecting data for EMS : [#{collector.manager.name}] id: [#{collector.manager.id}]"

    _log.info("#{log_header}...")

    resource_groups
    flavors
    availability_zones
    stacks
    stack_templates
    instances
    managed_images
    cloud_databases
    images if collector.options.get_private_images
    market_images if collector.options.get_market_images

    _log.info("#{log_header}...Complete")
  end

  private

  def resource_groups
    collector.resource_groups.each do |resource_group|
      uid = resource_group.id.downcase
      persister.resource_groups.build(
        :name    => resource_group.name,
        :ems_ref => uid,
      )
    end
  end

  def flavors
    collector.flavors.each do |flavor|
      name = flavor.name

      persister.flavors.build(
        :ems_ref         => name.downcase,
        :name            => name,
        :cpu_total_cores => flavor.number_of_cores,
        :memory          => flavor.memory_in_mb.megabytes,
        :root_disk_size  => flavor.os_disk_size_in_mb.megabytes,
        :swap_disk_size  => flavor.resource_disk_size_in_mb.megabytes,
        :enabled         => true
      )
    end
  end

  def availability_zones
    collector.availability_zones.each do |az|
      id = az.id.downcase

      persister.availability_zones.build(
        :ems_ref => id,
        :name    => az.name,
      )
    end
  end

  def instances
    collector.instances.each do |instance|
      uid = File.join(collector.subscription_id,
                      instance.resource_group.downcase,
                      instance.type.downcase,
                      instance.name)

      # TODO(lsmola) we have a non lazy dependency, can we remove that?
      series = persister.flavors.find(instance.properties.hardware_profile.vm_size.downcase)
      next if series.nil?

      rg_ems_ref = collector.get_resource_group_ems_ref(instance)
      parent_ref = collector.parent_ems_ref(instance)

      # We want to archive VMs with no status
      next if (status = collector.power_status(instance)).blank?

      persister_instance = persister.vms.build(
        :uid_ems             => instance.properties.vm_id,
        :ems_ref             => uid,
        :name                => instance.name,
        :vendor              => "azure",
        :connection_state    => "connected",
        :raw_power_state     => status,
        :flavor              => series,
        :location            => instance.location,
        :genealogy_parent    => persister.miq_templates.lazy_find(parent_ref),
        # TODO(lsmola) for release > g, we can use secondary indexes for this as
        :orchestration_stack => persister.stack_resources_secondary_index[instance.id.downcase],
        :availability_zone   => persister.availability_zones.lazy_find('default'),
        :resource_group      => persister.resource_groups.lazy_find(rg_ems_ref),
      )

      instance_hardware(persister_instance, instance, series)
      instance_operating_system(persister_instance, instance)

      vm_and_template_labels(persister_instance, instance['tags'] || [])
      vm_and_template_taggings(persister_instance, map_labels('VmAzure', instance['tags'] || []))
    end
  end

  def instance_hardware(persister_instance, instance, series)
    persister_hardware = persister.hardwares.build(
      :vm_or_template  => persister_instance,
      :cpu_total_cores => series[:cpu_total_cores],
      :memory_mb       => series[:memory] / 1.megabyte,
      :disk_capacity   => series[:root_disk_size] + series[:swap_disk_size],
    )

    hardware_networks(persister_hardware, instance)
    hardware_disks(persister_hardware, instance)
  end

  def instance_operating_system(persister_instance, instance)
    persister.operating_systems.build(
      :vm_or_template => persister_instance,
      :product_name   => guest_os(instance)
    )
  end

  def hardware_networks(persister_hardware, instance)
    collector.instance_network_ports(instance).each do |nic_profile|
      nic_profile.properties.ip_configurations.each do |ipconfig|
        hostname        = ipconfig.name
        private_ip_addr = ipconfig.properties.try(:private_ip_address)
        if private_ip_addr
          hardware_network(persister_hardware, private_ip_addr, hostname, "private")
        end

        public_ip_obj = ipconfig.properties.try(:public_ip_address)
        next unless public_ip_obj

        ip_profile = collector.instance_floating_ip(public_ip_obj)
        next unless ip_profile

        public_ip_addr = ip_profile.properties.try(:ip_address)
        hardware_network(persister_hardware, public_ip_addr, hostname, "public")
      end
    end
  end

  def hardware_network(persister_hardware, ip_address, hostname, description)
    persister.networks.build(
      :hardware    => persister_hardware,
      :description => description,
      :ipaddress   => ip_address,
      :hostname    => hostname,
    )
  end

  def hardware_disks(persister_hardware, instance)
    data_disks = instance.properties.storage_profile.data_disks
    data_disks.each do |disk|
      add_instance_disk(persister_hardware, instance, disk)
    end

    disk = instance.properties.storage_profile.os_disk
    add_instance_disk(persister_hardware, instance, disk)
  end

  # Redefine the inherited method for our purposes
  def add_instance_disk(persister_hardware, instance, disk)
    if instance.managed_disk?
      disk_type     = 'managed'
      disk_location = disk.managed_disk.id
      managed_disk  = collector.instance_managed_disk(disk_location)

      if managed_disk
        disk_size = managed_disk.properties.disk_size_gb.gigabytes
        mode      = managed_disk.try(:sku).try(:name)
      else
        _log.warn("Unable to find disk information for #{instance.name}/#{instance.resource_group}")
        disk_size = nil
        mode      = nil
      end
    else
      disk_type     = 'unmanaged'
      disk_location = disk.try(:vhd).try(:uri)
      disk_size     = disk.try(:disk_size_gb).try(:gigabytes)

      if disk_location
        uri = Addressable::URI.parse(disk_location)
        storage_name = uri.host.split('.').first
        container_name = File.dirname(uri.path)
        blob_name = uri.basename

        storage_acct = collector.instance_storage_accounts(storage_name)
        mode = storage_acct.try(:sku).try(:name)

        if collector.options.get_unmanaged_disk_space && disk_size.nil? && storage_acct.present?
          storage_keys = collector.instance_account_keys(storage_acct)
          storage_key  = storage_keys['key1'] || storage_keys['key2']
          blob_props   = storage_acct.blob_properties(container_name, blob_name, storage_key)
          disk_size    = blob_props.content_length.to_i
        end
      end
    end

    persister.disks.build(
      :hardware        => persister_hardware,
      :device_type     => 'disk',
      :controller_type => 'azure',
      :device_name     => disk.name,
      :location        => disk_location,
      :size            => disk_size,
      :disk_type       => disk_type,
      :mode            => mode
    )
  end

  def vm_and_template_labels(resource, tags)
    tags.each do |tag|
      persister
        .vm_and_template_labels
        .find_or_build_by(
          :resource => resource,
          :name     => tag.first,
        )
        .assign_attributes(
          :section => 'labels',
          :source  => 'azure',
          :value   => tag.second,
        )
    end
  end

  # Returns array of InventoryObject<Tag>.
  def map_labels(model_name, labels)
    label_hashes = labels.collect do |tag|
      { :name => tag.first, :value => tag.second }
    end
    persister.tag_mapper.map_labels(model_name, label_hashes)
  end

  def vm_and_template_taggings(resource, tags_inventory_objects)
    tags_inventory_objects.each do |tag|
      persister.vm_and_template_taggings.build(:taggable => resource, :tag => tag)
    end
  end

  def stacks
    collector.stacks.each do |deployment|
      name = deployment.name
      uid  = deployment.id

      persister_orchestration_stack = persister.orchestration_stacks.build(
        :ems_ref        => uid,
        :name           => name,
        :description    => name,
        :status         => deployment.properties.provisioning_state,
        :finish_time    => deployment.properties.timestamp,
        :resource_group => deployment.resource_group,
      )

      if (resources = collector.stacks_resources_cache[uid])
        # If the stack hasn't changed, we load existing resources in batches from our DB, this saves a lot of time
        # comparing to doing API query for resources per each stack
        stack_resources_from_cache(persister_orchestration_stack, resources)
      else
        stack_resources(persister_orchestration_stack, deployment)
      end

      stack_outputs(persister_orchestration_stack, deployment)
      stack_parameters(persister_orchestration_stack, deployment)
    end

    # TODO(lsmola) for release > g, we can use secondary indexes for this as
    # :parent => persister.orchestration_stacks_resources.lazy_find({:ems_ref => res_uid } , {:key => :stack, :ref => :by_...}),
    persister.orchestration_stacks.data.each do |stack_data|
      stack_data[:parent] = persister.stack_resources_secondary_index[stack_data[:ems_ref].downcase]
    end
  end

  def stack_parameters(persister_orchestration_stack, deployment)
    raw_parameters = deployment.properties.try(:parameters)
    return [] if raw_parameters.blank?

    raw_parameters.each do |param_key, param_obj|
      uid = File.join(deployment.id, param_key)
      persister.orchestration_stacks_parameters.build(
        :stack   => persister_orchestration_stack,
        :ems_ref => uid,
        :name    => param_key,
        :value   => param_obj['value']
      )
    end
  end

  def stack_outputs(persister_orchestration_stack, deployment)
    raw_outputs = deployment.properties.try(:outputs)
    return [] if raw_outputs.blank?

    raw_outputs.each do |output_key, output_obj|
      uid = File.join(deployment.id, output_key)
      persister.orchestration_stacks_outputs.build(
        :stack       => persister_orchestration_stack,
        :ems_ref     => uid,
        :key         => output_key,
        :value       => output_obj['value'],
        :description => output_key
      )
    end
  end

  def stack_resources(persister_orchestration_stack, deployment)
    collector.stack_resources(deployment).each do |resource|
      status_message = resource_status_message(resource)
      status_code = resource.properties.try(:status_code)
      persister_stack_resource = persister.orchestration_stacks_resources.build(
        :stack                  => persister_orchestration_stack,
        :ems_ref                => resource.properties.target_resource.id,
        :name                   => resource.properties.target_resource.resource_name,
        :logical_resource       => resource.properties.target_resource.resource_name,
        :physical_resource      => resource.properties.tracking_id,
        :resource_category      => resource.properties.target_resource.resource_type,
        :resource_status        => resource.properties.provisioning_state,
        :resource_status_reason => status_message || status_code,
        :last_updated           => resource.properties.timestamp
      )

      # TODO(lsmola) for release > g, we can use secondary indexes for this
      persister.stack_resources_secondary_index[persister_stack_resource[:ems_ref].downcase] = persister_stack_resource[:stack]
    end
  end

  def stack_resources_from_cache(persister_orchestration_stack, resources)
    resources.each do |resource|
      persister_stack_resource = persister.orchestration_stacks_resources.build(
        resource.merge!(:stack => persister_orchestration_stack)
      )

      # TODO(lsmola) for release > g, we can use secondary indexes for this
      persister.stack_resources_secondary_index[persister_stack_resource[:ems_ref].downcase] = persister_stack_resource[:stack]
    end
  end

  def stack_templates
    collector.stack_templates.each do |template|
      persister_orchestration_template = persister.orchestration_templates.build(
        :ems_ref     => template[:uid],
        :name        => template[:name],
        :description => template[:description],
        :content     => template[:content],
        :orderable   => false
      )

      # Assign template to stack here, so we don't need to always load the template
      persister_orchestration_stack = persister.orchestration_stacks.build(:ems_ref => template[:uid])
      persister_orchestration_stack[:orchestration_template] = persister_orchestration_template if persister_orchestration_stack
    end
  end

  def managed_images
    collector.managed_images.each do |image|
      uid = image.id.downcase
      rg_ems_ref = collector.get_resource_group_ems_ref(image)

      persister_miq_template = persister.miq_templates.build(
        :uid_ems            => uid,
        :ems_ref            => uid,
        :name               => image.name,
        :description        => "#{image.resource_group}/#{image.name}",
        :location           => collector.manager.provider_region,
        :vendor             => 'azure',
        :connection_state   => "connected",
        :raw_power_state    => 'never',
        :template           => true,
        :publicly_available => false,
        :resource_group     => persister.resource_groups.lazy_find(rg_ems_ref),
      )

      image_hardware(persister_miq_template, image.properties.storage_profile.try(:os_disk).try(:os_type) || 'unknown')
      image_operating_system(persister_miq_template, image)
    end
  end

  def market_images
    collector.market_images.each do |image|
      uid = image.id

      persister_miq_template = persister.miq_templates.build(
        :uid_ems            => uid,
        :ems_ref            => uid,
        :name               => "#{image.offer} - #{image.sku} - #{image.version}",
        :description        => "#{image.offer} - #{image.sku} - #{image.version}",
        :location           => collector.manager.provider_region,
        :vendor             => 'azure',
        :connection_state   => "connected",
        :raw_power_state    => 'never',
        :template           => true,
        :publicly_available => true,
      )

      image_hardware(persister_miq_template, 'unknown')
    end
  end

  def images
    collector.images.each do |image|
      uid = image.uri

      persister_miq_template = persister.miq_templates.build(
        :uid_ems            => uid,
        :ems_ref            => uid,
        :name               => build_image_name(image),
        :description        => build_image_description(image),
        :location           => collector.manager.provider_region,
        :vendor             => "azure",
        :connection_state   => "connected",
        :raw_power_state    => "never",
        :template           => true,
        :publicly_available => false,
      )

      image_hardware(persister_miq_template, image.operating_system)
    end
  end

  def image_hardware(persister_miq_template, os)
    persister.hardwares.build(
      :vm_or_template => persister_miq_template,
      :bitness        => 64,
      :guest_os       => OperatingSystem.normalize_os_name(os)
    )
  end

  def image_operating_system(persister_miq_template, image)
    persister.operating_systems.build(
      :vm_or_template => persister_miq_template,
      :product_name   => guest_os(image)
    )
  end

  def cloud_databases
    collector.mariadb_databases.each do |server, database|
      rg_ems_ref = collector.get_resource_group_ems_ref(database)

      persister.cloud_databases.build(
        :ems_ref        => database.id,
        :name           => "#{server.name}/#{database.name}",
        :status         => server.properties&.user_visible_state,
        :db_engine      => "MariaDB #{server.properties&.version}",
        :resource_group => persister.resource_groups.lazy_find(rg_ems_ref)
      )
    end

    collector.mysql_databases.each do |server, database|
      rg_ems_ref = collector.get_resource_group_ems_ref(database)

      persister.cloud_databases.build(
        :ems_ref        => database.id,
        :name           => "#{server.name}/#{database.name}",
        :status         => server.properties&.user_visible_state,
        :db_engine      => "MySQL #{server.properties&.version}",
        :resource_group => persister.resource_groups.lazy_find(rg_ems_ref)
      )
    end

    collector.postgresql_databases.each do |server, database|
      rg_ems_ref = collector.get_resource_group_ems_ref(database)

      persister.cloud_databases.build(
        :ems_ref   => database.id,
        :name      => "#{server.name}/#{database.name}",
        :status    => server.properties&.user_visible_state,
        :db_engine => "PostgreSQL #{server.properties&.version}",
        :resource_group => persister.resource_groups.lazy_find(rg_ems_ref)
      )
    end

    collector.sql_databases.each do |sql_server, sql_database|
      rg_ems_ref = collector.get_resource_group_ems_ref(sql_database)

      persister.cloud_databases.build(
        :ems_ref        => sql_database.id,
        :name           => "#{sql_server.name}/#{sql_database.name}",
        :status         => sql_database.properties&.status,
        :db_engine      => "SQL Server #{sql_server.properties&.version}",
        :resource_group => persister.resource_groups.lazy_find(rg_ems_ref)
      )
    end
  end

  # Helper methods
  # #################

  # Find both OS and SKU if possible, otherwise just the OS type.
  def guest_os(instance)
    image_reference = instance.properties.storage_profile.try(:image_reference)
    if image_reference&.try(:offer)
      "#{image_reference.offer} #{image_reference.sku.tr('-', ' ')}"
    else
      instance.properties.storage_profile.os_disk.os_type
    end
  end

  def resource_status_message(resource)
    return nil unless resource.properties.respond_to?(:status_message)
    if resource.properties.status_message.respond_to?(:error)
      resource.properties.status_message.error.message
    else
      resource.properties.status_message.to_s
    end
  end

  def build_image_description(image)
    # Description is a concatenation of resource group and storage account
    "#{image.storage_account.resource_group}/#{image.storage_account.name}"
  end
end
