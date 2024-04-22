def concurrency
  :shared
end

def register(
  params
)

  require 'date'
  require 'faraday'
  require 'fuzzystringmatch'
  require 'ipaddr'
  require 'json'
  require 'lru_redux'
  require 'psych'
  require 'stringex_lite'

  # enable/disable based on script parameters and global environment variable
  _enabled_str = params["enabled"]
  _enabled_env = params["enabled_env"]
  if _enabled_str.nil? && !_enabled_env.nil?
    _enabled_str = ENV[_enabled_env]
  end
  @netbox_enabled = [1, true, '1', 'true', 't', 'on', 'enabled'].include?(_enabled_str.to_s.downcase) &&
                    (not [1, true, '1', 'true', 't', 'on', 'enabled'].include?(ENV["NETBOX_DISABLED"].to_s.downcase))

  # source field containing lookup value
  @source = params["source"]

  # lookup type
  #   valid values are: ip_device, ip_prefix
  @lookup_type = params.fetch("lookup_type", "").to_sym

  # site value to include in queries for enrichment lookups, either specified directly or read from ENV
  @lookup_site = params["lookup_site"]
  _lookup_site_env = params["lookup_site_env"]
  if @lookup_site.nil? && !_lookup_site_env.nil?
    @lookup_site = ENV[_lookup_site_env]
  end
  if !@lookup_site.nil? && @lookup_site.empty?
    @lookup_site = nil
  end

  # whether or not to enrich service for ip_device
  _lookup_service_str = params["lookup_service"]
  _lookup_service_env = params["lookup_service_env"]
  if _lookup_service_str.nil? && !_lookup_service_env.nil?
    _lookup_service_str = ENV[_lookup_service_env]
  end
  @lookup_service = [1, true, '1', 'true', 't', 'on', 'enabled'].include?(_lookup_service_str.to_s.downcase)
  @lookup_service_port_source = params.fetch("lookup_service_port_source", "[destination][port]")

  # API parameters
  @page_size = params.fetch("page_size", 50)

  # caching parameters (default cache size = 1000, default cache TTL = 30 seconds)
  _cache_size_val = params["cache_size"]
  _cache_size_env = params["cache_size_env"]
  if (!_cache_size_val.is_a?(Integer) || _cache_size_val <= 0) && !_cache_size_env.nil?
    _cache_size_val = Integer(ENV[_cache_size_env], exception: false)
  end
  if _cache_size_val.is_a?(Integer) && (_cache_size_val > 0)
    @cache_size = _cache_size_val
  else
    @cache_size = 1000
  end
  _cache_ttl_val = params["cache_ttl"]
  _cache_ttl_env = params["cache_ttl_env"]
  if (!_cache_ttl_val.is_a?(Integer) || _cache_ttl_val <= 0) && !_cache_ttl_env.nil?
    _cache_ttl_val = Integer(ENV[_cache_ttl_env], exception: false)
  end
  if _cache_ttl_val.is_a?(Integer) && (_cache_ttl_val > 0)
    @cache_ttl = _cache_ttl_val
  else
    @cache_ttl = 30
  end

  # target field to store looked-up value
  @target = params["target"]

  # verbose - either specified directly or read from ENV via verbose_env
  #   false - store the "name" (fallback to "display") and "id" value(s) as @target.name and @target.id
  #             e.g., (@target is destination.segment) destination.segment.name => ["foobar"]
  #                                                    destination.segment.id => [123]
  #   true - store a hash of arrays *under* @target
  #             e.g., (@target is destination.segment) destination.segment.name => ["foobar"]
  #                                                    destination.segment.id => [123]
  #                                                    destination.segment.url => ["whatever"]
  #                                                    destination.segment.foo => ["bar"]
  #                                                    etc.
  _verbose_str = params["verbose"]
  _verbose_env = params["verbose_env"]
  if _verbose_str.nil? && !_verbose_env.nil?
    _verbose_str = ENV[_verbose_env]
  end
  @verbose = [1, true, '1', 'true', 't', 'on', 'enabled'].include?(_verbose_str.to_s.downcase)

  # connection URL for netbox
  @netbox_url = params.fetch("netbox_url", "http://netbox:8080/netbox/api").delete_suffix("/")
  @netbox_url_suffix = "/netbox/api"
  @netbox_url_base = @netbox_url.delete_suffix(@netbox_url_suffix)

  # connection token (either specified directly or read from ENV via netbox_token_env)
  @netbox_token = params["netbox_token"]
  _netbox_token_env = params["netbox_token_env"]
  if @netbox_token.nil? && !_netbox_token_env.nil?
    @netbox_token = ENV[_netbox_token_env]
  end

  # hash of lookup types (from @lookup_type), each of which contains the respective looked-up values
  @cache_hash = LruRedux::ThreadSafeCache.new(params.fetch("lookup_cache_size", 512))

  # these are used for autopopulation only, not lookup/enrichment

  # autopopulate - either specified directly or read from ENV via autopopulate_env
  #   false - do not autopopulate netbox inventory when uninventoried devices are observed
  #   true - autopopulate netbox inventory when uninventoried devices are observed (not recommended)
  #
  # For now this is only done for devices/virtual machines, not for services or network segments.
  _autopopulate_str = params["autopopulate"]
  _autopopulate_env = params["autopopulate_env"]
  if _autopopulate_str.nil? && !_autopopulate_env.nil?
    _autopopulate_str = ENV[_autopopulate_env]
  end
  @autopopulate = [1, true, '1', 'true', 't', 'on', 'enabled'].include?(_autopopulate_str.to_s.downcase)

  # fields for device autopopulation
  @source_hostname = params["source_hostname"]
  @source_oui = params["source_oui"]
  @source_mac = params["source_mac"]
  @source_segment = params["source_segment"]
  @default_status = params.fetch("default_status", "active").to_sym

  # default manufacturer, role and device type if not specified, either specified directly or read from ENVs
  @default_manuf = params["default_manuf"]
  _default_manuf_env = params["default_manuf_env"]
  if @default_manuf.nil? && !_default_manuf_env.nil?
    @default_manuf = ENV[_default_manuf_env]
  end
  if !@default_manuf.nil? && @default_manuf.empty?
    @default_manuf = nil
  end

  _vendor_oui_map_path = params.fetch("vendor_oui_map_path", "/etc/vendor_macs.yaml")
  if File.exist?(_vendor_oui_map_path)
    @macarray = Array.new
    psych_load_yaml(_vendor_oui_map_path).each do |mac|
      @macarray.push([mac_string_to_integer(mac['low']), mac_string_to_integer(mac['high']), mac['name']])
    end
    # Array.bsearch only works on a sorted array
    @macarray.sort_by! { |k| [k[0], k[1]]}
  else
    @macarray = nil
  end
  @macregex = Regexp.new(/\A([0-9a-fA-F]{2}[-:.]){5}([0-9a-fA-F]{2})\z/)

  _vm_oui_map_path = params.fetch("vm_oui_map_path", "/etc/vm_macs.yaml")
  if File.exist?(_vm_oui_map_path)
    @vm_namesarray = Set.new
    psych_load_yaml(_vm_oui_map_path).each do |mac|
      @vm_namesarray.add(mac['name'].to_s.downcase)
    end
  else
    @vm_namesarray = Set[ "pcs computer systems gmbh",
                          "proxmox server solutions gmbh",
                          "vmware, inc.",
                          "xensource, inc." ]
  end

  @default_dtype = params["default_dtype"]
  _default_dtype_env = params["default_dtype_env"]
  if @default_dtype.nil? && !_default_dtype_env.nil?
    @default_dtype = ENV[_default_dtype_env]
  end
  if !@default_dtype.nil? && @default_dtype.empty?
    @default_dtype = nil
  end

  @default_role = params["default_role"]
  _default_role_env = params["default_role_env"]
  if @default_role.nil? && !_default_role_env.nil?
    @default_role = ENV[_default_role_env]
  end
  if !@default_role.nil? && @default_role.empty?
    @default_role = nil
  end

  # threshold for fuzzy string matching (for manufacturer, etc.)
  _autopopulate_fuzzy_threshold_str = params["autopopulate_fuzzy_threshold"]
  _autopopulate_fuzzy_threshold_str_env = params["autopopulate_fuzzy_threshold_env"]
  if _autopopulate_fuzzy_threshold_str.nil? && !_autopopulate_fuzzy_threshold_str_env.nil?
    _autopopulate_fuzzy_threshold_str = ENV[_autopopulate_fuzzy_threshold_str_env]
  end
  if _autopopulate_fuzzy_threshold_str.nil? || _autopopulate_fuzzy_threshold_str.empty?
    @autopopulate_fuzzy_threshold = 0.95
  else
    @autopopulate_fuzzy_threshold = _autopopulate_fuzzy_threshold_str.to_f
  end

  # if the manufacturer is not found, should we create one or use @default_manuf?
  _autopopulate_create_manuf_str = params["autopopulate_create_manuf"]
  _autopopulate_create_manuf_env = params["autopopulate_create_manuf_env"]
  if _autopopulate_create_manuf_str.nil? && !_autopopulate_create_manuf_env.nil?
    _autopopulate_create_manuf_str = ENV[_autopopulate_create_manuf_env]
  end
  @autopopulate_create_manuf = [1, true, '1', 'true', 't', 'on', 'enabled'].include?(_autopopulate_create_manuf_str.to_s.downcase)

  # if the prefix is not found, should we create one?
  _autopopulate_create_prefix_str = params["auto_prefix"]
  _autopopulate_create_prefix_env = params["auto_prefix_env"]
  if _autopopulate_create_prefix_str.nil? && !_autopopulate_create_prefix_env.nil?
    _autopopulate_create_prefix_str = ENV[_autopopulate_create_prefix_env]
  end
  @autopopulate_create_prefix = [1, true, '1', 'true', 't', 'on', 'enabled'].include?(_autopopulate_create_prefix_str.to_s.downcase)

  # case-insensitive hash of OUIs (https://standards-oui.ieee.org/) to Manufacturers (https://demo.netbox.dev/static/docs/core-functionality/device-types/)
  @manuf_hash = LruRedux::TTL::ThreadSafeCache.new(params.fetch("manuf_cache_size", 2048), @cache_ttl)

  # case-insensitive hash of role names to IDs
  @role_hash = LruRedux::TTL::ThreadSafeCache.new(params.fetch("role_cache_size", 256), @cache_ttl)

  # case-insensitive hash of site names to IDs
  @site_hash = LruRedux::TTL::ThreadSafeCache.new(params.fetch("site_cache_size", 128), @cache_ttl)

  # end of autopopulation arguments

  # used for massaging OUI/manufacturer names for matching
  @name_cleaning_patterns = [ /\ba[sbg]\b/,
                              /\b(beijing|shenzhen)\b/,
                              /\bbv\b/,
                              /\bco(rp(oration|orate)?)?\b/,
                              /\b(computer|network|electronic|solution|system)s?\b/,
                              /\bglobal\b/,
                              /\bgmbh\b/,
                              /\binc(orporated)?\b/,
                              /\bint(ernationa)?l?\b/,
                              /\bkft\b/,
                              /\blimi?ted\b/,
                              /\bllc\b/,
                              /\b(co)?ltda?\b/,
                              /\bpt[ey]\b/,
                              /\bpvt\b/,
                              /\boo\b/,
                              /\bsa\b/,
                              /\bsr[ol]s?\b/,
                              /\btech(nolog(y|ie|iya)s?)?\b/ ].freeze

  @private_ip_subnets = [
    IPAddr.new('10.0.0.0/8'),
    IPAddr.new('172.16.0.0/12'),
    IPAddr.new('192.168.0.0/16'),
  ].freeze

  @nb_headers = { 'Content-Type': 'application/json' }.freeze

  @device_tag_autopopulated = { 'slug': 'malcolm-autopopulated' }.freeze
  # for ip_device hash lookups, if a device is pulled out that has one of these tags
  #   it should be *updated* instead of just created. this allows us to create even less-fleshed
  #   out device entries from things like DNS entries but then give more information (like
  #   manufacturer) later on when actual traffic is observed. these values should match
  #   what's in netbox/preload/tags.yml
  @device_tag_manufacturer_unknown = { 'slug': 'manufacturer-unknown' }.freeze
  @device_tag_hostname_unknown = { 'slug': 'hostname-unknown' }.freeze

  @virtual_machine_device_type_name = "Virtual Machine".freeze

