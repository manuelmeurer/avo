module Avo
  module Fields
    class FilesField < BaseField
      attr_accessor :is_audio
      attr_accessor :is_image
      attr_accessor :direct_upload
      attr_accessor :accept
      attr_reader :display_filename
      attr_reader :view_type
      attr_reader :hide_view_type_switcher

      def initialize(id, **args, &block)
        super(id, **args, &block)

        @is_audio = args[:is_audio].present? ? args[:is_audio] : false
        @is_image = args[:is_image].present? ? args[:is_image] : @is_avatar
        @direct_upload = args[:direct_upload].present? ? args[:direct_upload] : false
        @accept = args[:accept].present? ? args[:accept] : nil
        @display_filename = args[:display_filename].nil? ? true : args[:display_filename]
        @view_type = args[:view_type] || :grid
        @hide_view_type_switcher = args[:hide_view_type_switcher]
      end

      def view_component_name
        "FilesField"
      end

      def to_permitted_param
        {"#{id}": []}
      end

      def fill_field(record, key, value, params)
        return record unless record.methods.include? key.to_sym

        # attach files in one call to avoid index_active_storage_attachments_uniqueness violation
        record.send(key).attach(value.compact_blank)

        record
      end
    end
  end
end
