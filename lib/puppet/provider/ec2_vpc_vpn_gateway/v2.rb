require_relative '../../../puppet_x/puppetlabs/aws.rb'
require 'retries'

Puppet::Type.type(:ec2_vpc_vpn_gateway).provide(:v2, :parent => PuppetX::Puppetlabs::Aws) do
  confine feature: :aws

  mk_resource_methods
  remove_method :tags=

  def self.instances()
    regions.collect do |region|
      gateways = []
      ec2_client(region).describe_vpn_gateways(filters: [
        {:name => 'state', :values => ['pending', 'available']}
      ]).each do |response|
        response.data.vpn_gateways.each do |gateway|
          hash = gateway_to_hash(region, gateway)
          if hash[:name]
            gateways << new(hash)
          end
        end
      end
      gateways
    end.flatten
  end

  read_only(:vpc, :region, :type, :availability_zone)

  def self.prefetch(resources)
    instances.each do |prov|
      if resource = resources[prov.name]  # rubocop:disable Lint/AssignmentInCondition
        resource.provider = prov
      end
    end
  end

  def self.gateway_to_hash(region, gateway)
    attached = gateway.vpc_attachments.detect { |vpc| vpc.state == 'attached' }
    if attached
      vpc_id = attached.vpc_id
      vpc_response = ec2_client(region).describe_vpcs(
        vpc_ids: [vpc_id]
      )
      vpc = vpc_response.data.vpcs.first
      vpc_name_tag = vpc.tags.detect { |tag| tag.key == 'Name' }
      vpc_name = vpc_name_tag ? vpc_name_tag.value : nil
    else
      vpc_name = nil
      vpc_id = nil
    end
    {
      :name   => name_from_tag(gateway),
      :id     => gateway.vpn_gateway_id,
      :vpc    => vpc_name,
      :vpc_id => vpc_id,
      :availability_zone => gateway.availability_zone,
      :ensure => :present,
      :region => region,
      :type   => gateway.type,
      :tags   =>  tags_for(gateway),
    }
  end

  def exists?
    dest_region = resource[:region] if resource
    Puppet.info("Checking if VPN gateway #{name} exists in region #{dest_region || region}")
    @property_hash[:ensure] == :present
  end

  def create
    Puppet.info("Creating VPN gateway #{name} in region #{resource[:region]}")
    ec2 = ec2_client(resource[:region])

    vpc_response = ec2.describe_vpcs(filters: [
      {name: "tag:Name", values: [resource[:vpc]]},
    ])
    fail("Multiple VPCs with name #{resource[:vpc]}") if vpc_response.data.vpcs.count > 1
    fail("No VPCs with name #{resource[:vpc]}") if vpc_response.data.vpcs.empty?

    response = ec2.create_vpn_gateway(
      type: resource[:type],
      availability_zone: resource[:availability_zone],
    )

    gateway_id = response.data.vpn_gateway.vpn_gateway_id

    with_retries(:max_tries => 5) do
      ec2.create_tags(
        resources: [gateway_id],
        tags: tags_for_resource,
      )
    end

    ec2.attach_vpn_gateway(
      vpn_gateway_id: gateway_id,
      vpc_id: vpc_response.data.vpcs.first.vpc_id,
    )

    # Due to the possibility of dependent resources failing because the gateway
    # hasn't attached yet, we wait for attachment.

    @property_hash[:id] = gateway_id

    wait_until(:attached)

    @property_hash[:ensure] = :present
  end

  def detached?
    in_state?('detached')
  end

  def attached?
    in_state?('attached')
  end

  def destroy
    region = @property_hash[:region]
    Puppet.info("Destroying VPN gateway #{name} in #{region}")
    ec2 = ec2_client(region)
    vpc_id = @property_hash[:vpc_id]
    ec2.detach_vpn_gateway(
      vpn_gateway_id: @property_hash[:id],
      vpc_id: vpc_id,
    ) if vpc_id
    wait_until(:detached)
    with_retries(:max_tries => 10,
                 :rescue => Aws::EC2::Errors::IncorrectState,
                 :base_sleep_seconds => 10,
                 :max_sleep_seconds => 20) do |attempt|
      Puppet.debug("Attempt #{attempt} destroying the VPN gateway at #{Time.new}")
      ec2.delete_vpn_gateway(
        vpn_gateway_id: @property_hash[:id]
      )
    end
    @property_hash[:ensure] = :absent
  end

  private

    def wait_until(state, max_attempts=40, sleep_duration=15)
      Puppet.info("Waiting until VPN gateway is #{state}. This can take several minutes")
      attempt = 1
      state_function = state == :attached ? :'attached?' : :'detached?'
      until self.send(state_function)
        Puppet.debug("Waiting for VPN gateway to become #{state} attempt #{attempt} at #{Time.new}")
        attempt += 1
        sleep sleep_duration
        if attempt > max_attempts
          Puppet.warning("VPN gateway not #{state} but continuing")
          break
        end
      end
    end

    def in_state?(state)
      ec2 = ec2_client(resource[:region])
      state_response = ec2.describe_vpn_gateways(filters: [
        {name: 'attachment.state', values: [state]},
        {name: 'vpn-gateway-id', values: [@property_hash[:id]]},
      ])
      !state_response.data.vpn_gateways.empty?
    end

end