end

def filter(
  event
)
  _key = event.get("#{@source}")
  if (not @netbox_enabled) || @lookup_type.nil? || @lookup_type.empty? || _key.nil? || _key.empty?
    return [event]
  end

  # _key might be an array of IP addresses, but we're only going to set the first _result into @target.
  #    this is still useful, though as autopopulation may happen for multiple IPs even if we only
  #    store the result of the first one found
  if !_key.is_a?(Array) then
    _newKey = Array.new
    _newKey.push(_key) unless _key.nil?
    _key = _newKey
  end
  _result_set = false

  _key.each do |ip_key|

    _lookup_hash = @cache_hash.getset(@lookup_type){ LruRedux::TTL::ThreadSafeCache.new(@cache_size, @cache_ttl) }
    _result = _lookup_hash.getset(ip_key){ netbox_lookup(:event=>event, :ip_key=>ip_key) }

    if !_result.nil?

      if (_tags = _result.fetch(:tags, nil)) &&
         @autopopulate &&
         (@lookup_type == :ip_device) &&
         _tags.is_a?(Array) &&
         _tags.flatten! &&
         _tags.all? { |item| item.is_a?(Hash) } &&
         _tags.any? {|tag| tag[:slug] == @device_tag_autopopulated[:slug]}
      then
        _updated_result = nil
        if _tags.any? {|tag| tag[:slug] == @device_tag_hostname_unknown[:slug]} &&
          _autopopulate_hostname = event.get("#{@source_hostname}") &&
          !_autopopulate_hostname.to_s.empty?
        then
          # the hostname-unknown tag is set, but we appear to have a hostname
          #   from the event. we need to update the record in netbox (set the new hostname
          #   from this value and remove the tag) and in the result
          _updated_result = netbox_lookup(:event=>event, :ip_key=>ip_key, :previous_result=>_result)
          # puts('tried to update (1): %{result}' % { result: JSON.generate(_updated_result) })
        end
        if _tags.any? {|tag| tag[:slug] == @device_tag_manufacturer_unknown[:slug]}
          # the manufacturer-unknown tag is set, but we appear to have an OUI or MAC address
          #   from the event. we need to update the record in netbox (determine the manufacturer
          #   from this value and remove the tag) and in the result
          _updated_result = netbox_lookup(:event=>event, :ip_key=>ip_key, :previous_result=>_result)
          # puts('tried to update (2): %{result}' % { result: JSON.generate(_updated_result) })
        end
        _lookup_hash[ip_key] = (_result = _updated_result) if _updated_result
      end
      _result.delete(:tags)

      if _result.has_key?(:url) && !_result[:url]&.empty?
        _result[:url].map! { |u| u.delete_prefix(@netbox_url_base).gsub('/api/', '/') }
        if (@lookup_type == :ip_device) &&
           (!_result.has_key?(:device_type) || _result[:device_type]&.empty?) &&
           _result[:url].any? { |u| u.include? "virtual-machines" }
        then
          _result[:device_type] = [ @virtual_machine_device_type_name ]
        end
      end
    end
    unless _result_set || _result.nil? || _result.empty? || @target.nil? || @target.empty?
      event.set("#{@target}", _result)
      _result_set = true
    end
  end # _key.each do |ip_key|

  [event]
