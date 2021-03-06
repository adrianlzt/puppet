require 'puppet'
require 'puppet/parameter/boolean'

Puppet::Type.newtype(:resources) do
  @doc = "This is a metatype that can manage other resource types.  Any
    metaparams specified here will be passed on to any generated resources,
    so you can purge umanaged resources but set `noop` to true so the
    purging is only logged and does not actually happen."


  newparam(:name) do
    desc "The name of the type to be managed."

    validate do |name|
      raise ArgumentError, "Could not find resource type '#{name}'" unless Puppet::Type.type(name)
    end

    munge { |v| v.to_s }
  end

  newparam(:purge, :boolean => true, :parent => Puppet::Parameter::Boolean) do
    desc "Purge unmanaged resources.  This will delete any resource
      that is not specified in your configuration
      and is not required by any specified resources.
      Purging ssh_authorized_keys this way is deprecated; see the
      purge_ssh_keys parameter of the user type for a better alternative."

    defaultto :false

    validate do |value|
      if munge(value)
        unless @resource.resource_type.respond_to?(:instances)
          raise ArgumentError, "Purging resources of type #{@resource[:name]} is not supported, since they cannot be queried from the system"
        end
        raise ArgumentError, "Purging is only supported on types that accept 'ensure'" unless @resource.resource_type.validproperty?(:ensure)
      end
    end
  end

  newparam(:unless_system_user) do
    desc "This keeps system users from being purged.  By default, it
      does not purge users whose UIDs are less than 500 or 1000, depending on operating system, but you can specify
      a different UID as the inclusive limit."

    newvalues(:true, :false, /^\d+$/)

    munge do |value|
      case value
      when /^\d+/
        Integer(value)
      when :true, true
        @resource.system_users_max_uid
      when :false, false
        false
      when Integer; value
      else
        raise ArgumentError, "Invalid value #{value.inspect}"
      end
    end

    defaultto {
      if @resource[:name] == "user"
        @resource.system_users_max_uid
      else
        nil
      end
    }
  end

  newparam(:unless_uid) do
    desc 'This keeps specific uids or ranges of uids from being purged when purge is true.
      Accepts integers, integer strings, and arrays of integers or integer strings.
      To specify a range of uids, consider using the range() function from stdlib.'

    munge do |value|
      value = [value] unless value.is_a? Array
      value.flatten.collect do |v|
        case v
          when Integer
            v
          when String
            Integer(v)
          else
            raise ArgumentError, "Invalid value #{v.inspect}."
        end
      end
    end
  end

  def check(resource)
    @checkmethod ||= "#{self[:name]}_check"
    @hascheck ||= respond_to?(@checkmethod)
    if @hascheck
      return send(@checkmethod, resource)
    else
      return true
    end
  end

  def able_to_ensure_absent?(resource)
      resource[:ensure] = :absent
  rescue ArgumentError, Puppet::Error
      err "The 'ensure' attribute on #{self[:name]} resources does not accept 'absent' as a value"
      false
  end

  # Generate any new resources we need to manage.  This is pretty hackish
  # right now, because it only supports purging.
  def generate
    return [] unless self.purge?
    resource_type.instances.
      reject { |r| catalog.resource_refs.include? r.ref }.
      select { |r| check(r) }.
      select { |r| r.class.validproperty?(:ensure) }.
      select { |r| able_to_ensure_absent?(r) }.
      each { |resource|
        @parameters.each do |name, param|
          resource[name] = param.value if param.metaparam?
        end

        # Mark that we're purging, so transactions can handle relationships
        # correctly
        resource.purging
      }
  end

  def resource_type
    unless defined?(@resource_type)
      unless type = Puppet::Type.type(self[:name])
        raise Puppet::DevError, "Could not find resource type"
      end
      @resource_type = type
    end
    @resource_type
  end

  def self.deprecate_params(title,params)
    return unless params
    if title == 'cron' and ! params.select { |param| param.name.intern == :purge and param.value == true }.empty?
      Puppet.deprecation_warning("Change notice: purging cron entries will be more aggressive in future versions, take care when updating your agents. See http://links.puppetlabs.com/puppet-aggressive-cron-purge")
    end
  end

  # Make sure we don't purge users with specific uids
  def user_check(resource)
    return true unless self[:name] == "user"
    return true unless self[:unless_system_user]
    resource[:audit] = :uid
    current_values = resource.retrieve_resource
    current_uid = current_values[resource.property(:uid)]
    unless_uids = self[:unless_uid]

    return false if system_users.include?(resource[:name])
    return false if unless_uids && unless_uids.include?(current_uid)

    current_uid > self[:unless_system_user]
  end

  def system_users
    %w{root nobody bin noaccess daemon sys}
  end

  def system_users_max_uid
    case Facter.value(:osfamily)
    when 'Debian', 'OpenBSD', 'FreeBSD'
      999
    else
      499
    end
  end
end
