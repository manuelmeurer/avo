module Avo
  module TurboStreamActionsHelper
    def avo_download(content:, filename:)
      turbo_stream_action_tag :download, content: content, filename: filename
    end

    def avo_flash_alerts
      turbo_stream_action_tag :append,
        target: "alerts",
        template: @view_context.render(Avo::FlashAlertsComponent.new(flashes: @view_context.flash.discard))
    end

    def avo_close_modal
      turbo_stream_action_tag :replace,
        target: Avo::MODAL_FRAME_ID,
        template: @view_context.turbo_frame_tag(Avo::MODAL_FRAME_ID)
    end

    def avo_turbo_reload
      turbo_stream_action_tag :turbo_reload
    end
  end
end