end

def mac_string_to_integer(
  string
)
  string.tr('.:-','').to_i(16)
end

def psych_load_yaml(
  filename
)
  parser = Psych::Parser.new(Psych::TreeBuilder.new)
  parser.code_point_limit = 64*1024*1024
  parser.parse(IO.read(filename, :mode => 'r:bom|utf-8'))
  yaml_obj = Psych::Visitors::ToRuby.create().accept(parser.handler.root)
  if yaml_obj.is_a?(Array) && (yaml_obj.length() == 1)
    yaml_obj.first
  else
    yaml_obj
  end
end

def collect_values(
  hashes
)
  # https://stackoverflow.com/q/5490952
  hashes.reduce({}){ |h, pairs| pairs.each { |k,v| (h[k] ||= []) << v}; h }
end

def crush(
  thing
)
  if thing.is_a?(Array)
    thing.each_with_object([]) do |v, a|
      v = crush(v)
      a << v unless [nil, [], {}, "", "Unspecified", "unspecified"].include?(v)
    end
  elsif thing.is_a?(Hash)
    thing.each_with_object({}) do |(k,v), h|
      v = crush(v)
      h[k] = v unless [nil, [], {}, "", "Unspecified", "unspecified"].include?(v)
    end
  else
    thing
  end
end

def clean_manuf_string(
  val
)
    # 0. downcase
    # 1. replace commas with spaces
    # 2. remove all punctuation (except parens)
    # 3. squash whitespace down to one space
    # 4. remove each of @name_cleaning_patterns (LLC, LTD, Inc., etc.)
    # 5. remove all punctuation (even parens)
    # 6. strip leading and trailing spaces
    new_val = val.downcase.gsub(',', ' ').gsub(/[^\(\)A-Za-z0-9\s]/, '').gsub(/\s+/, ' ')
    @name_cleaning_patterns.each do |pat|
      new_val = new_val.gsub(pat, '')
    end
    new_val = new_val.gsub(/[^A-Za-z0-9\s]/, '').gsub(/\s+/, ' ').lstrip.rstrip
    new_val
end

def lookup_or_create_site(
  site_name,
  nb
)
  @site_hash.getset(site_name) {
    begin
      _site = nil

      # look it up first
      _query = { :offset => 0,
                 :limit => 1,
                 :name => site_name }
      if (_sites_response = nb.get('dcim/sites/', _query).body) &&
         _sites_response.is_a?(Hash) &&
         (_tmp_sites = _sites_response.fetch(:results, [])) &&
         (_tmp_sites.length() > 0)
      then
         _site = _tmp_sites.first
      end

      if _site.nil?
        # the device site is not found, create it
        _site_data = { :name => site_name,
                       :slug => site_name.to_url,
                       :status => "active" }
        if (_site_create_response = nb.post('dcim/sites/', _site_data.to_json, @nb_headers).body) &&
           _site_create_response.is_a?(Hash) &&
           _site_create_response.has_key?(:id)
        then
           _site = _site_create_response
        end
      end

    rescue Faraday::Error
      # give up aka do nothing
    end
    _site
  }
