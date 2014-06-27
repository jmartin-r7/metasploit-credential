# This class is used to export {Metasploit::Credential::Core} information, optionally scoped to associated
# {Metasploit::Credential::Login} objects.  In the case of exporting Login objects, the associated `Mdm::Host`
# and `Mdm::Server` information is exported as well. Exported data can be optionally scoped to include only
# a certain whitelist of database IDs.
#
# The {#export!} method creates a zip file on disk containing a CSV with the data.  If the {#workspace} contains
# {Metasploit::Credential::SSHKey} objects on the exported {Metasploit::Credential::Core} objects, the keys are
# exported to files inside a subdirectory of the zip file.
# @example Exporting all Cores
#   core_exporter = Metasploit::Credential::Exporter::Core.new(workspace: workspace, mode: :core)
#   core_exporter.export!
#   core_exporter.output_zipfile_path # => location of finished zip file
# @example Exporting all Logins
#   core_exporter = Metasploit::Credential::Exporter::Login.new(workspace: workspace, mode: :login)
#   core_exporter.export!
#   core_exporter.output_zipfile_path # => location of finished zip file
# @example Exporting with whitelist
#   core_exporter = Metasploit::Credential::Exporter::Login.new(workspace: workspace, mode: :login, whitelist_ids: whitelist_ids)
#   core_exporter.export!
#   core_exporter.output_zipfile_path # => location of finished zip file
class Metasploit::Credential::Exporter::Core
  include Metasploit::Credential::Exporter::Base

  #
  # Constants
  #


  # The symbol representation of the mode for exporting {Metasploit::Credential::Core} objects
  CORE_MODE = :core

  # The symbol representation of the mode for exporting {Metasploit::Credential::Login} objects
  LOGIN_MODE = :login

  # Valid modes
  ALLOWED_MODES  = [LOGIN_MODE, CORE_MODE]

  # The downcased and Symbolized name of the default object type to export
  DEFAULT_MODE  = LOGIN_MODE

  # An argument to {Dir::mktmpdir}
  TEMP_ZIP_PATH_PREFIX = "metasploit-exports"


  #
  # Attributes
  #

  # @!attribute export_data
  #   Holds the raw information from the database before it is formatted into the {#data} attribute
  #   @return [Array]
  attr_accessor :export_data

  # @!attribute finalized_zip_file
  #   The final output artifacts, zipped
  #   @return [Zip::File]
  attr_accessor :finalized_zip_file

  # @!attribute mode
  #   One of `:login` or `:core`
  #   @return [Symbol]
  attr_accessor :mode

  # @!attribute whitelist_ids
  #   A list of primary key IDs used to filter the objects in {#export_data}
  #   @return [Array<Fixnum>]
  attr_accessor :whitelist_ids


  #
  # Instance Methods
  #


  # The munged data that will be iterated over for export
  # @return [Array]
  def data
    return export_data if whitelist_ids.blank?
    export_data.select{ |datum| whitelist_ids.include? datum.id }
  end

  # Perform the export, creating the CSV and the zip file
  # @return [void]
  def export!
    render_manifest_output_and_keys
    render_zip
  end

  # Returns an `Enumerable` full of either {Metasploit::Credential::Login} or {Metasploit::Credential::Core} objects
  # depending on {#mode}
  # @return [ActiveRecord::Relation]
  def export_data
    unless instance_variable_defined? :@export_data
      @export_data = case mode
        when LOGIN_MODE
          Metasploit::Credential::Login.in_workspace_including_hosts_and_services(workspace)
        when CORE_MODE
          Metasploit::Credential::Core.workspace_id(workspace.id)
      end
    end
    @export_data
  end

  def initialize(args)
    @mode = args[:mode].present? ? args.fetch(:mode) : DEFAULT_MODE
    fail "Invalid mode" unless ALLOWED_MODES.include?(mode)
    super args
  end

  # Returns the CSV header line, which is dependent on mode
  # @return [Array<Symbol>]
  def header_line
    case mode
      when LOGIN_MODE
        Metasploit::Credential::Importer::Core::VALID_LONG_CSV_HEADERS.push(:host_address, :service_port, :service_name, :service_protocol)
      when CORE_MODE
        Metasploit::Credential::Importer::Core::VALID_LONG_CSV_HEADERS
    end
  end

  # Returns a platform-agnostic filesystem path where the key data will be saved as a file
  # @param line [Hash] the result of {#line_for_login} or #{line_for_core}
  # @return [String]
  def path_for_key(datum)
    core = datum.is_a?(Metasploit::Credential::Core) ? datum : datum.core
    dir_path = File.join(output_final_directory_path, Metasploit::Credential::Importer::Zip::KEYS_SUBDIRECTORY_NAME)
    FileUtils.mkdir_p(dir_path)
    File.join(dir_path,"#{core.public.username}-#{core.private.id}")
  end

  # Take a login and return a [Hash] that will be used for a CSV row.
  # The hashes returned by this method will contain credentials for
  # networked devices which may or may not successfully authenticate to those
  # devices.
  # @param login [Metasploit::Credential::Login]
  # @return [Hash]
  def line_for_login(login)
    result = line_for_core(login.core)
    result.merge({
      host_address: login.service.host.address,
      service_port: login.service.port,
      service_name: login.service.name,
      service_protocol: login.service.proto
    })
  end

  # Returns a lookup for cores containing data from the given {Metasploit::Credential::Core} object's
  # component types in order that it can be used as a CSV row.
  # @param core [Metasploit::Credential::Core]
  # @return [Hash]
  def line_for_core(core)
    {
      username: core.public.username,
      private_type: core.private.type,
      private_data: core.private.data,
      realm_key: core.realm.key,
      realm_value: core.realm.value,
    }
  end

  # The IO object representing the manifest CSV that contains the exported data (other than SSH keys)
  # @return [IO]
  def output
    @output ||= File.open(File.join(output_final_directory_path, Metasploit::Credential::Importer::Zip::MANIFEST_FILE_NAME), 'w')
  end

  # The platform-independent location of the export directory on disk, set in `Dir.tmpdir` by default
  # @return [String]
  def output_final_directory_path
    unless instance_variable_defined? :@output_final_directory_path
      tmp_path  = Dir.mktmpdir(TEMP_ZIP_PATH_PREFIX)
      @output_final_directory_path = File.join(tmp_path, output_final_subdirectory_name)
      FileUtils.mkdir_p @output_final_directory_path
    end
    @output_final_directory_path
  end

  # The final fragment of the {#output_final_directory_path}
  # @return [String]
  def output_final_subdirectory_name
    @output_final_subdiretory_name ||= "export-#{Time.now.to_i}"
  end

  # The path to the finished `Zip::File` on disk
  # @return [String]
  def output_zipfile_path
    Pathname.new(output_final_directory_path).dirname.to_s + '/' + zip_filename
  end

  # Iterate over the {#export_data} and write lines to the CSV at {#output}, returning the completed
  # CSV file.
  # @return [CSV]
  def render_manifest_output_and_keys
    CSV.open(output, 'wb') do |csv|
      csv << header_line
      data.each do |datum|
        line = self.send("line_for_#{mode}", datum)

        # Special-case any SSHKeys in the import
        if line[:private_type] == Metasploit::Credential::SSHKey.name
          key_path = path_for_key(datum)
          write_key_file(key_path, line[:private_data])
          line[:private_data] = File.basename(key_path)
        end

        csv << line.values
      end
    end
  end

  # Creates a `Zip::File` by recursively zipping up the contents of {#output_final_directory_path}
  # @return [void]
  def render_zip
    Zip::File.open(output_zipfile_path, Zip::File::CREATE) do |zipfile|
      Dir[File.join(output_final_directory_path, '**', '**')].each do |file|
        zipfile.add(file.sub(output_final_directory_path + '/', ''), file)
      end
    end
  end

  # @param path [String] the filesystem path where the +data+ will be written
  # @param data [String] the key data that will be written out at +path+
  # @return [void]
  def write_key_file(path, data)
    File.open(path, 'w') do |file|
      file << data
    end
  end

  # Returns the basename of the {#output_final_directory_path}
  # @return [String]
  def zip_filename
    output_final_subdirectory_name + ".zip"
  end
end