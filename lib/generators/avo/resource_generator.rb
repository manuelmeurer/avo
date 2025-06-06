require_relative "named_base_generator"
require_relative "concerns/parent_controller"
require_relative "concerns/override_controller"

module Generators
  module Avo
    class ResourceGenerator < NamedBaseGenerator
      include Concerns::ParentController
      include Concerns::OverrideController

      source_root File.expand_path("templates", __dir__)

      namespace "avo:resource"

      class_option "model-class",
        desc: "The name of the model.",
        type: :string,
        required: false

      class_option "array",
        desc: "Indicates if the resource should be an array.",
        type: :boolean,
        default: false

      class_option "http",
        desc: "Indicates if the resource should be HTTP.",
        type: :boolean,
        default: false

      def create
        return if override_controller?

        template "resource/resource.tt", "app/avo/resources/#{resource_name}.rb"
        invoke "avo:controller", [resource_name], options
      end

      no_tasks do
        def parent_resource
          if options["array"]
            "Avo::Resources::ArrayResource"
          elsif options["http"]
            "Avo::Core::Resources::Http"
          else
            "Avo::BaseResource"
          end
        end

        def can_connect_to_the_database?
          result = false
          begin
            ActiveRecord::Migration.check_all_pending!

            result = true
            # If all migrations were completed, try to generate some resource files
          rescue NoMethodError
            # Ignore #<NoMethodError: undefined method `check_all_pending!' for an instance of ActiveRecord::Migration>]
            result = true
          rescue ActiveRecord::ConnectionNotEstablished
            puts error_message("Connection not established.\nRun 'rails db:setup' to resolve.")
          rescue ActiveRecord::PendingMigrationError
            puts error_message("Migrations are pending.\nRun 'rails db:migrate' to resolve.")
          rescue => e
            puts "Something went wrong while trying to generate an Avo resource: #{e}"
          end

          result
        end

        def error_message(extra)
          "Avo will not attempt to create resources for you.\n#{extra}\nThen run 'rails generate avo:all_resources' to generate all your resources."
        end

        def resource_class
          class_name.remove(":").to_s
        end

        def controller_class
          "Avo::#{class_name.remove(":").pluralize}Controller"
        end

        def resource_name
          model_resource_name.to_s
        end

        def controller_name
          "#{model_resource_name.pluralize}_controller"
        end

        def current_models
          ActiveRecord::Base.connection.tables.map do |model|
            model.capitalize.singularize.camelize
          end
        rescue ActiveRecord::NoDatabaseError
          puts "Database not found, please create your database and regenerate the resource."
          []
        rescue ActiveRecord::ConnectionNotEstablished
          puts "Database connection error, please create your database and regenerate the resource."
          []
        end

        def class_from_args
          @class_from_args ||= options["model-class"]&.camelize || (class_name if class_name.include?("::"))
        end

        def model_class_from_args
          if class_from_args.present? || class_name.include?("::")
            "\n  self.model_class = ::#{class_from_args || class_name}"
          end
        end

        def model_class
          @model_class ||= class_from_args || singular_name
        end

        def model
          @model ||= model_class.classify.safe_constantize
        end

        def model_db_columns
          @model_db_columns ||= model.columns_hash.except(*db_columns_to_ignore)
        rescue ActiveRecord::NoDatabaseError
          puts "Database not found, please create your database and regenerate the resource."
          []
        rescue ActiveRecord::ConnectionNotEstablished
          puts "Database connection error, please create your database and regenerate the resource."
          []
        end

        def db_columns_to_ignore
          %w[id encrypted_password reset_password_token reset_password_sent_at remember_created_at created_at updated_at password_digest]
        end

        def reflections
          @reflections ||= model.reflections.reject do |name, _|
            reflections_sufixes_to_ignore.include?(name.split("_").pop) || reflections_to_ignore.include?(name)
          end
        end

        def reflections_sufixes_to_ignore
          %w[blob blobs tags]
        end

        def reflections_to_ignore
          %w[taggings]
        end

        def attachments
          @attachments ||= reflections.select do |_, reflection|
            reflection.options[:class_name] == "ActiveStorage::Attachment"
          end
        end

        def rich_texts
          @rich_texts ||= reflections.select do |_, reflection|
            reflection.options[:class_name] == "ActionText::RichText"
          end
        end

        def tags
          @tags ||= reflections.select { |_, reflection| reflection.options[:as] == :taggable }
        end

        def associations
          @associations ||= reflections.reject do |key|
            attachments.key?(key) || tags.key?(key) || rich_texts.key?(key)
          end
        end

        def fields
          @fields ||= {}
        end

        def invoked_by_model_generator?
          @options.dig("from_model_generator")
        end

        def field_string(name, type, options)
          "field :#{name}, as: :#{type}#{options}"
        end

        def fields_from_model_rich_texts
          rich_texts.each do |name, _|
            fields[name.delete_prefix("rich_text_")] = {field: "trix"}
          end
        end

        def fields_from_model_tags
          tags.each do |name, _|
            fields[(remove_last_word_from name).pluralize] = {field: "tags"}
          end
        end

        def fields_from_model_associations
          associations.each do |name, association|
            fields[name] =
              if association.polymorphic?
                field_with_polymorphic_association(association)
              elsif association.is_a?(ActiveRecord::Reflection::ThroughReflection)
                field_from_through_association(association)
              else
                ::Avo::Mappings::ASSOCIATIONS_MAPPING[association.class]
              end
          end
        end

        def field_with_polymorphic_association(association)
          Rails.application.eager_load! unless Rails.application.config.eager_load

          types = polymorphic_association_types(association)

          {
            field: "belongs_to",
            options: {
              polymorphic_as: ":#{association.name}",
              types: types.presence || "[] # Types weren't computed correctly. Please configure them."
            }
          }
        end

        def polymorphic_association_types(association)
          ActiveRecord::Base.descendants.filter_map do |model|
            Inspector.new(model.name) if model.reflect_on_all_associations(:has_many).any? { |assoc| assoc.options[:as] == association.name }
          end
        end

        def field_from_through_association(association)
          if association.through_reflection.is_a?(ActiveRecord::Reflection::HasManyReflection) || association.through_reflection.is_a?(ActiveRecord::Reflection::ThroughReflection)
            {
              field: "has_many",
              options: {
                through: ":#{association.options[:through]}"
              }
            }
          else
            # If the through_reflection is not a HasManyReflection, add it to the fields hash using the class of the through_reflection
            # ex (team.rb): has_one :admin, through: :admin_membership, source: :user
            # we use the class of the through_reflection (HasOneReflection -> has_one :admin) to generate the field
            ::Avo::Mappings::ASSOCIATIONS_MAPPING[association.through_reflection.class]
          end
        end

        def fields_from_model_attachements
          attachments.each do |name, attachment|
            fields[remove_last_word_from name] = ::Avo::Mappings::ATTACHMENTS_MAPPING[attachment.class]
          end
        end

        # "hello_world_hehe".split('_') => ['hello', 'world', 'hehe']
        # ['hello', 'world', 'hehe'].pop => ['hello', 'world']
        # ['hello', 'world'].join('_') => "hello_world"
        def remove_last_word_from(snake_case_string)
          snake_case_string = snake_case_string.split("_")
          snake_case_string.pop
          snake_case_string.join("_")
        end

        def fields_from_model_enums
          model.defined_enums.each_key do |enum|
            fields[enum] = {
              field: "select",
              options: {
                enum: "::#{model_class.classify}.#{enum.pluralize}"
              }
            }
          end
        end

        def fields_from_model_db_columns
          model_db_columns.each do |name, data|
            fields[name] = field(name, data.type)
          end
        end

        def generate_fields
          return generate_fields_from_args if invoked_by_model_generator?
          return unless can_connect_to_the_database?

          if model.blank?
            puts "Can't generate fields from model. '#{model_class}.rb' not found!"
            return
          end

          fields_from_model_db_columns
          fields_from_model_enums
          fields_from_model_attachements
          fields_from_model_associations
          fields_from_model_rich_texts
          fields_from_model_tags

          generated_fields_template
        end

        def generated_fields_template
          return if fields.blank?

          fields_string = ""

          fields.each do |field_name, field_options|
            # if field_options are not available (likely a missing resource for an association), skip the field
            fields_string += "\n    # Could not generate a field for #{field_name}" and next unless field_options

            options = ""
            field_options[:options].each { |k, v| options += ", #{k}: #{v}" } if field_options[:options].present?

            fields_string += "\n    #{field_string field_name, field_options[:field], options}"
          end

          fields_string
        end

        def generate_fields_from_args
          @args.each do |arg|
            name, type = arg.split(":")
            type = "string" if type.blank?
            fields[name] = field(name, type.to_sym)
          end

          generated_fields_template
        end

        def field(name, type)
          ::Avo::Mappings::NAMES_MAPPING[name.to_sym] || ::Avo::Mappings::FIELDS_MAPPING[type&.to_sym] || {field: "text"}
        end
      end
    end

    # This class modifies the inspect function to correctly handle polymorphic associations.
    # It is used in the polymorphic_association_types function.
    # Without modification: Model(id: integer, name: string)
    # After modification: Model
    class Inspector
      attr_accessor :name
      def initialize(name)
        @name = name
      end

      def inspect
        name
      end
    end
  end
end