end

def lookup_manuf(
  oui,
  nb
)
  @manuf_hash.getset(oui) {
    _fuzzy_matcher = FuzzyStringMatch::JaroWinkler.create( :pure )
    _oui_cleaned = clean_manuf_string(oui.to_s)
    _manufs = Array.new
    # fetch the manufacturers to do the comparison. this is a lot of work
    # and not terribly fast but once the hash it populated it shouldn't happen too often
    _query = { :offset => 0,
               :limit => @page_size }
    begin
      while true do
        if (_manufs_response = nb.get('dcim/manufacturers/', _query).body) &&
           _manufs_response.is_a?(Hash)
        then
          _tmp_manufs = _manufs_response.fetch(:results, [])
          _tmp_manufs.each do |_manuf|
            _tmp_name = _manuf.fetch(:name, _manuf.fetch(:display, nil))
            _tmp_distance = _fuzzy_matcher.getDistance(clean_manuf_string(_tmp_name.to_s), _oui_cleaned)
            if (_tmp_distance >= @autopopulate_fuzzy_threshold) then
              _manufs << { :name => _tmp_name,
                           :id => _manuf.fetch(:id, nil),
                           :url => _manuf.fetch(:url, nil),
                           :match => _tmp_distance,
                           :vm => false }
            end
          end
          _query[:offset] += _tmp_manufs.length()
          break unless (_tmp_manufs.length() >= @page_size)
        else
          break
        end
      end
    rescue Faraday::Error
      # give up aka do nothing
    end
    # return the manuf with the highest match
    # puts('0. %{key}: %{matches}' % { key: _autopopulate_oui_cleaned, matches: JSON.generate(_manufs) })-]
    !_manufs&.empty? ? _manufs.max_by{|k| k[:match] } : nil
  }
end

def lookup_prefixes(
  ip_str,
  lookup_site,
  nb
)
  prefixes = Array.new

  _query = { :contains => ip_str,
             :offset => 0,
             :limit => @page_size }
  _query[:site_n] = lookup_site unless lookup_site.nil? || lookup_site.empty?
  begin
    while true do
      if (_prefixes_response = nb.get('ipam/prefixes/', _query).body) &&
         _prefixes_response.is_a?(Hash)
      then
        _tmp_prefixes = _prefixes_response.fetch(:results, [])
        _tmp_prefixes.each do |p|
          # non-verbose output is flatter with just names { :name => "name", :id => "id", ... }
          # if verbose, include entire object as :details
          _prefixName = p.fetch(:description, nil)
          if _prefixName.nil? || _prefixName.empty?
            _prefixName = p.fetch(:display, p.fetch(:prefix, nil))
          end
          prefixes << { :name => _prefixName,
                        :id => p.fetch(:id, nil),
                        :site => ((_site = p.fetch(:site, nil)) && _site&.has_key?(:name)) ? _site[:name] : _site&.fetch(:display, nil),
                        :tenant => ((_tenant = p.fetch(:tenant, nil)) && _tenant&.has_key?(:name)) ? _tenant[:name] : _tenant&.fetch(:display, nil),
                        :url => p.fetch(:url, nil),
                        :tags => p.fetch(:tags, nil),
                        :details => @verbose ? p : nil }
        end
        _query[:offset] += _tmp_prefixes.length()
        break unless (_tmp_prefixes.length() >= @page_size)
      else
        break
      end
    end
  rescue Faraday::Error
    # give up aka do nothing
  end

  prefixes
end

def lookup_or_create_role(
  role_name,
  nb
)
  @role_hash.getset(role_name) {
    begin
      _role = nil

      # look it up first
      _query = { :offset => 0,
                 :limit => 1,
                 :name => role_name }
      if (_roles_response = nb.get('dcim/device-roles/', _query).body) &&
         _roles_response.is_a?(Hash) &&
         (_tmp_roles = _roles_response.fetch(:results, [])) &&
         (_tmp_roles.length() > 0)
      then
         _role = _tmp_roles.first
      end

      if _role.nil?
        # the role is not found, create it
        _role_data = { :name => role_name,
                       :slug => role_name.to_url,
                       :color => "d3d3d3" }
        if (_role_create_response = nb.post('dcim/device-roles/', _role_data.to_json, @nb_headers).body) &&
           _role_create_response.is_a?(Hash) &&
           _role_create_response.has_key?(:id)
        then
           _role = _role_create_response
        end
      end

    rescue Faraday::Error
      # give up aka do nothing
    end
    _role
  }
end

