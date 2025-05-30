class Avo::ResourceComponent < Avo::BaseComponent
  include Avo::Concerns::ChecksAssocAuthorization
  include Avo::Concerns::RequestMethods
  include Avo::Concerns::HasResourceStimulusControllers

  attr_reader :fields_by_panel
  attr_reader :has_one_panels
  attr_reader :has_many_panels
  attr_reader :has_as_belongs_to_many_panels
  attr_reader :resource_tools
  attr_reader :resource
  attr_reader :view

  def can_create?
    return authorize_association_for(:create) if @reflection.present?

    @resource.authorization.authorize_action(:create, raise_exception: false)
  end

  def can_delete?
    return authorize_association_for(:destroy) if @reflection.present?

    @resource.authorization.authorize_action(:destroy, raise_exception: false)
  end

  def can_detach?
    return false if @reflection.blank? || @resource.record.blank? || !authorize_association_for(:detach)

    # If the inverse_of is a belongs_to, we need to check if it's optional in order to know if we can detach it.
    if inverse_of.is_a?(ActiveRecord::Reflection::BelongsToReflection)
      inverse_of.options[:optional]
    else
      true
    end
  end

  def detach_path
    return "/" if @reflection.blank?

    helpers.resource_detach_path(params[:resource_name], params[:id], @reflection.name.to_s, @resource.record_param)
  end

  def can_see_the_edit_button?
    # Disable edit for ArrayResources
    return false if @resource.resource_type_array?

    return authorize_association_for(:edit) if @reflection.present?

    @resource.authorization.authorize_action(:edit, raise_exception: false)
  end

  def can_see_the_destroy_button?
    # Disable destroy for ArrayResources
    return false if @resource.resource_type_array?

    @resource.authorization.authorize_action(:destroy, raise_exception: false)
  end

  def can_see_the_actions_button?
    return authorize_association_for(:act_on) if @reflection.present?

    @resource.authorization.authorize_action(:act_on, raise_exception: false) && !has_reflection_and_is_read_only
  end

  def destroy_path
    args = {record: @resource.record, resource: @resource}

    args[:referrer] = if params[:via_resource_class].present?
      back_path
    # If we're deleting a resource from a parent resource, we need to go back to the parent resource page after the deletion
    elsif @parent_resource.present?
      helpers.resource_path(record: @parent_record, resource: @parent_resource)
    end

    helpers.resource_path(**args)
  end

  def main_panel
    @main_panel ||= @resource.get_items.find do |item|
      item.is_main_panel?
    end
  end

  def sidebars
    return [] if Avo.license.lacks_with_trial(:resource_sidebar)

    @sidebars ||= @item.items
      .select do |item|
        item.is_sidebar?
      end
      .map do |sidebar|
        sidebar.hydrate(view: view, resource: resource)
      end
  end

  def has_reflection_and_is_read_only
    if @reflection.present? && @reflection.active_record.name && @reflection.name
      resource = Avo.resource_manager.get_resource_by_model_class(@reflection.active_record.name).new(params: helpers.params, view: view, user: helpers._current_user)
      fields = resource.get_field_definitions
      filtered_fields = fields.filter { |f| f.id == @reflection.name }
    else
      return false
    end

    if filtered_fields.present?
      filtered_fields.find { |f| f.id == @reflection.name }.is_disabled?
    else
      false
    end
  end

  def render_control(control)
    send :"render_#{control.type}", control
  end

  def render_cards_component
    if Avo.plugin_manager.installed?("avo-dashboards")
      render Avo::CardsComponent.new cards: @resource.detect_cards.visible_cards, classes: "pb-4 sm:grid-cols-3"
    end
  end

  private

  def via_resource?
    (params[:via_resource_class].present? || params[:via_relation_class].present?) && params[:via_record_id].present?
  end

  def keep_referrer_params
    referrer_params
  end

  def render_back_button(control)
    return if back_path.blank? || is_a_related_resource?

    via_belongs_to = params[:via_belongs_to_resource_class].present?

    a_link via_belongs_to ? "javascript:void(0);" : back_path,
      style: :text,
      title: control.title,
      data: {
        tippy: control.title ? :tooltip : nil,
        action: via_belongs_to ? "click->modal#close" : nil
      }.compact,
      icon: "heroicons/outline/arrow-left" do
      control.label
    end
  end

  def render_actions_list(actions_list)
    return unless can_see_the_actions_button?

    render Avo::ActionsComponent.new(
      actions: @actions,
      resource: @resource,
      view: @view,
      exclude: actions_list.exclude,
      include: actions_list.include,
      style: actions_list.style,
      color: actions_list.color,
      label: actions_list.label,
      size: actions_list.size,
      icon: actions_list.icon,
      icon_class: actions_list.icon_class,
      title: actions_list.title,
      as_row_control: instance_of?(Avo::Index::ResourceControlsComponent)
    )
  end

  def render_delete_button(control)
    # If the resource is a related resource, we use the can_delete? policy method because it uses
    # authorize_association_for(:destroy).
    # Otherwise we use the can_see_the_destroy_button? policy method because it do no check for association
    # only for authorize_action .
    policy_method = is_a_related_resource? ? :can_delete? : :can_see_the_destroy_button?
    return unless send policy_method

    a_link destroy_path,
      style: :text,
      color: :red,
      icon: "avo/trash",
      form_class: "flex flex-col sm:flex-row sm:inline-flex",
      title: control.title,
      aria_label: control.title,
      data: {
        turbo_confirm: t("avo.are_you_sure", item: @resource.record.model_name.name.downcase),
        turbo_method: :delete,
        target: "control:destroy",
        control: :destroy,
        tippy: control.title ? :tooltip : nil,
        "resource-id": @resource.record_param,
      } do
      control.label
    end
  end

  def render_save_button(control)
    return unless can_see_the_save_button?

    data_attributes = {
      turbo_confirm: @resource.confirm_on_save ? t("avo.are_you_sure") : nil
    }

    add_stimulus_attributes_for(@resource, data_attributes, "saveButton")

    a_button color: :primary,
      style: :primary,
      loading: true,
      type: :submit,
      icon: "avo/save",
      data: data_attributes do
      control.label
    end
  end

  def render_edit_button(control)
    return unless can_see_the_edit_button?

    a_link edit_path,
      color: :primary,
      style: :primary,
      title: control.title,
      data: {tippy: control.title ? :tooltip : nil},
      icon: "avo/edit" do
      control.label
    end
  end

  def render_detach_button(control)
    return unless is_a_related_resource? && can_detach?

    a_link detach_path,
      icon: "avo/detach",
      form_class: "flex flex-col sm:flex-row sm:inline-flex",
      style: :text,
      data: {
        turbo_method: :delete,
        turbo_confirm: "Are you sure you want to detach this #{title}."
      } do
      control.label || t("avo.detach_item", item: title).humanize
    end
  end

  def render_create_button(control)
    return unless can_see_the_create_button?

    a_link create_path,
      color: :primary,
      style: :primary,
      icon: "heroicons/outline/plus",
      data: {
        target: :create
      } do
      control.label
    end
  end

  def render_attach_button(control)
    return unless can_attach?

    a_link attach_path,
      icon: "heroicons/outline/link",
      color: :primary,
      style: :text,
      data: {
        turbo_frame: Avo::MODAL_FRAME_ID,
        target: :attach
      } do
      control.label
    end
  end

  def render_link_to(link)
    a_link link.path,
      color: link.color,
      style: link.style,
      icon: link.icon,
      icon_class: link.icon_class,
      title: link.title, target: link.target,
      class: link.classes,
      size: link.size,
      data: {
        **link.data,
        tippy: link.title ? :tooltip : nil,
      } do
      link.label
    end
  end

  def render_action(action)
    return if !can_see_the_actions_button?
    return if !action.action.visible_in_view(parent_resource: @parent_resource)

    a_link action.path,
      color: action.color,
      style: action.style,
      icon: action.icon,
      icon_class: action.icon_class,
      title: action.title,
      size: action.size,
      data: {
        controller: "actions-picker",
        turbo_frame: Avo::MODAL_FRAME_ID,
        action_name: action.action.action_name,
        tippy: action.title ? :tooltip : nil,
        action: "click->actions-picker#visitAction",
        turbo_prefetch: false,
        # When action has record present behave as standalone and keep always active.
        "actions-picker-target": (action.action.standalone || action.action.record.present?) ? "standaloneAction" : "resourceAction",
        disabled: action.action.disabled?,
        resource_name: action.action.resource.model_key
      } do
      action.label
    end
  end

  def is_a_related_resource?
    @reflection.present? && @resource.record.present?
  end

  def inverse_of
    current_reflection = @reflection.active_record.reflect_on_all_associations.find do |reflection|
      reflection.name == @reflection.name.to_sym
    end

    inverse_of = current_reflection.inverse_of

    if inverse_of.blank? && Rails.env.development?
      puts "WARNING! Avo uses the 'inverse_of' option to determine the inverse association and figure out if the association permit or not detaching."
      # Ex: Please configure the 'inverse_of' option for the ':users' association on the 'Project' model.
      puts "Please configure the 'inverse_of' option for the '#{current_reflection.macro} :#{current_reflection.name}' association on the '#{current_reflection.active_record.name}' model."
      puts "Otherwise the detach button will be visible by default.\n\n"
    end

    inverse_of
  end
end