def lookup_devices(
  ip_str,
  lookup_site,
  lookup_service_port,
  url_base,
  url_suffix,
  nb
)
  _devices = Array.new
  _query = { :address => ip_str,
             :offset => 0,
             :limit => @page_size }
  begin
    while true do
      if (_ip_addresses_response = nb.get('ipam/ip-addresses/', _query).body) &&
         _ip_addresses_response.is_a?(Hash)
      then
        _tmp_ip_addresses = _ip_addresses_response.fetch(:results, [])
        _tmp_ip_addresses.each do |i|
          _is_device = nil
          if (_obj = i.fetch(:assigned_object, nil)) &&
             ((_device_obj = _obj.fetch(:device, nil)) ||
              (_virtualized_obj = _obj.fetch(:virtual_machine, nil)))
          then
            _is_device = !_device_obj.nil?
            _device = _is_device ? _device_obj : _virtualized_obj
            # if we can, follow the :assigned_object's "full" device URL to get more information
            _device = (_device.has_key?(:url) && (_full_device = nb.get(_device[:url].delete_prefix(url_base).delete_prefix(url_suffix).delete_prefix("/")).body)) ? _full_device : _device
            _device_id = _device.fetch(:id, nil)
            _device_site = ((_site = _device.fetch(:site, nil)) && _site&.has_key?(:name)) ? _site[:name] : _site&.fetch(:display, nil)
            next unless (_device_site.to_s.downcase == lookup_site.to_s.downcase) || lookup_site.nil? || lookup_site.empty? || _device_site.nil? || _device_site.empty?
            # look up service if requested (based on device/vm found and service port)
            if (lookup_service_port > 0)
              _services = Array.new
              _service_query = { (_is_device ? :device_id : :virtual_machine_id) => _device_id, :port => lookup_service_port, :offset => 0, :limit => @page_size }
              while true do
                if (_services_response = nb.get('ipam/services/', _service_query).body) &&
                   _services_response.is_a?(Hash)
                then
                  _tmp_services = _services_response.fetch(:results, [])
                  _services.unshift(*_tmp_services) unless _tmp_services.nil? || _tmp_services.empty?
                  _service_query[:offset] += _tmp_services.length()
                  break unless (_tmp_services.length() >= @page_size)
                else
                  break
                end
              end
              _device[:service] = _services
            end
            # non-verbose output is flatter with just names { :name => "name", :id => "id", ... }
            # if verbose, include entire object as :details
            _devices << { :name => _device.fetch(:name, _device.fetch(:display, nil)),
                          :id => _device_id,
                          :url => _device.fetch(:url, nil),
                          :tags => _device.fetch(:tags, nil),
                          :service => _device.fetch(:service, []).map {|s| s.fetch(:name, s.fetch(:display, nil)) },
                          :site => _device_site,
                          :role => ((_role = _device.fetch(:role, nil)) && _role&.has_key?(:name)) ? _role[:name] : _role&.fetch(:display, nil),
                          :cluster => ((_cluster = _device.fetch(:cluster, nil)) && _cluster&.has_key?(:name)) ? _cluster[:name] : _cluster&.fetch(:display, nil),
                          :device_type => ((_dtype = _device.fetch(:device_type, nil)) && _dtype&.has_key?(:name)) ? _dtype[:name] : _dtype&.fetch(:display, nil),
                          :manufacturer => ((_manuf = _device.dig(:device_type, :manufacturer)) && _manuf&.has_key?(:name)) ? _manuf[:name] : _manuf&.fetch(:display, nil),
                          :details => @verbose ? _device : nil }
          end
        end
        _query[:offset] += _tmp_ip_addresses.length()
        break unless (_tmp_ip_addresses.length() >= @page_size)
      else
        # weird/bad response, bail
        break
      end
    end # while true
  rescue Faraday::Error
    # give up aka do nothing
  end
  _devices
end

def autopopulate_devices(
  ip_str,
  autopopulate_mac,
  autopopulate_oui,
  autopopulate_default_site_name,
  autopopulate_default_role_name,
  autopopulate_default_dtype,
  autopopulate_default_manuf,
  autopopulate_hostname,
  autopopulate_default_status,
  nb
)

  _autopopulate_device = nil
  _autopopulate_role = nil
  _autopopulate_dtype = nil
  _autopopulate_oui = autopopulate_oui
  _autopopulate_manuf = nil
  _autopopulate_site = nil
  _autopopulate_tags = [ @device_tag_autopopulated ]

  # if MAC is set but OUI is not, do a quick lookup
  if (!autopopulate_mac.nil? && !autopopulate_mac.empty?) &&
     (_autopopulate_oui.nil? || _autopopulate_oui.empty?)
  then
    case autopopulate_mac
    when String
      if @macregex.match?(autopopulate_mac)
        _macint = mac_string_to_integer(autopopulate_mac)
        _vendor = @macarray.bsearch{ |_vendormac| (_macint < _vendormac[0]) ? -1 : ((_macint > _vendormac[1]) ? 1 : 0)}
        _autopopulate_oui = _vendor[2] unless _vendor.nil?
      end # autopopulate_mac matches @macregex
    when Array
      autopopulate_mac.each do |_addr|
        if @macregex.match?(_addr)
          _macint = mac_string_to_integer(_addr)
          _vendor = @macarray.bsearch{ |_vendormac| (_macint < _vendormac[0]) ? -1 : ((_macint > _vendormac[1]) ? 1 : 0)}
          if !_vendor.nil?
            _autopopulate_oui = _vendor[2]
            break
          end # !_vendor.nil?
        end # _addr matches @macregex
      end # autopopulate_mac.each do
    end # case statement autopopulate_mac String vs. Array
  end # MAC is populated but OUI is not

  # match/look up manufacturer based on OUI
  if !_autopopulate_oui.nil? && !_autopopulate_oui.empty?

    _autopopulate_oui = _autopopulate_oui.first() unless !_autopopulate_oui.is_a?(Array)

    # does it look like a VM or a regular device?
    if @vm_namesarray.include?(_autopopulate_oui.downcase)
      # looks like this is probably a virtual machine
      _autopopulate_manuf = { :name => _autopopulate_oui,
                              :match => 1.0,
                              :vm => true,
                              :id => nil }

    else
      # looks like this is not a virtual machine (or we can't tell) so assume its' a regular device
      _autopopulate_manuf = lookup_manuf(_autopopulate_oui, nb)
    end # virtual machine vs. regular device
  end # _autopopulate_oui specified

  # puts('1. %{key}: %{found}' % { key: _autopopulate_oui, found: JSON.generate(_autopopulate_manuf) })
  if !_autopopulate_manuf.is_a?(Hash)
    # no match was found at ANY match level (empty database or no OUI specified), set default ("unspecified") manufacturer
    _autopopulate_manuf = { :name => (@autopopulate_create_manuf && !_autopopulate_oui.nil? && !_autopopulate_oui.empty?) ? _autopopulate_oui : autopopulate_default_manuf,
                            :match => 0.0,
                            :vm => false,
                            :id => nil}
  end
  # puts('2. %{key}: %{found}' % { key: _autopopulate_oui, found: JSON.generate(_autopopulate_manuf) })

  if autopopulate_hostname.to_s.empty?
    _autopopulate_tags << @device_tag_hostname_unknown
  end

  # make sure the site and role exists
  _autopopulate_site = lookup_or_create_site(autopopulate_default_site_name, nb)
  _autopopulate_role = lookup_or_create_role(autopopulate_default_role_name, nb)

  # we should have found or created the autopopulate role and site
  begin
    if _autopopulate_site&.fetch(:id, nil)&.nonzero? &&
       _autopopulate_role&.fetch(:id, nil)&.nonzero?
    then

      if _autopopulate_manuf[:vm]
        # a virtual machine
        _device_name = autopopulate_hostname.to_s.empty? ? "#{_autopopulate_manuf[:name]} @ #{ip_str}" : autopopulate_hostname
        _device_data = { :name => _device_name,
                         :site => _autopopulate_site[:id],
                         :tags => _autopopulate_tags,
                         :status => autopopulate_default_status }
        if (_device_create_response = nb.post('virtualization/virtual-machines/', _device_data.to_json, @nb_headers).body) &&
           _device_create_response.is_a?(Hash) &&
           _device_create_response.has_key?(:id)
        then
           _autopopulate_device = _device_create_response
        end

      else
        # a regular non-vm device

        if !_autopopulate_manuf.fetch(:id, nil)&.nonzero?
          # the manufacturer was default (not found) so look it up first
          _query = { :offset => 0,
                     :limit => 1,
                     :name => _autopopulate_manuf[:name] }
          if (_manufs_response = nb.get('dcim/manufacturers/', _query).body) &&
             _manufs_response.is_a?(Hash) &&
             (_tmp_manufs = _manufs_response.fetch(:results, [])) &&
             (_tmp_manufs.length() > 0)
          then
             _autopopulate_manuf[:id] = _tmp_manufs.first.fetch(:id, nil)
             _autopopulate_manuf[:match] = 1.0
          end
        end
        # puts('3. %{key}: %{found}' % { key: _autopopulate_oui, found: JSON.generate(_autopopulate_manuf) })

        if !_autopopulate_manuf.fetch(:id, nil)&.nonzero?
          # the manufacturer is still not found, create it
          _manuf_data = { :name => _autopopulate_manuf[:name],
                          :tags => _autopopulate_tags,
                          :slug => _autopopulate_manuf[:name].to_url }
          if (_manuf_create_response = nb.post('dcim/manufacturers/', _manuf_data.to_json, @nb_headers).body) &&
             _manuf_create_response.is_a?(Hash)
          then
             _autopopulate_manuf[:id] = _manuf_create_response.fetch(:id, nil)
             _autopopulate_manuf[:match] = 1.0
          end
          # puts('4. %{key}: %{created}' % { key: _autopopulate_manuf, created: JSON.generate(_manuf_create_response) })
        end

        # at this point we *must* have the manufacturer ID
        if _autopopulate_manuf.fetch(:id, nil)&.nonzero?

          # never figured out the manufacturer, so tag it as such
          if (_autopopulate_manuf.fetch(:name, autopopulate_default_manuf) == autopopulate_default_manuf)
            _autopopulate_tags << @device_tag_manufacturer_unknown
          end

          # make sure the desired device type also exists, look it up first
          _query = { :offset => 0,
                     :limit => 1,
                     :manufacturer_id => _autopopulate_manuf[:id],
                     :model => autopopulate_default_dtype }
          if (_dtypes_response = nb.get('dcim/device-types/', _query).body) &&
             _dtypes_response.is_a?(Hash) &&
             (_tmp_dtypes = _dtypes_response.fetch(:results, [])) &&
             (_tmp_dtypes.length() > 0)
          then
             _autopopulate_dtype = _tmp_dtypes.first
          end

          if _autopopulate_dtype.nil?
            # the device type is not found, create it
            _dtype_data = { :manufacturer => _autopopulate_manuf[:id],
                            :model => autopopulate_default_dtype,
                            :tags => _autopopulate_tags,
                            :slug => autopopulate_default_dtype.to_url }
            if (_dtype_create_response = nb.post('dcim/device-types/', _dtype_data.to_json, @nb_headers).body) &&
               _dtype_create_response.is_a?(Hash) &&
               _dtype_create_response.has_key?(:id)
            then
               _autopopulate_dtype = _dtype_create_response
            end
          end

          # # now we must also have the device type ID
          if _autopopulate_dtype&.fetch(:id, nil)&.nonzero?

            # create the device
            _device_name = autopopulate_hostname.to_s.empty? ? "#{_autopopulate_manuf[:name]} @ #{ip_str}" : autopopulate_hostname
            _device_data = { :name => _device_name,
                             :device_type => _autopopulate_dtype[:id],
                             :role => _autopopulate_role[:id],
                             :site => _autopopulate_site[:id],
                             :tags => _autopopulate_tags,
                             :status => autopopulate_default_status }
            if (_device_create_response = nb.post('dcim/devices/', _device_data.to_json, @nb_headers).body) &&
               _device_create_response.is_a?(Hash) &&
               _device_create_response.has_key?(:id)
            then
               _autopopulate_device = _device_create_response
            end

          else
            # didn't figure out the device type ID, make sure we're not setting something half-populated
            _autopopulate_dtype = nil
          end # _autopopulate_dtype[:id] is valid

        else
          # didn't figure out the manufacturer ID, make sure we're not setting something half-populated
          _autopopulate_manuf = nil
        end # _autopopulate_manuf[:id] is valid

      end # virtual machine vs. regular device

    else
      # didn't figure out the IDs, make sure we're not setting something half-populated
      _autopopulate_site = nil
      _autopopulate_role = nil
    end # site and role are valid

  rescue Faraday::Error
    # give up aka do nothing
  end

  return _autopopulate_device,
         _autopopulate_role,
         _autopopulate_dtype,
         _autopopulate_oui,
         _autopopulate_manuf,
         _autopopulate_site
end

def autopopulate_prefixes(
  ip_obj,
  autopopulate_default_site,
  autopopulate_default_status,
  nb
)
  _autopopulate_tags = [ @device_tag_autopopulated ]

  _prefix_data = nil
  # TODO: IPv6?
  _private_ip_subnet = @private_ip_subnets.find { |subnet| subnet.include?(ip_obj) }
  if !_private_ip_subnet.nil?
    _new_prefix_ip = ip_obj.mask([_private_ip_subnet.prefix() + 8, 24].min)
    _new_prefix_name = _new_prefix_ip.to_s
    if !_new_prefix_name.to_s.include?('/')
      _new_prefix_name += '/' + _new_prefix_ip.prefix().to_s
    end
    _autopopulate_site = lookup_or_create_site(autopopulate_default_site, nb)
    _prefix_post = { :prefix => _new_prefix_name,
                     :description => _new_prefix_name,
                     :tags => _autopopulate_tags,
                     :site => _autopopulate_site&.fetch(:id, nil),
                     :status => autopopulate_default_status }
    begin
      _new_prefix_create_response = nb.post('ipam/prefixes/', _prefix_post.to_json, @nb_headers).body
      if _new_prefix_create_response &&
         _new_prefix_create_response.is_a?(Hash) &&
         _new_prefix_create_response.has_key?(:id)
      then
          _prefix_data = { :name => _new_prefix_name,
                           :id => _new_prefix_create_response.fetch(:id, nil),
                           :site => ((_site = _new_prefix_create_response.fetch(:site, nil)) && _site&.has_key?(:name)) ? _site[:name] : _site&.fetch(:display, nil),
                           :tenant => ((_tenant = _new_prefix_create_response.fetch(:tenant, nil)) && _tenant&.has_key?(:name)) ? _tenant[:name] : _tenant&.fetch(:display, nil),
                           :url => _new_prefix_create_response.fetch(:url, nil),
                           :tags => _new_prefix_create_response.fetch(:tags, nil),
                           :details => @verbose ? _new_prefix_create_response : nil }
      end
    rescue Faraday::Error
      # give up aka do nothing
    end
  end
  _prefix_data
end

def create_device_interface(
  ip_str,
  autopopulate_device,
  autopopulate_manuf,
  autopopulate_mac,
  nb
)

  _autopopulate_device = autopopulate_device
  _autopopulate_interface = nil
  _autopopulate_ip = nil
  _ip_obj = IPAddr.new(ip_str) rescue nil

  _interface_data = { autopopulate_manuf[:vm] ? :virtual_machine : :device => _autopopulate_device[:id],
                      :name => "e0",
                      :type => "other" }
  if !autopopulate_mac.nil? && !autopopulate_mac.empty?
    _interface_data[:mac_address] = autopopulate_mac.is_a?(Array) ? autopopulate_mac.first : autopopulate_mac
  end
  if (_interface_create_reponse = nb.post(autopopulate_manuf[:vm] ? 'virtualization/interfaces/' : 'dcim/interfaces/', _interface_data.to_json, @nb_headers).body) &&
     _interface_create_reponse.is_a?(Hash) &&
     _interface_create_reponse.has_key?(:id)
  then
     _autopopulate_interface = _interface_create_reponse
  end

  if !_autopopulate_interface.nil? && _autopopulate_interface.fetch(:id, nil)&.nonzero?
    # interface has been created, we need to create an IP address for it
    _interface_address = ip_str
    if !_interface_address.to_s.include?('/')
      _interface_address += '/' + (_ip_obj.nil? ? '32' : _ip_obj.prefix().to_s)
    end
    _ip_data = { :address => _interface_address,
                 :assigned_object_type => autopopulate_manuf[:vm] ? "virtualization.vminterface" : "dcim.interface",
                 :assigned_object_id => _autopopulate_interface[:id],
                 :status => "active" }
    if (_ip_create_reponse = nb.post('ipam/ip-addresses/', _ip_data.to_json, @nb_headers).body) &&
       _ip_create_reponse.is_a?(Hash) &&
       _ip_create_reponse.has_key?(:id)
    then
       _autopopulate_ip = _ip_create_reponse
    end
  end # check if interface was created and has ID

  if !_autopopulate_ip.nil? && _autopopulate_ip.fetch(:id, nil)&.nonzero?
    # IP address was created, need to associate it as the primary IP for the device
    _primary_ip_data = { _ip_obj&.ipv6? ? :primary_ip6 : :primary_ip4 => _autopopulate_ip[:id] }
    if (_ip_primary_reponse = nb.patch("#{autopopulate_manuf[:vm] ? 'virtualization/virtual-machines' : 'dcim/devices'}/#{_autopopulate_device[:id]}/", _primary_ip_data.to_json, @nb_headers).body) &&
       _ip_primary_reponse.is_a?(Hash) &&
       _ip_primary_reponse.has_key?(:id)
    then
       _autopopulate_device = _ip_create_reponse
    end
  end # check if the IP address was created and has an ID

  _autopopulate_device
end

def netbox_lookup(
  event:,
  ip_key:,
  previous_result: nil
)
  _lookup_result = nil

  _key_ip = IPAddr.new(ip_key) rescue nil
  if !_key_ip.nil? && _key_ip&.private? && (@autopopulate || (!@target.nil? && !@target.empty?))

    _nb = Faraday.new(@netbox_url) do |conn|
      conn.request :authorization, 'Token', @netbox_token
      conn.request :url_encoded
      conn.response :json, :parser_options => { :symbolize_names => true }
    end

    _lookup_service_port = (@lookup_service ? event.get("#{@lookup_service_port_source}") : nil).to_i
    _autopopulate_default_manuf = (@default_manuf.nil? || @default_manuf.empty?) ? "Unspecified" : @default_manuf
    _autopopulate_default_role = (@default_role.nil? || @default_role.empty?) ? "Unspecified" : @default_role
    _autopopulate_default_dtype = (@default_dtype.nil? || @default_dtype.empty?) ? "Unspecified" : @default_dtype
    _autopopulate_default_site =  (@lookup_site.nil? || @lookup_site.empty?) ? "default" : @lookup_site
    _autopopulate_hostname = event.get("#{@source_hostname}")
    _autopopulate_mac = event.get("#{@source_mac}")
    _autopopulate_oui = event.get("#{@source_oui}")

    _autopopulate_device = nil
    _autopopulate_role = nil
    _autopopulate_dtype = nil
    _autopopulate_manuf = nil
    _autopopulate_site = nil
    _prefixes = nil
    _devices = nil

    # handle :ip_device first, because if we're doing autopopulate we're also going to use
    # some of the logic from :ip_prefix

    if (@lookup_type == :ip_device)

      if (previous_result.nil? || previous_result.empty?)
        #################################################################################
        # retrieve the list of IP addresses where address matches the search key, limited to "assigned" addresses.
        # then, for those IP addresses, search for devices pertaining to the interfaces assigned to each
        # IP address (e.g., ipam.ip_address -> dcim.interface -> dcim.device, or
        # ipam.ip_address -> virtualization.interface -> virtualization.virtual_machine)
        _devices = lookup_devices(ip_key, @lookup_site, _lookup_service_port, @netbox_url_base, @netbox_url_suffix, _nb)

        if @autopopulate && (_devices.nil? || _devices.empty?)
          # no results found, autopopulate enabled, private-space IP address...
          # let's create an entry for this device
          _autopopulate_device,
          _autopopulate_role,
          _autopopulate_dtype,
          _autopopulate_oui,
          _autopopulate_manuf,
          _autopopulate_site = autopopulate_devices(ip_key,
                                                    _autopopulate_mac,
                                                    _autopopulate_oui,
                                                    _autopopulate_default_site,
                                                    _autopopulate_default_role,
                                                    _autopopulate_default_dtype,
                                                    _autopopulate_default_manuf,
                                                    _autopopulate_hostname,
                                                    @default_status,
                                                    _nb)
          if !_autopopulate_device.nil?
            # puts('5. %{key}: %{found}' % { key: autopopulate_oui, found: JSON.generate(_autopopulate_manuf) })
            # we created a device, so send it back out as the result for the event as well
            _devices = Array.new unless _devices.is_a?(Array)
            _devices << { :name => _autopopulate_device&.fetch(:name, _autopopulate_device&.fetch(:display, nil)),
                          :id => _autopopulate_device&.fetch(:id, nil),
                          :url => _autopopulate_device&.fetch(:url, nil),
                          :tags => _autopopulate_device&.fetch(:tags, nil),
                          :site => _autopopulate_site&.fetch(:name, nil),
                          :role => _autopopulate_role&.fetch(:name, nil),
                          :device_type => _autopopulate_dtype&.fetch(:name, nil),
                          :manufacturer => _autopopulate_manuf&.fetch(:name, nil),
                          :details => @verbose ? _autopopulate_device : nil }
          end # _autopopulate_device was not nil (i.e., we autocreated a device)
        end # _autopopulate turned on and no results found

      elsif @autopopulate
        #################################################################################
        # update with new information on an existing device (i.e., from a previous call to netbox_lookup)
        _patched_device_data = {}

        # get existing tags to update them to remove "unkown-..." values if needed
        _tags = previous_result.fetch(:tags, nil)&.flatten&.map{ |hash| { slug: hash[:slug] } }&.uniq

        # API endpoint is different for VM vs real device
        _is_vm = (previous_result.fetch(:device_type, nil)&.flatten&.any? {|dt| dt == @virtual_machine_device_type_name} ||
                  (previous_result.has_key?(:url) && !previous_result[:url]&.empty? && previous_result[:url].any? { |u| u.include? "virtual-machines" }))

        # get previous device ID (should only be dealing with a single device)
        _previous_device_id = previous_result.fetch(:id, nil)&.flatten&.uniq
        if _previous_device_id.is_a?(Array) &&
          (_previous_device_id.length() == 1) &&
          (_previous_device_id = _previous_device_id.first)
        then

          if !_autopopulate_hostname.to_s.empty? &&
             _tags&.any? {|tag| tag[:slug] == @device_tag_hostname_unknown[:slug]}
          then
            # a hostname field was specified, which means we're going to overwrite the device name previously created
            #   which was probably something like "Dell @ 192.168.10.100" and also remove the "unknown hostname" tag
            _patched_device_data = { :name => _autopopulate_hostname }
            _tags = _tags.filter{|tag| tag[:slug] != @device_tag_hostname_unknown[:slug]}
          end

          if _tags&.any? {|tag| tag[:slug] == @device_tag_manufacturer_unknown[:slug]}
            # TODO: handle device_tag_manufacturer_unknown
            # _tags = _tags.filter{|tag| tag[:slug] != @device_tag_manufacturer_unknown[:slug]}
          end

          if !_patched_device_data.empty? # we've got changes to make, so do it
            _patched_device_data[:tags] = _tags
            if (_patched_device_response = _nb.patch("#{_is_vm ? 'virtualization/virtual-machines' : 'dcim/devices'}/#{_previous_device_id}/", _patched_device_data.to_json, @nb_headers).body) &&
               _patched_device_response.is_a?(Hash) &&
               _patched_device_response.has_key?(:id)
            then
              # we've made the change to netbox, do a call to lookup_devices to get the formatted/updated data
              #   (yeah, this is a *little* inefficient, but this should really only happen one extra time per device at most)
               _devices = lookup_devices(ip_key, @lookup_site, _lookup_service_port, @netbox_url_base, @netbox_url_suffix, _nb)
            end # _nb.patch succeeded
          end # check _patched_device_data

        end # check previous device ID is valid
      end # check on previous_result function argument

      if !_devices.nil?
        _devices = collect_values(crush(_devices))
        _devices.fetch(:service, [])&.flatten!&.uniq!
        _lookup_result = _devices
      end
    end # @lookup_type == :ip_device

    # this || is because we are going to need to do the prefix lookup if we're autopopulating
    # as well as if we're specifically requested to do that enrichment

    if (@lookup_type == :ip_prefix) || !_autopopulate_device.nil?
    #################################################################################
      # retrieve the list of IP address prefixes containing the search key
      _prefixes = lookup_prefixes(ip_key, @lookup_site, _nb)

      if (_prefixes.nil? || _prefixes.empty?) && @autopopulate_create_prefix
        # we didn't find a prefix containing this private-space IPv4 address and auto-create is true
        _prefix_info = autopopulate_prefixes(_key_ip, _autopopulate_default_site, @default_status, _nb)
        _prefixes = Array.new unless _prefixes.is_a?(Array)
        _prefixes << _prefix_info
      end # if auto-create prefix

      _prefixes = collect_values(crush(_prefixes))
      _lookup_result = _prefixes unless (@lookup_type != :ip_prefix)
    end # @lookup_type == :ip_prefix

    if !_autopopulate_device.nil? && _autopopulate_device.fetch(:id, nil)&.nonzero?
      # device has been created, we need to create an interface for it
      _autopopulate_device = create_device_interface(ip_key,
                                                     _autopopulate_device,
                                                     _autopopulate_manuf,
                                                     _autopopulate_mac,
                                                     _nb)
    end # check if device was created and has ID
  end # IP address is private IP

  # yield return value for cache_hash getset
  _lookup_result
end

###############################################################################
# tests

###############################################################################